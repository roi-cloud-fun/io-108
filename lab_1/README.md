# Lab 1: IAM Access Denial Investigation and Rogue Hunt

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 1 — IAM Access Denial Investigation and Rogue Hunt |
| **Duration** | 45 minutes |
| **Difficulty** | Intermediate |
| **Severity** | **P2** (degraded service — reports stalled, no data loss) |
| **Prerequisites** | Lab 0 complete: the stack is deployed, `deploy_app.sh` has run, and your incident board was green except the two known rogue tiles. AWS CLI v2, `kubectl`, `jq`. |
| **Builds On** | Lab 0 (the connected application and the incident board) |

---

## Lab Overview

This lab has two connected halves, both classic Operations work:

1. **Access-denial investigation (the sold incident).** The `orders-api` pod suddenly cannot read its Aurora database credentials. You will work from the symptom on the board, through the pod logs, to the IAM root cause, and restore service.
2. **Rogue hunt (the add-on).** With the service restored, you turn to the intruder that has been in your environment since Lab 0. Using **CloudTrail** (who acted) and **AWS Config** (what they created), you attribute and locate the rogue, then **contain** it.

Both halves are driven by tiles on your board. The access-denial fix turns **`orders-api DB access (IRSA)`** green; the containment turns **`Rogue contained`** green.

> **A note on the network layer.** This lab is primarily IAM and audit work, but the rogue's containment touches the network path. This lab uses native AWS networking (and AWS Transit Gateway where transit appears). In your environment the hub-and-spoke transit is **Aviatrix**, managed by the network team — the concepts map directly; the management plane differs.

---

## Scenario

It is mid-morning. A monitoring alert fires and your **`orders-api DB access (IRSA)`** tile on the incident board has gone **red**. The order-processing API is returning errors and the scheduled reports have stopped landing in S3. No deployment went out; nothing changed in the application code.

You open a **P2** incident in **ServiceNow** — the service is degraded but there is no data loss and no customer-facing outage yet. Your job: find why the API lost access, restore it, and then — because Operations has been carrying two known-red security tiles since the environment was built — finally run down the rogue principal that has been quietly talking to your database.

**To inject this incident** (instructor-led, or self-serve), re-apply your stack in the `lab1` scenario:

```bash
cd lab_environment/lab_env_student
cp terraform.tfvars.example terraform.tfvars
nano or vi terraform.tfvars
set your region and sXX (current student ID)

terraform init
Enter our state folder path: io108/sXX/terraform.tfstate

terraform plan  -var scenario=lab1     # student_id + region come from your terraform.tfvars (Lab 0)
terraform apply -var scenario=lab1
```
<!-- source: course_outline_v3.md §"Lab 1: IAM Access Denial Investigation" -->

This swaps the `orders-api` IRSA role's policy for one that is **missing** the Aurora-secret read and the S3 object permissions. Within a minute the board tile goes red.

---

## Learning Objectives

By the end of this lab, you will:

- Read an `AccessDenied` error from pod logs and identify the exact API action and principal involved.
- Inspect an IRSA role's inline policy and use `iam:SimulatePrincipalPolicy` to confirm which action is being denied and why.
- Restore the missing permission and verify the application recovers — `orders-api DB access (IRSA)` returns to green.
- Use **CloudTrail** to attribute activity to the rogue IAM principal and **AWS Config**/tag search to enumerate what it created.
- **Contain** the rogue instance and confirm `Rogue contained` turns green.

---

## Task 1: Triage from the Board

1. **Open** your incident board (**CloudWatch → Dashboards → `io108-$SID-incident-board`**) and confirm the **`orders-api DB access (IRSA)`** tile under the Lab 1 band is **red**. The `Reports flowing` tile (Lab 3 band) may also dip, because the reporting path depends on the same data.

2. **Re-establish** your shell variables if you opened a new terminal:

    ```bash
    export SID=sNN
    export REGION=us-east-1       # <- CHANGE to YOUR assigned region (e.g. us-east-2, eu-west-1)
    export IRSA_ROLE=$(terraform output -raw irsa_role_arn)
    export SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
    export REPORTS_BUCKET=$(terraform output -raw reports_bucket)
    aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" --region $REGION
    ```
<!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

> **Expected Result:** The `orders-api DB access (IRSA)` tile is red. You have a confirmed, scoped incident (P2) logged in ServiceNow.

---

## Task 2: Reproduce and Read the Pod Logs

3. **Look** at the pod state in the `orders` namespace:

    ```bash
    kubectl -n orders get pods
    ```
<!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

    The `orders-api` pods are likely `Running` but failing their readiness probe (the app starts, but `/health` returns an error because it cannot reach the database). They may show `READY 0/1`.

4. **Tail** the logs of an `orders-api` pod:

    ```bash
    POD=$(kubectl -n orders get pods -l app=orders-api -o jsonpath='{.items[0].metadata.name}')
    kubectl -n orders logs "$POD" --tail=40
    ```
<!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

5. **Find** the error. The application tries to read the Aurora master credentials from Secrets Manager at startup and on each `/health` check. You should see an `AccessDenied` of the form:

    ```
    botocore.exceptions.ClientError: An error occurred (AccessDeniedException)
    when calling the GetSecretValue operation: User:
    arn:aws:sts::<account>:assumed-role/io108-sNN-orders-api-role/<session>
    is not authorized to perform: secretsmanager:GetSecretValue on resource: <secret-arn>
    because no identity-based policy allows the secretsmanager:GetSecretValue action
    ```

> **Expected Result:** You can name the **denied action** (`secretsmanager:GetSecretValue`), the **principal** (the assumed `io108-$SID-orders-api-role`), and the **resource** (the Aurora master secret). The error explicitly says *no identity-based policy allows the action* — this is a permissions problem, not a network or credential-rotation problem.

---

## Task 3: Confirm the Root Cause in IAM

6. **Read** the role's inline policy directly. The IRSA role is `io108-$SID-orders-api-role` and its inline policy is `io108-$SID-orders-api-inline`:

    ```bash
    aws iam get-role-policy \
      --role-name io108-$SID-orders-api-role \
      --policy-name io108-$SID-orders-api-inline \
      --region $REGION
    ```
<!-- source: facts_extracted_v2.md §"Common IAM Issues" -->

    In the broken state the policy contains a single, harmless `s3:ListBucket` statement on the reports bucket — and **nothing else**. The `secretsmanager:GetSecretValue` permission and the S3 object (`PutObject`/`GetObject`) permissions are gone.

7. **Prove** the denial with the IAM policy simulator rather than guessing. Simulate the role against the exact action and resource from the log:

    ```bash
    aws iam simulate-principal-policy \
      --policy-source-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/io108-$SID-orders-api-role \
      --action-names secretsmanager:GetSecretValue \
      --resource-arns "$SECRET_ARN" \
      --query 'EvaluationResults[0].EvalDecision' --output text
    ```
<!-- source: facts_extracted_v2.md §"IAM Policy Simulator" -->

> **Expected Result:** The simulator returns **`implicitDeny`** — the action is denied because no statement allows it. Re-running the simulation for `s3:PutObject` against `$REPORTS_BUCKET/*` also returns `implicitDeny`. You have now confirmed the root cause without touching the running app: the role's policy was stripped of the permissions the workload needs.

> **IAM evaluation, briefly.** A request is allowed only if an `Allow` matches and no `Deny` overrides it. With the permission simply absent, the request falls through to the default **implicit deny**. There is no explicit `Deny` here to hunt for — the fix is to *add back* the missing `Allow`, not to remove a block.

---

## Task 4: Restore Access and Confirm Green

8. **Restore** the role's permissions to the healthy policy — full S3 object access on the reports bucket plus `secretsmanager:GetSecretValue` on the Aurora secret. Put the corrected inline policy back:

    ```bash
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    REPORTS_ARN="arn:aws:s3:::$REPORTS_BUCKET"

    aws iam put-role-policy \
      --role-name io108-$SID-orders-api-role \
      --policy-name io108-$SID-orders-api-inline \
      --region $REGION \
      --policy-document "$(cat <<JSON
    {
      "Version": "2012-10-17",
      "Statement": [
        { "Sid": "ReportsBucketObjects", "Effect": "Allow",
          "Action": ["s3:PutObject","s3:GetObject"],
          "Resource": "$REPORTS_ARN/*" },
        { "Sid": "ReportsBucketList", "Effect": "Allow",
          "Action": ["s3:ListBucket"], "Resource": "$REPORTS_ARN" },
        { "Sid": "ReadAuroraMasterSecret", "Effect": "Allow",
          "Action": ["secretsmanager:GetSecretValue"], "Resource": "$SECRET_ARN" }
      ]
    }
    JSON
    )"
    ```
<!-- source: Lab_1_narrative.md §"Phase 5: Remediate and Validate" -->

9. **Re-simulate** to confirm the fix at the IAM layer before touching the app:

    ```bash
    aws iam simulate-principal-policy \
      --policy-source-arn arn:aws:iam::$ACCOUNT:role/io108-$SID-orders-api-role \
      --action-names secretsmanager:GetSecretValue \
      --resource-arns "$SECRET_ARN" \
      --query 'EvaluationResults[0].EvalDecision' --output text
    ```
<!-- source: facts_extracted_v2.md §"IAM Policy Simulator" -->

    This now returns **`allowed`**.

10. **Restart** the `orders-api` pods so they re-attempt the secret read with the restored permission (IRSA credentials are assumed at runtime; a fresh attempt picks up the new policy immediately):

    ```bash
    kubectl -n orders rollout restart deploy/orders-api
    kubectl -n orders rollout status deploy/orders-api --timeout=180s
    ```
<!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

> **Expected Result:** Pods reach `READY 1/1`. Within a minute the **`orders-api DB access (IRSA)`** tile on the board turns **green**, and `Reports flowing` recovers on the next schedule period. The P2 incident's first half is resolved — record the root cause (missing `secretsmanager:GetSecretValue` on the IRSA role) in ServiceNow.

---

## Task 5: Begin the Rogue Hunt — Who? (CloudTrail)

With service restored, turn to the intruder. Two tiles have been red since Lab 0: `Rogue contained` and `Aurora: no rogue sessions`. You close the first one here.

11. **Identify** the rogue's IAM principal. Your stack tags it for discoverability. Find the role tagged `Rogue=true`:

    ```bash
    export ROGUE_ROLE=$(terraform output -raw rogue_actor_role_arn)
    export ROGUE_ID=$(terraform output -raw rogue_instance_id)
    export ROGUE_IP=$(terraform output -raw rogue_private_ip)
    echo "Rogue role: $ROGUE_ROLE"
    echo "Rogue host: $ROGUE_ID @ $ROGUE_IP"
    ```

    In a real investigation you would not have these as outputs — Task 6 shows how you would *discover* them. Capture them now so you can cross-check your findings.

12. **Query CloudTrail** for who has been reading the Aurora master secret. Both the
    legitimate app roles and the rogue call `GetSecretValue`, and they all show up in the
    `Username` field as generic `botocore-session-...` assumed-role sessions — so you cannot
    tell them apart from that column. The real attribution lives one level deeper, in each
    event's `userIdentity.sessionContext.sessionIssuer.userName` (the ROLE behind the
    session). Pull the full events and tally the calling roles:

    ```bash
    aws cloudtrail lookup-events \
      --region $REGION \
      --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
      --max-results 50 \
      --query 'Events[].CloudTrailEvent' --output json \
    | jq -r '.[] | fromjson | .userIdentity.sessionContext.sessionIssuer.userName' \
    | sort | uniq -c | sort -rn
    ```
<!-- source: Module_2_narrative.md §"CloudTrail Event Structure" -->

    Among the expected app roles (`io108-$SID-orders-api-role`, `-health-checker-role`,
    `-report-lambda-role`) you will find **`io108-$SID-rogue-actor`** — a principal that has
    no business reading the database credentials at all. CloudTrail shows you **who** acted,
    **when**, and **from where** — the attribution backbone of any incident.

> **Expected Result:** The role tally includes **`io108-$SID-rogue-actor`** reading the Aurora
> master secret — an identity that should never touch it. The legitimate app roles read it
> constantly (every few seconds), so the rogue's reads are a low-frequency minority in the
> list (it re-reads roughly every few minutes); the *identity*, not the volume, is the tell.
> This is your evidence that a second, unauthorized principal is using stolen credentials
> against your database.

---

## Task 6: What Did It Create? (AWS Config and Tag Search)

13. **Enumerate** the rogue's footprint with **AWS Config**. Config records resource configuration and relationships over time, so you can ask "what resources carry the rogue marker?" without already knowing their ids. Use a Config advanced query (Config console → **Advanced queries**) or the CLI:

    ```bash
    aws configservice select-resource-config \
      --region $REGION \
      --expression "SELECT resourceId, resourceType, tags WHERE tags.key = 'Rogue'"
    ```
<!-- source: facts_extracted_v2.md §"AWS Config for Change Correlation" -->

    > **Instructor note:** AWS Config requires an account-level configuration recorder, which lives in the shared lab stack (one recorder per account/region). If this query returns nothing, confirm the shared recorder is enabled; fall back to the EC2 tag search in step 14.

14. **Cross-check** with a direct tag search on EC2 — this finds the rogue **instance** even if Config is unavailable:

    ```bash
    aws ec2 describe-instances \
      --region $REGION \
      --filters "Name=tag:Rogue,Values=true" \
      --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Ip:PrivateIpAddress}' \
      --output table
    ```
<!-- source: Module_2_narrative.md §"CloudTrail Audit and Rogue Resources" -->

> **Expected Result:** You independently arrive at the same instance id and private IP you captured in Task 5 (`$ROGUE_ID` / `$ROGUE_IP`), plus the tagged `rogue-actor` role. You have now answered both investigative questions: **who** (CloudTrail → rogue-actor principal) and **what** (Config / tag search → the rogue EC2 instance and its IAM role).

---

## Task 7: Contain the Rogue

15. **Contain** the instance. The fastest containment that stops both its API activity and its database chatter is to **stop the instance**. (In a real incident you might first snapshot it for forensics; here, stopping is sufficient.)

    ```bash
    aws ec2 stop-instances --region $REGION --instance-ids "$ROGUE_ID"
    aws ec2 wait instance-stopped --region $REGION --instance-ids "$ROGUE_ID"
    ```
<!-- source: Module_2_narrative.md §"CloudTrail Audit and Rogue Resources" -->

    **Alternative containment (network isolation):** instead of stopping it, detach its egress path by removing the rogue's access to Aurora. Swap the instance off the rogue security group, or delete the standalone ingress rule that lets the rogue reach Aurora on 5432 (`io108-$SID-aurora-from-rogue`). Either approach severs the connection the `Rogue contained` probe watches.

16. **Confirm** on the board.

> **Expected Result:** Within a minute the **`Rogue contained`** tile turns **green**. Note that **`Aurora: no rogue sessions`** (the Lab 4 band) may also clear once the rogue's existing Postgres sessions age out — but the *definitive* database-side lockout, using `pg_stat_activity` and the Aurora ingress rules, is the subject of **Lab 4**. For now, the instance is contained and the P2 incident is fully resolved. Close it in ServiceNow with the timeline: access-denial root cause, restoration, and rogue containment.

---

## Knowledge Check

**Question 1:** The pod log said the request was denied "because no identity-based policy allows the action." Walking IAM's evaluation logic, why does restoring a missing `Allow` fix this, and why was there no explicit `Deny` to find?

**Answer:** IAM denies by default. A request is permitted only when a policy statement explicitly **allows** the action *and* no statement explicitly **denies** it. In this incident the `secretsmanager:GetSecretValue` permission was simply removed from the role's policy, so the request matched no `Allow` and fell through to the **implicit deny**. There was never an explicit `Deny` statement — the fix is to add the missing `Allow` back, which is exactly what restoring the healthy policy does. This is why `simulate-principal-policy` reported `implicitDeny` before the fix and `allowed` after.

**Question 2:** Why is `iam:SimulatePrincipalPolicy` a better first move than editing the policy and watching the app, when you suspect a permissions issue?

**Answer:** The simulator evaluates the *exact* principal, action, and resource against the live policies and returns the decision (`allowed` / `implicitDeny` / `explicitDeny`) **without making any change and without waiting on the application**. It confirms the root cause deterministically and lets you verify a proposed fix at the IAM layer before you touch the running workload — shrinking the change-and-pray loop. You only restart the pods once the simulation already says `allowed`.

**Question 3:** During the hunt you used CloudTrail and AWS Config for different questions. What does each answer, and why do you need both?

**Answer:** **CloudTrail** is the audit log of API activity — it answers **who** did **what action**, **when**, and **from where** (e.g., the rogue-actor principal reading the Aurora secret every minute). **AWS Config** records the configuration and relationships of resources over time — it answers **what exists / what was created** and lets you enumerate resources by attribute (e.g., everything tagged `Rogue=true`). You need both because attribution (CloudTrail) and footprint enumeration (Config) are different halves of the same investigation: one finds the actor, the other finds the assets.

---

## Lab Summary

You worked a **P2** access-denial incident from the board tile to root cause and back to green: pod logs surfaced an `AccessDenied` on `secretsmanager:GetSecretValue`, the IAM policy simulator confirmed an **implicit deny** caused by a stripped permission, and restoring the role's policy — full S3 object access plus the secret read — recovered the `orders-api DB access (IRSA)` check. You then opened the rogue hunt: **CloudTrail** attributed unauthorized secret reads to the tagged `rogue-actor` principal, **AWS Config** and a tag search enumerated the rogue EC2 instance, and you **contained** it — turning `Rogue contained` green. The deeper Aurora-side lockout waits for Lab 4.

## Completion Checklist

- [ ] `orders-api DB access (IRSA)` tile confirmed red (incident logged as P2 in ServiceNow)
- [ ] `AccessDenied` on `secretsmanager:GetSecretValue` found in `orders-api` pod logs
- [ ] Root cause confirmed: role policy missing the secret read and S3 object permissions (`simulate-principal-policy` → `implicitDeny`)
- [ ] Healthy policy restored with `put-role-policy`; re-simulation returns `allowed`
- [ ] `orders-api` restarted; `orders-api DB access (IRSA)` tile green
- [ ] CloudTrail activity attributed to the `rogue-actor` principal
- [ ] Rogue EC2 instance enumerated via AWS Config / tag search
- [ ] Rogue contained (stopped or network-isolated); `Rogue contained` tile green

---

## Next Steps

In **Lab 2: EKS Pod Failure Investigation**, the `EKS pods schedulable` tile goes red — your pods are stuck `Pending` with nowhere to run. You will diagnose the scheduling failure with `kubectl describe` and Container Insights, trace it to node-group capacity, and scale it back up. As an add-on you will untangle a default-deny NetworkPolicy that is cutting pod egress to the internet and DNS, learning why the VPC CNI must have NetworkPolicy enforcement enabled for those rules to bite.
