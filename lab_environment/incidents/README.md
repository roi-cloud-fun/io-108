# IO-108 Incident Scripts — placeholder

Incident break scripts (`incident-1.sh` … `incident-5.sh`) land here **after
client confirmation** of the five lab scenarios:

1. IAM access denial (IRSA policy break)
2. EKS pod failure (ImagePullBackOff + OOMKilled)
3. Lambda & Step Functions performance (reserved concurrency + SG block)
4. Aurora failover & endpoint misconfiguration
5. Multi-layered capstone (SG + IAM drift + red herring)

Each script will break ONE student stack reproducibly; recovery is a targeted
`terraform apply` from `../lab_env_student/`. Do not add scripts here until
the scenarios are confirmed.
