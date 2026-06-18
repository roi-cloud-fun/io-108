#!/usr/bin/env bash
###############################################################################
# IO-108 -- verify.sh
# Lab 0 health verification: prints PASS/FAIL for every component of the
# stack. Run from lab_env_student/ after ./deploy_app.sh.
###############################################################################
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

REGION=$(terraform output -raw region)
CLUSTER_NAME=$(terraform output -raw cluster_name)
DB_HOST=$(terraform output -raw aurora_cluster_endpoint)
DB_CLUSTER_ID="${DB_HOST%%.*}"
SFN_ARN=$(terraform output -raw sfn_state_machine_arn)
REPORTS_BUCKET=$(terraform output -raw reports_bucket)
DASHBOARD=$(terraform output -raw dashboard_name)

# 1. Nodes Ready
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready"' | wc -l)
TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [ "$TOTAL" -ge 2 ] && [ "$NOT_READY" -eq 0 ]; then
  pass "all $TOTAL EKS nodes Ready"
else
  fail "EKS nodes -- $NOT_READY of $TOTAL not Ready (kubectl get nodes)"
fi

# 2. Orders pods Running
# NOTE: ignore Completed/Succeeded pods -- the orders-conncheck CronJob spawns
# short-lived Job pods that finish (Completed) every cycle; those are healthy,
# not failures. Only long-running pods (orders-api, orders-worker) must be
# Running. A genuinely broken pod (Pending/CrashLoopBackOff/ImagePullBackOff/
# OOMKilled -- e.g. scenario=lab2) still counts as not-Running and FAILs.
RUNNING=$(kubectl -n orders get pods --no-headers 2>/dev/null | awk '$3 == "Running"' | wc -l)
NOT_RUNNING=$(kubectl -n orders get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" && $3 != "Succeeded"' | wc -l)
if [ "$RUNNING" -ge 3 ] && [ "$NOT_RUNNING" -eq 0 ]; then
  pass "orders pods healthy ($RUNNING Running; Completed conncheck Job pods ignored)"
else
  fail "orders pods -- $NOT_RUNNING in a bad state (kubectl -n orders get pods)"
fi

# 3. /health returns ok (in-cluster probe)
HEALTH=$(kubectl -n orders run "verify-health-$$" --rm -i --restart=Never \
  --image=public.ecr.aws/docker/library/python:3.12-slim --quiet -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://orders-api:8080/health', timeout=10).read().decode())" 2>/dev/null)
if echo "$HEALTH" | grep -q '"status": *"ok"'; then
  pass "orders-api /health reports ok (database connected)"
else
  fail "orders-api /health -- got: ${HEALTH:-no response}"
fi

# 4. Aurora cluster available
DB_STATUS=$(aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER_ID" \
  --region "$REGION" --query 'DBClusters[0].Status' --output text 2>/dev/null)
if [ "$DB_STATUS" = "available" ]; then
  pass "Aurora cluster $DB_CLUSTER_ID is available"
else
  fail "Aurora cluster $DB_CLUSTER_ID status: ${DB_STATUS:-unknown}"
fi

# 5. Latest Step Functions execution succeeded
LATEST_STATUS=$(aws stepfunctions list-executions --state-machine-arn "$SFN_ARN" \
  --region "$REGION" --max-results 1 --query 'executions[0].status' --output text 2>/dev/null)
if [ "$LATEST_STATUS" = "SUCCEEDED" ] || [ "$LATEST_STATUS" = "RUNNING" ]; then
  pass "latest report workflow execution: $LATEST_STATUS"
elif [ "$LATEST_STATUS" = "None" ] || [ -z "$LATEST_STATUS" ]; then
  fail "report workflow has no executions yet -- wait one schedule period (default 5 min) and re-run"
else
  fail "latest report workflow execution: $LATEST_STATUS (check Step Functions console)"
fi

# 6. Report object exists in S3
REPORT_KEY=$(aws s3api list-objects-v2 --bucket "$REPORTS_BUCKET" --prefix "reports/" \
  --max-items 1 --region "$REGION" --query 'Contents[0].Key' --output text 2>/dev/null)
if [ -n "$REPORT_KEY" ] && [ "$REPORT_KEY" != "None" ]; then
  pass "report found: s3://$REPORTS_BUCKET/$REPORT_KEY"
else
  fail "no report in s3://$REPORTS_BUCKET/reports/ yet -- the first one lands within one schedule period (default 5 min)"
fi

# 7. Dashboard exists
if aws cloudwatch get-dashboard --dashboard-name "$DASHBOARD" --region "$REGION" >/dev/null 2>&1; then
  pass "CloudWatch dashboard $DASHBOARD exists"
else
  fail "CloudWatch dashboard $DASHBOARD not found"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED -- your stack is healthy. Capture this baseline for Lab 0."
else
  echo "$FAILURES CHECK(S) FAILED -- investigate before starting the incident labs."
  exit 1
fi
