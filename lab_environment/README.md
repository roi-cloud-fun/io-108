# IO-108 Lab Environment — "One App, Five Incidents"

Each of 8 students deploys their own full stack (prefix `io108-<student_id>-` on
every named resource). The incident labs later break this stack in controlled
ways; this directory builds only the **healthy** environment.

```
EKS cluster (per student, 2-node managed group)
  └─ orders-api  (Flask via Helm, IRSA role) ──→ Aurora PostgreSQL
  └─ orders-worker (traffic generator)           (writer + reader, cluster endpoint)
EventBridge (rate 5 min) ──→ Step Functions ──→ Lambda "report-generator"
                                                  ├─ queries Aurora
                                                  └─ writes report → S3 bucket
CloudWatch: Container Insights, 3 alarms, incident dashboard
CloudTrail + AWS Config (shared, once per account): change audit for every lab
```

## Layout

| Path | Who runs it | What |
|------|-------------|------|
| `lab_env_shared/` | Instructor, ONCE per account/region | CloudTrail trail + AWS Config recorder/rules |
| `lab_env_student/` | Each student | VPC, EKS, Aurora, Lambda/SFN reporting, monitoring |
| `lab_env_student/deploy_app.sh` | Each student, after apply | kubeconfig + helm install + smoke test |
| `lab_env_student/verify.sh` | Each student (Lab 0) | PASS/FAIL health verification |
| `incidents/` | Later | Incident break scripts land here after client confirmation |

## Prerequisites

- Terraform >= 1.10
- AWS CLI v2 (authenticated to the training account)
- kubectl, helm, jq
- AWS CloudShell works for all of the above (terraform via download).

> **Run from a normal local clone or CloudShell — NOT a Google Drive / OneDrive
> synced folder.** The `report_generator` Lambda is packaged by `archive_file`,
> which walks and hashes the vendored `app/lambda_build/` deps on every
> plan/apply. On Google Drive File Stream that step takes ~90s (each file is
> fetched on access); on local disk it is ~0s. Worse, a cloud-sync client
> touching `.tfstate` mid-apply can corrupt state. Clone to local disk first.

> **Verified end-to-end 2026-06-15** against a real account (58 resources,
> apply ~15 min, all `verify.sh` checks PASS including the EventBridge → Step
> Functions → Lambda → Aurora → S3 report pipeline).

## Instructor: shared audit layer (once)

```bash
cd lab_env_shared
terraform init
terraform apply
```

**If the training account already has a CloudTrail trail**, set
`-var enable_cloudtrail=false`. **If it already has a Config recorder**
(Config allows only ONE recorder per region), set `-var enable_config=false`.
Both default to `true`.

## Student flow

```bash
cd lab_env_student
terraform init
terraform apply -var student_id=s01        # ~20-25 min (EKS + Aurora dominate)
./deploy_app.sh                             # kubeconfig + helm + smoke test
./verify.sh                                 # Lab 0: PASS/FAIL on every component
```

Notes:

- `student_id` is lowercase alphanumeric, 2-12 chars (s01 … s08).
- The Lambda package directory `lab_env_student/app/lambda_build/` is
  **committed** (pg8000 + deps vendored, plus `report_generator.py`). Do not
  delete it — `terraform apply` zips it as-is; students never run pip.
- App code lives ONCE in `lab_env_student/app/`. `deploy_app.sh` copies
  `orders_api.py` and `worker.py` into `charts/orders/files/` before
  `helm upgrade --install` so the chart's ConfigMap can embed them.
- The first report appears in S3 within one schedule period (default 5 min)
  after deploy — `verify.sh` says so if you check too early.

## Teardown (order matters)

```bash
cd lab_env_student
helm uninstall orders -n orders             # FIRST: releases in-cluster resources
terraform destroy -var student_id=s01
```

Uninstall the Helm release before `terraform destroy`. Anything the cluster
created on its own (ENIs for pods/load balancers) can otherwise block subnet
and VPC deletion with DependencyViolation. If destroy hangs on subnets, look
for leftover ENIs in the VPC.

> **Expect destroy to take ~25-30 min, and to sit for 10-20 min on the Lambda
> security group + a private subnet.** This is normal, not a hang: the in-VPC
> `report_generator` Lambda leaves AWS-managed hyperplane ENIs that AWS only
> releases several minutes after the function is deleted; they hold the SG and
> subnet until then. Terraform retries automatically and completes cleanly
> (verified 2026-06-15: 58 destroyed, 0 errors). Don't Ctrl-C it.

## Cost (us-east-1 list prices, approximate)

Per student per day (~8 hr running, rounded):

| Item | Rate | ~Day |
|------|------|------|
| EKS control plane | $0.10/hr | $0.80 |
| 2 × t3.medium nodes | $0.0416/hr each | $0.67 |
| 2 × db.t4g.medium Aurora | $0.073/hr each | $1.17 |
| 1 × NAT gateway | $0.045/hr + data | $0.40 |
| Lambda / SFN / S3 / CloudWatch | trivial at lab volume | <$0.20 |
| **Per student** | | **~$3.25/day** |
| **8 students** | | **~$26/day** |

If stacks run 24 hr instead of class hours, triple those numbers. Destroy
stacks at end of day; rebuild is one `terraform apply` + `./deploy_app.sh`.

## Incidents

Incident break scripts (`incident-N.sh`) come LATER — see
`incidents/README.md`. Build and verify the healthy baseline first.
