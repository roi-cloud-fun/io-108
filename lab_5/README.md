# Lab 5: Multi-Layered Incident Simulation — Capstone

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 5 - Multi-Layered Incident Simulation (Capstone) |
| **Duration** | 60 minutes |
| **Difficulty** | Advanced |
| **Severity (this incident)** | **P0** at declaration (multiple systems impaired, customer-facing); managed down to **P1**/**P2** as each layer is restored |
| **Incident platform** | ServiceNow (declare the major incident, set Priority = P0, run the timeline, write the post-incident report) |
| **Prerequisites** | Labs 1-4 completed; AWS CLI v2, `kubectl`, `jq`; access to your `io108-<id>-incident-board`, VPC console, and CloudWatch Logs |
| **Builds On** | Everything. The capstone composes the IAM break (Lab 1), a pod-network deny, a new network misroute, and the still-present rogue (Labs 1/4) into one compound incident. You reuse every tool from Labs 1-4 and add network-path analysis. |

---

## Lab Overview

It is 09:00 and the board is on fire. Multiple tiles are red at once: customers are reporting failed orders, a partner integration is unreachable, and internal checks are failing. You are the incident lead. There is no single root cause — this is a **compound incident**, and your job is to **clear the whole board**.

This capstone tests the methodology the whole course has been building toward:

1. **Lead with the incident board** as your map — it tells you *which* systems are impaired before you touch a log.
2. **Triage in the right order** — stabilize the broad network path, then work each domain.
3. **Use the right tool per layer** — VPC Flow Logs and Reachability Analyzer for the network; the per-domain tools from Labs 1-4 for IAM, pods, DB, and the rogue.
4. **Optionally stand up an open-source packet-analysis box** and compare it against the AWS-native tools — learning *when* each is worth it.
5. **Close out** with a structured **post-incident report** framed for ServiceNow.

> **Note on SYF's network (READ THIS):** This lab uses native AWS networking, and **AWS Transit Gateway** where transit appears. In your environment the hub-and-spoke transit is **Aviatrix**, managed by the network team — the concepts (routing, blackholes, asymmetric paths, reachability) map directly; the management plane differs. When this guide says "fix the route table," in production you would raise it with the network team and they would correct the equivalent Aviatrix route.

---

## Scenario

> **Major incident declared 09:02:** "Partner settlement integration is down. New orders are failing. Internal pod health checks are red. Security is asking why a flagged instance is still talking to the database."

Under `scenario=lab5` the stack carries **four** independent faults at once:

| Layer | Fault | Red tile(s) |
|-------|-------|-------------|
| **Network** | A more-specific route sends partner-CIDR traffic to the internet gateway - a blackhole from the private subnets | `app_path_reachable`, `tgw_or_network_ok` |
| **IAM** | The orders-api IRSA role is stripped of its Aurora-secret and S3 permissions (the Lab 1 break) | `orders_api_db_access` |
| **Pod network** | A default-deny egress **Kubernetes NetworkPolicy** cuts pod egress | `eks_pod_internet`, `eks_pod_dns` |
| **Security** | The rogue instance is still querying Aurora (the through-line) | `aurora_no_rogue`, `rogue_contained` |

Clear all of them and every tile goes green — incident resolved.

---

## Learning Objectives

By the end of this lab, you will be able to:

- Use a red/green dashboard to scope a compound incident and choose a triage order.
- Diagnose a network blackhole with **VPC Flow Logs** (REJECT / asymmetry) and **VPC Reachability Analyzer** (which hop is broken).
- Compare AWS-native network diagnosis against an **open-source packet-analysis box** fed by **VPC Traffic Mirroring**, and articulate when each is the pragmatic choice.
- Reapply the per-domain fixes from Labs 1-4 (IRSA, pod NetworkPolicy, DB, rogue) under incident pressure.
- Write a structured post-incident report (severity, timeline, root cause, remediation) for ServiceNow.

---

## Pre-Lab Setup

Run from a local clone or AWS CloudShell.

1. **Materialize the capstone incident** (replace `s01` with your assigned id):

    ```bash
    cd lab_environment/lab_env_student
    terraform apply -var="student_id=s01" -var="scenario=lab5" -auto-approve
    ./deploy_app.sh
    ```
<!-- source: course_outline_v3.md §"Lab 5" -->

2. **Capture outputs:**

    ```bash
    export REGION=$(terraform output -raw region)
    export STUDENT_ID=$(terraform output -raw student_id)
    export DASHBOARD=$(terraform output -raw incident_board_dashboard_name)
    export VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Student,Values=$STUDENT_ID" --query 'Vpcs[0].VpcId' --output text)
    export IRSA_ROLE="io108-${STUDENT_ID}-orders-api-role"
    export SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
    export REPORTS_BUCKET=$(terraform output -raw reports_bucket)
    export ROGUE_ID=$(terraform output -raw rogue_instance_id)
    export ROGUE_IP=$(terraform output -raw rogue_private_ip)
    export PARTNER_CIDR=203.0.113.0/24   # var.partner_cidr default
    export FLOW_LG="/io108/${STUDENT_ID}/vpc-flow-logs"
    echo "VPC:          $VPC_ID"
    echo "Partner CIDR: $PARTNER_CIDR"
    echo "Flow logs:    $FLOW_LG"
    ```

---

## Task 1: Lead with the Board - Scope and Order the Incident

1. **Open** your incident board (`$DASHBOARD`). Note **every** red tile. You should see (at minimum): `app_path_reachable`, `tgw_or_network_ok`, `orders_api_db_access`, `eks_pod_internet`, `eks_pod_dns`, `aurora_no_rogue`, `rogue_contained`.

2. **Decide a triage order.** A defensible order:

    1. **Network path first** — the partner blackhole is the broadest-blast-radius failure and the hardest to reason about once you are deep in another layer.
    2. **IAM / pod network** — app-domain failures that the board localizes for you.
    3. **Rogue containment** — security, can be done in parallel once the path is stable.

> **Why the board first?** In a compound incident the worst move is to grab the first log you think of. The board tells you the *set* of impaired systems up front, so you triage deliberately instead of chasing one symptom while three others smolder.

---

## Task 2: Diagnose the Network Blackhole (Flow Logs + Reachability Analyzer)

3. **Query VPC Flow Logs** for the partner path. The misroute sends partner-CIDR traffic to the internet gateway; from the private subnets (no public IPs) the SYN leaves but nothing returns — an asymmetric blackhole. In **CloudWatch Logs Insights**, select log group `$FLOW_LG` and run:

    ```
    fields @timestamp, srcAddr, dstAddr, action, bytes
    | filter dstAddr like /203\.0\.113\./
    | sort @timestamp desc
    | limit 50
    ```

    You will see outbound attempts toward the partner CIDR with no corresponding return traffic (or `REJECT` records) — the signature of a one-way path.

4. **Run VPC Reachability Analyzer** to name the broken hop. In the **VPC console -> Reachability Analyzer -> Create and analyze path**:

    - **Source:** an EKS node ENI (or the private subnet) in `$VPC_ID`
    - **Destination type:** IP address, **Destination address:** an address inside `$PARTNER_CIDR` (e.g. `203.0.113.10`)
    - **Analyze**

    The result reports **Not reachable** and points at the route table hop - a route for `203.0.113.0/24` sending traffic to an **internet gateway** instead of the NAT gateway. Reachability Analyzer has just told you exactly which hop is misconfigured, without reading a single packet.

> **Flow Logs vs Reachability Analyzer:** Flow Logs show you what *did* happen on the wire (drops, asymmetry, volume). Reachability Analyzer reasons about the *configuration* and tells you which hop *would* break a path and why - even with no live traffic. For a routing fault, Reachability Analyzer usually localizes it fastest; Flow Logs confirm the real-world symptom.

---

## Task 3: (Optional add-on) Open-Source Packet-Analysis Box - Compare and Contrast

This piece is a **documented manual add-on**, not pre-built. Do it if you have time; the lesson is about *tool selection*, not about the capture itself.

When AWS-native tools are not enough — or when you genuinely need to see bytes on the wire — you can mirror traffic to an EC2 "analysis box" running open-source tools. Conceptually:

5. **Launch a small EC2 analysis box** (e.g. `t3.small`, Amazon Linux 2023) in a subnet that can receive mirrored traffic, reachable via **SSM** (no SSH).
6. **Install the OSS toolkit:**

    ```bash
    sudo dnf install -y nmap tcpdump wireshark-cli   # nmap, tcpdump, tshark
    # ntopng for NetFlow-style flow visualization (from its repo / container)
    ```
<!-- source: content/narratives/Module_2_narrative.md §"Wireshark and tcpdump for packet capture" -->

7. **Configure VPC Traffic Mirroring:** create a **mirror target** (the analysis box ENI), a **mirror filter** (e.g. the partner CIDR), and a **mirror session** from the source ENI you care about. Mirrored packets now arrive on the analysis box.
8. **Inspect the same incident on the wire:**

    ```bash
    sudo tcpdump -ni any net 203.0.113.0/24        # see the one-way SYNs, no returns
    sudo tshark -ni any -Y "ip.dst == 203.0.113.10"
    nmap -Pn -p 443 203.0.113.10                    # confirm reachability from this box
    # ntopng: open the web UI for flow-level visualization
    ```
<!-- source: content/narratives/Module_2_narrative.md §"an EC2 analysis box running nmap" -->

> **The lesson - pragmatic tool selection:** For this routing fault, a **Flow Logs query** or a quick **`nmap`/`traceroute` from an EC2 instance** told us what we needed in under a minute. Standing up Traffic Mirroring + an OSS capture stack is real work, and for a misroute it was *slower* than the native tools. **Sometimes**, though — intermittent corruption, an application-layer protocol bug, a "the metrics look fine but it's still broken" mystery — the deep packet view is exactly what cracks it. Know both; reach for the lighter tool first. In SYF's environment this packet/flow role is played by **SolarWinds, NewRelic, and Aviatrix**; we use OSS here so there is no licensing, and AWS-native remains primary.

---

## Task 4: Fix the Misroute

9. **Find** the private route table and the offending route. In the **VPC console -> Route tables**, select the `io108-<your-id>` **private** route table, open **Routes**, and locate the entry `203.0.113.0/24 -> igw-...`. Or from the CLI:

    ```bash
    RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*private*" \
      --query 'RouteTables[0].RouteTableId' --output text)
    aws ec2 describe-route-tables --route-table-ids "$RT_ID" --region "$REGION" \
      --query 'RouteTables[0].Routes' --output table
    ```
<!-- source: facts_extracted_v2.md §"Route Table Troubleshooting" -->

10. **Delete** the misroute so partner traffic falls back to the route table's `0.0.0.0/0 -> NAT gateway` default:

    ```bash
    aws ec2 delete-route --route-table-id "$RT_ID" \
      --destination-cidr-block "$PARTNER_CIDR" --region "$REGION"
    ```
<!-- source: facts_extracted_v2.md §"Missing route" -->

> **Expected Result:** Within 1-2 minutes **`app_path_reachable`** and **`tgw_or_network_ok`** turn **GREEN**. (In production this is the network team correcting the Aviatrix route — same concept.)

---

## Task 5: Restore the IRSA Path (reuse Lab 1)

The `orders_api_db_access` tile is red because the orders-api IRSA role was stripped of its Aurora-secret read and S3 permissions — the same break you diagnosed in Lab 1 (the pod gets `AccessDenied` reading DB credentials).

11. **Restore** the role's inline policy. Recreate the permissions the healthy role carries:

    ```bash
    cat > /tmp/orders_api_restore.json <<JSON
    {
      "Version": "2012-10-17",
      "Statement": [
        { "Sid": "ReadAuroraMasterSecret", "Effect": "Allow",
          "Action": ["secretsmanager:GetSecretValue"], "Resource": "$SECRET_ARN" },
        { "Sid": "ReadWriteReports", "Effect": "Allow",
          "Action": ["s3:GetObject","s3:PutObject","s3:ListBucket"],
          "Resource": ["arn:aws:s3:::$REPORTS_BUCKET","arn:aws:s3:::$REPORTS_BUCKET/*"] }
      ]
    }
    JSON
    aws iam put-role-policy --role-name "$IRSA_ROLE" \
      --policy-name "io108-${STUDENT_ID}-orders-api-inline" \
      --policy-document file:///tmp/orders_api_restore.json
    ```
<!-- source: course_outline_v3.md §"IAM/IRSA policy analysis" -->

12. **Restart** the orders-api so pods pick up fresh credentials via IRSA:

    ```bash
    kubectl -n orders rollout restart deploy/orders-api
    kubectl -n orders rollout status deploy/orders-api --timeout=180s
    ```
<!-- source: content/narratives/Module_3_narrative.md §"pods get their AWS permissions through IRSA" -->

> **Expected Result:** **`orders_api_db_access`** turns **GREEN** within a cycle. (Refer back to Lab 1 for the full diagnosis of how you would *find* this from `AccessDenied` if it were not already localized for you.)

---

## Task 6: Fix the Pod NetworkPolicy

The `eks_pod_internet` and `eks_pod_dns` tiles are red because a default-deny egress **Kubernetes NetworkPolicy** is cutting pod egress (so the in-cluster conncheck CronJob cannot reach the internet or DNS, and its metrics stop publishing).

13. **List** the NetworkPolicies in the `orders` namespace and find the default-deny:

    ```bash
    kubectl -n orders get networkpolicy
    kubectl -n orders describe networkpolicy
    ```
<!-- source: content/narratives/Module_1_narrative.md §"resolve DNS and reach the internet" -->

14. **Remove** the default-deny by redeploying the chart with the policy disabled (the clean, declarative fix):

    ```bash
    helm upgrade orders charts/orders --namespace orders --reuse-values \
      --set networkPolicy.defaultDeny=false
    ```
<!-- source: content/narratives/Module_1_narrative.md §"deployed with Helm" -->

    (If you need an immediate manual fix instead, `kubectl -n orders delete networkpolicy <default-deny-name>` clears it; the declarative helm change is preferred so the next deploy does not reintroduce it.)

> **Expected Result:** **`eks_pod_internet`** and **`eks_pod_dns`** turn **GREEN** once the conncheck CronJob's egress is restored and it resumes publishing metrics.

---

## Task 7: Contain the Rogue (reuse Lab 4)

15. **Revoke** the rogue's Aurora path and **stop** the instance, exactly as in Lab 4:

    ```bash
    ROGUE_SG=$(aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
    AURORA_SG=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=io108-${STUDENT_ID}-aurora-sg" \
      --query 'SecurityGroups[0].GroupId' --output text)
    aws ec2 revoke-security-group-ingress --group-id "$AURORA_SG" --region "$REGION" \
      --protocol tcp --port 5432 --source-group "$ROGUE_SG"
    aws ec2 stop-instances --instance-ids "$ROGUE_ID" --region "$REGION"
    ```
<!-- source: content/narratives/Module_1_narrative.md §"containing the rogue" -->

> **Expected Result:** **`aurora_no_rogue`** and **`rogue_contained`** turn **GREEN**.

---

## Task 8: Confirm the Board Is All Green = Incident Resolved

16. **Return** to the incident board and confirm **every tile is green** across all five lab bands. That is your objective signal that the compound incident is resolved.

17. **Sanity-check** end to end: reports flowing, app writing to the writer endpoint, partner path reachable, pods healthy, rogue contained.

> **What Just Happened?** You ran a real compound incident the way it should be run: board first to scope it, deliberate triage order, the right tool per layer (Reachability Analyzer and Flow Logs for the route; the per-domain tools for IAM, pods, DB, security), and a clean confirmation that every check recovered. No single "root cause" — four of them, cleared in order.

---

## Task 9: Post-Incident Write-up (ServiceNow)

18. **Write** a structured post-incident report. In ServiceNow this is the major-incident record; capture at minimum:

    - **Severity:** declared **P0** (multi-system, customer-facing), de-escalated to P1/P2 as layers recovered, closed when the board went fully green.
    - **Timeline:** detection time (board), each tile's red-to-green time, and the action that flipped it.
    - **Root cause - one line per layer:**
      - Network: a more-specific `203.0.113.0/24` route pointed at the IGW blackholed the partner path.
      - IAM: orders-api IRSA role missing Aurora-secret + S3 permissions (AccessDenied).
      - Pod network: default-deny egress NetworkPolicy cut pod egress / DNS.
      - Security: rogue instance with stolen credentials querying Aurora.
    - **Remediation:** delete the misroute; restore the IRSA inline policy + restart; disable the default-deny NetworkPolicy; revoke the rogue SG path + stop the instance.
    - **Follow-ups / prevention:** guardrails on route-table changes, IAM policy drift detection, NetworkPolicy review in CI, and how the rogue obtained credentials (feed to security).

> **Expected Result:** A complete ServiceNow incident record a teammate could read cold and understand what broke, what you did, and what should change so it does not recur.

---

## Troubleshooting

### A network tile stays red after deleting the route

**Check:** Confirm you deleted the route from the **private** route table (the one the EKS nodes/pods use), not a public one. Re-run the `describe-route-tables` query — the `203.0.113.0/24` entry should be gone and only `0.0.0.0/0 -> nat-...` should remain for egress.

### `orders_api_db_access` stays red

**Check:** Confirm `aws iam get-role-policy --role-name "$IRSA_ROLE" --policy-name "io108-${STUDENT_ID}-orders-api-inline"` shows the secret + S3 statements, and that you restarted the deployment so pods re-assumed the role.

### Pod tiles stay red

**Check:** `kubectl -n orders get networkpolicy` should no longer show a default-deny. The conncheck CronJob runs every minute; give it a cycle to republish metrics.

---

## Knowledge Check

**Question 1:** You have a routing incident where a partner CIDR is unreachable. You could reach for VPC Flow Logs, VPC Reachability Analyzer, or a full packet capture (Traffic Mirroring + tcpdump/tshark). Rank them for *this* fault and justify which you would run first and which you would rarely need.

**Question 2:** In a compound incident with seven red tiles, why is "fix the broadest network path first" a defensible triage order, and what is the risk of instead fixing whichever symptom you happen to recognize first?

**Question 3:** The misroute sent partner traffic to the internet gateway from a private subnet with no public IPs. Explain why that produces an *asymmetric blackhole* rather than an immediate, obvious error, and how that shows up in Flow Logs.

<details>
<summary><strong>Answers</strong></summary>

**A1:** Run **Reachability Analyzer first** — it reasons about configuration and names the bad hop (the `203.0.113.0/24 -> IGW` route) directly, even with no live traffic, which is the fastest path to root cause for a routing fault. Use **Flow Logs** next to confirm the real-world symptom (outbound with no return / REJECTs). A **full packet capture** is rarely needed for a pure routing fault — it is heavyweight and slower to stand up; reserve it for intermittent corruption, protocol-level bugs, or cases where flow/config tools come back clean but the problem persists.

**A2:** A network-path failure has the broadest blast radius and is the hardest to reason about once you are deep inside another layer, so stabilizing it first prevents it from confounding every other diagnosis. The risk of chasing the first symptom you recognize is tunnel vision: you may spend the incident on one layer while three others stay broken, and overlapping failures can mask or mimic each other, leading to wrong conclusions.

**A3:** The instances have no public IPs and rely on NAT for egress; sending partner-bound packets to the internet gateway means the SYN leaves but the return path cannot make it back to a private, non-NATed source — so instead of a clean "no route" error you get connections that hang and time out (asymmetric, one-way). In Flow Logs this appears as outbound records toward the partner CIDR with no matching inbound/return records (and/or REJECTs), which is the tell for a one-way path rather than a closed port.

</details>

---

## Lab Summary

- You led a **compound (P0) incident** from the **red/green board**, scoping the full set of failures before acting.
- You diagnosed a **network blackhole** with **Flow Logs** (asymmetry) and **Reachability Analyzer** (the misconfigured hop), and saw where an **OSS packet-analysis box** fits - and where it is overkill.
- You cleared every layer: deleted the **misroute**, restored the **IRSA** path, removed the default-deny **NetworkPolicy**, and **contained the rogue**.
- You confirmed **every tile green** and wrote a structured **ServiceNow post-incident report** with severity, timeline, root cause, and remediation.

## Course Wrap-up

You now have a repeatable incident methodology: **board first, triage deliberately, right tool per layer, confirm recovery, write it up.** That is exactly how SYF's Technology Operations group runs connectivity and workload incidents day to day — with CloudWatch, NewRelic, SolarWinds, and Aviatrix as the production equivalents of the tools you used here. Well done clearing the board.
