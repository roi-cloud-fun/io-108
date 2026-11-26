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

## Task 1: Lab Setup

Run every command in this lab on your **lab host** as **`ec2-user`** (Session Manager, then `sudo su - ec2-user`, as in Lab 1, *Start Here*, step 1). Run each code block on its own, and wait for it to finish before you start the next.

1. **Go to** the lab directory and **check** your variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
    ```

    The `echo` must show your own id and region, for example `SID=user01 REGION=us-east-1` (not blank, not `userNN`). If it is blank, finish Lab 1 *Start Here* step 3.

2. **Preview** the capstone incident (your id and region come from `terraform.tfvars`, set in Lab 1). Run this command on its own:

    ```bash
    terraform plan -var scenario=lab5
    ```
<!-- source: course_outline_v3.md §"Lab 5" -->

    This changes nothing; it shows what the apply will do. Terraform takes about a minute to compare your stack with the code, then prints a **plan** ending in a line like:

    ```
    Plan: 1 to add, 2 to change, 0 to destroy.
    ```

    Expect a small plan: about **2–4 to change, 0–2 to add, 0 to destroy**. It lists `aws_route.capstone_misroute[0]` (add: the partner misroute), `aws_iam_role_policy.orders_api` (change: the IAM break) and `aws_cloudwatch_dashboard.incident_board` (change). Coming from Lab 4, it may also list `aws_ec2_instance_state.rogue[0]` (restarts the rogue you stopped) or the `aurora_from_rogue` security-group rule you revoked.

    If it shows dozens or 100+ to add, or wants to destroy anything unexpected, stop and tell your instructor; do not run the next step.

3. **Inject** the capstone incident. Run this command on its own:

    ```bash
    terraform apply -var scenario=lab5
    ```

    Terraform prints the same plan again and stops at `Enter a value:`:

    ```
    Plan: 1 to add, 2 to change, 0 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    - **If the `Plan:` line matches the preview,** type **`yes`** and press **Enter**. Terraform will not continue until you do, and anything other than `yes` cancels.
    - **Otherwise,** type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** After about a minute, Terraform prints **`Apply complete! Resources: 1 added, 2 changed, 0 destroyed.`** (your numbers match your plan), followed by a list of outputs. If it ends with `Error:` instead, run the same `terraform apply` command again and type `yes`. A failed apply can stop before the misroute is created.

4. **Redeploy** the app, which applies the pod-network fault. Run this only after step 3 has finished:

    ```bash
    ./deploy_app.sh
    ```

    This takes from under a minute to about 5 minutes. **Do not press Ctrl+C.**

    > **Expected Result:** It prints `netpol default-deny: true` near the top and ends with `Deploy complete. Next steps:`. It may finish within a minute, or wait about 5 minutes and print `WARNING: orders-api is not Ready`. Both are fine: the app is meant to be broken.

5. **Capture** the values this lab uses into shell variables. **After any reconnect, run steps 1 and 5 again**, because a new session forgets these variables:

    ```bash
    STUDENT_ID=$SID
    export VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=io108-${STUDENT_ID}-vpc" --query 'Vpcs[0].VpcId' --output text)
    export IRSA_ROLE="io108-${STUDENT_ID}-orders-api-role"   # role NAME (Lab 1 used the ARN)
    export SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
    export REPORTS_BUCKET=$(terraform output -raw reports_bucket)
    export ROGUE_ID=$(terraform output -raw rogue_instance_id)
    export ROGUE_IP=$(terraform output -raw rogue_private_ip)
    export PARTNER_CIDR=203.0.113.0/24   # var.partner_cidr default
    export FLOW_LG="/io108/${STUDENT_ID}/vpc-flow-logs"
    echo "VPC:            $VPC_ID"
    echo "IRSA role:      $IRSA_ROLE"
    echo "Secret ARN:     $SECRET_ARN"
    echo "Reports bucket: $REPORTS_BUCKET"
    echo "Rogue:          $ROGUE_ID / $ROGUE_IP"
    echo "Partner CIDR:   $PARTNER_CIDR"
    echo "Flow logs:      $FLOW_LG"
    ```

    > **Expected Result:** Check:
    >
    > - `VPC` starts with `vpc-`.
    > - `IRSA role` reads `io108-<your-id>-orders-api-role`.
    > - `Secret ARN` starts with `arn:aws:secretsmanager:`.
    > - `Reports bucket` is not blank.
    > - `Rogue` shows `i-...` and a `10.x.x.x` address.
    > - `Flow logs` reads `/io108/<your-id>/vpc-flow-logs`.
    >
    > If anything is blank or `None`, run step 1 again, then this step.

> **Reconnecting later?** Sessions time out when idle. Start a new session, run `sudo su - ec2-user`, then run **steps 1 and 5** again, and then re-run the first command block of the task you were on. Several tasks set short-lived variables (`ENI`, `NIP` and `NIA` in step 9, `RT_ID` in step 14, `ROGUE_SG` and `AURORA_SG` in step 20) that a reconnect loses. Do **not** re-run step 3: it re-injects every fault.

---

## Task 2: Lead with the Board — Scope and Order the Incident

6. **Open** your incident board: **CloudWatch console** (your region) → **Dashboards** → **`io108-<your-id>-incident-board`**. Tiles refresh about every minute. Note **every** red tile. You should see (at minimum): `app_path_reachable`, `tgw_or_network_ok`, `orders_api_db_access`, `eks_pod_internet`, `eks_pod_dns`, `aurora_no_rogue`, `rogue_contained`. The two `eks_pod_*` tiles go red last, 5–8 minutes after the deploy.

7. **Decide a triage order.** A defensible order:

    1. **Network path first** — the partner blackhole is the broadest-blast-radius failure and the hardest to reason about once you are deep in another layer.
    2. **IAM / pod network** — app-domain failures that the board localizes for you.
    3. **Rogue containment** — security, can be done in parallel once the path is stable.

> **Why the board first?** In a compound incident the worst move is to grab the first log you think of. The board tells you the *set* of impaired systems up front, so you triage deliberately instead of chasing one symptom while three others smolder.

---

## Task 3: Diagnose the Network Blackhole (Flow Logs + Reachability Analyzer)

8. **Generate traffic toward the partner path, then query VPC Flow Logs.** Nothing in the stack routinely sends packets to the partner CIDR, so Flow Logs have nothing to match until you drive some traffic at it. From a pod in the private subnet, attempt a connection to an address in the partner range — the misroute sends it to the internet gateway, and from a private (no-public-IP) subnet the SYN leaves but nothing returns, so it times out. That timeout **is** the symptom:

    ```bash
    kubectl -n orders run nettest --rm -i --restart=Never \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket; socket.setdefaulttimeout(8); socket.create_connection(('203.0.113.10',443))" || echo "blackholed (expected)"
    ```
    <!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

    `kubectl run --rm` starts a throwaway pod, runs one command, and deletes the pod. It takes about 10–40 seconds (longer the first time, while the image downloads). You may see `If you don't see a command prompt, try pressing enter.`; ignore it.

    > **Expected Result:** A Python error (a *traceback*) ending in `TimeoutError: timed out`, then `pod "nettest" deleted` and **`blackholed (expected)`**. The timeout **is** the expected result: the connection never completed.

    Run it two or three times if you want more records. *VPC Flow Logs* are a record of every connection attempt in your VPC, delivered to CloudWatch Logs. Wait about 1–2 minutes for delivery, then query them:

    - **CloudWatch console** (your region) → left menu **Logs → Logs Insights**.
    - **Select log groups:** `/io108/<your-id>/vpc-flow-logs`.
    - **Time range:** **Last 15 minutes**.
    - Replace the query text with the following, then choose **Run query** (5–20 seconds):

    ```
    fields @timestamp, srcAddr, dstAddr, action, bytes
    | filter dstAddr like /203\.0\.113\./
    | sort @timestamp desc
    | limit 50
    ```

    No rows? Wait another minute, re-run the `nettest` command, and run the query again.

    You will now see outbound records toward the partner CIDR (`dstAddr` in `203.0.113.x`). `srcAddr` is your EKS **node's** IP, not the pod's, because the VPC CNI (the EKS networking plugin) rewrites the source address of pod traffic leaving the VPC to the node's address (*source NAT*). The `action` column shows **`ACCEPT`**. That only means the packet was allowed to leave; it does not mean it arrived. The proof of the fault is that there is **no return traffic**: change the filter line to `| filter srcAddr like /203\.0\.113\./` and run again, and you get **0 rows**. That is the asymmetric, one-way signature of a routing blackhole. A security-group or NACL block would instead show `REJECT` records; here the packets simply leave via the wrong hop and never come back.

9. **Run VPC Reachability Analyzer** to name the broken hop. Reachability Analyzer reads your network *configuration* (route tables, gateways, security groups) and reports whether a path works and where it breaks. You can use the console or the CLI; both give the same answer.

    **Option A: console.** In the **VPC console** (your region), open the left menu **Network Analysis → Reachability Analyzer** and choose **Create and analyze path**:

    - **Source type:** **Network interfaces**. **Source:** pick a network interface (*ENI*, a virtual network card) whose description or attached instance is one of your EKS nodes (`io108-<your-id>-node`).
    - **Destination type:** **IP address**. **Destination:** `203.0.113.10` (an address inside the partner CIDR).
    - **Protocol:** **TCP**.
    - Choose **Create and analyze path**. The analysis takes about 1–3 minutes; the status changes from *Pending* to *Succeeded*.

    If your console does not offer an IP address as the destination, use Option B.

    **Option B: CLI.** First find a node's primary network interface and check it:

    ```bash
    ENI=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:Name,Values=io108-${STUDENT_ID}-node" "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`0`].NetworkInterfaceId | [0]' --output text)
    echo "ENI=$ENI"
    ```

    It must print `ENI=eni-...`. If it prints `None`, re-run steps 1 and 5 and try again. Then create the path and start the analysis:

    ```bash
    NIP=$(aws ec2 create-network-insights-path --region "$REGION" --source "$ENI" --protocol tcp \
      --filter-at-source DestinationAddress=203.0.113.10 \
      --query NetworkInsightsPath.NetworkInsightsPathId --output text)
    NIA=$(aws ec2 start-network-insights-analysis --region "$REGION" --network-insights-path-id "$NIP" \
      --query NetworkInsightsAnalysis.NetworkInsightsAnalysisId --output text)
    echo "NIP=$NIP NIA=$NIA"
    sleep 60
    ```

    The `echo` prints `NIP=nip-... NIA=nia-...`. `sleep 60` then pauses for one minute **with no output**; wait for the `$` prompt to return. Then read the result:

    ```bash
    aws ec2 describe-network-insights-analyses --region "$REGION" --network-insights-analysis-ids "$NIA" \
      --query 'NetworkInsightsAnalyses[0].{Status:Status,Found:NetworkPathFound,Why:Explanations[].ExplanationCode}'
    ```

    If `Status` is `running`, wait 30 seconds and run this last command again. When `Status` is `succeeded`, **`Found` is `false`**: the path is not reachable.

    > **What to look for:** In the console, the analysis shows **Reachability status: Not reachable**. Open the **Explanations** section and find the route-table hop: your private route table has a route for `203.0.113.0/24` that sends traffic to an **internet gateway** (`igw-...`) instead of the NAT gateway. The CLI's `Why` list names the same problem as explanation codes. Instances in a private subnet have no public IP, so they cannot use an internet gateway directly. Reachability Analyzer has told you which hop is misconfigured, without reading a single packet.

> **Flow Logs vs. Reachability Analyzer:** Flow Logs show you what *did* happen on the wire (drops, asymmetry, volume). Reachability Analyzer reasons about the *configuration* and tells you which hop *would* break a path and why — even with no live traffic. For a routing fault, Reachability Analyzer usually localizes it fastest; Flow Logs confirm the real-world symptom.

---

## Task 4: (Optional — Instructor Demo) Open-Source Packet-Analysis Box — Compare and Contrast

> **Optional. Skip this task unless your instructor runs it as a demo.** Nothing here is pre-built, nothing on the board depends on it, and the rest of the lab does not need it. Steps 10–13 describe *what* the demo does so you can follow along; they are not a full build guide. The lesson is about *tool selection*, not about the capture itself.
>
> **Cost and teardown:** the analysis box is an EC2 instance billed by the hour, and Traffic Mirroring is billed per mirrored network interface per hour. Whoever builds it must tear it down the same day: **delete the mirror session, then the mirror target and mirror filter, then terminate the analysis box.**

When AWS-native tools are not enough — or when you genuinely need to see bytes on the wire — you can mirror traffic to an EC2 "analysis box" running open-source tools. Conceptually:

10. **Launch a small EC2 analysis box** (e.g. `t3.small`, Amazon Linux 2023) in a subnet that can receive mirrored traffic, reachable via **SSM** (no SSH).
11. **Install the OSS toolkit:**

    ```bash
    sudo dnf install -y nmap tcpdump wireshark-cli   # nmap, tcpdump, tshark
    # ntopng for NetFlow-style flow visualization (from its repo / container)
    ```
<!-- source: content/narratives/Module_2_narrative.md §"Wireshark and tcpdump for packet capture" -->

12. **Configure VPC Traffic Mirroring:** create a **mirror target** (the analysis box ENI), a **mirror filter** (e.g. the partner CIDR), and a **mirror session** from the source ENI you care about. Mirrored packets now arrive on the analysis box **wrapped in VXLAN** (UDP port 4789): each original packet is carried inside a new packet addressed to the analysis box.
13. **Inspect the same incident on the wire.** Because of the VXLAN wrapper, filter on UDP 4789 and let the tool decode the inner packet. A plain `net 203.0.113.0/24` filter would match nothing.

    ```bash
    sudo tcpdump -ni eth0 udp port 4789                                   # mirrored traffic; inner packets show the one-way SYNs to 203.0.113.x, no replies
    sudo tshark -ni eth0 -d udp.port==4789,vxlan -Y "ip.dst == 203.0.113.10"   # decode VXLAN, show only the inner partner-bound packets
    nmap -Pn -p 443 203.0.113.10                                          # active probe from the box itself
    # ntopng: open the web UI for flow-level visualization
    ```

    The interface name may be `ens5` instead of `eth0`; `ip -br addr` lists it. Press **Ctrl+C** once to stop `tcpdump` or `tshark`.
<!-- source: content/narratives/Module_2_narrative.md §"an EC2 analysis box running nmap" -->

> **The lesson - pragmatic tool selection:** For this routing fault, a **Flow Logs query** or a quick **`nmap`/`traceroute` from an EC2 instance** told us what we needed in under a minute. Standing up Traffic Mirroring + an OSS capture stack is real work, and for a misroute it was *slower* than the native tools. **Sometimes**, though — intermittent corruption, an application-layer protocol bug, a "the metrics look fine but it's still broken" mystery — the deep packet view is exactly what cracks it. Know both; reach for the lighter tool first. In SYF's environment this packet/flow role is played by **SolarWinds, NewRelic, and Aviatrix**; we use OSS here so there is no licensing, and AWS-native remains primary.

---

## Task 5: Fix the Misroute

14. **Find** the private route table and the offending route. A *route table* tells traffic leaving a subnet where to go next. You can view it in the **VPC console → Route tables**: select **`io108-<your-id>-private-rt`**, open the **Routes** tab, and find the entry `203.0.113.0/24 → igw-...`. Run the CLI either way, because the next step needs the `RT_ID` it sets:

    ```bash
    RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=io108-${STUDENT_ID}-private-rt" \
      --query 'RouteTables[0].RouteTableId' --output text)
    echo "RT_ID=$RT_ID"
    aws ec2 describe-route-tables --route-table-ids "$RT_ID" --region "$REGION" \
      --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,State]' --output table
    ```
<!-- source: facts_extracted_v2.md §"Route Table Troubleshooting" -->

    > **Expected Result:** `RT_ID=rtb-...`, then a table that includes these two rows (plus a `local` row for the VPC itself):
    >
    > - `0.0.0.0/0` with a `nat-...` id: the healthy default route through the NAT gateway.
    > - **`203.0.113.0/24` with an `igw-...` id**: the misroute.
    >
    > If `RT_ID` is `None` or blank, re-run steps 1 and 5, then this block.

15. **Delete** the misroute so partner traffic falls back to the route table's `0.0.0.0/0 -> NAT gateway` default:

    ```bash
    aws ec2 delete-route --route-table-id "$RT_ID" \
      --destination-cidr-block "$PARTNER_CIDR" --region "$REGION"
    ```
<!-- source: facts_extracted_v2.md §"Missing route" -->

    This command prints **nothing** when it succeeds. Re-run the `describe-route-tables` command from step 14: the `203.0.113.0/24` row is gone. If you get `InvalidRoute.NotFound`, the route was already deleted; continue.

> **Expected Result:** Within 1–2 minutes (the probes run every minute) **`app_path_reachable`** and **`tgw_or_network_ok`** turn **GREEN**. (In production this is the network team correcting the Aviatrix route — same concept.)

---

## Task 6: Restore the IRSA Path (reuse Lab 1)

The `orders_api_db_access` tile is red because the orders-api IRSA role was stripped of its Aurora-secret read and S3 permissions — the same break you diagnosed in Lab 1 (the pod gets `AccessDenied` reading DB credentials).

16. **Restore** the role's inline policy. Recreate the permissions the healthy role carries. First check the three values the policy is built from:

    ```bash
    echo "ROLE=$IRSA_ROLE"
    echo "SECRET=$SECRET_ARN"
    echo "BUCKET=$REPORTS_BUCKET"
    ```

    `ROLE` must read `io108-<your-id>-orders-api-role` (a role **name**, not an `arn:...`), `SECRET` must start with `arn:aws:secretsmanager:`, and `BUCKET` must not be blank. If any is wrong, re-run steps 1 and 5. Then write the policy:

    ```bash
    aws iam put-role-policy --role-name "$IRSA_ROLE" \
      --policy-name "io108-${STUDENT_ID}-orders-api-inline" \
      --policy-document "$(cat <<JSON
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
    )"
    ```
<!-- source: course_outline_v3.md §"IAM/IRSA policy analysis" -->

    This command prints **nothing** when it succeeds. Confirm the policy was written:

    ```bash
    aws iam get-role-policy --role-name "$IRSA_ROLE" \
      --policy-name "io108-${STUDENT_ID}-orders-api-inline" \
      --query 'PolicyDocument.Statement[].Sid' --output text
    ```

    Expected: one line containing `ReadAuroraMasterSecret` and `ReadWriteReports`. A `MalformedPolicyDocument` or `ValidationError` error means one of the three values above was wrong.

> **Expected Result:** **`orders_api_db_access`** turns **GREEN** within about 3 minutes (the probe asks IAM directly). Leave the pods alone for now: they install packages at startup, so they cannot come back until Task 7 restores egress. (Refer back to Lab 1 for the full diagnosis of how you would *find* this from `AccessDenied` if it were not already localized for you.)

---

## Task 7: Fix the Pod NetworkPolicy

The `eks_pod_internet` and `eks_pod_dns` tiles are red because a default-deny egress **Kubernetes NetworkPolicy** is cutting pod egress (so the in-cluster conncheck CronJob cannot reach the internet or DNS, and its metrics stop publishing).

17. **List** the NetworkPolicies in the `orders` namespace and find the default-deny:

    ```bash
    kubectl -n orders get networkpolicy
    kubectl -n orders describe networkpolicy
    ```
<!-- source: content/narratives/Module_1_narrative.md §"resolve DNS and reach the internet" -->

    Expected: the policy is listed as **`orders-default-deny-egress`**. `describe` shows `Policy Types: Egress` and no allowed egress rules.

18. **Remove** the default-deny by redeploying the chart with the policy disabled (the clean, declarative fix). Helm is the tool that installed the app; this command must run from the Terraform directory, where the chart lives (you are already there from step 1):

    ```bash
    helm upgrade orders charts/orders --namespace orders --reuse-values \
      --set networkPolicy.defaultDeny=false
    ```
    <!-- source: content/narratives/Module_1_narrative.md §"deployed with Helm" -->

    > **Expected Result:** `Release "orders" has been upgraded. Happy Helming!` Running `kubectl -n orders get networkpolicy` no longer lists `orders-default-deny-egress` (it may print `No resources found in orders namespace.`).

    (If you need an immediate manual fix instead, `kubectl -n orders delete networkpolicy orders-default-deny-egress` clears it; the declarative helm change is preferred so the next deploy does not reintroduce it.)

19. **Restart** the orders-api so it starts cleanly with both fixes (IAM and egress) in place. The pods install packages at startup, so this takes about 1–3 minutes:

    ```bash
    kubectl -n orders rollout restart deploy/orders-api
    kubectl -n orders rollout status deploy/orders-api --timeout=180s
    ```
<!-- source: content/narratives/Module_3_narrative.md §"pods get their AWS permissions through IRSA" -->

    > **Expected Result:** `deployment.apps/orders-api restarted`, then (after 1–3 minutes) `deployment "orders-api" successfully rolled out`. If it says `timed out waiting for the condition`, run the `rollout status` line again. If it times out twice, check that steps 16 and 18 succeeded.

> **Expected Result:** **`eks_pod_internet`** and **`eks_pod_dns`** turn **GREEN** within about 2–3 minutes, once the conncheck CronJob (which runs every minute) can reach the network again and resumes publishing metrics.

---

## Task 8: Contain the Rogue (reuse Lab 4)

20. **Revoke** the rogue's Aurora path and **stop** the instance, exactly as in Lab 4. First look up the two security-group ids and check them:

    ```bash
    ROGUE_SG=$(aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
    AURORA_SG=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=io108-${STUDENT_ID}-aurora-sg" \
      --query 'SecurityGroups[0].GroupId' --output text)
    echo "ROGUE_SG=$ROGUE_SG AURORA_SG=$AURORA_SG"
    ```

    Both must start with `sg-`. If either is `None` or blank, re-run steps 1 and 5, then this block. Then revoke and stop:

    ```bash
    aws ec2 revoke-security-group-ingress --group-id "$AURORA_SG" --region "$REGION" \
      --protocol tcp --port 5432 --source-group "$ROGUE_SG"
    aws ec2 stop-instances --instance-ids "$ROGUE_ID" --region "$REGION"
    ```
<!-- source: content/narratives/Module_1_narrative.md §"containing the rogue" -->

    The revoke prints JSON containing `"Return": true` (`InvalidPermission.NotFound` means the rule is already gone; continue). The stop prints JSON showing `"CurrentState"` with `"Name": "stopping"`.

> **Expected Result:** **`rogue_contained`** turns **GREEN** within 1–3 minutes, **`aurora_no_rogue`** within about 8 (its open session has to expire).

---

## Task 9: Confirm the Board Is All Green = Incident Resolved

21. **Return** to the incident board and confirm **every tile is green** across all five lab bands. That is your objective signal that the compound incident is resolved.

22. **Sanity-check** end to end: reports flowing, app writing to the writer endpoint, partner path reachable, pods healthy, rogue contained. Run the stack's health check (about 30 seconds):

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    ./verify.sh
    ```

    > **Expected Result:** Seven `PASS:` lines, ending with **`ALL CHECKS PASSED -- your stack is healthy.`** If the report workflow or report-in-S3 check shows `FAIL:`, wait 5 minutes and run it again; reports are produced every 5 minutes. For any other `FAIL:`, go back to the task for that layer.

> **What Just Happened?** You ran a real compound incident the way it should be run: board first to scope it, deliberate triage order, the right tool per layer (Reachability Analyzer and Flow Logs for the route; the per-domain tools for IAM, pods, DB, security), and a clean confirmation that every check recovered. No single "root cause" — four of them, cleared in order.

---

## Task 10: Post-Incident Write-up (ServiceNow)

23. **Write** a structured post-incident report. In ServiceNow this is the major-incident record; capture at minimum:

    - **Severity:** declared **P0** (multi-system, customer-facing), de-escalated to P1/P2 as layers recovered, closed when the board went fully green.
    - **Timeline:** detection time (board), each tile's red-to-green time, and the action that flipped it.
    - **Root cause - one line per layer:**
      - Network: a more-specific `203.0.113.0/24` route pointed at the IGW blackholed the partner path.
      - IAM: orders-api IRSA role missing Aurora-secret + S3 permissions (AccessDenied).
      - Pod network: default-deny egress NetworkPolicy cut pod egress / DNS.
      - Security: rogue instance with stolen credentials querying Aurora.
    - **Remediation:** delete the misroute; restore the IRSA inline policy; disable the default-deny NetworkPolicy + restart the pods; revoke the rogue SG path + stop the instance.
    - **Follow-ups / prevention:** guardrails on route-table changes, IAM policy drift detection, NetworkPolicy review in CI, and how the rogue obtained credentials (feed to security).

> **Expected Result:** A complete ServiceNow incident record a teammate could read cold and understand what broke, what you did, and what should change so it does not recur.

---

## Troubleshooting

### A network tile stays red after deleting the route

**Check:** Confirm you deleted the route from the **private** route table (the one the EKS nodes/pods use), not a public one. Re-run the `describe-route-tables` query — the `203.0.113.0/24` entry should be gone and only `0.0.0.0/0 -> nat-...` should remain for egress.

### `orders_api_db_access` stays red

**Check:** Confirm `aws iam get-role-policy --role-name "$IRSA_ROLE" --policy-name "io108-${STUDENT_ID}-orders-api-inline"` shows the secret + S3 statements. (Pods still failing after Task 7? Re-run the step 19 restart.)

### `aurora_no_rogue` or `rogue_contained` stays red

**Check:** `aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].State.Name' --output text` should print `stopped` (or `stopping`); if it prints `running`, repeat step 20. `aurora_no_rogue` can take up to ~8 minutes after the stop while the rogue's open database session expires. Did you run `terraform apply` after step 20? That restarts the rogue and recreates its ingress rule; repeat step 20.

### Pod tiles stay red

**Check:** `kubectl -n orders get networkpolicy` should no longer show a default-deny. The conncheck CronJob runs every minute; give it a cycle to republish metrics. (After the *apply*, these two tiles take 5–8 minutes to go red.)

---

## Knowledge Check

**Question 1:** You have a routing incident where a partner CIDR is unreachable. You could reach for VPC Flow Logs, VPC Reachability Analyzer, or a full packet capture (Traffic Mirroring + tcpdump/tshark). Rank them for *this* fault and justify which you would run first and which you would rarely need.

**Question 2:** In a compound incident with seven red tiles, why is "fix the broadest network path first" a defensible triage order, and what is the risk of instead fixing whichever symptom you happen to recognize first?

**Question 3:** The misroute sent partner traffic to the internet gateway from a private subnet with no public IPs. Explain why that produces an *asymmetric blackhole* rather than an immediate, obvious error, and how that shows up in Flow Logs.

<details>
<summary><strong>Answers</strong></summary>

**A1:** Run **Reachability Analyzer first** — it reasons about configuration and names the bad hop (the `203.0.113.0/24 -> IGW` route) directly, even with no live traffic, which is the fastest path to root cause for a routing fault. Use **Flow Logs** next to confirm the real-world symptom (outbound records with no return traffic). A **full packet capture** is rarely needed for a pure routing fault — it is heavyweight and slower to stand up; reserve it for intermittent corruption, protocol-level bugs, or cases where flow/config tools come back clean but the problem persists.

**A2:** A network-path failure has the broadest blast radius and is the hardest to reason about once you are deep inside another layer, so stabilizing it first prevents it from confounding every other diagnosis. The risk of chasing the first symptom you recognize is tunnel vision: you may spend the incident on one layer while three others stay broken, and overlapping failures can mask or mimic each other, leading to wrong conclusions.

**A3:** The instances have no public IPs and rely on NAT for egress; sending partner-bound packets to the internet gateway means the SYN leaves but the return path cannot make it back to a private, non-NATed source — so instead of a clean "no route" error you get connections that hang and time out (asymmetric, one-way). In Flow Logs this appears as outbound records toward the partner CIDR with no matching inbound/return records (the outbound records show `ACCEPT`, not `REJECT`), which is the tell for a one-way path rather than a closed port.

</details>

---

## Lab Summary

- You led a **compound (P0) incident** from the **red/green board**, scoping the full set of failures before acting.
- You diagnosed a **network blackhole** with **Flow Logs** (asymmetry) and **Reachability Analyzer** (the misconfigured hop), and saw where an **OSS packet-analysis box** fits — and where it is overkill.
- You cleared every layer: deleted the **misroute**, restored the **IRSA** path, removed the default-deny **NetworkPolicy**, and **contained the rogue**.
- You confirmed **every tile green** and wrote a structured **ServiceNow post-incident report** with severity, timeline, root cause, and remediation.

**After the course:** your instructor tears down the stacks. The fixes you made by hand (route, IAM policy, Helm value, rogue) are not recorded in Terraform. To reset your stack to the healthy baseline yourself, go to `~/io-108/lab_environment/lab_env_student` and run `terraform plan -var scenario=healthy` on its own to preview the change (it changes nothing; expect a small plan, and if it shows dozens or 100+ to add, stop and tell your instructor). Then run `terraform apply -var scenario=healthy` on its own: if its `Plan:` line matches the preview, type `yes` and press **Enter**; otherwise type `no`, press **Enter**, and tell your instructor. When it finishes, run `./deploy_app.sh` on its own. If you used the CLI in Task 3, you can also delete the Reachability Analyzer objects: `aws ec2 delete-network-insights-analysis --network-insights-analysis-id "$NIA" --region "$REGION"`, then `aws ec2 delete-network-insights-path --network-insights-path-id "$NIP" --region "$REGION"`.

## Course Wrap-up

You now have a repeatable incident methodology: **board first, triage deliberately, right tool per layer, confirm recovery, write it up.** That is exactly how SYF's Technology Operations group runs connectivity and workload incidents day to day — with CloudWatch, NewRelic, SolarWinds, and Aviatrix as the production equivalents of the tools you used here. Well done clearing the board.
