# Lab 3: Lambda and Step Functions Performance Incident + Event Fan-out

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 3 - Lambda and Step Functions Performance Incident |
| **Duration** | 40 minutes |
| **Difficulty** | Intermediate |
| **Severity (this incident)** | **P2** - degraded reporting, no customer-facing outage |
| **Incident platform** | ServiceNow (log the incident, attach your timeline, set Priority = P2) |
| **Prerequisites** | Labs 1-2 completed; AWS CLI v2, `kubectl`, `jq` configured for the training account; access to your `io108-<id>-incident-board` CloudWatch dashboard |
| **Builds On** | The single connected application stack you deployed in Lab 0 (EKS orders-api -> Aurora -> Lambda/Step Functions reporting). The rogue instance from the security through-line is still present and its tiles (`aurora_no_rogue`, `rogue_contained`) stay red until Lab 4/the capstone. |

---

## Lab Overview

SYF's Technology Operations group runs a scheduled reporting workflow: every few minutes an **Amazon EventBridge** rule starts an **AWS Step Functions** state machine, which invokes a **report-generator AWS Lambda** that queries Aurora and writes a JSON report to S3. This morning the business reported that reports have gone stale — the dashboards downstream are showing yesterday's numbers.

In this lab you treat that as a real incident. You will:

1. Open the **red/green incident board** and confirm which tile is red.
2. Diagnose the workflow failure using **Step Functions execution history** and **Lambda CloudWatch metrics** (Throttles vs. Errors).
3. Apply the fix and watch the `reports_flowing` tile go green.
4. Study the **event fan-out** pipeline that distributes a single incident event to multiple monitoring endpoints, and verify the same event lands in both simulated sinks.

This is a P2: reporting is degraded, but no customer transaction path is down. Log it in **ServiceNow** as you would in production, and capture a short timeline as you work.

---

## Scenario

> **Incident:** "Scheduled financial reports stopped refreshing around 09:10. Latest report object in S3 is over an hour old. No error visible in the app itself."

The reporting pipeline is healthy in wiring but broken in capacity. Under the hood, the report-generator Lambda has had its **reserved concurrency pinned to 0**. Every invocation is throttled before it can run; the Step Functions task exhausts its retries and the execution lands in a `Fail` state. No fresh report is ever written. Your incident board shows `reports_flowing` **red**.

Your job: find the throttle, restore capacity, confirm reports flow again, then understand how the platform fanned the incident alarm out to SYF's monitoring tools.

---

## Learning Objectives

By the end of this lab, you will be able to:

- Use a CloudWatch alarm-status dashboard as the entry point ("incident map") for triage.
- Read **Step Functions** execution history to find the failing task and distinguish a retry storm from a one-off error.
- Tell **Lambda Throttles** apart from **Lambda Errors** in CloudWatch metrics, and explain what each means.
- Fix a reserved-concurrency throttle from the console or CLI and verify recovery on the dashboard.
- Explain how a **Step Functions Parallel** state fans one event out to N destinations, and verify the same event reached two independent sinks.

---

## Pre-Lab Setup

Run from a local clone or AWS CloudShell — **not** a Google Drive/OneDrive synced folder.

1. **Materialize this lab's incident.** From the lab environment directory, apply the `lab3` scenario (replace `s01` with your assigned student id):

    ```bash
    cd lab_environment/lab_env_student
    terraform apply -var="student_id=s01" -var="scenario=lab3" -auto-approve
    ```
<!-- source: course_outline_v3.md §"using Terraform and verify its health" -->

2. **Redeploy the app** so it picks up the scenario wiring:

    ```bash
    ./deploy_app.sh
    ```
<!-- source: course_outline_v3.md §"Deploy a multi-service AWS application stack" -->

3. **Capture the outputs** every task below reads. Paste this block verbatim:

    ```bash
    export REGION=$(terraform output -raw region)
    export STUDENT_ID=$(terraform output -raw student_id)
    export DASHBOARD=$(terraform output -raw incident_board_dashboard_name)
    export SFN_ARN=$(terraform output -raw sfn_state_machine_arn)
    export REPORTS_BUCKET=$(terraform output -raw reports_bucket)
    export REPORT_FN="io108-${STUDENT_ID}-report-generator"
    export SINK_NR=$(terraform output -json sink_buckets | jq -r .newrelic)
    export SINK_SW=$(terraform output -json sink_buckets | jq -r .solarwinds)
    export FANOUT_ALARM=$(terraform output -raw fanout_trigger_alarm_name)
    echo "Dashboard:   $DASHBOARD"
    echo "Report fn:   $REPORT_FN"
    echo "Report SFN:  $SFN_ARN"
    ```

> **Note:** The metrics-based tiles read CloudWatch data published every minute. After you apply a fix, allow **1-2 minutes** for a probe cycle before a tile flips color.

---

## Task 1: Read the Incident Board

1. **Open** the CloudWatch console and navigate to **Dashboards**. Open the dashboard named in `$DASHBOARD` (it is `io108-<your-id>-incident-board`).

2. **Find** the **Lab 3** band. You should see three tiles:

    - **Reports flowing** (`reports_flowing`) - **RED**
    - **Sink: NewRelic (fan-out)** (`sink_newrelic`) - GREEN
    - **Sink: SolarWinds (fan-out)** (`sink_solarwinds`) - GREEN

    The two sink tiles being green tells you the event-distribution pipeline is healthy; only report *generation* is broken. That narrows the incident immediately.

> **Expected Result:** `reports_flowing` is red; both `sink_*` tiles are green. Note the time the tile went red — that is your incident start time for the ServiceNow timeline.

---

## Task 2: Diagnose with Step Functions Execution History

3. **Open** the Step Functions console and select the state machine `io108-<your-id>-report-workflow` (ARN in `$SFN_ARN`).

4. **Open** the most recent execution. You will see the `GenerateReport` task **fail**, retry on its `Retry` policy, fail again, and the execution route into the `ReportFailed` state. From the CLI:

    ```bash
    aws stepfunctions list-executions --state-machine-arn "$SFN_ARN" \
      --region "$REGION" --max-results 3 \
      --query 'executions[].{start:startDate,status:status}' --output table
    ```
<!-- source: Module_3_narrative.md §"A FAILED execution shows you the exact state that failed" -->

    Expected: the latest executions show `FAILED`.

5. **Inspect** the failing task's cause. In the execution graph, click the **GenerateReport** step and read the event detail, or pull it from the CLI:

    ```bash
    EXEC_ARN=$(aws stepfunctions list-executions --state-machine-arn "$SFN_ARN" \
      --region "$REGION" --status-filter FAILED --max-results 1 \
      --query 'executions[0].executionArn' --output text)
    aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" \
      --region "$REGION" --reverse-order --max-results 20 \
      --query "events[?type=='LambdaFunctionScheduleFailed' || type=='TaskFailed'].[type,taskFailedEventDetails.cause]" \
      --output text
    ```
<!-- source: Module_3_narrative.md §"Open the failed execution and read the history" -->

    You are looking for a cause that mentions throttling / `TooManyRequestsException` / `Rate Exceeded`, not an application stack trace. **That distinction is the whole diagnosis:** the workflow is wired correctly and the Lambda code is fine — the function is being *throttled before it runs*.

> **What Just Happened?** Step Functions did exactly what it was told: it retried a failing task and, when the retries were exhausted, failed the execution cleanly into `ReportFailed`. The failure is not in the workflow logic — it is in the Lambda's capacity to execute.

---

## Task 3: Confirm Throttling in Lambda Metrics

6. **Open** the Lambda console, select function `$REPORT_FN`, and go to the **Monitor** tab. Compare two metrics over the last hour:

    - **Throttles** — elevated (every invocation is being throttled).
    - **Errors** — flat or zero (the code never ran, so it never errored).

    From the CLI, confirm the throttle count is non-zero:

    ```bash
    aws cloudwatch get-metric-statistics --namespace AWS/Lambda \
      --metric-name Throttles --dimensions Name=FunctionName,Value="$REPORT_FN" \
      --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
      --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --period 300 --statistics Sum --region "$REGION" --output table
    ```
<!-- source: Module_3_narrative.md §"The Throttles metric in CloudWatch counts these exactly" -->

7. **Check** the function's concurrency configuration — this is the root cause:

    ```bash
    aws lambda get-function-concurrency --function-name "$REPORT_FN" --region "$REGION"
    ```
<!-- source: Lab_3_narrative.md §"aws lambda get-function-concurrency" -->

    Expected: `"ReservedConcurrentExecutions": 0`. A reserved concurrency of **0** means the function is allowed **zero** simultaneous executions — so AWS throttles every single invocation.

> **Throttles vs. Errors — the takeaway:** **Throttles** mean the platform refused to run your function (capacity/quota). **Errors** mean your function ran and failed (bug, exception, timeout). They live in different metrics and point at completely different fixes. Misreading one for the other sends responders down the wrong path.

---

## Task 4: Fix the Throttle and Confirm Green

8. **Raise** the reserved concurrency so the function can run. From the Lambda console: **Configuration -> Concurrency -> Edit -> Reserve concurrency** and set it to **5**. Or from the CLI:

    ```bash
    aws lambda put-function-concurrency --function-name "$REPORT_FN" \
      --reserved-concurrent-executions 5 --region "$REGION"
    ```
<!-- source: Lab_3_narrative.md §"aws lambda put-function-concurrency" -->

    > Setting a small positive reserve (5) both fixes the throttle and keeps a sensible cap. Alternatively `aws lambda delete-function-concurrency` removes the limit entirely and lets the function draw from the account pool. Either restores capacity.

9. **Trigger** a fresh run rather than waiting for the next schedule:

    ```bash
    aws stepfunctions start-execution --state-machine-arn "$SFN_ARN" --region "$REGION"
    ```
<!-- source: Module_3_narrative.md §"Step Functions state machine driven by EventBridge" -->

10. **Confirm** the execution now succeeds and a fresh report lands in S3:

    ```bash
    aws s3 ls "s3://$REPORTS_BUCKET/reports/" --recursive | tail -5
    ```
<!-- source: course_outline_v3.md §"report landing in S3" -->

    Expected: a new object with a recent timestamp.

> **Expected Result:** Within 1-2 minutes the **Reports flowing** (`reports_flowing`) tile on your incident board turns **GREEN**. Capture the recovery time for your timeline.

---

## Task 5: Understand and Verify the Event Fan-out

When the report pipeline failed, a CloudWatch alarm (`$FANOUT_ALARM`, on report-generator **Errors**) is wired to fan that incident out to every monitoring tool SYF uses. This is the teaching centerpiece: **one event, many destinations.**

The path is:

```
CloudWatch Alarm (report errors) ---\
                                      >--> EventBridge rule
EventBridge heartbeat (every 2 min) -/         |
                                               v
                    Step Functions state machine -- Parallel state
                       |-- branch "newrelic"   --> SQS queue --\
                       |-- branch "solarwinds" --> SQS queue --- > forwarder Lambda
                                                               --> writes the SAME event
                                                                   to BOTH S3 sink buckets
```

A **Step Functions Parallel** state sends the *same input* to every branch simultaneously. Each branch drops the event on its own SQS queue; a forwarder Lambda drains both queues and writes an object to each destination's S3 sink. A heartbeat keeps the sinks fresh (green) while healthy; a real alarm fans out the same way.

> **Note on simulated destinations:** The two S3 buckets (`$SINK_NR`, `$SINK_SW`) *represent* NewRelic and SolarWinds. In SYF's environment these are the real NewRelic and SolarWinds ingestion endpoints; here we land the event in S3 so you can inspect it directly without a third-party integration.

11. **Trigger** a fan-out and verify the same event reached both sinks. Start the fan-out state machine directly:

    ```bash
    export FANOUT_SFN=$(terraform output -raw fanout_state_machine_arn)
    aws stepfunctions start-execution --state-machine-arn "$FANOUT_SFN" \
      --input '{"source":"lab3-manual-test","incident":"report-pipeline"}' --region "$REGION"
    ```
<!-- source: Module_2_narrative.md §"hands the same event to several branches at once" -->

12. **Confirm** a fresh object appeared in **both** sink buckets:

    ```bash
    echo "== NewRelic sink ==";  aws s3 ls "s3://$SINK_NR/"  --recursive | tail -3
    echo "== SolarWinds sink =="; aws s3 ls "s3://$SINK_SW/" --recursive | tail -3
    ```

    Expected: both buckets received a new object at the same time — the single fan-out execution reached both monitoring endpoints.

> **Expected Result:** Both `sink_newrelic` and `sink_solarwinds` tiles remain **green**, and you can see a matching pair of fresh objects in the two buckets. You have proven the platform delivers one incident event to multiple tools.

> **What Just Happened?** This is how AWS distributes a single observability event to a whole monitoring estate. The Parallel state is the fan-out primitive; SQS gives each destination its own buffered, retryable queue; the forwarder Lambda does any per-tool transformation. Add a third tool tomorrow and you add one branch and one queue — the source event does not change.

---

## Troubleshooting

### The `reports_flowing` tile stays red after the fix

**Check:** Confirm `aws lambda get-function-concurrency` no longer returns `0`. Then confirm the most recent Step Functions execution is `SUCCEEDED` and a report object newer than your fix time exists in S3.

**Fix:** If concurrency is correct but executions still fail, read the new failure cause — it should now be an application/DB error, not a throttle, which is a different problem. Give the dashboard 1-2 minutes; the probe only runs once a minute.

### Step Functions execution shows no failures at all

**Check:** You may be looking at executions from before the incident, or the schedule has not fired since you applied `lab3`. Start one manually with `aws stepfunctions start-execution`.

### A sink tile is red

**Check:** List the bucket for a recent object. The heartbeat fans out every 2 minutes, so a sink should never be stale for long. If a sink is red, confirm the forwarder Lambda (`io108-<id>-fanout-forwarder`) has no errors in its CloudWatch logs.

---

## Knowledge Check

**Question 1:** Your teammate sees the Step Functions execution failed and immediately starts reading the report-generator's application code for a bug. Based on what the **Throttles** and **Errors** metrics showed, why is that the wrong place to look, and what is the actual root cause?

**Question 2:** The reporting Lambda's reserved concurrency was set to `0`. Explain precisely what that value does to invocations, and why it produces *throttles* rather than *errors*.

**Question 3:** In the fan-out pipeline, the Step Functions **Parallel** state is what delivers the same event to both NewRelic and SolarWinds. If SYF onboards a third monitoring tool next quarter, what is the minimal change needed, and why does the original incident event not need to change?

<details>
<summary><strong>Answers</strong></summary>

**A1:** The **Errors** metric was flat/zero while **Throttles** was elevated, which means the function code never executed — so there is no application bug to find. The root cause is capacity: reserved concurrency pinned to 0 caused AWS to throttle every invocation before it ran. The fix is to restore concurrency, not to touch the code.

**A2:** Reserved concurrency caps the number of simultaneous executions a function may have. Set to `0`, the function is permitted zero concurrent executions, so every invocation is rejected by the Lambda service with a throttle (`TooManyRequestsException` / 429). The code is never entered, so nothing can raise an application error — that is why it shows as a throttle, not an error.

**A3:** Add one branch to the Parallel state (and its own SQS queue + forwarder handling) for the new destination. The Parallel state passes the *same input* to every branch, so the source event and the upstream alarm/EventBridge wiring are unchanged - you are only adding a new delivery leg.

</details>

---

## Lab Summary

- You triaged a stale-reports incident starting from the **red/green incident board**, not from raw logs.
- You used **Step Functions execution history** to localize the failure to the `GenerateReport` task, then used **Lambda CloudWatch metrics** to prove it was a **throttle**, not an **error**.
- You restored capacity by raising reserved concurrency and watched `reports_flowing` go green.
- You traced the **event fan-out** (CloudWatch Alarm -> EventBridge -> Step Functions Parallel -> SQS x N -> forwarder Lambda -> S3 sinks) and verified one event reaching two monitoring endpoints.

**Before you move on:** In **ServiceNow**, record this as a **P2** incident — title, start time (tile went red), root cause (reserved concurrency = 0 throttling the report Lambda), remediation (raised reserved concurrency to 5), and recovery time (tile went green). You will assemble several of these into a full post-incident report in the Lab 5 capstone.

## Next Steps

In **Lab 4: Aurora Failover and Connectivity Investigation**, the database stays *up* but the application can no longer write to it — the classic "the database is fine but the app is broken" incident. You will also trace live database sessions to catch the rogue client that has been querying Aurora since day one.
