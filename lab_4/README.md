# Lab 4: Aurora Failover and Connectivity Investigation + Query Tracing

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 4 - Aurora Failover and Connectivity Investigation |
| **Duration** | 45 minutes |
| **Difficulty** | Intermediate / Advanced |
| **Severity (this incident)** | **P1** - the orders application cannot persist writes (customer-impacting); drops to **P2** once the workaround is confirmed and the data path is stable |
| **Incident platform** | ServiceNow (log the incident, set Priority = P1, attach your timeline and the rogue-session finding) |
| **Prerequisites** | Labs 1-3 completed; AWS CLI v2, `kubectl`, `jq`; access to your `io108-<id>-incident-board` dashboard and the RDS console |
| **Builds On** | The same connected app stack. The rogue instance has been querying Aurora since Lab 0 - in this lab you finally trace it on the database itself and lock it out. |

---

## Lab Overview

SYF's orders-api writes every order to **Amazon Aurora PostgreSQL**. Customers can read their order history, but new orders fail. The database is *reachable*, so why can't the app write? In this lab you will:

1. Confirm from the incident board that Aurora is **reachable but not writable**.
2. Prove the app's connection is landing on a **read-only replica**.
3. Distinguish the Aurora **cluster (writer)**, **reader**, and **instance** endpoints, and repoint the app to the correct one.
4. Use **query tracing** (`pg_stat_activity`, Performance Insights, connection logs) to catch the **rogue client** querying Aurora, and lock it out.

> **Note:** This lab uses native AWS networking. In your environment the hub-and-spoke transit is **Aviatrix**, managed by the network team; the concepts map directly.

---

## Scenario

> **Incident:** "Order writes started failing at 02:40. App logs show `cannot execute INSERT in a read-only transaction`. The database console shows the cluster Available and healthy. Reads work."

The app's database host was changed to the **Aurora reader endpoint** instead of the **cluster (writer) endpoint**. Connections and `SELECT`s succeed, but every `INSERT`/`UPDATE`/`DELETE` is rejected. Separately, a rogue instance is opening sessions to Aurora. You open a **P1** incident in **ServiceNow**.

---

## Learning Objectives

By the end of this lab, you will be able to:

- Interpret "reachable but not writable" from the dashboard and the application error.
- Use `SELECT pg_is_in_recovery();` to prove a connection is on a read replica.
- Distinguish the Aurora **cluster endpoint**, **reader endpoint**, and **instance endpoints**, and choose the right one for a read-write workload.
- Repoint a running application to the writer endpoint and confirm recovery on the board.
- Trace live database sessions with **`pg_stat_activity`**, corroborate with **Performance Insights** and **connection logs**, identify a client by source IP, and revoke its access.

---

## Task 1: Lab Setup

Run every command in this lab on your **lab host** as **`ec2-user`** (Session Manager, Lab 1, *Start Here*, step 1, then `sudo su - ec2-user`). Run each code block on its own, and wait for it to finish before you start the next.

1. **Go to** the lab directory and **check** your variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
    ```

    > **Expected Result:** Your own id and region, for example `SID=user01 REGION=us-east-1`. If it is blank, finish Lab 1 *Start Here* step 3.

2. **Preview** this lab's incident. This changes nothing. Run this command on its own:

    ```bash
    terraform plan -var scenario=lab4
    ```

    After about a minute, Terraform prints a plan ending in a line like:

    ```
    Plan: 0 to add, 2 to change, 0 to destroy.
    ```

    > **Expected Result:** A small plan: about **2–4 to change, 0–2 to add, 0 to destroy**, listing `aws_lambda_function.health_checker` and `aws_cloudwatch_dashboard.incident_board` (coming from Lab 3, possibly also `aws_ec2_instance_state.rogue[0]` and `aws_lambda_function.report_generator`). If it shows dozens or 100+ to add, or destroys anything unexpected, stop and tell your instructor.

3. **Inject** this lab's incident. Run this command on its own:

    ```bash
    terraform apply -var scenario=lab4
    ```

    Terraform prints the same plan again and stops at `Enter a value:`:

    ```
    Plan: 0 to add, 2 to change, 0 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    If the `Plan:` line matches the preview, type **`yes`** and press **Enter**; otherwise type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** After about a minute, Terraform prints **`Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`** (your numbers match your plan), followed by a list of outputs.

4. **Redeploy** the app so it picks up the new database target (1–5 minutes). Run this only after step 3 has finished:

    ```bash
    ./deploy_app.sh
    ```

    > **This can look stuck - that is normal.** The script waits up to 5 minutes for the pods to roll out and may print `Waiting for deployment "orders-api" rollout to finish...` for a while. Do not press **Ctrl+C**.

    > **Expected Result:** The script prints `db host:` followed by an endpoint containing **`.cluster-ro-`** (the reader), and ends with `Deploy complete. Next steps:`. A `WARNING: orders-api is not Ready` line is acceptable under a fault scenario.
<!-- source: course_outline_v3.md §"Lab 4" -->

5. **Capture** the values this lab uses into shell variables. **After any reconnect, run steps 1 and 5 again**, because a new session forgets these variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    STUDENT_ID=$SID
    export WRITER=$(terraform output -raw aurora_cluster_endpoint)
    export READER=$(terraform output -raw aurora_reader_endpoint)
    export APP_DB_HOST=$(terraform output -raw app_db_host)
    export SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
    export ROGUE_IP=$(terraform output -raw rogue_private_ip)
    export ROGUE_ID=$(terraform output -raw rogue_instance_id)
    export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
      --region "$REGION" --query SecretString --output text | jq -r .password)
    export PGUSER=orders_admin
    export PGDATABASE=orders
    echo "Writer (cluster) endpoint: $WRITER"
    echo "Reader endpoint:           $READER"
    echo "App is currently using:    $APP_DB_HOST"
    echo "Rogue instance / IP:       $ROGUE_ID / $ROGUE_IP"
    echo "Secret ARN:                $SECRET_ARN"
    echo "DB password length:        ${#PGPASSWORD}"
    ```

    > **Expected Result:**
    >
    > - The writer endpoint contains **`.cluster-`** and the reader contains **`.cluster-ro-`**.
    > - `App is currently using` matches the **reader**. That is the injected fault; do not "fix" it yet.
    > - The rogue line shows an `i-...` id and a `10.x.x.x` address.
    > - The secret ARN starts with `arn:aws:secretsmanager:`.
    > - `DB password length` is greater than **0** (the password itself is never printed).
    >
    > If any value is blank or the length is `0`, run step 1 again, then this block.

6. **Start** a `psql` client pod in the cluster. Later steps run database queries through it.

    > **Where this runs.** Aurora only accepts connections from inside the VPC's app network, so the lab host cannot run `psql` against it directly. Every later `kubectl -n orders exec psql-client -- psql ...` command runs `psql` **inside this pod** for you and prints the result on your lab host. You never leave the lab host shell.

    ```bash
    kubectl -n orders run psql-client --restart=Never \
      --image=public.ecr.aws/docker/library/postgres:16 \
      --env="PGPASSWORD=$PGPASSWORD" -- sleep 14400
    kubectl -n orders wait --for=condition=Ready pod/psql-client --timeout=120s
    ```

    > **Expected Result:** `pod/psql-client created`, then after 30–90 seconds `pod/psql-client condition met`. If you see `AlreadyExists`, reuse the pod, unless your password changed or the pod is not `Running`: then run `kubectl -n orders delete pod psql-client` and re-run this step.

> **Reconnecting later?** Start a new session, run `sudo su - ec2-user`, then run **steps 1 and 5** again. Do **not** re-run step 3 (it re-applies the fault) or step 6 (the pod is still running).
<!-- source: Lab_4_narrative.md §"ConfigMap/Secret for database URL" -->

---

## Task 2: Confirm "Reachable but Not Writable"

7. **Open** your incident board. In the AWS console search bar, type **CloudWatch** and open it. Check that the region at the top right matches your `REGION`. In the left menu choose **Dashboards**, then open **`io108-<your-id>-incident-board`**. Allow 1–2 minutes after the apply, and click the refresh icon (circular arrow) at the top right if the tiles look stale.

    > **Expected Result:** In the **Lab 4** band:
    >
    > - **Aurora reachable** (`aurora_reachable`) is **GREEN**.
    > - **Aurora writable (writer endpoint)** (`aurora_writable`) is **RED**.
    > - **Aurora: no rogue sessions** (`aurora_no_rogue`) is **RED**.
    >
    > Green-reachable with red-writable means the network and credentials are fine; the *target* is wrong. Record the incident start time in your incident notes.

8. **Check** the orders-api logs for the read-only error.

    > **The app is supposed to be failing here.** Errors in this log are the symptom you are investigating, not a problem with your setup.


    ```bash
    kubectl -n orders logs deploy/orders-api --tail=30 | grep -i "read-only" || \
      kubectl -n orders logs deploy/orders-api --tail=30
    ```
    <!-- source: Lab_4_narrative.md §"Identify Affected Applications" -->

    > **Expected Result:** A Python traceback whose last line looks like `pg8000.exceptions.DatabaseError: {... 'M': 'cannot execute INSERT in a read-only transaction' ...}`. If nothing matches, wait 30 seconds and re-run; the app posts an order every 30 seconds.

---

## Task 3: Prove the Connection Is on a Read Replica

9. **Query** the endpoint the app is using (the reader) from inside the cluster:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$READER" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT pg_is_in_recovery();"
    ```
    <!-- source: Module_3_narrative.md §"read replica" -->

    > **Expected Result:**
    >
    > ```
    >  pg_is_in_recovery
    > -------------------
    >  t
    > (1 row)
    > ```
    >
    > **`t`** (true) means the connection is on a read-only replica. If you get `password authentication failed` or `no password supplied`, re-run steps 1 and 5, then delete and recreate the pod (step 6).

10. **Query** the cluster (writer) endpoint:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT pg_is_in_recovery();"
    ```
    <!-- source: Module_3_narrative.md §"always tracks the current primary" -->

    > **Expected Result:** The same table with **` f`** (false). The cluster endpoint always points at the current writer.

11. **Open** the endpoints in the console. In the AWS console search bar, type **RDS** and open it. Choose **Databases**, click **`io108-<your-id>-aurora`**, and open the **Connectivity & security** tab.

    > **Expected Result:** Three kinds of endpoint:
    >
    > - **Cluster (writer)**, containing `.cluster-`: always the current primary, follows failover. Use it for read-write apps.
    > - **Reader**, containing `.cluster-ro-`: load-balanced read-only replicas. Wrong for writes.
    > - **Instance** endpoints, starting with the instance name (`io108-<your-id>-aurora-0`, `-1`): one specific instance, which can become a reader during failover.

---

## Task 4: Repoint the App to the Writer Endpoint and Confirm Green

The app's DB target comes from Terraform (`deploy_app.sh` reads `app_db_host`), and the `aurora_writable` probe checks that same target. So the fix is to apply the healthy scenario and redeploy.

> **Why this matters.** Repointing the app fixes only the first problem. The healthy apply does **not** stop the rogue, and it keeps the rogue's database rule in place; you lock the rogue out yourself in Task 6.

12. **Preview** the healthy scenario. This changes nothing. Make sure you are in the Terraform directory:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    ```

    Then run this command on its own:

    ```bash
    terraform plan -var scenario=healthy
    ```
    <!-- source: Lab_4_narrative.md §"use cluster endpoint" -->

    The plan ends in a line like:

    ```
    Plan: 0 to add, 2 to change, 0 to destroy.
    ```

    > **Expected Result:** A small plan: about **2–4 to change, 0–2 to add, 0 to destroy**, listing `aws_lambda_function.health_checker` and `aws_cloudwatch_dashboard.incident_board`. If it shows dozens or 100+ to add, or destroys anything unexpected, stop and tell your instructor.

13. **Apply** the healthy scenario. Run this command on its own:

    ```bash
    terraform apply -var scenario=healthy
    ```

    Terraform stops at the same `Enter a value:` prompt as step 3:

    ```
    Plan: 0 to add, 2 to change, 0 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    If the `Plan:` line matches the preview, type **`yes`** and press **Enter**; otherwise type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** **`Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`** (your numbers match your plan), followed by the outputs.

14. **Redeploy** the app onto the writer endpoint (1–5 minutes). Run this only after step 13 has finished:

    ```bash
    ./deploy_app.sh
    ```
    <!-- source: Lab_4_narrative.md §"use cluster endpoint" -->

    > **Expected Result:** `db host:` now shows an endpoint containing **`.cluster-`** (not `.cluster-ro-`), and the script ends with `Deploy complete. Next steps:`.

    > **Note:** In a live incident you might first hot-patch the running pods with `helm upgrade orders charts/orders --namespace orders --reuse-values --set env.dbHost="$WRITER"` (from `~/io-108/lab_environment/lab_env_student`). That restores writes, but the board's probe follows the Terraform target, so you still need the apply above to close the incident.

15. **Confirm** the new pods use the writer (normally returns at once; allow up to 3 minutes):

    ```bash
    kubectl -n orders rollout status deploy/orders-api --timeout=180s
    kubectl -n orders exec deploy/orders-api -- printenv DB_HOST
    ```
<!-- source: Lab_4_narrative.md §"restart the pods so they pick up the new configuration" -->

    > **Expected Result:** `deployment "orders-api" successfully rolled out`, then the same endpoint as `$WRITER` (contains `.cluster-`). If `rollout status` times out, run it again.

16. **Verify** writes succeed:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" \
      -c "CREATE TABLE IF NOT EXISTS lab4_writecheck(id serial, ts timestamptz default now()); INSERT INTO lab4_writecheck DEFAULT VALUES RETURNING id;"
    ```
    <!-- source: Lab_4_narrative.md §"Submit test order, verify processing" -->

    > **Expected Result:** `CREATE TABLE` (or, on a re-run, `NOTICE:  relation "lab4_writecheck" already exists, skipping`), then:
    >
    > ```
    >  id
    > ----
    >   1
    > (1 row)
    >
    > INSERT 0 1
    > ```
    >
    > An error containing `read-only transaction` means you are still on the reader; check that `$WRITER` contains `.cluster-` (step 5).

17. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab, wait 1–2 minutes after the apply, and click the refresh icon.

    > **Expected Result:** **`Aurora writable (writer endpoint)`** is **green**. `Aurora: no rogue sessions` is still red; you fix that next. Record the recovery time and root cause in your incident notes: app pointed at the reader endpoint.

> **Note:** Applications must use the cluster endpoint so they follow the writer through a failover. Hard-coding a reader or instance endpoint turns a 30-second failover into an outage.

---

## Task 5: Trace the Rogue Client with Query Tracing

The rogue instance (stopped in Lab 1, restarted by the `lab4` apply) holds a Postgres session open to Aurora using stolen master credentials. You will find it on the database itself.

18. **List** live sessions with `pg_stat_activity`:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c \
      "SELECT pid, client_addr, usename, state, query
         FROM pg_stat_activity
        WHERE client_addr IS NOT NULL
        ORDER BY backend_start DESC;"
    ```
    <!-- source: Module_3_narrative.md §"the source address on the query is the tell" -->

    You will see several rows: the orders-api pods, the health-checker Lambda, and this `psql` session. Now show only the rogue's sessions (its IP is `$ROGUE_IP` from step 5):

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c \
      "SELECT pid, client_addr, state, query FROM pg_stat_activity WHERE client_addr = '$ROGUE_IP';"
    ```

    > **Expected Result:** One row with the rogue IP, `state` `active`, and `query` `SELECT pg_sleep(300)`: a harmless-looking query that holds a connection open for 5 minutes, then reconnects. If it shows `(0 rows)`, wait a minute and re-run.

19. **Open** Performance Insights. In the **RDS console → Databases**, click the instance whose **Role** is *Writer instance* (`io108-<your-id>-aurora-0` or `-1`). Open the **Monitoring** tab and choose **Performance Insights** (it may open in CloudWatch **Database Insights**). Set the time range to **Last 1 hour** and **Slice by** to **Hosts**.

    > **Expected Result:** A host matching `$ROGUE_IP` appears as a load contributor separate from the application pods, with a `PgSleep` wait: the rogue's `pg_sleep`.

20. **Search** the Aurora connection log for the rogue IP (about 10–30 seconds):

    ```bash
    aws logs filter-log-events \
      --log-group-name "/aws/rds/cluster/io108-${STUDENT_ID}-aurora/postgresql" \
      --start-time $(( ($(date +%s) - 3600) * 1000 )) \
      --filter-pattern "\"$ROGUE_IP\"" --region "$REGION" \
      --query 'events[].[message]' --output text | grep 'connection received' | tail -10
    ```
    <!-- source: Module_3_narrative.md §"rogue IP we are hunting" -->

    > **Expected Result:** Up to ten lines containing `connection received: host=<rogue IP> port=<number>`, about 5 minutes apart. No output? Check that `echo $STUDENT_ID $ROGUE_IP` prints both values (re-run steps 1 and 5 if not).

> **Note:** Three independent sources (live sessions, Performance Insights, the connection log) point at the same IP. Get at least two to agree before you contain.

---

## Task 6: Lock Out the Rogue and Confirm Green

> **Do not run `terraform apply` again after this point.** Any apply with `healthy`, `lab1`, `lab4` or `lab5` starts the rogue again and recreates the security-group rule you are about to remove, undoing this task.

21. **Revoke** the rogue's path to Aurora. It connects through a dedicated ingress rule on Aurora's security group (SG). First look up the two SG ids:

    ```bash
    ROGUE_SG=$(aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
    AURORA_SG=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=io108-${STUDENT_ID}-aurora-sg" \
      --query 'SecurityGroups[0].GroupId' --output text)
    echo "ROGUE_SG=$ROGUE_SG AURORA_SG=$AURORA_SG"
    ```

    Both values must start with `sg-`. If either is `None` or blank, re-run steps 1 and 5, then this block.

    > **The next command changes your stack.** It deletes one inbound rule from Aurora's security group: the rule that lets the rogue's security group reach port 5432. The app pods and the health checker use their own rules and are not affected.

    Remove the rule:

    ```bash
    aws ec2 revoke-security-group-ingress --group-id "$AURORA_SG" --region "$REGION" \
      --protocol tcp --port 5432 --source-group "$ROGUE_SG"
    ```
<!-- source: facts_extracted_v2.md §"Security group rules" -->

    > **Expected Result:** JSON containing `"Return": true`. If you get `InvalidPermission.NotFound`, the rule is already gone; continue.

22. **Stop** the rogue instance:

    ```bash
    aws ec2 stop-instances --instance-ids "$ROGUE_ID" --region "$REGION"
    ```
<!-- source: Module_3_narrative.md §"rogue IP we are hunting" -->

    > **Expected Result:** JSON showing `"CurrentState"` with `"Name": "stopping"` (or `"stopped"` if it was already stopped).

23. **Re-run** the filtered `pg_stat_activity` query from step 18 (the one with `WHERE client_addr = '$ROGUE_IP'`).

    > **A session can outlive the fix.** Removing a security-group rule blocks *new* connections; a connection that is already open can stay listed until it ends or the stopped instance's TCP session times out (up to about 8 minutes). Still one row? That is expected: repeat the query every couple of minutes.

    > **Expected Result:** `(0 rows)`.

24. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab and click the refresh icon. Allow up to 8 minutes for the rogue's last session to expire.

    > **Expected Result:** **`Aurora: no rogue sessions`** (`aurora_no_rogue`) is **green**, and the Lab 1 `rogue_contained` tile is green (within 1–3 minutes of step 22). Record the second root cause in your incident notes: rogue sessions from `$ROGUE_IP`, contained by revoking the SG rule and stopping the instance.


---

## Troubleshooting

### `aurora_writable` stays red after repointing

**Check:** `kubectl -n orders exec deploy/orders-api -- printenv DB_HOST` should print the same value as `echo $WRITER` (contains `.cluster-`, not `.cluster-ro-`). If not, repeat steps 12–14. The tile follows the Terraform target, so allow 1–2 minutes after the apply.

### `psql` pod cannot connect at all (timeout)

**Check:** The `psql-client` pod must run in the `orders` namespace. Run `echo "$WRITER $READER ${#PGPASSWORD}"`: both endpoints must be present and the length above 0. If they are blank, re-run steps 1 and 5. If the password was blank when you created the pod, delete and recreate it (step 6).

### `aurora_no_rogue` stays red

**Check:** A session that was mid-flight can take up to ~8 minutes to expire. Confirm the SG ingress rule was revoked:

```bash
aws ec2 describe-security-groups --group-ids "$AURORA_SG" --region "$REGION" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`5432\`].UserIdGroupPairs[].GroupId" --output text
```

The output must **not** contain the `$ROGUE_SG` id (`echo $ROGUE_SG`). If it does, repeat step 21.

---

## Knowledge Check

**Question 1:** The database was Available the whole time and reads worked, yet writes failed. Explain in one or two sentences why, and what single query you would run to confirm a connection is on a read replica.

**Question 2:** Name the three Aurora endpoint types and state which one a read-write application should use and why — specifically what happens to each during a failover.

**Question 3:** You found the rogue by its `client_addr` in `pg_stat_activity`. Why is it better practice to corroborate with at least one more source (Performance Insights or the connection log) before containing, and why did you revoke the security-group rule *and* stop the instance rather than just blocking the IP?

<details>
<summary><strong>Answers</strong></summary>

**A1:** The application was connected to the Aurora **reader** endpoint, which always lands on a read-only replica; the replica accepts connections and `SELECT`s but rejects any write with `cannot execute ... in a read-only transaction`. Confirm with `SELECT pg_is_in_recovery();` — it returns `t` (true) on a replica, `f` (false) on the writer.

**A2:** **Cluster (writer) endpoint** — always tracks the current primary; the right choice for read-write apps because it automatically follows the writer through a failover. **Reader endpoint** - load-balances across read replicas and is read-only. **Instance endpoint** — targets one named instance, which is brittle because that instance can be demoted to a reader or replaced during failover. A read-write app must use the cluster endpoint.

**A3:** Multiple independent lenses guard against acting on a false positive (e.g. a legitimate admin host that merely looks unusual); `pg_stat_activity` (live), Performance Insights (historical top SQL by host), and the connection log (audit) agreeing gives confidence. Revoking the SG rule removes the authorized network path so the rogue cannot reconnect from any address that relied on it, and stopping the instance contains the compromised asset itself - blocking only the current IP would let it return from a new one.

</details>

---

## Lab Summary

- You diagnosed an "up but can't write" incident: Aurora **reachable** but **not writable** because the app was on the **reader** endpoint.
- You proved it with `pg_is_in_recovery()` and distinguished the **cluster / reader / instance** endpoints.
- You repointed the app to the **cluster (writer) endpoint** and confirmed recovery on the board.
- You traced the rogue client three ways — **`pg_stat_activity`**, **Performance Insights**, **connection logs** - identified it by source IP, and contained it by revoking its SG path and stopping the instance.

**Before you move on:** Finish your incident notes for this **P1** (downgraded to P2 once writes were restored): start time, both root causes (app pointed at the reader endpoint; rogue sessions from `$ROGUE_IP`), remediation (repoint to the cluster endpoint; revoke the rogue SG ingress; stop the rogue instance), and recovery times for both tiles.

**Clean up** the client pod:

```bash
kubectl -n orders delete pod psql-client
```

Expected: `pod "psql-client" deleted`.

## Next Steps

In **Lab 5: Multi-Layered Incident Simulation (Capstone)**, several failures hit at once — a network misroute, a broken IAM path, a pod-network deny, and the rogue — lighting up the whole board. You will lead with the incident board as your map, add **VPC Flow Logs**, **Reachability Analyzer**, and an optional **open-source packet-analysis box**, clear every tile, and write the post-incident report.
