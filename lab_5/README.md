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

It is 09:00 and the board is on fire: several tiles are red at once. There is no single root cause. This is a **compound incident**, and your job as incident lead is to **clear the whole board**:

- **Lead with the incident board** to see every impaired system, then choose a triage order.
- **Use the right tool per layer:** VPC Flow Logs and Reachability Analyzer for the network; the Labs 1-4 tools for IAM, pods and the rogue.
- **Optionally** compare an open-source packet-analysis box against the AWS-native tools.
- **Close out** with a structured post-incident report.

> **Note:** This lab uses native AWS networking. In your environment the hub-and-spoke transit is **Aviatrix**, managed by the network team; the concepts are the same. Where this guide says "fix the route table," in production you would ask the network team to correct the equivalent Aviatrix route.

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

On the board these appear as **`Partner path reachable`**, **`Network path OK`**, **`orders-api DB access (IRSA)`**, **`Pod → internet`**, **`Pod → DNS`**, **`Aurora: no rogue sessions`** and **`Rogue contained`**.

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

2. **Preview** the capstone incident. This changes nothing. Run it on its own:

    ```bash
    terraform plan -var scenario=lab5
    ```
<!-- source: course_outline_v3.md §"Lab 5" -->

    After about a minute it prints a plan ending in a line like:

    ```
    Plan: 1 to add, 2 to change, 0 to destroy.
    ```

    Expect about **2–4 to change, 0–2 to add, 0 to destroy**: `aws_route.capstone_misroute[0]` (the partner misroute), `aws_iam_role_policy.orders_api` (the IAM break) and `aws_cloudwatch_dashboard.incident_board`. Coming from Lab 4, it may also list `aws_ec2_instance_state.rogue[0]` or the `aurora_from_rogue` security-group rule. If it shows dozens or 100+ to add, or wants to destroy anything unexpected, stop and tell your instructor.

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

    - **If the `Plan:` line matches the preview,** type **`yes`** and press **Enter**.
    - **Otherwise,** type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** After about a minute, **`Apply complete! Resources: 1 added, 2 changed, 0 destroyed.`** (your numbers match your plan), followed by a list of outputs. If it ends with `Error:` instead, run the same `terraform apply` command again and type `yes`.

4. **Redeploy** the app, which applies the pod-network fault. Run this only after step 3 has finished:

    ```bash
    ./deploy_app.sh
    ```

    This takes from under a minute to about 5 minutes. **Do not press Ctrl+C.**

    > **Expected Result:** It prints `netpol default-deny: true` near the top and ends with `Deploy complete. Next steps:`. It may also print `WARNING: orders-api is not Ready`; that is fine, the app is meant to be broken.

5. **Capture** the values this lab uses into shell variables. **After any reconnect, run steps 1 and 5 again**:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
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

    > **Expected Result:**
    >
    > - `VPC` starts with `vpc-`.
    > - `IRSA role` reads `io108-<your-id>-orders-api-role`.
    > - `Secret ARN` starts with `arn:aws:secretsmanager:`.
    > - `Reports bucket` is not blank.
    > - `Rogue` shows `i-...` and a `10.x.x.x` address.
    > - `Flow logs` reads `/io108/<your-id>/vpc-flow-logs`.
    >
    > If anything is blank or `None`, run step 1 again, then this step.

> **Reconnecting later?** Start a new session, run `sudo su - ec2-user`, then run **steps 1 and 5** again, and re-run the first command block of the step you were on. A reconnect also loses `ENI`, `NIP` and `NIA` (step 11), `RT_ID` (step 17), and `ROGUE_SG` and `AURORA_SG` (step 28). Do **not** re-run step 3: it re-injects every fault.

---

## Task 2: Lead with the Board — Scope and Order the Incident

6. **Open** your incident board. In the AWS console search bar, type **CloudWatch** and open it. Check that the region at the top right matches your `REGION`. In the left menu choose **Dashboards**, then open **`io108-<your-id>-incident-board`**. Click the refresh icon (circular arrow) at the top right if the tiles look stale.

    > **Expected Result:** At least seven red tiles: **`Partner path reachable`**, **`Network path OK`**, **`orders-api DB access (IRSA)`**, **`Pod → internet`**, **`Pod → DNS`**, **`Aurora: no rogue sessions`** and **`Rogue contained`**. The two `Pod →` tiles go red last, 5–8 minutes after the deploy.

7. **Record** the incident and a triage order in your incident notes: declare it **P0** (multi-system, customer-facing) and note the time. A defensible order:

    - **Network path first:** the partner blackhole has the broadest blast radius and confuses every other diagnosis.
    - **IAM, then pod network:** app-domain failures the board has already localized.
    - **Rogue containment:** security, can run in parallel once the path is stable.

    > **Expected Result:** Your notes list the seven red tiles, P0, the declaration time, and the order you will work them in.

---

## Task 3: Diagnose the Network Blackhole (Flow Logs + Reachability Analyzer)

8. **Generate** traffic toward the partner range. Nothing in the stack sends packets there on its own, so Flow Logs have nothing to show until you do. This starts a throwaway pod that tries to connect to `203.0.113.10` and then deletes itself (about 10–40 seconds; longer the first time):

    ```bash
    kubectl -n orders run nettest --rm -i --restart=Never \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket; socket.setdefaulttimeout(8); socket.create_connection(('203.0.113.10',443))" || echo "blackholed (expected)"
    ```
    <!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

    Ignore `If you don't see a command prompt, try pressing enter.` if it appears.

    > **Expected Result:** A Python traceback ending in `TimeoutError: timed out`, then `pod "nettest" deleted` and **`blackholed (expected)`**. The timeout is the symptom: the connection never completed. Run it two or three times for more records.

9. **Query** VPC Flow Logs in Logs Insights. Wait about 1–2 minutes after step 8 for delivery, then:

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

    > **Expected Result:** Rows with `dstAddr` in `203.0.113.x` and `action` **`ACCEPT`**. `srcAddr` is your EKS **node's** IP, not the pod's (the VPC CNI source-NATs pod traffic leaving the VPC). `ACCEPT` only means the packet was allowed to leave. No rows? Wait another minute, re-run step 8, and run the query again.

10. **Check** for return traffic. In the same query, change the filter line to `| filter srcAddr like /203\.0\.113\./` and choose **Run query** again.

    > **Expected Result:** **0 rows**: packets leave but nothing comes back. That one-way pattern is the signature of a routing blackhole. (A security-group or NACL block would show `REJECT` records instead.)

11. **Run** VPC Reachability Analyzer. It reads your network *configuration* (route tables, gateways, security groups) and reports whether a path works. Use either path; both give the same answer.

    **Console path:** Open the **VPC console** (your region) → left menu **Network Analysis → Reachability Analyzer** → **Create and analyze path**:

    - **Source type:** **Network interfaces**. **Source:** a network interface (*ENI*) whose description or attached instance is one of your EKS nodes (`io108-<your-id>-node`).
    - **Destination type:** **IP address**. **Destination:** `203.0.113.10`.
    - **Protocol:** **TCP**.
    - Choose **Create and analyze path**. The status changes from *Pending* to *Succeeded* in about 1–3 minutes.

    If your console does not offer an IP address as the destination, use the CLI path.

    **CLI path:** Find a node's primary network interface:

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

    It prints `NIP=nip-... NIA=nia-...`, then pauses one minute **with no output**. Wait for the `$` prompt, then read the result:

    ```bash
    aws ec2 describe-network-insights-analyses --region "$REGION" --network-insights-analysis-ids "$NIA" \
      --query 'NetworkInsightsAnalyses[0].{Status:Status,Found:NetworkPathFound,Why:Explanations[].ExplanationCode}'
    ```

    If `Status` is `running`, wait 30 seconds and run this last command again.

    > **Expected Result:** Console: **Reachability status: Not reachable**. CLI: `Status` is `succeeded` and **`Found` is `false`**.

12. **Read** which hop is broken.

    **Console path:** Open your analysis and expand the **Explanations** section. Find the route-table hop.

    **CLI path:** Read the `Why` list from step 11; it names the same problem as explanation codes.

    > **Expected Result:** Your private route table has a route for `203.0.113.0/24` that sends traffic to an **internet gateway** (`igw-...`) instead of the NAT gateway. Instances in a private subnet have no public IP, so they cannot use an internet gateway. Record this as the network root cause in your incident notes.

> **Note:** Flow Logs show what *did* happen on the wire; Reachability Analyzer reasons about configuration and names the hop that breaks a path, even with no live traffic. For a routing fault, Reachability Analyzer localizes it fastest and Flow Logs confirm the symptom.

---

## Task 4: (Optional — Instructor Demo) Open-Source Packet-Analysis Box — Compare and Contrast

> **Optional. Skip this task unless your instructor runs it as a demo.** Nothing here is pre-built, nothing on the board depends on it, and the rest of the lab does not need it. Steps 13–16 outline what the demo does; they are not a full build guide.
>
> **Cost and teardown:** the analysis box and Traffic Mirroring are billed by the hour. Whoever builds it must tear it down the same day: **delete the mirror session, then the mirror target and mirror filter, then terminate the analysis box.**

13. **Launch a small EC2 analysis box** (e.g. `t3.small`, Amazon Linux 2023) in a subnet that can receive mirrored traffic, reachable via **SSM** (no SSH).
14. **Install the OSS toolkit:**

    ```bash
    sudo dnf install -y nmap tcpdump wireshark-cli   # nmap, tcpdump, tshark
    # ntopng for NetFlow-style flow visualization (from its repo / container)
    ```
<!-- source: content/narratives/Module_2_narrative.md §"Wireshark and tcpdump for packet capture" -->

15. **Configure VPC Traffic Mirroring:** create a **mirror target** (the analysis box ENI), a **mirror filter** (e.g. the partner CIDR), and a **mirror session** from the source ENI you care about. Mirrored packets arrive **wrapped in VXLAN** (UDP port 4789).
16. **Inspect the same incident on the wire.** Filter on UDP 4789 and let the tool decode the inner packet; a plain `net 203.0.113.0/24` filter would match nothing.

    ```bash
    sudo tcpdump -ni eth0 udp port 4789                                   # mirrored traffic; inner packets show the one-way SYNs to 203.0.113.x, no replies
    sudo tshark -ni eth0 -d udp.port==4789,vxlan -Y "ip.dst == 203.0.113.10"   # decode VXLAN, show only the inner partner-bound packets
    nmap -Pn -p 443 203.0.113.10                                          # active probe from the box itself
    # ntopng: open the web UI for flow-level visualization
    ```

    The interface may be `ens5` instead of `eth0` (`ip -br addr` lists it). Press **Ctrl+C** once to stop `tcpdump` or `tshark`.
<!-- source: content/narratives/Module_2_narrative.md §"an EC2 analysis box running nmap" -->

> **Note:** For this misroute, a Flow Logs query or Reachability Analyzer answered in minutes; a capture stack was slower to stand up. Reserve deep packet capture for intermittent corruption, protocol bugs, or "metrics look fine but it's still broken." In SYF's environment this role is played by **SolarWinds, NewRelic, and Aviatrix**.

---

## Task 5: Fix the Misroute

17. **Find** the private route table and the offending route.

    **Console path (view only):** **VPC console → Route tables** → select **`io108-<your-id>-private-rt`** → **Routes** tab. Find `203.0.113.0/24 → igw-...`.

    **CLI path (required, because step 18 uses `RT_ID`):**

    ```bash
    RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=io108-${STUDENT_ID}-private-rt" \
      --query 'RouteTables[0].RouteTableId' --output text)
    echo "RT_ID=$RT_ID"
    aws ec2 describe-route-tables --route-table-ids "$RT_ID" --region "$REGION" \
      --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,State]' --output table
    ```
<!-- source: facts_extracted_v2.md §"Route Table Troubleshooting" -->

    > **Expected Result:** `RT_ID=rtb-...`, then a table that includes (plus a `local` row):
    >
    > - `0.0.0.0/0` with a `nat-...` id: the healthy default route through the NAT gateway.
    > - **`203.0.113.0/24` with an `igw-...` id**: the misroute.
    >
    > If `RT_ID` is `None` or blank, re-run steps 1 and 5, then this block.

18. **Delete** the misroute so partner traffic falls back to the `0.0.0.0/0 -> NAT gateway` default:

    ```bash
    aws ec2 delete-route --route-table-id "$RT_ID" \
      --destination-cidr-block "$PARTNER_CIDR" --region "$REGION"
    ```
<!-- source: facts_extracted_v2.md §"Missing route" -->

    This prints **nothing** on success (`InvalidRoute.NotFound` means it was already deleted; continue). Then run the second command from step 17 (`aws ec2 describe-route-tables --route-table-ids ...`) again.

    > **Expected Result:** The `203.0.113.0/24` row is gone; `0.0.0.0/0 → nat-...` remains.

19. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab, wait 1–2 minutes (the probes run every minute), and click the refresh icon.

    > **Expected Result:** **`Partner path reachable`** and **`Network path OK`** are **green**. Record the time in your incident notes.

---

## Task 6: Restore the IRSA Path (reuse Lab 1)

The `orders-api DB access (IRSA)` tile is red because the orders-api IRSA role lost its Aurora-secret and S3 permissions: the same break as Lab 1.

20. **Check** the three values the policy is built from:

    ```bash
    echo "ROLE=$IRSA_ROLE"
    echo "SECRET=$SECRET_ARN"
    echo "BUCKET=$REPORTS_BUCKET"
    ```

    > **Expected Result:** `ROLE` reads `io108-<your-id>-orders-api-role` (a role **name**, not an `arn:...`), `SECRET` starts with `arn:aws:secretsmanager:`, and `BUCKET` is not blank. If any is wrong, re-run steps 1 and 5.

21. **Restore** the role's inline policy:

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

    > **Expected Result:** No output. A `MalformedPolicyDocument` or `ValidationError` means one of the values in step 20 was wrong.

22. **Verify** the policy was written:

    ```bash
    aws iam get-role-policy --role-name "$IRSA_ROLE" \
      --policy-name "io108-${STUDENT_ID}-orders-api-inline" \
      --query 'PolicyDocument.Statement[].Sid' --output text
    ```

    > **Expected Result:** One line containing `ReadAuroraMasterSecret` and `ReadWriteReports`.

23. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab, wait about 3 minutes, and click the refresh icon.

    > **Expected Result:** **`orders-api DB access (IRSA)`** is **green** (the probe asks IAM directly). The pods stay down until Task 7 restores egress; leave them alone for now.

---

## Task 7: Fix the Pod NetworkPolicy

The `Pod → internet` and `Pod → DNS` tiles are red because a default-deny egress NetworkPolicy stops the conncheck CronJob reaching the internet or DNS, so its metrics stop publishing.

24. **List** the NetworkPolicies in the `orders` namespace:

    ```bash
    kubectl -n orders get networkpolicy
    kubectl -n orders describe networkpolicy
    ```
<!-- source: content/narratives/Module_1_narrative.md §"resolve DNS and reach the internet" -->

    > **Expected Result:** A policy named **`orders-default-deny-egress`**; `describe` shows `Policy Types: Egress` and no allowed egress rules.

25. **Remove** the default-deny by redeploying the chart with the policy disabled. Run it from the lab directory (step 1), where the chart lives:

    ```bash
    helm upgrade orders charts/orders --namespace orders --reuse-values \
      --set networkPolicy.defaultDeny=false
    ```
    <!-- source: content/narratives/Module_1_narrative.md §"deployed with Helm" -->

    > **Expected Result:** `Release "orders" has been upgraded. Happy Helming!` Running `kubectl -n orders get networkpolicy` no longer lists `orders-default-deny-egress` (it may print `No resources found in orders namespace.`).

    > **Note:** `kubectl -n orders delete networkpolicy orders-default-deny-egress` also works, but the next deploy would bring the policy back; the Helm change is preferred.

26. **Restart** the orders-api so it starts with both fixes in place. The pods install packages at startup, so this takes about 1–3 minutes:

    ```bash
    kubectl -n orders rollout restart deploy/orders-api
    kubectl -n orders rollout status deploy/orders-api --timeout=180s
    ```
<!-- source: content/narratives/Module_3_narrative.md §"pods get their AWS permissions through IRSA" -->

    > **Expected Result:** `deployment.apps/orders-api restarted`, then `deployment "orders-api" successfully rolled out`. If it says `timed out waiting for the condition`, run the `rollout status` line again. If it times out twice, check that steps 21 and 25 succeeded.

27. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab, wait 2–3 minutes (the conncheck CronJob runs every minute), and click the refresh icon.

    > **Expected Result:** **`Pod → internet`** and **`Pod → DNS`** are **green**.

---

## Task 8: Contain the Rogue (reuse Lab 4)

28. **Look up** the rogue's and Aurora's security-group ids:

    ```bash
    ROGUE_SG=$(aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
    AURORA_SG=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=io108-${STUDENT_ID}-aurora-sg" \
      --query 'SecurityGroups[0].GroupId' --output text)
    echo "ROGUE_SG=$ROGUE_SG AURORA_SG=$AURORA_SG"
    ```

    > **Expected Result:** Both start with `sg-`. If either is `None` or blank, re-run steps 1 and 5, then this block.

29. **Revoke** the rogue's Aurora path and **stop** the instance, exactly as in Lab 4:

    ```bash
    aws ec2 revoke-security-group-ingress --group-id "$AURORA_SG" --region "$REGION" \
      --protocol tcp --port 5432 --source-group "$ROGUE_SG"
    aws ec2 stop-instances --instance-ids "$ROGUE_ID" --region "$REGION"
    ```
<!-- source: content/narratives/Module_1_narrative.md §"containing the rogue" -->

    > **Expected Result:** The revoke prints JSON containing `"Return": true` (`InvalidPermission.NotFound` means the rule is already gone; continue). The stop prints JSON with `"CurrentState"` showing `"Name": "stopping"`.

30. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab, wait 1–3 minutes, and click the refresh icon. Refresh again after about 8 minutes.

    > **Expected Result:** **`Rogue contained`** is **green** within 1–3 minutes; **`Aurora: no rogue sessions`** turns **green** within about 8 minutes (its open database session has to expire).

---

## Task 9: Confirm the Board Is All Green = Incident Resolved

31. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab and click the refresh icon.

    > **Expected Result:** **Every tile is green** across all five lab bands. That is your objective signal that the compound incident is resolved. Record the time in your incident notes.

32. **Run** the stack's end-to-end health check (about 30 seconds):

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    ./verify.sh
    ```

    > **Expected Result:** Seven `PASS:` lines, ending with **`ALL CHECKS PASSED -- your stack is healthy.`** If the report workflow or report-in-S3 check shows `FAIL:`, wait 5 minutes and run it again (reports are produced every 5 minutes). For any other `FAIL:`, go back to the task for that layer.

---

## Task 10: Post-Incident Write-up

33. **Write** a structured post-incident report in your incident notes (in production this is the ServiceNow major-incident record). Include at minimum:

    - **Severity:** declared **P0** (multi-system, customer-facing), de-escalated to P1/P2 as layers recovered, closed when the board went fully green.
    - **Timeline:** detection time, each tile's red-to-green time, and the action that flipped it.
    - **Root cause, one line per layer:**
      - Network: a more-specific `203.0.113.0/24` route pointed at the IGW blackholed the partner path.
      - IAM: orders-api IRSA role missing Aurora-secret + S3 permissions (AccessDenied).
      - Pod network: default-deny egress NetworkPolicy cut pod egress / DNS.
      - Security: rogue instance with stolen credentials querying Aurora.
    - **Remediation:** delete the misroute; restore the IRSA inline policy; disable the default-deny NetworkPolicy + restart the pods; revoke the rogue SG path + stop the instance.
    - **Follow-ups / prevention:** guardrails on route-table changes, IAM policy drift detection, NetworkPolicy review in CI, and how the rogue obtained credentials (feed to security).

    > **Expected Result:** A report a teammate could read cold and understand what broke, what you did, and what should change so it does not recur.

---

## Troubleshooting

### A network tile stays red after deleting the route

**Check:** Confirm you deleted the route from the **private** route table (`io108-<your-id>-private-rt`), not a public one. Re-run the `describe-route-tables` command from step 17: the `203.0.113.0/24` entry should be gone and only `0.0.0.0/0 -> nat-...` should remain for egress.

### `orders-api DB access (IRSA)` stays red

**Check:** Re-run step 22; it should show both statements. If pods are still failing after Task 7, re-run the step 26 restart.

### `Aurora: no rogue sessions` or `Rogue contained` stays red

**Check:** `aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].State.Name' --output text` should print `stopped` (or `stopping`); if it prints `running`, repeat steps 28–29. `Aurora: no rogue sessions` can take up to ~8 minutes after the stop. If you ran `terraform apply` after step 29, it restarted the rogue and recreated its ingress rule: repeat steps 28–29.

### Pod tiles stay red

**Check:** `kubectl -n orders get networkpolicy` should no longer show a default-deny. The conncheck CronJob runs every minute; give it 2–3 minutes. (After the *apply*, these two tiles take 5–8 minutes to go red.)

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
- You confirmed **every tile green** and wrote a structured **post-incident report** (framed for ServiceNow) with severity, timeline, root cause, and remediation.

**After the course:** your instructor tears down the stacks. The fixes you made by hand (route, IAM policy, Helm value, rogue) are not recorded in Terraform. To reset your stack to the healthy baseline yourself, go to `~/io-108/lab_environment/lab_env_student` and run `terraform plan -var scenario=healthy` on its own to preview the change (it changes nothing; expect a small plan, and if it shows dozens or 100+ to add, stop and tell your instructor). Then run `terraform apply -var scenario=healthy` on its own: if its `Plan:` line matches the preview, type `yes` and press **Enter**; otherwise type `no`, press **Enter**, and tell your instructor. When it finishes, run `./deploy_app.sh` on its own. If you used the CLI path in step 11, you can also delete the Reachability Analyzer objects: `aws ec2 delete-network-insights-analysis --network-insights-analysis-id "$NIA" --region "$REGION"`, then `aws ec2 delete-network-insights-path --network-insights-path-id "$NIP" --region "$REGION"`.

## Course Wrap-up

You now have a repeatable incident methodology: **board first, triage deliberately, right tool per layer, confirm recovery, write it up.** That is how SYF's Technology Operations group runs connectivity and workload incidents, with CloudWatch, NewRelic, SolarWinds, and Aviatrix as the production equivalents of the tools you used here. Well done clearing the board.
