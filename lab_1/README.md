# Lab 1: IAM Access Denial Investigation and Rogue Hunt

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 1 — IAM Access Denial Investigation and Rogue Hunt |
| **Duration** | 45 minutes |
| **Difficulty** | Intermediate |
| **Severity** | **P2** (degraded service — the orders API cannot reach its database; no data loss) |
| **Prerequisites** | Lab 0 complete (by you or by your instructor): the stack is deployed, `deploy_app.sh` has run, and your incident board was green except the two known rogue tiles. AWS CLI v2, `kubectl`, `jq`. |
| **Builds On** | Lab 0 (the connected application and the incident board) |

---

## Lab Overview

This lab has two connected halves, both classic Operations work:

1. **Access-denial investigation (the sold incident).** The `orders-api` pod suddenly cannot read its Aurora database credentials. You will work from the symptom on the board, through the pod logs, to the IAM root cause, and restore service.
2. **Rogue hunt (the add-on).** With the service restored, you turn to the intruder that has been in your environment since Lab 0. Using **CloudTrail** (who acted) and **AWS Config** (what they created), you attribute and locate the rogue, then **contain** it.

Both halves are driven by tiles on your board. The access-denial fix turns **`orders-api DB access (IRSA)`** green; the containment turns **`Rogue contained`** green.

> **A note on the network layer.** This lab is primarily IAM and audit work, but the rogue's containment touches the network path. This lab uses native AWS networking (and AWS Transit Gateway where transit appears). In your environment the hub-and-spoke transit is **Aviatrix**, managed by the network team — the concepts map directly; the management plane differs.

---

## Start Here: Connect to Your Lab Host

Your instructor has already built your stack (Lab 0) and given you a student id, a region, and an EC2 **lab host** with every tool installed. Do this once. Run **everything** in this course from the lab host, because your cluster only accepts `kubectl` from the machine that last ran `terraform apply`.

> **Built Lab 0 yourself?** If you did it on this same machine, skip to the Scenario.

1. **Connect.** In the AWS console, open **Systems Manager → Session Manager → Start session**, in the region your instructor gives you for the hosts. Select **`io108-<your-id>-lab-host`** and choose **Start session**.

    A terminal opens in your browser with a bare `sh-5.2$` prompt. This is the lab host.

2. **Switch** to the user that owns the lab files. Do this every time you connect:

    ```bash
    sudo su - ec2-user
    whoami
    ```

    `whoami` must print **`ec2-user`**. If it prints `ssm-user`, run `sudo su - ec2-user` again.

3. **Set** your student id and region, verify them, then save them so they survive a reconnect.

    Set the two values:

    ```bash
    export SID=userNN             # <- your assigned student id, e.g. user01
    export REGION=us-east-1       # <- your assigned region
    ```

    **Verify** them before saving:

    ```bash
    echo "SID=$SID REGION=$REGION"
    ```

    You should see your own id and region, for example `SID=user01 REGION=us-east-1`. If either value is blank or still reads `userNN`, re-run the `export` lines above with the correct values. Do not continue until the output is right.

    **Save** them to `~/.bashrc` only after they check out. The second line also stops the AWS CLI from opening long output in a pager:

    ```bash
    echo "export SID=$SID REGION=$REGION" >> ~/.bashrc
    echo 'export AWS_PAGER=""' >> ~/.bashrc && export AWS_PAGER=""
    ```

4. **Check** your stack before you touch it. **Do not run Terraform yet.** Terraform builds whatever its state file says is missing, so if your id or region is wrong it will build a second copy of the whole stack (100+ resources, about 20 minutes). These read-only commands change nothing; they confirm your stack exists under the id and region you just set:

    ```bash
    STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 \
      --name /io108/tfstate-bucket --query Parameter.Value --output text)
    echo "State bucket: $STATE_BUCKET"
    aws s3api head-object --bucket "$STATE_BUCKET" --key "io108/$SID/terraform.tfstate" \
      --query '[LastModified,ContentLength]' --output text
    aws eks describe-cluster --name io108-$SID-eks --region $REGION \
      --query cluster.status --output text
    aws rds describe-db-clusters --db-cluster-identifier io108-$SID-aurora --region $REGION \
      --query 'DBClusters[0].Status' --output text
    aws iam get-role-policy --role-name io108-$SID-orders-api-role \
      --policy-name io108-$SID-orders-api-inline --query PolicyName --output text
    aws ec2 describe-instances --region $REGION \
      --filters "Name=tag:Rogue,Values=true" "Name=tag:Student,Values=$SID" \
      --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
    ```

    > **Expected Result:** Six lines of output, in this order:
    >
    > | Check | What you should see |
    > |---|---|
    > | State bucket | `State bucket: io108-tfstate-...` |
    > | Your state file | one line: a date and a size in bytes, e.g. `2026-11-25T16:58:00+00:00  412345` |
    > | Your EKS cluster | `ACTIVE` |
    > | Your Aurora cluster | `available` |
    > | The policy Lab 1 breaks | `io108-<your-id>-orders-api-inline` |
    > | Your rogue instance | `i-...   running` |
    >
    > **If `State bucket:` is followed by nothing, or any command prints an error such as `Not Found` / `404`, `Invalid bucket name`, `ResourceNotFoundException`, `DBClusterNotFoundFault` or `NoSuchEntity`: stop.** Do not run Terraform. Re-check `SID` and `REGION` (step 3); if they are right, tell your instructor your stack is missing.

    **What Lab 1 changes in this stack.** Everything else stays exactly as your instructor built it:

    | Resource | Who changes it | When |
    |---|---|---|
    | EKS access entry (who may use `kubectl`) | Terraform | Step 7: moves cluster access to your lab host |
    | `io108-<your-id>-orders-api-inline` (the orders API's IAM policy) | Terraform `scenario=lab1` breaks it; **you** repair it | Scenario, then Tasks 3–4 |
    | `orders-api` pods | **You** restart them | Task 5 |
    | `io108-<your-id>-rogue` EC2 instance | **You** stop it | Task 8 |

    Optional: look at them in the console now (all in your region): **EKS → Clusters**, **RDS → Databases**, **IAM → Roles** (search `orders-api`), and **EC2 → Instances** (search `rogue`).

5. **Point** Terraform at your stack. Terraform keeps its record of what it built (the *state*) in the S3 file you just checked. These commands write your id and region into `terraform.tfvars`, then connect Terraform to that state file:

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

    If either line is wrong, go back to step 3. Then initialize Terraform (this downloads its plugins, about 30 seconds):

    ```bash
    terraform init -backend-config="bucket=$STATE_BUCKET" \
      -backend-config="key=io108/$SID/terraform.tfstate"
    ```

    > **Expected Result:** `terraform init` ends with a green **`Terraform has been successfully initialized!`**. If it complains that the bucket is empty or missing (for example after a reconnect), re-run the first two lines of step 4, then this command.

6. **Preview** what Terraform will change. This command changes nothing; it only shows the plan:

    ```bash
    terraform plan -var scenario=healthy
    ```

    It takes about a minute, then ends with a `Plan:` line. **Check it.** It must read **`Plan: 2 to add, 0 to change, 2 to destroy.`** The resources listed above it are the two `aws_eks_access_*` entries that move cluster access to your lab host.

    - **If it matches,** go on to step 7.
    - **If it shows any other numbers, stop** and tell your instructor. In particular, **dozens or 100+ "to add" means Terraform cannot see your stack**; applying it would build a second copy.
    - If it says **`No changes. Your infrastructure matches the configuration.`**, your lab host already has cluster access (for example, you did this before). Skip step 7 and go on to step 8.

7. **Apply** the healthy baseline. This grants your lab host access to your EKS cluster; nothing else changes. Run:

    ```bash
    terraform apply -var scenario=healthy
    ```

    Terraform prints the same plan again and stops at a confirmation prompt:

    ```
    Plan: 2 to add, 0 to change, 2 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    **Check that the `Plan:` line matches the preview in step 6** (**2 to add, 0 to change, 2 to destroy**):

    - **If it matches,** type **`yes`** and press **Enter**. Terraform will not continue until you do, and anything other than `yes` cancels.
    - **If it shows any other numbers,** type **`no`** and press **Enter**, then tell your instructor. In particular, **dozens or 100+ "to add" means Terraform cannot see your stack**, and `yes` would build a second copy of it.

    > **Expected Result:** After about a minute, Terraform prints **`Apply complete! Resources: 2 added, 0 changed, 2 destroyed.`** followed by a list of outputs. You are returned to the `$` prompt.
    >
    > If instead Terraform prints **`No changes. Your infrastructure matches the configuration.`** and `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` without asking for `yes`, your lab host already has cluster access (for example, you ran this step before). That is fine; continue.

8. **Connect** `kubectl` to your cluster, then **verify** it can reach the cluster:

    ```bash
    aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" --region $REGION
    kubectl get pods -n kube-system
    ```

    `update-kubeconfig` prints one line, `Added new context arn:aws:eks:...:cluster/io108-<your-id>-eks to /home/ec2-user/.kube/config`. `kubectl` then lists the cluster's system pods.

    > **Expected Result:** A table of about six pods, every one `Running` (names end in random characters):
    >
    > ```
    > NAME                       READY   STATUS    RESTARTS   AGE
    > aws-node-xxxxx             2/2     Running   0          2h
    > aws-node-yyyyy             2/2     Running   0          2h
    > coredns-xxxxxxxxxx-xxxxx   1/1     Running   0          2h
    > coredns-xxxxxxxxxx-yyyyy   1/1     Running   0          2h
    > kube-proxy-xxxxx           1/1     Running   0          2h
    > kube-proxy-yyyyy           1/1     Running   0          2h
    > ```
    >
    > **If you see `error: You must be logged in to the server (Unauthorized)`** or `the server has asked for the client to provide credentials`, step 7 did not finish: re-run step 7 and make sure you typed `yes`. If you see `couldn't get current server API group list` or a timeout, check that `REGION` is right (`echo $REGION`) and re-run this step.

9. **Verify** the whole baseline with the course's check script (about 30 seconds):

    ```bash
    ./verify.sh
    ```

    It runs seven checks and prints `PASS:` or `FAIL:` for each.

    > **Expected Result:** Seven `PASS:` lines (EKS nodes, orders pods, orders-api `/health`, Aurora, report workflow, report in S3, dashboard), ending with a line that starts **`ALL CHECKS PASSED -- your stack is healthy.`**
    >
    > **Troubleshooting:** If `verify.sh` shows `FAIL:` only for the report workflow or the report in S3, wait 5 minutes and run `./verify.sh` again; reports are produced every 5 minutes. If the `orders pods` and `/health` checks fail, run `kubectl -n orders get pods`: **`No resources found in orders namespace`** means the application was never installed on your stack (Lab 0's `deploy_app.sh` step). Tell your instructor; do not start the Scenario until it is installed. For any other `FAIL:`, tell your instructor.

10. **Open** your incident board. In the AWS console search bar, type **CloudWatch** and open it. Check that the region selector at the top right matches your `REGION`. In the left menu choose **Dashboards**, then open **`io108-<your-id>-incident-board`** (for example `io108-user01-incident-board`; *not* the similarly named `...-incident-dashboard`).

    > **Expected Result:** Every tile is **green** except two: **`Rogue contained`** and **`Aurora: no rogue sessions`**. Those two are red on purpose; you hunt the rogue later in this lab and in Lab 4. Tiles refresh about once a minute; click the refresh icon (circular arrow) at the top right to update them. If any other tile is red, wait 2 minutes, refresh, and tell your instructor if it stays red. Skim **Lab 0, Task 7** for what each tile means.

> **Reconnecting later?** Sessions time out when idle, and a new session forgets every shell variable except `SID` and `REGION` (saved in step 3). Start a new session, run `sudo su - ec2-user`, then re-run the **"Capture the values"** step of the lab you are on (in this lab, **step 15**). It changes to the right directory and restores everything that lab uses. Do not repeat steps 3–10.

---

## Scenario

It is mid-morning. A monitoring alert fires and your **`orders-api DB access (IRSA)`** tile on the incident board has gone **red**. The order-processing API is returning errors and cannot reach its database. No deployment went out; nothing changed in the application code.

You open a **P2** incident in **ServiceNow** — the service is degraded but there is no data loss and no customer-facing outage yet. Your job: find why the API lost access, restore it, and then — because Operations has been carrying two known-red security tiles since the environment was built — finally run down the rogue principal that has been quietly talking to your database.

---

## Learning Objectives

By the end of this lab, you will:

- Read an `AccessDenied` error from pod logs and identify the exact API action and principal involved.
- Inspect an IRSA role's inline policy and use `iam:SimulatePrincipalPolicy` to confirm which action is being denied and why.
- Restore the missing permission and verify the application recovers — `orders-api DB access (IRSA)` returns to green.
- Use **CloudTrail** to attribute activity to the rogue IAM principal and **AWS Config**/tag search to enumerate what it created.
- **Contain** the rogue instance and confirm `Rogue contained` turns green.

---

## Task 1: Lab Setup

Finish **Start Here** (steps 1–10) first. Inject this incident now, unless your instructor tells you they already did. Run each code block on its own, and wait for it to finish before you start the next.

11. **Go to** the lab directory and **check** your variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
    ```

    The `echo` must show your own id and region, for example `SID=user01 REGION=us-east-1`. If it is blank, run `source ~/.bashrc` and run this block again.

12. **Preview** the incident. This command changes nothing; it only shows the plan. Run it on its own:

    ```bash
    terraform plan -var scenario=lab1
    ```

    It takes 15–60 seconds and ends with a `Plan:` line. **Check it.** It must read **`Plan: 0 to add, 2 to change, 0 to destroy.`**, and the two resources marked `~ update in-place` are:

    - `aws_iam_role_policy.orders_api`: the orders API's IAM policy, which is the fault
    - `aws_cloudwatch_dashboard.incident_board`: the board header, which shows the active scenario

    If it shows anything to add or destroy, **stop** and tell your instructor; do not run step 13.

13. **Inject** the incident: apply the `lab1` scenario. Run this command on its own:

    ```bash
    terraform apply -var scenario=lab1
    ```
<!-- source: course_outline_v3.md §"Lab 1: IAM Access Denial Investigation" -->

    Terraform prints the same plan again and stops at `Enter a value:`. If the `Plan:` line matches the preview in step 12 (**0 to add, 2 to change, 0 to destroy**), type **`yes`** and press **Enter**. Otherwise type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** After a few seconds, **`Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`** Within 1–2 minutes the `orders-api DB access (IRSA)` tile goes red.

    This swaps the `orders-api` IRSA role's policy for one that is **missing** the Aurora-secret read and the S3 object permissions.

---

## Task 2: Triage from the Board

14. **Refresh** the incident board you opened in Start Here step 10 (click the circular-arrow icon at the top right). Confirm the **`orders-api DB access (IRSA)`** tile under the Lab 1 band is now **red**. The `Reports flowing` tile (Lab 3 band) stays green: the report Lambda uses its own role, which this incident does not touch.

15. **Capture** the values this lab uses into shell variables. Later steps depend on them. `SID` and `REGION` already come from `~/.bashrc` (Start Here step 3), so they are only displayed here, not set. **After any reconnect, run this block again**, because a new session forgets these variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
    export IRSA_ROLE=$(terraform output -raw irsa_role_arn)
    export SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
    export REPORTS_BUCKET=$(terraform output -raw reports_bucket)
    export ROGUE_ROLE=$(terraform output -raw rogue_actor_role_arn)
    export ROGUE_ID=$(terraform output -raw rogue_instance_id)
    export ROGUE_IP=$(terraform output -raw rogue_private_ip)
    export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    echo "role=$IRSA_ROLE bucket=$REPORTS_BUCKET rogue=$ROGUE_ID"
    ```
<!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

    **Verify** the two `echo` lines. The first must show your own id and region (not blank, not `userNN`). If it is blank, run `source ~/.bashrc` and re-run the block; if it is still wrong, redo Start Here step 3. The second must show an `arn:aws:iam::...:role/io108-<your-id>-orders-api-role`, a bucket name, and an `i-...` instance id. If any value is blank, or you see `No outputs found`, Terraform is not connected to your stack: redo Start Here steps 4–5.

> **Expected Result:** The `orders-api DB access (IRSA)` tile is red, and both `echo` lines show real values (the commands in between print nothing). You have a confirmed, scoped incident (P2). Record it in your incident notes (in production you would open it in ServiceNow).

---

## Task 3: Reproduce and Read the Pod Logs

16. **Look** at the pod state in the `orders` namespace:

    ```bash
    kubectl -n orders get pods
    ```
    <!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

    You will see output like this (names and ages differ):

    ```
    NAME                              READY   STATUS      RESTARTS   AGE
    orders-api-65d98c7b59-bw4f6       1/1     Running     0          11h
    orders-api-65d98c7b59-lvqf8       1/1     Running     0          11h
    orders-conncheck-29927910-zk2st   0/1     Completed   0          45s
    orders-worker-765f947b85-5qx2g    1/1     Running     0          13h
    ```

    Only the `orders-api` rows matter. **They most likely still look healthy (`1/1 Running`, 0 restarts).** The failure is intermittent at first: some `/health` checks still succeed, so Kubernetes has not marked the pods unready. The pod table does not show this fault, which is a lesson in itself: the evidence is in the logs (next step). If the pods were restarted after the fault began, or the incident has run longer, you may instead see `0/1`, restarts, or `CrashLoopBackOff`. `Completed` conncheck pods are normal and can be ignored.

17. **Tail** the logs of an `orders-api` pod:

    ```bash
    POD=$(kubectl -n orders get pods -l app=orders-api -o jsonpath='{.items[0].metadata.name}')
    kubectl -n orders logs "$POD" --tail=40      # container restarted? add --previous
    ```
<!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

18. **Find** the error. The application tries to read the Aurora master credentials from Secrets Manager at startup and on each `/health` check. Most log lines are web requests such as `"GET /health HTTP/1.1" 200 -`, and you will see `503` responses mixed in with the `200`s. Look for a line containing **`ERROR health check failed:`**. It is one long line (wrapped here for width):

    ```
    2026-11-26 06:29:14,322 ERROR health check failed: An error occurred
    (AccessDeniedException) when calling the GetSecretValue operation: User:
    arn:aws:sts::<account>:assumed-role/io108-<your-id>-orders-api-role/botocore-session-<n>
    is not authorized to perform: secretsmanager:GetSecretValue on resource:
    arn:aws:secretsmanager:...:secret:rds!cluster-... because no identity-based policy
    allows the secretsmanager:GetSecretValue action
    ```

    If no `ERROR` line appears yet, wait a minute and run the `logs` command again (the first error can take a minute or more after the fault is injected). If the pod has restarted, you may instead see a Python traceback ending in `botocore.exceptions.ClientError:` with the same message; add `--previous` to the `logs` command to see the run before the restart.

> **Expected Result:** You can name the **denied action** (`secretsmanager:GetSecretValue`), the **principal** (the assumed `io108-$SID-orders-api-role`), and the **resource** (the Aurora master secret). The error explicitly says *no identity-based policy allows the action* — this is a permissions problem, not a network or credential-rotation problem.

---

## Task 4: Confirm the Root Cause in IAM

19. **Read** the role's inline policy directly. The IRSA role is `io108-<your-id>-orders-api-role` and its inline policy is `io108-<your-id>-orders-api-inline`. Use either path; both show the same policy.

    **Console path:** In the AWS console search bar, type **IAM** and open it. In the left menu choose **Roles**, type `orders-api` in the search box, and open **`io108-<your-id>-orders-api-role`**. On the **Permissions** tab, under **Permissions policies**, click the **+** next to **`io108-<your-id>-orders-api-inline`** (type **Customer inline**) to expand it, then choose **JSON** to see the raw policy.

    **CLI path:**

    ```bash
    aws iam get-role-policy \
      --role-name io108-$SID-orders-api-role \
      --policy-name io108-$SID-orders-api-inline \
      --region $REGION
    ```
    <!-- source: facts_extracted_v2.md §"Common IAM Issues" -->

    The CLI output is JSON; look under `PolicyDocument` → `Statement`. Either way, in the broken state the policy contains a single, harmless `s3:ListBucket` statement on the reports bucket — and **nothing else**. The `secretsmanager:GetSecretValue` permission and the S3 object (`PutObject`/`GetObject`) permissions are gone.

20. **Prove** the denial with the IAM policy simulator rather than guessing. The simulator evaluates the role's real policies against an exact action and resource and tells you whether AWS would allow it, without changing anything. Simulate the role against the action and resource from the log.

    **Console path:** First print the secret ARN you will paste into the simulator:

    ```bash
    echo "$SECRET_ARN"
    ```

    Open the IAM Policy Simulator at **https://policysim.aws.amazon.com** (it opens in its own tab and uses your current console sign-in). Then:

    - In the left pane, change **Users** to **Roles** and select **`io108-<your-id>-orders-api-role`**. Its policies appear under **Permission policies**.
    - In the right pane, for **Select service** choose **Secrets Manager**, and for **Select actions** choose **GetSecretValue**.
    - Expand the **GetSecretValue** row. In **Resource**, paste the `SECRET_ARN` value you printed above.
    - Choose **Run Simulation**.

    The **Permission** column shows **denied**, and expanding the row shows **Implicitly denied (no matching statements)**. To check the S3 permission too, choose **Clear Results**, select service **Amazon S3**, action **PutObject**, resource `arn:aws:s3:::<your reports bucket>/*` (the bucket name is in `$REPORTS_BUCKET`), and run it again: also **denied**.

    **CLI path:**

    ```bash
    aws iam simulate-principal-policy \
      --policy-source-arn "$IRSA_ROLE" \
      --action-names secretsmanager:GetSecretValue \
      --resource-arns "$SECRET_ARN" \
      --query 'EvaluationResults[0].EvalDecision' --output text
    aws iam simulate-principal-policy \
      --policy-source-arn "$IRSA_ROLE" \
      --action-names s3:PutObject \
      --resource-arns "arn:aws:s3:::$REPORTS_BUCKET/*" \
      --query 'EvaluationResults[0].EvalDecision' --output text
    ```
<!-- source: facts_extracted_v2.md §"IAM Policy Simulator" -->

> **Expected Result:** The console shows **denied / Implicitly denied** for both actions, and each CLI command prints one word, **`implicitDeny`** — the action is denied because no statement allows it. If you get `Invalid ARN` or a blank value error, re-run step 15. You have now confirmed the root cause without touching the running app: the role's policy was stripped of the permissions the workload needs.

> **IAM evaluation, briefly.** A request is allowed only if an `Allow` matches and no `Deny` overrides it. With the permission simply absent, the request falls through to the default **implicit deny**. There is no explicit `Deny` here to hunt for — the fix is to *add back* the missing `Allow`, not to remove a block.

---

## Task 5: Restore Access and Confirm Green

21. **Restore** the role's permissions to the healthy policy — full S3 object access on the reports bucket plus `secretsmanager:GetSecretValue` on the Aurora secret. First **verify** the two values the policy is built from:

    ```bash
    echo "bucket=$REPORTS_BUCKET"
    echo "secret=$SECRET_ARN"
    ```

    Both must show a value (the secret starts with `arn:aws:secretsmanager:`). If either is blank, re-run step 15. Then put the corrected inline policy back, using either path.

    **Console path:** Print the corrected policy with your real bucket and secret filled in:

    ```bash
    REPORTS_ARN="arn:aws:s3:::$REPORTS_BUCKET"
    cat <<JSON
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
    ```

    Select and copy the whole printed JSON, from the first `{` to the last `}`. In the IAM console, open **`io108-<your-id>-orders-api-role`** again (step 19). On the **Permissions** tab, select the checkbox next to **`io108-<your-id>-orders-api-inline`** and choose **Edit**. Choose the **JSON** tab, select everything in the editor and delete it, then paste the policy you copied. Choose **Next**, then **Save changes**. A green banner confirms the policy was updated. (If the editor shows a red error, the paste was incomplete: copy the whole block again.)

    **CLI path:**

    ```bash
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

    > **Expected Result:** In the console, the green **policy updated** banner. On the CLI, the command returns to the `$` prompt with **no output**. That is success. Any line starting `An error occurred` (for example `MalformedPolicyDocument`) means it failed: re-check the two `echo` values and run it again.

22. **Re-simulate** to confirm the fix at the IAM layer before touching the app.

    **Console path:** In the Policy Simulator tab, reload the page, select the role again (the simulator caches the old policy until you do), and run the same **GetSecretValue** simulation on your secret ARN. The **Permission** column now shows **allowed**.

    **CLI path:**

    ```bash
    aws iam simulate-principal-policy \
      --policy-source-arn "$IRSA_ROLE" \
      --action-names secretsmanager:GetSecretValue \
      --resource-arns "$SECRET_ARN" \
      --query 'EvaluationResults[0].EvalDecision' --output text
    ```
    <!-- source: facts_extracted_v2.md §"IAM Policy Simulator" -->

    This now returns **`allowed`** (console: **allowed**). If it still says `implicitDeny` / **denied**, wait 15 seconds (IAM changes take a moment to spread) and run it again.

23. **Restart** the `orders-api` pods so they re-attempt the secret read with the restored permission (IRSA credentials are assumed at runtime; a fresh attempt picks up the new policy immediately):

    ```bash
    kubectl -n orders rollout restart deploy/orders-api
    kubectl -n orders rollout status deploy/orders-api --timeout=300s
    ```
<!-- source: facts_extracted_v2.md §"kubectl Debugging Commands" -->

    The first command prints `deployment.apps/orders-api restarted`. The second waits while new pods start, one at a time (each installs its Python packages first), printing lines that start `Waiting for deployment "orders-api" rollout to finish:` followed by a progress message. This takes about 2–4 minutes. Do not press Ctrl+C.

> **Expected Result:** `deployment "orders-api" successfully rolled out`. `kubectl -n orders get pods` shows both `orders-api` pods `1/1 Running`. Within a minute the **`orders-api DB access (IRSA)`** tile on the board turns **green** (refresh the dashboard); it may already be green, because the old pods recover as soon as IAM allows the read. If you instead see `error: timed out waiting for the condition`, run `kubectl -n orders get pods` and wait until both `orders-api` pods show `1/1 Running`. The P2 incident's first half is resolved: record the root cause (missing `secretsmanager:GetSecretValue` on the IRSA role) in your incident notes.

---

## Task 6: Begin the Rogue Hunt — Who? (CloudTrail)

With service restored, turn to the intruder. Two tiles have been red since Lab 0: `Rogue contained` and `Aurora: no rogue sessions`. You close the first one here.

24. **Display** the rogue's identifiers, which you captured from Terraform outputs in step 15:

    ```bash
    echo "Rogue role: $ROGUE_ROLE"
    echo "Rogue host: $ROGUE_ID @ $ROGUE_IP"
    ```

    You should see `Rogue role: arn:aws:iam::...:role/io108-<your-id>-rogue-actor` and `Rogue host: i-... @ 10.x.x.x`. If either is blank, re-run step 15. In a real investigation you would not have these as outputs. Tasks 5 and 6 show how you would *discover* them; keep these values to cross-check your findings.

25. **Query CloudTrail** for who has been reading the Aurora master secret. Both the
    legitimate app roles and the rogue call `GetSecretValue`, and they all show up in the
    `Username` field as generic `botocore-session-...` assumed-role sessions — so you cannot
    tell them apart from that column. The real attribution lives one level deeper, in each
    event's `userIdentity.sessionContext.sessionIssuer.userName` (the ROLE behind the
    session). Pull the events for YOUR secret (the account is shared, so filtering
    on the event name alone returns every student's) and tally the calling roles. CloudTrail can
    lag up to 15 minutes:

    ```bash
    aws cloudtrail lookup-events \
      --region $REGION \
      --lookup-attributes AttributeKey=ResourceName,AttributeValue="$SECRET_ARN" \
      --start-time "$(date -u -d '-60 min' +%FT%TZ)" \
      --max-items 3000 \
      --query 'Events[].CloudTrailEvent' --output json \
    | jq -r '.[] | fromjson | .userIdentity.sessionContext.sessionIssuer.userName' \
    | sort | uniq -c | sort -rn
    ```
    <!-- source: Module_2_narrative.md §"CloudTrail Event Structure" -->

    This covers the last hour and takes 10–60 seconds. The output is a tally: the number is how many reads that role made, and the name is the role. For example:

    ```
       1250 io108-user01-orders-api-role
        190 io108-user01-health-checker-role
         15 io108-user01-rogue-actor
         12 io108-user01-report-lambda-role
    ```

    Your numbers will differ: the orders API and health checker read the secret constantly, the report Lambda only a few times an hour. A `null` line, if any, can be ignored. If `rogue-actor` is missing, wait 5 minutes and run the command again (CloudTrail lags up to 15 minutes).

> **Expected Result:** The role tally includes **`io108-<your-id>-rogue-actor`** reading the Aurora
> master secret — an identity that should never touch it. The orders API and health checker
> read it constantly, so the rogue's reads are a low-frequency minority in the list (it
> re-reads every few minutes); the *identity*, not the volume, is the tell.
> This is your evidence that a second, unauthorized principal is using stolen credentials
> against your database.

---

## Task 7: What Did It Create? (AWS Config and Tag Search)

26. **Enumerate** the rogue's footprint with **AWS Config**. Config records resource configuration and relationships over time, so you can ask "what resources carry the rogue marker?" without already knowing their ids. Use a Config advanced query (Config console → **Advanced queries**) or the CLI:

    ```bash
    aws configservice select-resource-config \
      --region $REGION \
      --expression "SELECT resourceId, resourceType, tags WHERE tags.tag = 'Rogue=true' AND tags.tag = 'Student=$SID'" \
      --query 'Results' --output json \
    | jq -r '.[] | fromjson | "\(.resourceType)  \(.resourceId)"'
    ```
    <!-- source: facts_extracted_v2.md §"AWS Config for Change Correlation" -->

    You should see two lines, one per resource carrying the rogue marker:

    ```
    AWS::IAM::Role  AROA...
    AWS::EC2::Instance  i-...
    ```

    The role's id is AWS's internal role id; the instance id matches `$ROGUE_ID`. If the command prints nothing, Config has not recorded the resources yet; go on to step 27, which does not depend on Config.

27. **Cross-check** with a direct tag search on EC2 — this finds the rogue **instance** even if Config is unavailable:

    ```bash
    aws ec2 describe-instances \
      --region $REGION \
      --filters "Name=tag:Rogue,Values=true" "Name=tag:Student,Values=$SID" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Ip:PrivateIpAddress}' \
      --output table
    ```
<!-- source: Module_2_narrative.md §"CloudTrail Audit and Rogue Resources" -->

    You should see a small table with one row: the instance `Id` (`i-...`), its private `Ip`, and `State` `running`.

> **Expected Result:** You independently arrive at the same instance id and private IP you captured in Task 6 (`$ROGUE_ID` / `$ROGUE_IP`), plus the tagged `rogue-actor` role. You have now answered both investigative questions: **who** (CloudTrail → rogue-actor principal) and **what** (Config / tag search → the rogue EC2 instance and its IAM role).

---

## Task 8: Contain the Rogue

28. **Contain** the instance. The fastest containment that stops both its API activity and its database chatter is to **stop the instance**. (In a real incident you might first snapshot it for forensics; here, stopping is sufficient.)

    ```bash
    aws ec2 stop-instances --region $REGION --instance-ids "$ROGUE_ID"
    aws ec2 wait instance-stopped --region $REGION --instance-ids "$ROGUE_ID"
    ```
    <!-- source: Module_2_narrative.md §"CloudTrail Audit and Rogue Resources" -->

    `stop-instances` prints JSON showing `"Name": "stopping"`. `wait` then prints nothing for up to 2 minutes (often under 30 seconds) and returns to the `$` prompt once the instance is stopped. Do not press Ctrl+C. If it prints `Waiter InstanceStopped failed` or `Invalid id`, run `echo $ROGUE_ID`; if that is blank, re-run step 15, then this step.

    > **Alternative containment (network isolation), for discussion:** instead of stopping the instance, you could quarantine it by replacing its security group `io108-<your-id>-rogue-sg` with an empty one (**EC2 → Instances** → select the instance → **Actions → Security → Change security groups**). The `Rogue contained` probe accepts either a stopped instance or the rogue security group removed. Deleting the `io108-<your-id>-aurora-from-rogue` ingress rule is a *database-side* fix covered in Lab 4; it does not turn this tile green.

29. **Confirm** on the board. Go back to your `io108-<your-id>-incident-board` dashboard and click the refresh icon (circular arrow) at the top right.

> **Expected Result:** Within a minute the **`Rogue contained`** tile turns **green**. Note that **`Aurora: no rogue sessions`** (the Lab 4 band) may also clear once the rogue's existing Postgres session ages out (allow up to 8 minutes) — but the *definitive* database-side lockout, using `pg_stat_activity` and the Aurora ingress rules, is the subject of **Lab 4**. For now, the instance is contained and the P2 incident is fully resolved. Close it in your incident notes with the timeline: access-denial root cause, restoration, and rogue containment.
>
> **Note:** Any later `terraform apply` with `scenario=healthy` or `lab1` starts the rogue again (it is part of the stack). That is expected; Lab 4 deals with it for good.

---

## Knowledge Check

**Question 1:** The pod log said the request was denied "because no identity-based policy allows the action." Walking IAM's evaluation logic, why does restoring a missing `Allow` fix this, and why was there no explicit `Deny` to find?

**Answer:** IAM denies by default. A request is permitted only when a policy statement explicitly **allows** the action *and* no statement explicitly **denies** it. In this incident the `secretsmanager:GetSecretValue` permission was simply removed from the role's policy, so the request matched no `Allow` and fell through to the **implicit deny**. There was never an explicit `Deny` statement — the fix is to add the missing `Allow` back, which is exactly what restoring the healthy policy does. This is why `simulate-principal-policy` reported `implicitDeny` before the fix and `allowed` after.

**Question 2:** Why is `iam:SimulatePrincipalPolicy` a better first move than editing the policy and watching the app, when you suspect a permissions issue?

**Answer:** The simulator evaluates the *exact* principal, action, and resource against the live policies and returns the decision (`allowed` / `implicitDeny` / `explicitDeny`) **without making any change and without waiting on the application**. It confirms the root cause deterministically and lets you verify a proposed fix at the IAM layer before you touch the running workload — shrinking the change-and-pray loop. You only restart the pods once the simulation already says `allowed`.

**Question 3:** During the hunt you used CloudTrail and AWS Config for different questions. What does each answer, and why do you need both?

**Answer:** **CloudTrail** is the audit log of API activity — it answers **who** did **what action**, **when**, and **from where** (e.g., the rogue-actor principal reading the Aurora secret every few minutes). **AWS Config** records the configuration and relationships of resources over time — it answers **what exists / what was created** and lets you enumerate resources by attribute (e.g., everything tagged `Rogue=true`). You need both because attribution (CloudTrail) and footprint enumeration (Config) are different halves of the same investigation: one finds the actor, the other finds the assets.

---

## Lab Summary

You worked a **P2** access-denial incident from the board tile to root cause and back to green: pod logs surfaced an `AccessDenied` on `secretsmanager:GetSecretValue`, the IAM policy simulator confirmed an **implicit deny** caused by a stripped permission, and restoring the role's policy — full S3 object access plus the secret read — recovered the `orders-api DB access (IRSA)` check. You then opened the rogue hunt: **CloudTrail** attributed unauthorized secret reads to the tagged `rogue-actor` principal, **AWS Config** and a tag search enumerated the rogue EC2 instance, and you **contained** it — turning `Rogue contained` green. The deeper Aurora-side lockout waits for Lab 4.

## Completion Checklist

- [ ] `orders-api DB access (IRSA)` tile confirmed red (incident recorded as P2)
- [ ] `AccessDenied` on `secretsmanager:GetSecretValue` found in `orders-api` pod logs
- [ ] Root cause confirmed: role policy missing the secret read and S3 object permissions (`simulate-principal-policy` → `implicitDeny`)
- [ ] Healthy policy restored with `put-role-policy`; re-simulation returns `allowed`
- [ ] `orders-api` restarted; `orders-api DB access (IRSA)` tile green
- [ ] CloudTrail activity attributed to the `rogue-actor` principal
- [ ] Rogue EC2 instance enumerated via AWS Config / tag search
- [ ] Rogue contained (instance stopped); `Rogue contained` tile green

---

## Next Steps

In **Lab 2: EKS Pod Failure Investigation**, the `EKS pods schedulable` tile goes red — your pods are stuck `Pending` with nowhere to run. You will diagnose the scheduling failure with `kubectl describe` and Container Insights, trace it to node-group capacity, and scale it back up. As an add-on you will untangle a default-deny NetworkPolicy that is cutting pod egress to the internet and DNS, learning why the VPC CNI must have NetworkPolicy enforcement enabled for those rules to bite.
