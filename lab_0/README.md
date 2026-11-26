# Lab 0: Deploy Your Incident Lab Stack

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 0 — Deploy Your Incident Lab Stack |
| **Duration** | 30 minutes |
| **Difficulty** | Foundational (setup) |
| **Prerequisites** | Access to the training AWS account and your EC2 **lab host** (it has AWS CLI v2, `terraform`, `kubectl`, `helm`, `jq`, `git` and this repo at `~/io-108` already installed) |
| **Builds On** | None — this lab provisions the single connected application and the red/green incident board that every later lab diagnoses and repairs. |

---

## Lab Overview

> **Most students: your instructor has already run this lab for you.** Do **not** run any command in Tasks 1–5. Go to **Lab 1, "Start Here"** to connect to your lab host, and come back here only to read **Task 6** (how to read your incident board). Running these build steps against a stack that already exists can create a second copy of it.
>
> Tasks 1–5 are for the instructor, or for a self-paced student whose stack has **not** been built yet.

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

## Task 1: Connect, Set Your Identifiers and Confirm Prerequisites

1. **Connect** to your lab host. In the AWS console, check that the region selector at the top right shows your assigned region, then open **Systems Manager → Session Manager → Start session**. Select **`io108-<your-id>-lab-host`** and choose **Start session**. A browser terminal opens showing a `sh-5.2$` prompt. Then switch to the user that owns the lab files (do this every time you connect):

    ```bash
    sudo su - ec2-user
    ```

    The prompt changes to `[ec2-user@ip-... ~]$`. If it still shows `sh-5.2$`, run the command again. Run **every** command in this course here, on the lab host, as `ec2-user`: your cluster only accepts `kubectl` from the identity that last ran `terraform apply`.

2. **Set** your student id and region, verify them, then save them so they survive a reconnect.

    Set the two values:

    ```bash
    export SID=userNN             # <- your assigned student id, e.g. user01
    export REGION=us-east-1       # <- your assigned region
    ```

    **Verify** them before saving:

    ```bash
    echo "SID=$SID REGION=$REGION"
    ```

    You should see your own id and region, for example `SID=user01 REGION=us-east-1`. If either value is blank or still reads `userNN`, re-run the `export` lines above with the correct values. Do not continue until the output is right. (Your `student_id` must be lowercase letters and digits, 2–12 characters. Every resource you own is named `io108-$SID-...`, so this prefix is how you find your stack among the cohort's.)

    **Save** them to `~/.bashrc` only after they check out. The second line also stops the AWS CLI from opening long output in a pager:

    ```bash
    echo "export SID=$SID REGION=$REGION" >> ~/.bashrc
    echo 'export AWS_PAGER=""' >> ~/.bashrc && export AWS_PAGER=""
    ```

3. **Confirm** your tools are present and that you are signed in to the training account:

    ```bash
    aws --version          # AWS CLI v2.x
    terraform version      # 1.10+
    kubectl version --client
    helm version --short
    jq --version
    aws sts get-caller-identity
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

> **Expected Result:** Each tool prints a version line (`aws-cli/2...`, `Terraform v1...`, `Client Version: v1...`, `v4...`, `jq-1...`). `aws sts get-caller-identity` prints a short JSON block whose `Arn` contains `lab-host-role`. If any command prints `command not found` or an error, stop and tell your instructor.

> **Reconnecting later?** Sessions time out when idle, and a new session forgets every shell variable except `SID`, `REGION` and `AWS_PAGER` (saved in step 2). Start a new session, run `sudo su - ec2-user`, then `cd ~/io-108/lab_environment/lab_env_student`. If you are in the middle of Task 2, re-run the `STATE_BUCKET=...` lines from step 4; if you are past Task 3, re-run the step 9 `export` block. Do not repeat step 2.

---

## Task 2: Provision the Stack with Terraform

4. **Check** that your stack has **not** already been built. **Do not run Terraform yet.** Terraform builds whatever its state file says is missing, so if a stack already exists under a different state key, or your id is wrong, it will build a second copy of the whole stack. This read-only check looks for your state file:

    ```bash
    STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 \
      --name /io108/tfstate-bucket --query Parameter.Value --output text)
    echo "State bucket: $STATE_BUCKET"
    aws s3api head-object --bucket "$STATE_BUCKET" --key "io108/$SID/terraform.tfstate" \
      --query '[LastModified,ContentLength]' --output text
    ```

    > **Expected Result:** The first line reads `State bucket: io108-tfstate-...`. For a stack that has not been built yet, the second command prints **`An error occurred (404) when calling the HeadObject operation: Not Found`**. That error is what you want here: no state file means no stack yet.
    >
    > - **If the second command prints a date and a size** (e.g. `2026-11-25T16:58:00+00:00  412345`), **your stack was already built for you. Stop: do not run the rest of this lab.** Go to **Lab 1, Start Here**.
    > - **If `State bucket:` is followed by nothing, or you see `ParameterNotFound` or `Invalid bucket name`,** stop and tell your instructor.

5. **Point** Terraform at your stack. These commands write your id and region into `terraform.tfvars`, the file Terraform reads them from, so every later command is just `-var scenario=...`:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    cp terraform.tfvars.example terraform.tfvars
    sed -i "s/^student_id.*/student_id = \"$SID\"/; s/^region.*/region = \"$REGION\"/" terraform.tfvars
    grep -E '^(student_id|region)' terraform.tfvars
    ```

    **Verify** the `grep` output shows **your** id and region, for example:

    ```
    student_id = "user01"
    region = "us-east-1"
    ```

    If either line is wrong, go back to step 2.

6. **Initialize** Terraform against your remote state. Your state lives in the shared S3 bucket from step 4, under your own key. This downloads Terraform's plugins (about 30 seconds):

    ```bash
    terraform init -backend-config="bucket=$STATE_BUCKET" \
      -backend-config="key=io108/$SID/terraform.tfstate"
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

    > **Expected Result:** `terraform init` ends with a green **`Terraform has been successfully initialized!`**. If it complains that the bucket is empty or missing (for example after a reconnect), re-run the first two lines of step 4, then this command.

7. **Preview** the build. This command changes nothing; it only shows the plan. Run it on its own:

    ```bash
    terraform plan -var scenario=healthy
    ```

    Terraform ends the plan with `Note: You didn't use the -out option to save this plan...`. That note is normal after every `terraform plan`; ignore it.

    It takes about a minute and ends with a `Plan:` line. **Check it.** For a fresh build it reads about **`Plan: 126 to add, 0 to change, 0 to destroy.`** (the exact add count can differ by a few as the course is updated). The key check is **`0 to change, 0 to destroy`**.

    - **If it matches,** go on to step 8.
    - **If it shows anything to change or destroy, stop** and tell your instructor. A stack already exists in this state, and applying would modify it.

8. **Apply** the **healthy** baseline. The `scenario` variable selects which incident (if any) is injected; `healthy` is the green starting point. Run:

    ```bash
    terraform apply -var scenario=healthy
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

    Terraform prints the same plan again and stops at a confirmation prompt:

    ```
    Plan: 126 to add, 0 to change, 0 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    - **If the `Plan:` line matches your preview in step 7,** type **`yes`** and press **Enter**. Terraform will not continue until you do, and anything other than `yes` cancels.
    - **If it differs,** type **`no`** and press **Enter**, then tell your instructor.

    This provisions your VPC (public/private subnets, NAT), the EKS cluster and managed node group, the Aurora cluster, the reporting Lambda and Step Functions workflow, the S3 report and sink buckets, the health-checker Lambda, the alarms, and **both** CloudWatch dashboards. EKS cluster creation is the long pole: the full apply typically takes **15–20 minutes**, printing `Still creating...` lines as it goes.

    > **Keep the session open.** Do not close the Session Manager tab or let your laptop sleep during the apply. If the session drops anyway, reconnect (see the Reconnecting note in Task 1), `cd ~/io-108/lab_environment/lab_env_student`, and run `terraform apply -var scenario=healthy` again: Terraform picks up where it stopped, so this time the plan shows fewer resources to add (still `0 to destroy`). If it fails with `Error acquiring the state lock`, tell your instructor.

> **Expected Result:** Terraform prints **`Apply complete! Resources: 126 added, 0 changed, 0 destroyed.`** (the same number the plan showed) followed by a block of outputs, and you are returned to the `$` prompt. The final output, `next_step`, tells you exactly what to run next (`./deploy_app.sh <your-id> <your-region>`). If the apply ends with a red `Error:` instead, run the same `terraform apply` command once more; if the same error repeats, copy it and tell your instructor.

> **A note on the network layer.** The VPC, route tables, and NAT gateway Terraform just created are the AWS-native stand-in for the Aviatrix-managed hub-and-spoke transit in your production environment. The diagnostic *concepts* (route tables, egress paths, reachability) are identical; only the management plane (Aviatrix controller vs. AWS console) differs.

---

## Task 3: Capture Your Stack Outputs

9. **Capture** the Terraform outputs you will reference in later labs. These are read straight from `terraform output`, so they always match your real resource names. Run them from the Terraform directory:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
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

> **Expected Result:** Five lines, for example `Cluster:   io108-user01-eks`, `Board:     io108-user01-incident-board`, `Reports:   io108-user01-reports-...`, `IRSA role: arn:aws:iam::...:role/io108-user01-orders-api-role` and `Rogue id:  i-0...`. If any value is empty, check you are in `~/io-108/lab_environment/lab_env_student` and run that line's command on its own (for example `terraform output -raw cluster_name`). If it says `No outputs found`, Terraform is pointed at the wrong state: redo steps 4–6.

> **Why a rogue id already?** Your stack ships with a **rogue EC2 instance** (`io108-$SID-rogue`) and a tagged **rogue IAM principal** (`io108-$SID-rogue-actor`) already present in the environment. This is the security through-line of the course. You will hunt and contain it starting in Lab 1 — for now, just note that it exists.

---

## Task 4: Deploy the Application onto EKS

10. **Run** the deploy script from the same directory. It updates your kubeconfig (so `kubectl` talks to your cluster), copies the app code into the Helm chart, and installs the `orders` release into the `orders` namespace:

    ```bash
    ./deploy_app.sh $SID $REGION
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

11. **Watch** the output. It takes about **3–5 minutes** and ends on its own; you do not need to press anything. Progress lines start with `==>`. The longest wait is `==> Waiting for orders-api rollout`: each app pod installs its dependencies at startup, and the script waits up to 5 minutes for them. It then runs an in-cluster smoke test against `/health`.

> **Expected Result:** The rollout wait prints `deployment "orders-api" successfully rolled out`. After `==> Smoke test: GET /health from inside the cluster` you see `{"database":"connected","status":"ok"}`, then `pod "curl-test" deleted`. The script finishes with `Deploy complete. Next steps:` and returns you to the `$` prompt.
>
> If you see `WARNING: orders-api is not Ready`, or the smoke test prints an error instead of the JSON line, wait 2 minutes and run `./deploy_app.sh $SID $REGION` again. If it fails a second time, tell your instructor.

---

## Task 5: Verify the Baseline

12. **Run** the verification script from the same directory. It checks every component of the stack and prints one `PASS:` or `FAIL:` line per check. It takes about **30–60 seconds**:

    ```bash
    ./verify.sh
    ```
    <!-- source: course_outline_v3.md §"Lab 0" -->

13. **Read** the results. The seven checks are, in order: all EKS nodes `Ready`, the `orders` pods healthy, `/health` reports `ok` (database connected), the Aurora cluster `available`, the latest Step Functions report execution `SUCCEEDED` or `RUNNING`, a report object present in S3, and the dashboard exists.

> **Expected Result:** Seven `PASS:` lines, ending with **`ALL CHECKS PASSED -- your stack is healthy. Capture this baseline for Lab 0.`**
>
> The first report lands within **one schedule period (default 5 minutes)**. If only the report workflow and/or S3 report checks show `FAIL:` on the very first run, wait 5 minutes and re-run `./verify.sh` — those two are timing-dependent, not broken. Report runs that started before `deploy_app.sh` show as `FAILED` with `relation "orders" does not exist`, because the app creates that table; the next scheduled run succeeds. If any **other** check shows `FAIL:`, or the report checks still fail after 10 minutes, copy the output and tell your instructor.

---

## Task 6: Open and Read Your Incident Board

14. **Open** your board. In the AWS console, check that the region selector at the top right shows your assigned region. Type **CloudWatch** in the search bar at the top and open it. In the left menu choose **Dashboards**, then open **`io108-<your-id>-incident-board`** (for example `io108-user01-incident-board`). Do **not** open `io108-<your-id>-incident-dashboard`; that is a different dashboard. To see the latest state, click the refresh button (circular arrow) at the top right of the dashboard.

15. **Study** the layout. The board is organized into bands, one per lab, each a row of **alarm-status tiles**:

    | Band | Tiles |
    |------|-------|
    | **Lab 1 — IAM Access Denial and Rogue Hunt** | `orders-api DB access (IRSA)`, `Rogue contained` |
    | **Lab 2 — EKS Pod Failure and Connectivity** | `EKS pods schedulable`, `Pod -> internet`, `Pod -> DNS` |
    | **Lab 3 — Lambda and Step Functions Performance + Event Fan-out** | `Reports flowing`, `Sink: NewRelic (fan-out)`, `Sink: SolarWinds (fan-out)` |
    | **Lab 4 — Aurora Failover and Connectivity** | `Aurora reachable`, `Aurora writable (writer endpoint)`, `Aurora: no rogue sessions` |
    | **Lab 5 — Capstone (Network)** | `Partner path reachable`, `Network path OK` |

    Each tile is **green when its probe reports healthy** and **red when the probe reports broken** (or stops publishing). The probes run about every minute, so the board reflects reality with roughly a one-minute lag.

16. **Note** which tiles are red *even in the healthy baseline*. These are the **security through-line** tiles:

    - **`Rogue contained`** — RED, because the rogue instance is running and reachable. You contain it in **Lab 1**.
    - **`Aurora: no rogue sessions`** — RED, because the rogue holds a benign Postgres session open to Aurora. You lock it out in **Lab 4**.

    Some Lab 3 fan-out sink tiles may also take a couple of minutes to first go green while the distribution heartbeat warms up.

> **Expected Result:** Almost every tile is green, **except** `Rogue contained` and `Aurora: no rogue sessions`, which are intentionally red. This is your baseline: a healthy application with a known, unaddressed intruder already inside the environment.

> **The through-line, stated plainly.** The rogue is not a Lab 0 bug — it is the adversary you work against all day. Treating those two red tiles as "known and tracked" (rather than "broken setup") is exactly the triage judgement Operations makes when a board lights up: which reds are *new incidents* and which are *known issues already in the queue*.

---

## Knowledge Check

**Question 1:** Your board shows every tile green except `Rogue contained` and `Aurora: no rogue sessions`. A teammate says "the deploy is broken, two checks are red." Are they right? Explain what those two tiles actually mean.

**Answer:** No — the deploy is healthy. Those two tiles are the **security through-line**: a rogue EC2 instance (`io108-$SID-rogue`) and its tagged IAM principal are deliberately present in the environment from the first apply. `Rogue contained` is red because the instance is still running and reachable; `Aurora: no rogue sessions` is red because the rogue holds a benign Postgres session open to Aurora. Both are *known issues* you address later (Lab 1 contains the instance, Lab 4 locks it out of Aurora), not deployment failures.

**Question 2:** How does a single check on the board turn from green to red, mechanically — from probe to tile?

**Answer:** The health-checker Lambda runs on an EventBridge schedule (about every minute), executes each probe, and publishes a custom CloudWatch metric in the `IO108/Health` namespace — `1` for healthy or `0` for broken — dimensioned by `Student`. Each probe has a CloudWatch alarm that enters `ALARM` when the metric drops below `1` (or stops publishing, since missing data is treated as breaching). Each alarm renders as one alarm-status tile on the board, which shows red in `ALARM` and green in `OK`.

**Question 3:** The first `./verify.sh` run reported `FAIL` on the Step Functions report execution and the S3 report object, but everything else passed. What is the most likely explanation and the correct response?

**Answer:** Those two checks are timing-dependent. The report workflow runs on a schedule (default `rate(5 minutes)`), so on a freshly applied stack the first execution and first S3 report object may not exist yet. The correct response is to wait one schedule period and re-run `./verify.sh` — not to start tearing down the stack. (This is itself a triage lesson: distinguish "not yet" from "broken.")

---

## Lab Summary

You deployed the one connected application IO-108 is built around — EKS orders API, Aurora, and the Lambda/Step Functions reporting pipeline — with a single `terraform apply`, then installed the workload with `deploy_app.sh` and verified it end-to-end. You opened your **red/green incident board** and learned to read it: green is healthy, red is broken, probes refresh about once a minute. Critically, you established the **baseline** and identified the two tiles that are red *by design* — the rogue through-line you will pursue across Labs 1 and 4.

From here on, every red tile that appears is an **incident**: you will give it a P0–P4 severity, log it in ServiceNow, diagnose it with the AWS-native tools, fix it, and watch the tile go green.

## Completion Checklist

- [ ] `terraform apply -var scenario=healthy` completed with `Apply complete!`
- [ ] Stack outputs captured (`cluster_name`, `incident_board_dashboard_name`, `reports_bucket`, `irsa_role_arn`, `rogue_instance_id`)
- [ ] `./deploy_app.sh` smoke test returned `{"database":"connected","status":"ok"}`
- [ ] `./verify.sh` printed `ALL CHECKS PASSED` (after waiting one schedule period if needed)
- [ ] Incident board `io108-$SID-incident-board` open and read band-by-band
- [ ] Confirmed `Rogue contained` and `Aurora: no rogue sessions` are the only intentionally-red tiles

---

## Next Steps

**Do not run `terraform destroy`.** Every later lab uses this same stack, and your instructor tears it down at the end of the course.

In **Lab 1: IAM Access Denial Investigation and Rogue Hunt**, the `orders-api DB access (IRSA)` tile goes red: the orders API can no longer read its database credentials. You will diagnose the AccessDenied from the pod logs, trace it to a stripped IAM permission, restore access, and then begin the rogue hunt with CloudTrail and AWS Config — containing the instance so `Rogue contained` finally turns green.
