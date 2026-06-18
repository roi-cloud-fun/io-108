# IO-108 — Troubleshooting and Incident Simulation

Monorepo for ROI Training's IO-108 course. **Contains everything to stand up and run the labs end-to-end:** the per-student Terraform environment, the step-by-step lab guides, and the shared instructor infra.

The course is built on **one connected application, five incidents**. Each of ~8 students deploys their own full stack (prefix `io108-<student_id>-` on every named resource), then spends the day diagnosing and fixing injected incidents against it. A single `var.scenario` switches the stack between a healthy baseline and the five fault states.

## What's where

```
io-108/
├── lab_environment/
│   ├── lab_env_student/             Per-student stack — one `terraform apply` then `./deploy_app.sh`
│   │   ├── eks.tf  aurora.tf  reporting.tf  monitoring.tf  network.tf …
│   │   ├── faults.tf                The var.scenario fault toggle (healthy / lab1 … lab5)
│   │   ├── healthcheck.tf  fanout.tf  rogue.tf  *_tracing.tf  *_diagnostics.tf
│   │   ├── app/                     Flask orders-api, worker, Lambda handlers + committed lambda_build/
│   │   ├── charts/orders/           Helm chart (api, worker, NetworkPolicies, conncheck CronJob)
│   │   ├── deploy_app.sh            kubeconfig + helm install + smoke test
│   │   └── verify.sh                Lab 0 PASS/FAIL health check (red/green board source)
│   ├── lab_env_shared/              Instructor, ONCE per account/region: CloudTrail + AWS Config
│   └── incidents/                   Break-script placeholder (faults are injected via var.scenario)
│
├── lab_0/README.md   Deploy Your Incident Lab Stack (baseline + red/green board)
├── lab_1/README.md   IAM Access Denial Investigation and Rogue Hunt
├── lab_2/README.md   EKS Pod Failure Investigation
├── lab_3/README.md   Lambda and Step Functions Performance Incident (+ event fan-out)
├── lab_4/README.md   Aurora Failover and Connectivity Investigation (+ rogue query tracing)
└── lab_5/README.md   Multi-Layered Incident Simulation — Capstone
```

## The application

```
EKS cluster (per student, 2-node managed group)
  └─ orders-api  (Flask via Helm, IRSA role) ──→ Aurora PostgreSQL
  └─ orders-worker (traffic generator)           (writer + reader, cluster endpoint)
EventBridge (rate 5 min) ──→ Step Functions ──→ Lambda "report-generator"
                                                  ├─ queries Aurora
                                                  └─ writes report → S3 bucket
CloudWatch: Container Insights, alarms, red/green incident dashboard
CloudTrail + AWS Config (shared, once per account): change audit for every lab
A "rogue" instance queries Aurora alongside the legit app — the security through-line (Labs 1 & 4).
```

## How students run it

```bash
cd lab_environment/lab_env_student
cp terraform.tfvars.example terraform.tfvars   # set student_id (e.g. s01)
terraform init
terraform apply -var student_id=s01            # scenario defaults to "healthy"  (~15-20 min; EKS is the long pole)
./deploy_app.sh                                 # kubeconfig + helm install + smoke test
./verify.sh                                     # Lab 0: PASS/FAIL on every component (your red/green board)
```

Then, per the lab guides, switch scenarios to break and fix:

```bash
terraform apply -var student_id=s01 -var scenario=lab1   # inject the lab's fault
# ...diagnose with CloudWatch / CloudTrail / kubectl / psql, then fix in Terraform or kubectl...
terraform apply -var student_id=s01 -var scenario=healthy # reset / confirm fix
```

> **Run from a normal local clone or CloudShell — NOT a Google Drive / OneDrive synced folder.** The Lambda zips are packaged by `archive_file`, which hashes the vendored `app/lambda_build/` deps every plan; on a cloud-sync filesystem that is slow, and a sync client touching `.tfstate` mid-apply can corrupt state.

## Notes

- `student_id` is lowercase alphanumeric, 2-12 chars (s01 … s08). It prefixes every named resource so 8 students share one account.
- The five fault scenarios are toggled by `var.scenario` (`faults.tf`). The `incidents/` directory is a placeholder for optional break-script equivalents.
- `lab_env_shared/` is applied **once per account/region** by the instructor (CloudTrail + Config), not per student.
- The committed `app/lambda_build/` is the vendored dependency set so students never run `pip`; `archive_file` just zips it deterministically. The generated `*.zip` files are gitignored.

## Status

The `lab_env_student` and `lab_env_shared` modules pass `terraform validate`, and the student stack was **deployed end-to-end against a real account 2026-06-15** (58 resources, apply ~15 min, all `verify.sh` checks PASS including the EventBridge → Step Functions → Lambda → Aurora → S3 report pipeline). The five incident scenarios are scheduled for live end-to-end testing.
