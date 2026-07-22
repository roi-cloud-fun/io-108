# IO-108 Lab Hosts (instructor-run, optional)

Provisions one pre-tooled EC2 "lab host" per student so nobody has to install
terraform/kubectl/helm in AWS CloudShell (whose 1 GB `$HOME` is too small for the
Terraform AWS provider + repo). Each host has terraform, kubectl, helm, AWS CLI v2, git,
jq preinstalled and the repo cloned to `~/io-108`, and is reached over **SSM Session
Manager** (no SSH keys — safe on a shared account).

## Why it "just works" with EKS

The student stack's EKS access entry follows the **caller identity**
(`lab_env_student/eks.tf` → `apply_host_principal_arn`). When a student runs
`terraform apply` **from their host**, that host's role becomes the cluster admin
automatically, so `kubectl` works with no extra config. **Students must run everything —
including the first `terraform apply` — from the host, not CloudShell**, or the access
entry points at the wrong principal.

## Use (instructor, once per account)

```bash
cd lab_environment/lab_hosts
terraform init
terraform apply -var 'student_ids=["s01","s02","s03","s04","s05","s06","s07","s08"]'
terraform output connect_hint     # SSM start-session command per student
```

Give each student their `student_id` and instance (or let them pick their
`io108-<id>-lab-host` in the Systems Manager → Session Manager console). Then on the host:

```bash
cat ~/README-LAB-HOST.txt          # the exact commands for their id
cd ~/io-108/lab_environment/lab_env_student
terraform init && terraform apply -var student_id=<id>
./deploy_app.sh && ./verify.sh
```

## Notes

- Cost: ~t3.small + 20 GB per host ≈ **$1/host/48h** (SSM is free).
- Independent of each student's `io108-<id>` VPC — the hosts live in their own small VPC and
  reach everything over public AWS APIs (the EKS endpoint is public).
- Tear down with `terraform destroy` in this dir (separate state from `lab_env_student`).
- Requires the running principal to have EC2/IAM/VPC/SSM permissions.
