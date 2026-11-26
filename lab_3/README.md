# Lab 3: Lambda and Step Functions Performance Incident + Event Fan-out

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 3 - Lambda and Step Functions Performance Incident |
| **Duration** | 40 minutes |
| **Difficulty** | Intermediate |
| **Severity (this incident)** | **P2** - degraded reporting, no customer-facing outage |
| **Incident platform** | Your incident notes (in production: ServiceNow, Priority = P2) |
| **Prerequisites** | Labs 1-2 completed, including Lab 1 **Start Here** on your lab host (it saves `SID`/`REGION` and connects Terraform). Every command runs on the lab host as `ec2-user`. |
| **Builds On** | The application stack from Lab 0 (EKS orders-api -> Aurora -> Lambda/Step Functions reporting). The Lab 1 rogue instance stays as you left it: if you contained it, `Rogue contained` and `Aurora: no rogue sessions` stay green; if not, they stay red. Lab 4 starts the rogue again. |

---

## Lab Overview

Every 5 minutes an **Amazon EventBridge** rule starts an **AWS Step Functions** state machine, which invokes a **report-generator AWS Lambda** that queries Aurora and writes a JSON report to S3. This morning the reports went stale.

In this lab you will:

1. Confirm on the **incident board** which tile is red.
2. Diagnose the failure with **Step Functions execution history** and **Lambda CloudWatch metrics** (Throttles vs. Errors).
3. Apply the fix and watch the `reports_flowing` tile go green.
4. Verify the **event fan-out** pipeline delivers one incident event to two simulated monitoring sinks.

---

## Scenario

> **Incident:** "Scheduled financial reports stopped refreshing around 09:10. Latest report object in S3 is over an hour old. No error visible in the app itself."

You open a **P2** incident in **ServiceNow**: reporting is degraded, but no customer transaction path is down. Your board shows `reports_flowing` **red**. Find why the workflow fails, restore it, and confirm the incident alarm reached SYF's monitoring tools.

---

## Learning Objectives

By the end of this lab, you will be able to:

- Use a CloudWatch alarm-status dashboard as the entry point ("incident map") for triage.
- Read **Step Functions** execution history to find the failing task and distinguish a retry storm from a one-off error.
- Tell **Lambda Throttles** apart from **Lambda Errors** in CloudWatch metrics, and explain what each means.
- Fix a reserved-concurrency throttle from the console or CLI and verify recovery on the dashboard.
- Explain how a **Step Functions Parallel** state fans one event out to N destinations, and verify the same event reached two independent sinks.

---

## Task 1: Lab Setup

Run every command in this lab on your **lab host** as **`ec2-user`** (Session Manager, then `sudo su - ec2-user`, as in Lab 1 Start Here). Run each code block on its own, and wait for it to finish before you start the next.

1. **Go to** the lab directory and **check** your variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
    ```

    The `echo` must show your own id and region, for example `SID=user01 REGION=us-east-1` (not blank, not `userNN`). If it is blank, run `source ~/.bashrc` and run this block again; if it is still wrong, redo Lab 1 Start Here step 3.

2. **Preview** the incident. This command changes nothing; it only shows what the apply will do. Run it on its own:

    ```bash
    terraform plan -var scenario=lab3
    ```
<!-- source: course_outline_v3.md §"using Terraform and verify its health" -->

    It takes about a minute and ends with a `Plan:` line. **Check it.** It should be small: about **`Plan: 0 to add, 2 to change, 0 to destroy.`** (2–3 to change, 0–1 to add or destroy). The resources listed above the `Plan:` line are `aws_lambda_function.report_generator` (reserved concurrency set to `0`) and `aws_cloudwatch_dashboard.incident_board` (the board's scenario label). You may also see `aws_ec2_instance_state.rogue[0]` destroyed (this only drops Terraform's record of the rogue's run state; the rogue stays as you left it), or the node group if you changed it outside Lab 2's steps.

    If it wants to add dozens or 100+ resources, **stop** and tell your instructor; do not run step 3. Terraform cannot see your stack.

3. **Inject** this lab's incident. Run this command on its own:

    ```bash
    terraform apply -var scenario=lab3
    ```

    Terraform prints the same plan again and stops at `Enter a value:`. If the `Plan:` line matches your preview in step 2, type **`yes`** and press **Enter**; otherwise type **`no`**, press **Enter**, and tell your instructor.

    > **Expected Result:** Within about a minute, Terraform prints **`Apply complete! Resources: 0 added, 2 changed, 0 destroyed.`** (your numbers may differ by one, as above) followed by a list of outputs, and you are back at the `$` prompt.

4. **Redeploy** the app. This re-installs it from its Helm chart and removes Lab 2's NetworkPolicies (including your `orders-allow-egress`), so the cluster starts this lab clean. Run this only after step 3 has finished:

    ```bash
    ./deploy_app.sh
    ```
<!-- source: course_outline_v3.md §"Deploy a multi-service AWS application stack" -->

    > **Expected Result:** After about 1–2 minutes the script prints `netpol default-deny: false` near the top, then `deployment "orders-api" successfully rolled out`, and ends with **`Deploy complete.`** If it prints `WARNING: orders-api is not Ready`, wait 2 minutes and run `kubectl -n orders get pods`; the `orders-api-...` pods should show `1/1   Running`.

5. **Capture** the values this lab uses into shell variables. **After any reconnect, run steps 1 and 5 again**, because a new session forgets these variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
    export DASHBOARD=$(terraform output -raw incident_board_dashboard_name)
    export SFN_ARN=$(terraform output -raw sfn_state_machine_arn)
    export FANOUT_SFN=$(terraform output -raw fanout_state_machine_arn)
    export REPORTS_BUCKET=$(terraform output -raw reports_bucket)
    export REPORT_FN="io108-${SID}-report-generator"
    export SINK_NR=$(terraform output -json sink_buckets | jq -r .newrelic)
    export SINK_SW=$(terraform output -json sink_buckets | jq -r .solarwinds)
    export FANOUT_ALARM=$(terraform output -raw fanout_trigger_alarm_name)
    echo "Dashboard:   $DASHBOARD"
    echo "Report fn:   $REPORT_FN"
    echo "Report SFN:  $SFN_ARN"
    echo "Fan-out SFN: $FANOUT_SFN"
    echo "Reports:     $REPORTS_BUCKET"
    echo "Sinks:       $SINK_NR  $SINK_SW"
    echo "Alarm:       $FANOUT_ALARM"
    ```

    > **Expected Result:** Every line shows a value: your own `SID=` and `REGION=`, then lines like `Dashboard:   io108-user01-incident-board`, `Report fn:   io108-user01-report-generator`, and `arn:aws:states:...` ARNs. If `SID` is blank, run `source ~/.bashrc` and re-run the block. If any other value is blank, or you see `No outputs found`, run step 1 again, then this step; if it is still blank, redo Lab 1 Start Here steps 4–5.

> **Expect a wait:** `reports_flowing` turns red once the newest report is over 10 minutes old, about **10 minutes** after the apply. Executions start failing at the next 5-minute schedule, so you can start Task 3 after about 5 minutes.

> **Reconnecting later?** Start a new session, run `sudo su - ec2-user`, then run **steps 1 and 5** again. If you were between steps 17 and 18, also re-run step 17.

---

## Task 2: Read the Incident Board

6. **Open** your incident board. In the AWS console search bar, type **CloudWatch** and open it. Check that the region selector at the top right matches your `REGION`. In the left menu choose **Dashboards**, then open **`io108-<your-id>-incident-board`** (the name printed as `Dashboard:` in step 5). Click the refresh icon (circular arrow) at the top right if the tiles look stale.

7. **Find** the **Lab 3** band. Record the incident as P2 in your incident notes, with the current time as the start time.

    > **Expected Result:** **Reports flowing** (`reports_flowing`) is **red**; **Sink: NewRelic (fan-out)** (`sink_newrelic`) and **Sink: SolarWinds (fan-out)** (`sink_solarwinds`) are **green**. Only report *generation* is broken; event distribution is healthy. If `reports_flowing` is still green, wait a few minutes and refresh.

---

## Task 3: Diagnose with Step Functions Execution History

8. **Open** the state machine. In the AWS console search bar, type **Step Functions** and open it (same region). In the left menu choose **State machines**, then click **`io108-<your-id>-report-workflow`**.

    > **Expected Result:** The state machine page opens with an **Executions** tab listing recent runs.

9. **Open** the newest failed execution. On the **Executions** tab, click the top execution whose **Status** is **Failed**. In the **Graph view**, click the **GenerateReport** step.

    > **Expected Result:** `GenerateReport` failed (after two retries) and the execution ended in the `ReportFailed` state. The step's error is `Lambda.TooManyRequestsException`. If no execution is **Failed** yet, wait 5 minutes and refresh.

10. **List** the latest executions from the CLI:

    ```bash
    aws stepfunctions list-executions --state-machine-arn "$SFN_ARN" \
      --region "$REGION" --max-results 3 \
      --query 'executions[].{start:startDate,status:status}' --output table
    ```
    <!-- source: Module_3_narrative.md §"A FAILED execution shows you the exact state that failed" -->

    > **Expected Result:** A small table whose newest rows (top) show `FAILED`; older rows from before the incident may show `SUCCEEDED`. If every row is `SUCCEEDED`, wait 5 minutes and re-run.

11. **Read** the failure cause from the execution history:

    ```bash
    EXEC_ARN=$(aws stepfunctions list-executions --state-machine-arn "$SFN_ARN" \
      --region "$REGION" --status-filter FAILED --max-results 1 \
      --query 'executions[0].executionArn' --output text)
    echo "EXEC_ARN=$EXEC_ARN"
    aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" \
      --region "$REGION" --reverse-order --max-results 20 \
      --query "events[?type=='TaskFailed'].[taskFailedEventDetails.error,taskFailedEventDetails.cause]" \
      --output text
    ```
    <!-- source: Module_3_narrative.md §"Open the failed execution and read the history" -->

    > **Expected Result:** `EXEC_ARN=arn:aws:states:...:execution:...`, then three similar lines (the first try plus two retries), each starting with **`Lambda.TooManyRequestsException`** and a cause such as `Rate Exceeded. (Service: Lambda, Status Code: 429, ...)`. If you see `EXEC_ARN=None`, no execution has failed yet (see step 10).

    > **Note:** A throttle, not an application stack trace. The workflow and the code are fine; the function is being *throttled before it runs*.

---

## Task 4: Confirm Throttling in Lambda Metrics

12. **Open** the function's metrics. In the AWS console search bar, type **Lambda** and open it (same region). Choose **Functions**, click **`io108-<your-id>-report-generator`** (the name printed as `Report fn:`), and open the **Monitor** tab.

    > **Expected Result:** Over the last hour, **Throttles** is elevated and **Errors** is flat or zero: the code never ran, so it never errored.

13. **Count** the throttles from the CLI:

    ```bash
    aws cloudwatch get-metric-statistics --namespace AWS/Lambda \
      --metric-name Throttles --dimensions Name=FunctionName,Value="$REPORT_FN" \
      --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
      --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --period 300 --statistics Sum --region "$REGION" --output table
    ```
<!-- source: Module_3_narrative.md §"The Throttles metric in CloudWatch counts these exactly" -->

    > **Expected Result:** One row per 5-minute period since the incident started, each with a `Sum` of about `3.0` (one scheduled run = three throttled attempts). An empty table means no run has been throttled yet: wait 5 minutes and re-run.

14. **Check** the function's concurrency configuration:

    ```bash
    aws lambda get-function-concurrency --function-name "$REPORT_FN" --region "$REGION"
    ```
    <!-- source: Lab_3_narrative.md §"aws lambda get-function-concurrency" -->

    > **Expected Result:**

    ```
    {
        "ReservedConcurrentExecutions": 0
    }
    ```

    This is the root cause: reserved concurrency **0** allows zero simultaneous executions, so Lambda throttles every invocation.

> **Throttles vs. Errors:** **Throttles** mean the platform refused to run your function (capacity). **Errors** mean your function ran and failed (bug, exception, timeout). They point at completely different fixes.

---

## Task 5: Fix the Throttle and Confirm Green

15. **Remove** the concurrency cap so the function can use the account pool again:

    ```bash
    aws lambda delete-function-concurrency --function-name "$REPORT_FN" --region "$REGION"
    ```
    <!-- source: Lab_3_narrative.md §"aws lambda put-function-concurrency" -->

    > **Expected Result:** Nothing is printed; you are back at the `$` prompt.

    > **Note:** Do not re-apply `scenario=lab3`; that pins concurrency back to `0`. A small positive reserve (`put-function-concurrency`) would fail on this training account, because AWS keeps at least 10 concurrency unreserved and the account limit is 10. (Console equivalent of this fix: **Configuration → Concurrency → Edit → Use unreserved account concurrency**.)

16. **Verify** the cap is gone:

    ```bash
    aws lambda get-function-concurrency --function-name "$REPORT_FN" --region "$REGION"
    ```

    > **Expected Result:** `{}` (no reserved concurrency). If it still shows `"ReservedConcurrentExecutions": 0`, re-run step 15 and check it for an error.

17. **Trigger** a fresh run rather than waiting for the schedule:

    ```bash
    RUN_ARN=$(aws stepfunctions start-execution --state-machine-arn "$SFN_ARN" \
      --region "$REGION" --query executionArn --output text)
    echo "RUN_ARN=$RUN_ARN"
    ```
<!-- source: Module_3_narrative.md §"Step Functions state machine driven by EventBridge" -->

    > **Expected Result:** `RUN_ARN=arn:aws:states:...:execution:io108-<your-id>-report-workflow:...`. If it is blank, read the error above it.

18. **Check** the run succeeded and wrote a report. Wait 30 seconds, then:

    ```bash
    aws stepfunctions describe-execution --execution-arn "$RUN_ARN" \
      --region "$REGION" --query status --output text
    date -u
    aws s3 ls "s3://$REPORTS_BUCKET/reports/" --recursive | tail -5
    ```
    <!-- source: course_outline_v3.md §"report landing in S3" -->

    > **Expected Result:** **`SUCCEEDED`**, then the time, then a listing whose last line is a new `reports/<date>T<HH-MM-SS>Z.json` within a minute or two of the `date -u` time (both UTC). If it reads `RUNNING`, wait 30 seconds and re-run; if `FAILED`, see Troubleshooting.

19. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab, wait 1–2 minutes, and click the refresh icon. When the tile turns green, note the time in your incident notes as the recovery time.

    > **Expected Result:** **Reports flowing** (`reports_flowing`) is **green**; both sink tiles are still green.

---

## Task 6: Verify the Event Fan-out

When the report pipeline failed, a CloudWatch alarm (`$FANOUT_ALARM`, on the report workflow's failed executions) fanned the incident out to every monitoring tool SYF uses: **one event, many destinations.**

```
CloudWatch Alarm (report failed) ---\
                                      >--> EventBridge rule
EventBridge heartbeat (every 2 min) -/         |
                                               v
                    Step Functions state machine -- Parallel state
                       |-- branch "newrelic"   --> SQS queue --\
                       |-- branch "solarwinds" --> SQS queue --- > forwarder Lambda
                                                               --> writes the SAME event
                                                                   to BOTH S3 sink buckets
```

The **Parallel** state sends the same input to every branch; each branch queues it on SQS; a forwarder Lambda writes it to each destination's S3 sink. A 2-minute heartbeat keeps the sinks green while healthy.

> **Note:** The two sink buckets (`$SINK_NR`, `$SINK_SW`) stand in for the real NewRelic and SolarWinds ingestion endpoints, so you can inspect the event directly.

20. **Trigger** a fan-out:

    ```bash
    aws stepfunctions start-execution --state-machine-arn "$FANOUT_SFN" \
      --input '{"source":"lab3-manual-test","incident":"report-pipeline"}' --region "$REGION"
    ```
<!-- source: Module_2_narrative.md §"hands the same event to several branches at once" -->

    > **Expected Result:** A short JSON block with an `executionArn` and a `startDate`. If you see `Invalid Arn` or `ParameterValidationError`, `$FANOUT_SFN` is blank: run steps 1 and 5 again.

21. **List** both sink buckets. Wait about 15 seconds, then:

    ```bash
    echo "== NewRelic sink ==";  aws s3 ls "s3://$SINK_NR/"  --recursive | tail -3
    echo "== SolarWinds sink =="; aws s3 ls "s3://$SINK_SW/" --recursive | tail -3
    ```

    > **Expected Result:** Each listing ends with keys like `incidents/2026/11/25/143205-a1b2c3d4.json` (date, UTC time `HHMMSS`, random suffix). The newest key in each bucket should be your event.

22. **Read** the newest object in each bucket. Replace `<key>` with the last key from each listing in step 21:

    ```bash
    aws s3 cp "s3://$SINK_NR/<key>" -
    aws s3 cp "s3://$SINK_SW/<key>" -
    ```

    > **Expected Result:** One line of JSON each. The `destination` is `newrelic` in one and `solarwinds` in the other, and **both** contain `"source": "lab3-manual-test"`. If you see `"source": "heartbeat"`, that is the 2-minute heartbeat: try the second-to-last key, or re-run step 20.

23. **Confirm** on the board. Go back to your **`io108-<your-id>-incident-board`** tab and click the refresh icon.

    > **Expected Result:** **Sink: NewRelic (fan-out)** and **Sink: SolarWinds (fan-out)** are **green**, so all three Lab 3 tiles are green.

24. **Close** the incident in your incident notes: P2, start time (step 7), root cause (reserved concurrency = 0 throttling the report Lambda), remediation (removed the reserved-concurrency cap), and recovery time (step 19).

    > **Expected Result:** Your notes hold all five items. You will use them in the Lab 5 post-incident report.

---

## Troubleshooting

### The `reports_flowing` tile stays red after the fix

**Check:** `aws lambda get-function-concurrency --function-name "$REPORT_FN" --region "$REGION"` must return `{}`. Still `0`? You may have re-run `terraform apply -var scenario=lab3`, which re-injects the fault: repeat step 15. Then confirm the newest execution is `SUCCEEDED` and S3 has a report newer than your fix.

**Fix:** If concurrency is correct but executions still fail, read the new failure cause; an application/DB error is a different problem. The probe runs once a minute, so allow 1–2 minutes and refresh.

### Step Functions execution shows no failures at all

**Check:** The schedule may not have fired since you applied `lab3`. Wait 5 minutes, or start a run manually: `aws stepfunctions start-execution --state-machine-arn "$SFN_ARN" --region "$REGION"`.

### A command prints an empty value, `Invalid Arn`, or `No outputs found`

**Fix:** Your session lost its variables (for example after a reconnect). Run `sudo su - ec2-user` if your prompt is not `ec2-user`, then run steps 1 and 5 again.

### A sink tile is red

**Check:** List the bucket for a recent object; the heartbeat writes one every 2 minutes. If a sink stays red, check the forwarder Lambda (`io108-<your-id>-fanout-forwarder`) for errors in its CloudWatch logs.

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
- You restored capacity by removing the reserved-concurrency cap and watched `reports_flowing` go green.
- You traced the **event fan-out** (CloudWatch Alarm -> EventBridge -> Step Functions Parallel -> SQS x N -> forwarder Lambda -> S3 sinks) and verified one event reaching two monitoring endpoints.

## Completion Checklist

- [ ] `lab3` applied (`Apply complete!`), app redeployed (`Deploy complete.`), all step 5 variables show values
- [ ] `reports_flowing` confirmed red; both `sink_*` tiles green
- [ ] Failed execution found; `TaskFailed` cause reads `Lambda.TooManyRequestsException`
- [ ] Throttles non-zero, Errors flat; `get-function-concurrency` showed `"ReservedConcurrentExecutions": 0`
- [ ] Concurrency cap removed (`get-function-concurrency` returns `{}`); manual run `SUCCEEDED`; fresh report in S3; `reports_flowing` green
- [ ] Fan-out triggered; `lab3-manual-test` event read from **both** sink buckets; all three Lab 3 tiles green
- [ ] Incident recorded in your incident notes (P2, start time, root cause, remediation, recovery time)

## Next Steps

In **Lab 4: Aurora Failover and Connectivity Investigation**, the database stays *up* but the application can no longer write to it — the classic "the database is fine but the app is broken" incident. You will also trace live database sessions to catch the rogue client that has been querying Aurora since day one.
