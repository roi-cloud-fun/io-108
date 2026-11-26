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

SYF's orders-api writes every order to **Amazon Aurora PostgreSQL**. Overnight the on-call engineer was paged: customers can read their order history, but new orders fail. The database is clearly *reachable* — so why can't the app write?

This is the classic, frequently-misdiagnosed incident: **the database is up but the application can't write.** In this lab you will:

1. Confirm from the incident board that Aurora is **reachable but not writable**.
2. Read the app error and prove the connection is landing on a **read-only replica**.
3. Distinguish the Aurora **cluster (writer)**, **reader**, and **instance** endpoints, and repoint the app to the correct one.
4. Use **query tracing** (`pg_stat_activity`, Performance Insights, connection logs) to catch the **rogue client** that has been quietly querying Aurora, and lock it out.

> **Note on SYF's network:** This lab uses native AWS networking. Aurora connectivity here is within the VPC; where account-to-account or account-to-partner transit appears (the capstone), the hub-and-spoke transit in your environment is **Aviatrix**, managed by the network team — the concepts map directly; the management plane differs.

---

## Scenario

> **Incident:** "Order writes started failing at 02:40. App logs show `cannot execute INSERT in a read-only transaction`. The database console shows the cluster Available and healthy. Reads work."

The application's database host was changed to the **Aurora reader endpoint** instead of the **cluster (writer) endpoint**. The reader only ever points at a read-only replica, so the connection succeeds, `SELECT`s work, but any `INSERT`/`UPDATE`/`DELETE` is rejected. Your board shows `aurora_reachable` **green** and `aurora_writable` **red** — a precise picture of "up but can't write."

Separately, the `aurora_no_rogue` tile is red: a rogue instance is opening sessions to Aurora. You will trace it on the database and shut its access path.

---

## Learning Objectives

By the end of this lab, you will be able to:

- Interpret "reachable but not writable" from the dashboard and the application error.
- Use `SELECT pg_is_in_recovery();` to prove a connection is on a read replica.
- Distinguish the Aurora **cluster endpoint**, **reader endpoint**, and **instance endpoints**, and choose the right one for a read-write workload.
- Repoint a running application to the writer endpoint and confirm recovery on the board.
- Trace live database sessions with **`pg_stat_activity`**, corroborate with **Performance Insights** and **connection logs**, identify a client by source IP, and revoke its access.

---

## Pre-Lab Setup

Run **everything** in this lab on your **lab host**, as `ec2-user`. Connect with Session Manager (Lab 1, *Start Here*, step 1), then run `sudo su - ec2-user`.

1. **Inject this lab's incident.** Go to the Terraform directory and apply the `lab4` scenario (your id and region come from `terraform.tfvars`, set in Lab 1):

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    terraform apply -var scenario=lab4
    ```

    Terraform takes about a minute to compare your stack with the code, then prints a **plan** and stops at a confirmation prompt:

    ```
    Plan: 0 to add, 2 to change, 0 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    **Check the `Plan:` line first.** Expect a small plan: about **2–4 to change, 0–2 to add, 0 to destroy**. It lists `aws_lambda_function.health_checker` and `aws_cloudwatch_dashboard.incident_board`. Coming from Lab 3, it may also list `aws_ec2_instance_state.rogue[0]` (add) and `aws_lambda_function.report_generator` (change).

    - **If it matches,** type **`yes`** and press **Enter**. Terraform will not continue until you do, and anything other than `yes` cancels.
    - **If it wants to add dozens or 100+ resources, or destroy anything unexpected,** type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** After about a minute, Terraform prints **`Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`** (your numbers match your plan), followed by a list of outputs.

    Then redeploy the app so it picks up the new database target (1–5 minutes):

    ```bash
    ./deploy_app.sh
    ```

    > **Expected Result:** The script prints `db host:` followed by an endpoint containing **`.cluster-ro-`** (the reader), and ends with `Deploy complete. Next steps:`. A `WARNING: orders-api is not Ready` line is acceptable under a fault scenario.
<!-- source: course_outline_v3.md §"Lab 4" -->

2. **Set** this lab's variables. Re-run this whole block any time you reconnect (after `sudo su - ec2-user`):

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
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

    > **Expected Result:** The first line shows your own id and region (for example `SID=user01 REGION=us-east-1`). If it is blank, finish Lab 1 *Start Here* step 3. Then check:
    >
    > - The writer endpoint contains **`.cluster-`** and the reader contains **`.cluster-ro-`**.
    > - `App is currently using` matches the **reader**. That is the injected fault.
    > - The rogue line shows an `i-...` id and a `10.x.x.x` address.
    > - The secret ARN starts with `arn:aws:secretsmanager:`.
    > - `DB password length` is a number greater than **0**. The password itself is never printed.
    >
    > If any value is blank or the length is `0`, make sure you are in `~/io-108/lab_environment/lab_env_student` and re-run the block.

3. **Start a small `psql` client pod** inside the cluster. `psql` is the PostgreSQL command-line client, and later steps run queries through this pod. The pod receives the password from step 2 when it is created:

    ```bash
    kubectl -n orders run psql-client --restart=Never \
      --image=public.ecr.aws/docker/library/postgres:16 \
      --env="PGPASSWORD=$PGPASSWORD" -- sleep 14400
    kubectl -n orders wait --for=condition=Ready pod/psql-client --timeout=120s
    ```

    > **Expected Result:** `pod/psql-client created`, then after 30–90 seconds (first image download) `pod/psql-client condition met`.
    >
    > If you see `AlreadyExists`, the pod is left over from an earlier attempt. If your password changed or the pod is not `Running`, run `kubectl -n orders delete pod psql-client` (prints `pod "psql-client" deleted`), then re-run this step. Otherwise reuse it.

> **Reconnected?** Sessions time out when idle. Start a new session, run `sudo su - ec2-user`, then re-run the step 2 block. Do **not** re-run step 1 (it re-applies the fault) or step 3 (the pod is still running).
<!-- source: Lab_4_narrative.md §"ConfigMap/Secret for database URL" -->

---

## Task 1: Confirm "Reachable but Not Writable"

1. **Open** your incident board: **CloudWatch console** (your region) → **Dashboards** → **`io108-<your-id>-incident-board`**. Tiles refresh about every minute, so allow 1–2 minutes after the apply. Find the **Lab 4** band:

    - **Aurora reachable** (`aurora_reachable`) - **GREEN**
    - **Aurora writable (writer endpoint)** (`aurora_writable`) - **RED**
    - **Aurora: no rogue sessions** (`aurora_no_rogue`) - **RED**

    The combination green-reachable/red-writable is the signature of this incident class. The network path and credentials are fine; the *target* is wrong.

2. **Reproduce** the application symptom. Check the orders-api logs for the read-only error:

    ```bash
    kubectl -n orders logs deploy/orders-api --tail=30 | grep -i "read-only" || \
      kubectl -n orders logs deploy/orders-api --tail=30
    ```
    <!-- source: Lab_4_narrative.md §"Identify Affected Applications" -->

    Expected: a Python error (a *traceback*) whose last line looks like `pg8000.exceptions.DatabaseError: {... 'M': 'cannot execute INSERT in a read-only transaction' ...}`. If nothing matches, wait 30 seconds and re-run. The worker posts an order every 30 seconds, and each post fails this way.

> **Expected Result:** `aurora_writable` is red, the app logs the read-only error, and `aurora_reachable` confirms the DB is up. Record the incident start time.

---

## Task 2: Prove the Connection Is on a Read Replica

3. **Run** a query **against the endpoint the app is currently using** (the reader), from inside the cluster so the network path matches the app's:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$READER" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT pg_is_in_recovery();"
    ```
    <!-- source: Module_3_narrative.md §"read replica" -->

    `kubectl exec` runs a command inside the pod. Expected output:

    ```
     pg_is_in_recovery
    -------------------
     t
    (1 row)
    ```

    **`t`** (true) means this connection is on a *read replica*, a read-only copy of the database. If you get `password authentication failed` or `no password supplied`, re-run Pre-Lab step 2, then delete and recreate the pod (Pre-Lab step 3).

4. **Compare** against the cluster (writer) endpoint:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT pg_is_in_recovery();"
    ```
    <!-- source: Module_3_narrative.md §"always tracks the current primary" -->

    Expected: the same table, but with **` f`** (false) on the value line. The cluster endpoint always points at the current writer.

> **The three Aurora endpoints - know which is which:**
> - **Cluster (writer) endpoint** — always points at the current primary; use it for read-write workloads. Survives failover automatically.
> - **Reader endpoint** — load-balances across read replicas; read-only. Great for reporting, wrong for writes.
> - **Instance endpoints** — target one specific instance by name; brittle, because that instance can become a reader or be replaced during failover.
>
> Open the **RDS console → Databases → `io108-<your-id>-aurora` → Connectivity & security** tab and read all three off the page so you can recognize them by shape next time. The writer contains `.cluster-`, the reader `.cluster-ro-`, and each instance endpoint starts with the instance name (`io108-<your-id>-aurora-0`, `-1`).

---

## Task 3: Repoint the App to the Writer Endpoint and Confirm Green

5. **Repoint the stack at the writer (cluster) endpoint.** The application's DB target is set
    from Terraform — `deploy_app.sh` reads `app_db_host` — and the health board's
    `aurora_writable` probe checks that *same* Terraform-intended target. So the durable fix
    that also turns the tile green is to correct the wiring in Terraform and redeploy, returning
    the DB target from the reader to the cluster/writer endpoint:

    Make sure you are in the Terraform directory, then apply the healthy scenario:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    terraform apply -var scenario=healthy
    ```
    <!-- source: Lab_4_narrative.md §"use cluster endpoint" -->

    Terraform prints a plan and stops at the same prompt as Pre-Lab step 1:

    ```
    Plan: 0 to add, 2 to change, 0 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    **Check the `Plan:` line first.** Expect a small plan: about **2–4 to change, 0–2 to add, 0 to destroy**. It lists `aws_lambda_function.health_checker` (the probe's DB target) and `aws_cloudwatch_dashboard.incident_board`.

    - **If it matches,** type **`yes`** and press **Enter**.
    - **If it wants to add dozens or 100+ resources, or destroy anything unexpected,** type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** **`Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`** (your numbers match your plan), followed by the outputs.

    Then redeploy the app onto the writer endpoint (1–5 minutes). The script also waits for the new pods:

    ```bash
    ./deploy_app.sh
    ```
    <!-- source: Lab_4_narrative.md §"use cluster endpoint" -->

    > **Expected Result:** `db host:` now shows an endpoint containing **`.cluster-`** (not `.cluster-ro-`), and the script ends with `Deploy complete. Next steps:`.

    This points `app_db_host` back at the cluster (writer) endpoint for both the app and the
    probe. (The rogue is always-on and unaffected — you contain it in Task 5.)

    > **Immediate mitigation vs. durable fix.** In a live incident your first move might be to
    > hot-patch the running pods to stop the bleeding. From `~/io-108/lab_environment/lab_env_student`, run
    > `helm upgrade orders charts/orders --namespace orders --reuse-values --set env.dbHost="$WRITER"`.
    > Changing the value rolls the pods automatically, which restores writes within a minute or two.
    > That is a valid first action, but it only changes the live pods; the board's
    > `aurora_writable` probe follows the Terraform-declared DB target, so reconcile Terraform
    > (above) to actually close the incident on the board.

6. **Confirm** the new pods are running (`deploy_app.sh` already waited, so this normally returns at once; allow up to 3 minutes):

    ```bash
    kubectl -n orders rollout status deploy/orders-api --timeout=180s
    kubectl -n orders exec deploy/orders-api -- printenv DB_HOST
    ```
<!-- source: Lab_4_narrative.md §"restart the pods so they pick up the new configuration" -->

    > **Expected Result:** `deployment "orders-api" successfully rolled out`, then the same endpoint as `$WRITER` (contains `.cluster-`). If `rollout status` times out, run it again; the pods install packages at startup.

7. **Verify** writes succeed now:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" \
      -c "CREATE TABLE IF NOT EXISTS lab4_writecheck(id serial, ts timestamptz default now()); INSERT INTO lab4_writecheck DEFAULT VALUES RETURNING id;"
    ```
    <!-- source: Lab_4_narrative.md §"Submit test order, verify processing" -->

    Expected: `CREATE TABLE` (or, on a re-run, `NOTICE:  relation "lab4_writecheck" already exists, skipping`), then a new `id` and `INSERT 0 1`:

    ```
     id
    ----
      1
    (1 row)

    INSERT 0 1
    ```

    The `INSERT` returned a new `id`, so writes work. An error containing `read-only transaction` means you are still on the reader; check that `$WRITER` contains `.cluster-` (Pre-Lab step 2).

> **Expected Result:** Within 1–2 minutes of the apply, the **Aurora writable** (`aurora_writable`) tile turns **GREEN**. The app can persist orders again. Record recovery time.

> **What Just Happened?** Nothing was wrong with the database, the network, or the credentials. The app was simply pointed at a read-only target. In a real failover, the *same* fix matters: applications must use the cluster endpoint so they follow the writer automatically — hard-coding an instance or reader endpoint is what turns a 30-second failover into an outage.

---

## Task 4: Trace the Rogue Client with Query Tracing

The `aurora_no_rogue` tile is still red. Since Lab 0, a rogue instance has held a Postgres session open to Aurora using stolen master credentials. (You stopped it in Lab 1; it is back — applying `lab4` restarted it.) Now you will catch it on the database itself.

8. **List live sessions** with `pg_stat_activity` and look for a client whose source IP is **not** an EKS pod:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c \
      "SELECT pid, client_addr, usename, state, query
         FROM pg_stat_activity
        WHERE client_addr IS NOT NULL
        ORDER BY backend_start DESC;"
    ```
    <!-- source: Module_3_narrative.md §"the source address on the query is the tell" -->

    You will see several rows: the orders-api pods, the health-checker Lambda, and this `psql` session. Compare each `client_addr` with the rogue IP from Pre-Lab step 2 (`echo $ROGUE_IP`). To show only the rogue's sessions, filter on its address:

    ```bash
    kubectl -n orders exec psql-client -- psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c \
      "SELECT pid, client_addr, state, query FROM pg_stat_activity WHERE client_addr = '$ROGUE_IP';"
    ```

    Expected: one row whose `client_addr` is the rogue IP, `state` is `active`, and `query` is `SELECT pg_sleep(300)`. That is a benign-looking query that holds one connection open for 5 minutes and is then reopened: exactly the kind of low-and-slow access that hides in plain sight. If it shows `(0 rows)`, wait a minute and re-run; the rogue reconnects within seconds of each session ending.

9. **Corroborate with Performance Insights.** Performance Insights records which clients put load on the database over time. In the **RDS console → Databases**, select the writer instance **`io108-<your-id>-aurora-0`** (or `-1`, whichever shows *Writer instance* in the **Role** column). Open the **Monitoring** tab and choose **Performance Insights** (it may open in CloudWatch **Database Insights**). Set the time range to **Last 1 hour** and change **Slice by** to **Hosts**. Look for a host matching `$ROGUE_IP`, shown as a load contributor separate from the application pods. Its load shows a sleep wait (`PgSleep`), which is the rogue's `pg_sleep`. This is the GUI view of the same evidence, useful when you cannot get a psql session.

10. **Corroborate with connection logs.** The cluster has `log_connections` and `log_disconnections` enabled, so every new session writes a line to the log group `/aws/rds/cluster/io108-<your-id>-aurora/postgresql`. Search the last hour for the rogue IP (about 10–30 seconds):

    ```bash
    aws logs filter-log-events \
      --log-group-name "/aws/rds/cluster/io108-${STUDENT_ID}-aurora/postgresql" \
      --start-time $(( ($(date +%s) - 3600) * 1000 )) \
      --filter-pattern "\"$ROGUE_IP\"" --region "$REGION" \
      --query 'events[].[message]' --output text | grep 'connection received' | tail -10
    ```
    <!-- source: Module_3_narrative.md §"rogue IP we are hunting" -->

    Expected: up to ten lines containing `connection received: host=<rogue IP> port=<number>`, about 5 minutes apart: one each time the rogue reopens its session. No output? Check that `echo $STUDENT_ID $ROGUE_IP` prints both values (re-run Pre-Lab step 2 if not).

> **Three lenses, one conclusion:** `pg_stat_activity` (live), Performance Insights (top SQL by host, historical), and the connection log (audit trail) all point at the same client IP. In an investigation you want at least two independent lenses agreeing before you take containment action.

---

## Task 5: Lock Out the Rogue and Confirm Green

11. **Revoke the rogue's network path** to Aurora. A *security group* (SG) is a firewall attached to a resource, and an *ingress rule* allows traffic in. The rogue reaches the database through a dedicated ingress rule on Aurora's SG. First look up the two SG ids and check them:

    ```bash
    ROGUE_SG=$(aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
    AURORA_SG=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=io108-${STUDENT_ID}-aurora-sg" \
      --query 'SecurityGroups[0].GroupId' --output text)
    echo "ROGUE_SG=$ROGUE_SG AURORA_SG=$AURORA_SG"
    ```

    Both values must start with `sg-`. If either is `None` or blank, re-run Pre-Lab step 2, then this block. Then remove the rule, so new connections from the rogue are dropped at the SG:

    ```bash
    aws ec2 revoke-security-group-ingress --group-id "$AURORA_SG" --region "$REGION" \
      --protocol tcp --port 5432 --source-group "$ROGUE_SG"
    ```
<!-- source: facts_extracted_v2.md §"Security group rules" -->

    > **Expected Result:** JSON containing `"Return": true`. If you get `InvalidPermission.NotFound`, the rule is already gone; continue.

12. **Stop the rogue instance** to fully contain it (this also clears the Lab 1 `rogue_contained` tile if it is still red):

    ```bash
    aws ec2 stop-instances --instance-ids "$ROGUE_ID" --region "$REGION"
    ```
<!-- source: Module_3_narrative.md §"rogue IP we are hunting" -->

    > **Expected Result:** JSON showing `"CurrentState"` with `"Name": "stopping"` (or `"stopped"` if it was already stopped).

13. **Confirm** no rogue sessions remain. Re-run the filtered `pg_stat_activity` query from step 8 (the one with `WHERE client_addr = '$ROGUE_IP'`). A session that was already open can linger for several minutes, so repeat every couple of minutes until it prints `(0 rows)`.

> **Expected Result:** `rogue_contained` goes green within 1–3 minutes. **Aurora: no rogue sessions** (`aurora_no_rogue`) turns **GREEN** once the rogue's last open session expires: allow up to 8 minutes.
>
> **Do not run `terraform apply` again in this lab.** Applying any scenario except `lab2` or `lab3` restarts the rogue and recreates the ingress rule you just revoked.

> **What Just Happened?** You did not just block an IP - you removed the *path* (the SG ingress rule) and contained the *asset* (the instance). Blocking only the symptom would let the rogue reconnect from a new address; removing the authorized path and stopping the instance closes the incident.

---

## Troubleshooting

### `aurora_writable` stays red after repointing

**Check:** Confirm the running pods actually use the writer endpoint: `kubectl -n orders exec deploy/orders-api -- printenv DB_HOST` should print the same value as `echo $WRITER` (contains `.cluster-`, not `.cluster-ro-`). If not, repeat step 5 (apply `healthy`, type `yes`, then `./deploy_app.sh`). The tile follows the Terraform target, so it stays red until that apply completes. Allow 1–2 minutes after it.

### `psql` pod cannot connect at all (timeout)

**Check:** The `psql-client` pod must run in the `orders` namespace so it inherits the path to Aurora's security group. Run `echo "$WRITER $READER ${#PGPASSWORD}"`: both endpoints must be present and the length above 0. If they are blank, re-run Pre-Lab step 2. If the password was blank when you created the pod, delete and recreate it (Pre-Lab step 3).

### `aurora_no_rogue` stays red

**Check:** The probe counts sessions from the rogue IP. If you only stopped the instance but a session was mid-flight, give it up to ~8 minutes. Confirm the SG ingress rule was actually revoked:

```bash
aws ec2 describe-security-groups --group-ids "$AURORA_SG" --region "$REGION" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`5432\`].UserIdGroupPairs[].GroupId" --output text
```

The output must **not** contain the `$ROGUE_SG` id (`echo $ROGUE_SG`). If it does, repeat step 11.

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

**Before you move on:** Log this in **ServiceNow** as a **P1** (downgrading to P2 after the writer repoint stabilizes). Capture: start time, root cause (app pointed at reader endpoint; separately, rogue sessions from `$ROGUE_IP`), remediation (repoint to cluster endpoint; revoke rogue SG ingress; stop rogue instance), and recovery times for both tiles.

**Clean up** the client pod:

```bash
kubectl -n orders delete pod psql-client
```

Expected: `pod "psql-client" deleted`.

## Next Steps

In **Lab 5: Multi-Layered Incident Simulation (Capstone)**, several failures hit at once — a network misroute, a broken IAM path, a pod-network deny, and the rogue — lighting up the whole board. You will lead with the incident board as your map, add **VPC Flow Logs**, **Reachability Analyzer**, and an optional **open-source packet-analysis box**, clear every tile, and write the post-incident report.
