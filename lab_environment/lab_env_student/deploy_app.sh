#!/usr/bin/env bash
###############################################################################
# IO-108 -- deploy_app.sh
# Phase 2 of the student stack: deploy the orders app onto YOUR cluster.
# Run from lab_env_student/ AFTER `terraform apply` completes.
#
# Usage: ./deploy_app.sh [student_id] [region]
#   Both args optional -- everything is read from terraform outputs.
###############################################################################
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Reading terraform outputs"
CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION="${2:-$(terraform output -raw region)}"
STUDENT_ID="${1:-$(terraform output -raw student_id)}"
IRSA_ROLE_ARN=$(terraform output -raw irsa_role_arn)
SECRET_ARN=$(terraform output -raw aurora_master_secret_arn)
# Scenario-aware app DB host: cluster (writer) endpoint when healthy; Aurora
# READER endpoint under scenario=lab4 (the failover break the student diagnoses).
DB_HOST=$(terraform output -raw app_db_host)
REPORTS_BUCKET=$(terraform output -raw reports_bucket)
SCENARIO=$(terraform output -raw scenario)
CONNCHECK_ROLE_ARN=$(terraform output -raw eks_conncheck_role_arn)
NETPOL_DEFAULT_DENY=$(terraform output -raw network_policy_default_deny)

echo "    cluster:  $CLUSTER_NAME ($REGION)"
echo "    scenario: $SCENARIO"
echo "    db host:  $DB_HOST"
echo "    bucket:   $REPORTS_BUCKET"
echo "    netpol default-deny: $NETPOL_DEFAULT_DENY"

echo "==> Updating kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "==> Copying app code into the chart (canonical copy lives in app/)"
cp app/orders_api.py app/worker.py charts/orders/files/

# Lab 2 / capstone: apply the default-deny egress NetworkPolicy when the
# scenario calls for it (terraform computes network_policy_default_deny).
NETPOL_DEFAULT_DENY="${NETPOL_DEFAULT_DENY:-false}"

echo "==> Installing the orders chart"
helm upgrade --install orders charts/orders \
  --namespace orders --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$IRSA_ROLE_ARN" \
  --set env.secretArn="$SECRET_ARN" \
  --set env.dbHost="$DB_HOST" \
  --set env.dbName="orders" \
  --set env.reportsBucket="$REPORTS_BUCKET" \
  --set connCheck.roleArn="$CONNCHECK_ROLE_ARN" \
  --set connCheck.studentId="$STUDENT_ID" \
  --set connCheck.region="$REGION" \
  --set networkPolicy.defaultDeny="$NETPOL_DEFAULT_DENY"

echo "==> Waiting for orders-api rollout (pip install at startup takes a minute)"
# Under a fault scenario the app is MEANT to be broken (lab2: pods Pending for
# lack of capacity; lab1: IRSA AccessDenied so /health 503s), so a failed rollout
# is expected -- warn and continue instead of aborting the whole deploy.
if ! kubectl -n orders rollout status deploy/orders-api --timeout=300s; then
  echo "    WARNING: orders-api is not Ready. For scenario='$SCENARIO' this may be"
  echo "             EXPECTED (the injected fault). Open the incident board and diagnose."
fi

if [ "$SCENARIO" = "healthy" ]; then
  echo "==> Smoke test: GET /health from inside the cluster"
  kubectl -n orders run curl-test --rm -i --restart=Never \
    --image=public.ecr.aws/docker/library/python:3.12-slim -- \
    python -c "import urllib.request; print(urllib.request.urlopen('http://orders-api:8080/health', timeout=10).read().decode())"
fi

echo ""
echo "Deploy complete. Next steps:"
echo "  1. ./verify.sh                 # full health verification (Lab 0)"
echo "  2. Open your CloudWatch dashboard: $(terraform output -raw dashboard_name)"
echo "  3. Reports land in s3://$REPORTS_BUCKET/reports/ within one schedule period."
