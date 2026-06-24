# Lab 0: Deploy Your Incident Lab Stack

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 0 — Deploy Your Incident Lab Stack |
| **Duration** | 30 minutes |
| **Difficulty** | Foundational (setup) |
| **Prerequisites** | Access to the training AWS account; AWS CLI v2, `kubectl`, `terraform`, `jq`, and `git` configured on your workstation, CloudShell, or the provided lab host |
| **Builds On** | None — this lab provisions the single connected application and the red/green incident board that every later lab diagnoses and repairs. |

---

## Lab Overview

Every incident lab in IO-108 runs against **one connected application** that you deploy and own. There is no separate sandbox per lab — you stand the application up once here in Lab 0, and from Lab 1 onward you break, diagnose, and repair pieces of *this same* stack.

The application is a small but realistic order-processing system:

- An **orders API** running as pods on **Amazon EKS** (namespace `orders`, ServiceAccount `orders-api` using IRSA for AWS access)
- An **Aurora PostgreSQL** cluster the API reads and writes
- A **report generator** built on **AWS Lambda + Step Functions** that runs on a schedule and writes JSON reports to **Amazon S3**
- A **CloudWatch red/green incident board** — a per-student dashboard where each connectivity or health check is a tile: **green = healthy, red = broken**

A background **health-checker Lambda** runs a set of probes about once a minute and publishes a `1` (healthy) or `0` (broken) custom metric per check. Each metric drives a CloudWatch alarm, and each alarm renders as one tile on your board. This board is your map for the whole day: **here are the broken things — use the tools to diagnose and fix them, watch the tiles go green.**

> **A note on the network layer.** This lab uses native AWS networking (and AWS Transit Gateway where transit appears). In your environment the hub-and-spoke transit is **Aviatrix**, managed by the network team — the concepts map directly; the management plane differs. Throughout IO-108, wherever you see a route table, NAT path, or transit hop, that is the AWS stand-in for an Aviatrix-managed path you would diagnose with Aviatrix flow metrics in production.

---

## Scenario

You are an engineer on SYF's Technology Operations team. A new order-processing service has just been handed to Operations to run. Before you can respond to incidents on it, you need the service deployed in your training account and a working **health board** so you can see, at a glance, what is up and what is down.

This lab is not an incident — it is the **baseline capture**. But the board you build here is exactly the board you will triage against for the rest of the course. From Lab 1 on, every red tile is a live incident: you will assign it a severity on the **P0–P4** scale and log it in **ServiceNow**, just as you would on the job. Lab 0 establishes "normal" so you can recognize "abnormal" the moment it appears.

---

## Learning Objectives

By the end of this lab, you will:

- Deploy the connected application (Amazon EKS orders API → Aurora → Lambda/Step Functions reporting) into your own training account with a single `terraform apply`.
- Deploy the workload onto your EKS cluster with `deploy_app.sh` and confirm the application responds and reports are flowing.
- Open and read your **red/green incident board**, understanding what each tile measures and how the health-checker publishes it.
- Capture a clean **baseline** and recognize which tiles are *intentionally* red from day one because of the security through-line.

---

## Task 1: Set Your Identifiers and Confirm Prerequisites

1. **Open** a terminal on your lab host (workstation, AWS CloudShell, or the provided EC2 lab box) with the AWS CLI configured for the training account.

2. **Set** two shell variables you will reuse all day. Replace `sNN` with the student id your instructor assigned (for example `s07`):

    ```bash
    export SID=sNN
    export REGION=us-east-1
    ```

    Your `student_id` must be lowercase alphanumeric, 2–12 characters. Every resource you own is named `io108-$SID-...`, so this prefix is how you find your stack among the cohort's.

3. **Confirm** your tools are present:

    ```bash
    aws --version          # AWS CLI v2.x
    terraform version      # 1.5+
    kubectl version --client
    jq --version
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

> **Expected Result:** Each command prints a version. If `aws sts get-caller-identity` returns your training identity, you are authenticated to the right account.

---

## Task 2: Provision the Stack with Terraform

4. **Change** into the student lab environment directory:

    ```bash
    cd lab_environment/lab_env_student
    ```

5. **Copy** the example variables file and set your `student_id`:

    ```bash
    cp terraform.tfvars.example terraform.tfvars
    # edit terraform.tfvars: set student_id = "sNN" (your id) and region
    ```

6. **Initialize** Terraform, then **apply** the **healthy** baseline. The `scenario` variable defaults to `healthy`, so no fault is injected — this is the green starting point:

    ```bash
    terraform init
    terraform apply -var student_id=$SID -var scenario=healthy
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

    Review the plan and type **yes** to confirm. This provisions your VPC (public/private subnets, NAT), the EKS cluster and managed node group, the Aurora cluster, the reporting Lambda and Step Functions workflow, the S3 report and sink buckets, the health-checker Lambda, the alarms, and **both** CloudWatch dashboards.

> **Expected Result:** `terraform apply` completes with `Apply complete!` and a block of outputs. EKS cluster creation is the long pole — the full apply typically takes **15–20 minutes**. The final output `next_step` tells you exactly what to run next.

> **A note on the network layer.** The VPC, route tables, and NAT gateway Terraform just created are the AWS-native stand-in for the Aviatrix-managed hub-and-spoke transit in your production environment. The diagnostic *concepts* (route tables, egress paths, reachability) are identical; only the management plane (Aviatrix controller vs. AWS console) differs.

---

## Task 3: Capture Your Stack Outputs

7. **Capture** the Terraform outputs you will reference in later labs. These are read straight from `terraform output`, so they always match your real resource names:

    ```bash
    export CLUSTER=$(terraform output -raw cluster_name)
    export DASHBOARD=$(terraform output -raw incident_board_dashboard_name)
    export REPORTS_BUCKET=$(terraform output -raw reports_bucket)
    export IRSA_ROLE=$(terraform output -raw irsa_role_arn)
    export ROGUE_ID=$(terraform output -raw rogue_instance_id)

    echo "Cluster:   $CLUSTER"
    echo "Board:     $DASHBOARD"
    echo "Reports:   $REPORTS_BUCKET"
    echo "IRSA role: $IRSA_ROLE"
    echo "Rogue id:  $ROGUE_ID"
    ```

> **Expected Result:** `Cluster` reads `io108-$SID-eks`, `Board` reads `io108-$SID-incident-board`, and the rogue instance id is an `i-...` value. If any variable is empty, re-run the `terraform output` for it from inside `lab_env_student/`.

> **Why a rogue id already?** Your stack ships with a **rogue EC2 instance** (`io108-$SID-rogue`) and a tagged **rogue IAM principal** (`io108-$SID-rogue-actor`) already present in the environment. This is the security through-line of the course. You will hunt and contain it starting in Lab 1 — for now, just note that it exists.

---

## Task 4: Deploy the Application onto EKS

8. **Run** the deploy script. It updates your kubeconfig, copies the app code into the Helm chart, and installs the `orders` release into the `orders` namespace:

    ```bash
    ./deploy_app.sh $SID $REGION
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

9. **Watch** the output. The script waits for the `orders-api` Deployment to roll out (the app does a short dependency install at startup, so allow a minute), then runs an in-cluster smoke test against `/health`.

> **Expected Result:** The script prints `==> Smoke test: GET /health from inside the cluster` followed by a JSON body containing `"status": "ok"`. It finishes with `Deploy complete.` and the next-step hints. Because you deployed the `healthy` scenario, the rollout succeeds.

---

## Task 5: Verify the Baseline

10. **Run** the verification script. It checks every component of the stack and prints `PASS`/`FAIL` per item:

    ```bash
    ./verify.sh
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

11. **Read** the results. The script confirms: all EKS nodes `Ready`, all `orders` pods `Running`, `/health` reports `ok` (database connected), the Aurora cluster `available`, the latest Step Functions report execution `SUCCEEDED` or `RUNNING`, a report object present in S3, and the dashboard exists.

> **Expected Result:** `ALL CHECKS PASSED -- your stack is healthy. Capture this baseline for Lab 0.`
>
> The first report lands within **one schedule period (default 5 minutes)**. If the Step Functions / S3 report checks fail on the very first run, wait one period and re-run `./verify.sh` — those two are timing-dependent, not broken.

---

## Task 6: Open and Read Your Incident Board

12. **Open** the AWS Management Console, go to **CloudWatch → Dashboards**, and open **`io108-$SID-incident-board`** (the value in `$DASHBOARD`).

13. **Study** the layout. The board is organized into bands, one per lab, each a row of **alarm-status tiles**:

    | Band | Tiles |
    |------|-------|
    | **Lab 1 — IAM Access Denial and Rogue Hunt** | `orders-api DB access (IRSA)`, `Rogue contained` |
    | **Lab 2 — EKS Pod Failure and Connectivity** | `EKS pods schedulable`, `Pod → internet`, `Pod → DNS` |
    | **Lab 3 — Lambda and Step Functions Performance** | `Reports flowing`, `Sink: NewRelic`, `Sink: SolarWinds` |
    | **Lab 4 — Aurora Failover and Connectivity** | `Aurora reachable`, `Aurora writable`, `Aurora: no rogue sessions` |
    | **Lab 5 — Capstone (Network)** | `Partner path reachable`, `Network path OK` |

    Each tile is **green when its probe reports healthy** and **red when the probe reports broken** (or stops publishing). The probes run about every minute, so the board reflects reality with roughly a one-minute lag.

14. **Note** which tiles are red *even in the healthy baseline*. These are the **security through-line** tiles:

    - **`Rogue contained`** — RED, because the rogue instance is running and reachable. You contain it in **Lab 1**.
    - **`Aurora: no rogue sessions`** — RED, because the rogue opens a benign Postgres session to Aurora about once a minute. You lock it out in **Lab 4**.

    Some Lab 3 fan-out sink tiles may also take a couple of minutes to first go green while the distribution heartbeat warms up.

> **Expected Result:** Almost every tile is green, **except** `Rogue contained` and `Aurora: no rogue sessions`, which are intentionally red. This is your baseline: a healthy application with a known, unaddressed intruder already inside the environment.

> **The through-line, stated plainly.** The rogue is not a Lab 0 bug — it is the adversary you work against all day. Treating those two red tiles as "known and tracked" (rather than "broken setup") is exactly the triage judgement Operations makes when a board lights up: which reds are *new incidents* and which are *known issues already in the queue*.

---

## Knowledge Check

**Question 1:** Your board shows every tile green except `Rogue contained` and `Aurora: no rogue sessions`. A teammate says "the deploy is broken, two checks are red." Are they right? Explain what those two tiles actually mean.

**Answer:** No — the deploy is healthy. Those two tiles are the **security through-line**: a rogue EC2 instance (`io108-$SID-rogue`) and its tagged IAM principal are deliberately present in the environment from the first apply. `Rogue contained` is red because the instance is still running and reachable; `Aurora: no rogue sessions` is red because the rogue opens a benign Postgres session to Aurora about once a minute. Both are *known issues* you address later (Lab 1 contains the instance, Lab 4 locks it out of Aurora), not deployment failures.

**Question 2:** How does a single check on the board turn from green to red, mechanically — from probe to tile?

**Answer:** The health-checker Lambda runs on an EventBridge schedule (about every minute), executes each probe, and publishes a custom CloudWatch metric in the `IO108/Health` namespace — `1` for healthy or `0` for broken — dimensioned by `Student`. Each probe has a CloudWatch alarm that enters `ALARM` when the metric drops below `1` (or stops publishing, since missing data is treated as breaching). Each alarm renders as one alarm-status tile on the board, which shows red in `ALARM` and green in `OK`.

**Question 3:** The first `./verify.sh` run reported `FAIL` on the Step Functions report execution and the S3 report object, but everything else passed. What is the most likely explanation and the correct response?

**Answer:** Those two checks are timing-dependent. The report workflow runs on a schedule (default `rate(5 minutes)`), so on a freshly applied stack the first execution and first S3 report object may not exist yet. The correct response is to wait one schedule period and re-run `./verify.sh` — not to start tearing down the stack. (This is itself a triage lesson: distinguish "not yet" from "broken.")

---

## Lab Summary

You deployed the one connected application IO-108 is built around — EKS orders API, Aurora, and the Lambda/Step Functions reporting pipeline — with a single `terraform apply`, then installed the workload with `deploy_app.sh` and verified it end-to-end. You opened your **red/green incident board** and learned to read it: green is healthy, red is broken, probes refresh about once a minute. Critically, you established the **baseline** and identified the two tiles that are red *by design* — the rogue through-line you will pursue across Labs 1 and 4.

From here on, every red tile that appears is an **incident**: you will give it a P0–P4 severity, log it in ServiceNow, diagnose it with the AWS-native tools, fix it, and watch the tile go green.

## Completion Checklist

- [ ] `terraform apply -var student_id=$SID -var scenario=healthy` completed with `Apply complete!`
- [ ] Stack outputs captured (`cluster_name`, `incident_board_dashboard_name`, `reports_bucket`, `irsa_role_arn`, `rogue_instance_id`)
- [ ] `./deploy_app.sh` smoke test returned `"status": "ok"`
- [ ] `./verify.sh` printed `ALL CHECKS PASSED` (after waiting one schedule period if needed)
- [ ] Incident board `io108-$SID-incident-board` open and read band-by-band
- [ ] Confirmed `Rogue contained` and `Aurora: no rogue sessions` are the only intentionally-red tiles

---

## Next Steps

In **Lab 1: IAM Access Denial Investigation and Rogue Hunt**, the `orders-api DB access (IRSA)` tile goes red: the orders API can no longer read its database credentials. You will diagnose the AccessDenied from the pod logs, trace it to a stripped IAM permission, restore access, and then begin the rogue hunt with CloudTrail and AWS Config — containing the instance so `Rogue contained` finally turns green.
