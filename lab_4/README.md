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

Run from a local clone or AWS CloudShell.

1. **Materialize this lab's incident** (replace `s01` with your assigned id):

    ```bash
    cd lab_environment/lab_env_student
    terraform plan  -var scenario=lab4                       # student_id + region from terraform.tfvars (Lab 0)
    terraform apply -var scenario=lab4 -auto-approve
    ./deploy_app.sh
    ```
<!-- source: course_outline_v3.md §"Lab 4" -->

2. **Capture outputs:**

    ```bash
    export REGION=$(terraform output -raw region)
    export STUDENT_ID=$(terraform output -raw student_id)
    export DASHBOARD=$(terraform output -raw incident_board_dashboard_name)
    export WRITER=$(terraform output -raw aurora_cluster_endpoint)
    export READER=$(terraform output -raw aurora_reader_endpoint)
    export APP_DB_HOST=$(terraform output -raw app_db_host)
    export SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
    export ROGUE_IP=$(terraform output -raw rogue_private_ip)
    export ROGUE_ID=$(terraform output -raw rogue_instance_id)
    echo "Writer (cluster) endpoint: $WRITER"
    echo "Reader endpoint:           $READER"
    echo "App is currently using:    $APP_DB_HOST"
    echo "Rogue private IP:          $ROGUE_IP"
    ```

    Notice `APP_DB_HOST` matches the **reader** endpoint - that is the injected fault.

3. **Get the DB password** into your shell for the `psql` steps later (managed master credentials in Secrets Manager):

    ```bash
    export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
      --region "$REGION" --query SecretString --output text | jq -r .password)
    export PGUSER=orders_admin
    export PGDATABASE=orders
    ```
<!-- source: Lab_4_narrative.md §"ConfigMap/Secret for database URL" -->

---

## Task 1: Confirm "Reachable but Not Writable"

1. **Open** your incident board (`$DASHBOARD`) and find the **Lab 4** band:

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

    Expected: `cannot execute INSERT in a read-only transaction` (or `UPDATE`/`DELETE`).

> **Expected Result:** `aurora_writable` is red, the app logs the read-only error, and `aurora_reachable` confirms the DB is up. Record the incident start time.

---

## Task 2: Prove the Connection Is on a Read Replica

3. **Open** a one-off `psql` session **against the endpoint the app is currently using** (the reader), from inside the cluster so the network path matches the app's:

    ```bash
    kubectl -n orders run psql-reader --rm -it --restart=Never \
      --image=public.ecr.aws/docker/library/postgres:16 \
      --env="PGPASSWORD=$PGPASSWORD" -- \
      psql -h "$READER" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT pg_is_in_recovery();"
    ```
<!-- source: Module_3_narrative.md §"read replica" -->

    Expected: `pg_is_in_recovery` returns **`t`** (true) — this connection is on a read replica, which is read-only by definition.

4. **Compare** against the cluster (writer) endpoint:

    ```bash
    kubectl -n orders run psql-writer --rm -it --restart=Never \
      --image=public.ecr.aws/docker/library/postgres:16 \
      --env="PGPASSWORD=$PGPASSWORD" -- \
      psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT pg_is_in_recovery();"
    ```
<!-- source: Module_3_narrative.md §"always tracks the current primary" -->

    Expected: returns **`f`** (false) — the cluster endpoint always points at the current writer.

> **The three Aurora endpoints - know which is which:**
> - **Cluster (writer) endpoint** — always points at the current primary; use it for read-write workloads. Survives failover automatically.
> - **Reader endpoint** — load-balances across read replicas; read-only. Great for reporting, wrong for writes.
> - **Instance endpoints** — target one specific instance by name; brittle, because that instance can become a reader or be replaced during failover.
>
> Open the **RDS console -> Databases -> your cluster -> Connectivity & security** and read all three off the page so you can recognize them by shape next time.

---

## Task 3: Repoint the App to the Writer Endpoint and Confirm Green

5. **Repoint the stack at the writer (cluster) endpoint.** The application's DB target is set
    from Terraform — `deploy_app.sh` reads `app_db_host` — and the health board's
    `aurora_writable` probe checks that *same* Terraform-intended target. So the durable fix
    that also turns the tile green is to correct the wiring in Terraform and redeploy, returning
    the DB target from the reader to the cluster/writer endpoint:

    ```bash
    terraform apply -var student_id=$SID -var scenario=healthy -auto-approve
    ./deploy_app.sh
    ```
<!-- source: Lab_4_narrative.md §"use cluster endpoint" -->

    This points `app_db_host` back at the cluster (writer) endpoint for both the app and the
    probe. (The rogue is always-on and unaffected — you contain it in Task 5.)

    > **Immediate mitigation vs. durable fix.** In a live incident your first move might be to
    > hot-patch the running pods to stop the bleeding —
    > `helm upgrade orders charts/orders --namespace orders --reuse-values --set env.dbHost="$WRITER"`
    > then `kubectl -n orders rollout restart deploy/orders-api` — which restores writes within
    > seconds. That is a valid first action, but it only changes the live pods; the board's
    > `aurora_writable` probe follows the Terraform-declared DB target, so reconcile Terraform
    > (above) to actually close the incident on the board.

6. **Restart** the deployment if you used the hot-patch mitigation, so pods reconnect:

    ```bash
    kubectl -n orders rollout status deploy/orders-api --timeout=180s
    ```
<!-- source: Lab_4_narrative.md §"restart the pods so they pick up the new configuration" -->

7. **Verify** writes succeed now:

    ```bash
    kubectl -n orders run psql-check --rm -it --restart=Never \
      --image=public.ecr.aws/docker/library/postgres:16 \
      --env="PGPASSWORD=$PGPASSWORD" -- \
      psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" \
      -c "CREATE TABLE IF NOT EXISTS lab4_writecheck(id serial, ts timestamptz default now()); INSERT INTO lab4_writecheck DEFAULT VALUES RETURNING id;"
    ```
<!-- source: Lab_4_narrative.md §"Submit test order, verify processing" -->

    Expected: the `INSERT` returns a new `id` - writes work.

> **Expected Result:** Within 1-2 minutes the **Aurora writable** (`aurora_writable`) tile turns **GREEN**. The app can persist orders again. Record recovery time.

> **What Just Happened?** Nothing was wrong with the database, the network, or the credentials. The app was simply pointed at a read-only target. In a real failover, the *same* fix matters: applications must use the cluster endpoint so they follow the writer automatically — hard-coding an instance or reader endpoint is what turns a 30-second failover into an outage.

---

## Task 4: Trace the Rogue Client with Query Tracing

The `aurora_no_rogue` tile is still red. Since Lab 0, a rogue instance has opened a Postgres session to Aurora roughly once a minute using stolen master credentials. Now you will catch it on the database itself.

8. **List live sessions** with `pg_stat_activity` and look for a client whose source IP is **not** an EKS pod:

    ```bash
    kubectl -n orders run psql-activity --rm -it --restart=Never \
      --image=public.ecr.aws/docker/library/postgres:16 \
      --env="PGPASSWORD=$PGPASSWORD" -- \
      psql -h "$WRITER" -U "$PGUSER" -d "$PGDATABASE" -c \
      "SELECT pid, client_addr, usename, state, query
         FROM pg_stat_activity
        WHERE client_addr IS NOT NULL
        ORDER BY backend_start DESC;"
    ```
<!-- source: Module_3_narrative.md §"the source address on the query is the tell" -->

    Compare the `client_addr` values against the rogue IP you captured (`$ROGUE_IP`). The rogue's source IP will appear holding a long-lived, benign-looking idle session (a `pg_sleep` that keeps one connection open) — exactly the kind of low-and-slow access that hides in plain sight.

9. **Corroborate with Performance Insights.** In the **RDS console -> Performance Insights**, select your writer instance, and group the top load **by host / client**. The rogue's host shows up as a contributor distinct from the application pods. This is the GUI view of the same evidence — useful when you cannot get a psql session.

10. **Corroborate with connection logs.** The cluster has `log_connections` and `log_disconnections` enabled. In **CloudWatch Logs**, open the log group `/aws/rds/cluster/io108-<your-id>-aurora/postgresql` and filter for the rogue IP:

    ```bash
    aws logs filter-log-events \
      --log-group-name "/aws/rds/cluster/io108-${STUDENT_ID}-aurora/postgresql" \
      --filter-pattern "\"$ROGUE_IP\"" --region "$REGION" \
      --query 'events[].message' --output text | tail -10
    ```
<!-- source: Module_3_narrative.md §"rogue IP we are hunting" -->

    Expected: repeated `connection received: host=<rogue IP>` lines on the ~1-minute cadence.

> **Three lenses, one conclusion:** `pg_stat_activity` (live), Performance Insights (top SQL by host, historical), and the connection log (audit trail) all point at the same client IP. In an investigation you want at least two independent lenses agreeing before you take containment action.

---

## Task 5: Lock Out the Rogue and Confirm Green

11. **Revoke the rogue's network path** to Aurora. The rogue reaches the database through a dedicated security-group ingress rule. Remove it so new connections from the rogue are dropped at the SG:

    ```bash
    ROGUE_SG=$(aws ec2 describe-instances --instance-ids "$ROGUE_ID" --region "$REGION" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
    AURORA_SG=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=io108-${STUDENT_ID}-aurora-sg" \
      --query 'SecurityGroups[0].GroupId' --output text)
    aws ec2 revoke-security-group-ingress --group-id "$AURORA_SG" --region "$REGION" \
      --protocol tcp --port 5432 --source-group "$ROGUE_SG"
    ```
<!-- source: facts_extracted_v2.md §"Security group rules" -->

12. **Stop the rogue instance** to fully contain it (this also clears the Lab 1 `rogue_contained` tile if it is still red):

    ```bash
    aws ec2 stop-instances --instance-ids "$ROGUE_ID" --region "$REGION"
    ```
<!-- source: Module_3_narrative.md §"rogue IP we are hunting" -->

13. **Confirm** no rogue sessions remain. Re-run the `pg_stat_activity` query from Task 4 step 8; the rogue IP should no longer appear (existing sessions die within a cycle).

> **Expected Result:** Within 1-2 minutes the **Aurora: no rogue sessions** (`aurora_no_rogue`) tile turns **GREEN**. With the instance stopped, `rogue_contained` goes green too.

> **What Just Happened?** You did not just block an IP - you removed the *path* (the SG ingress rule) and contained the *asset* (the instance). Blocking only the symptom would let the rogue reconnect from a new address; removing the authorized path and stopping the instance closes the incident.

---

## Troubleshooting

### `aurora_writable` stays red after repointing

**Check:** Confirm the running pods actually use the writer endpoint: `kubectl -n orders exec deploy/orders-api -- printenv | grep -i dbhost` (or check the value you set). Make sure you ran `rollout restart` — existing pods keep their old connection until recycled.

### `psql` pod cannot connect at all (timeout)

**Check:** The throwaway `psql` pod must run in the `orders` namespace so it inherits the path to Aurora's security group. Confirm `$PGPASSWORD` is set and you are using the right endpoint variable.

### `aurora_no_rogue` stays red

**Check:** The probe counts sessions from the rogue IP. If you only stopped the instance but a session was mid-flight, give it a cycle. Confirm the SG ingress rule was actually revoked: `aws ec2 describe-security-groups --group-ids "$AURORA_SG"` should no longer list the rogue SG on port 5432.

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

## Next Steps

In **Lab 5: Multi-Layered Incident Simulation (Capstone)**, several failures hit at once — a network misroute, a broken IAM path, a pod-network deny, and the rogue — lighting up the whole board. You will lead with the incident board as your map, add **VPC Flow Logs**, **Reachability Analyzer**, and an optional **open-source packet-analysis box**, clear every tile, and write the post-incident report.
