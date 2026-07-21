# IO-108 — Required AWS IAM Permissions

The IO-108 lab stack touches more services than a typical "PowerUser" training policy grants.
If a student's `terraform apply` fails with `AccessDenied` / `not authorized to perform`, the
account's policy is almost certainly missing one of the services below. This was hit during
lab testing (2026-07-21): a `TerraformPowerUser`-style policy that covered
ec2/eks/rds/lambda/s3/iam/kms/logs/cloudwatch/sns/sqs was missing **`states`**, **`events`**,
and **`ssm`**, which the report pipeline and the rogue AMI lookup require.

## Student stack (`lab_env_student`) — per attendee

Each student needs, at minimum, full access to these services (Resource `*` is fine for a
throwaway training account):

```
ec2:*                 elasticloadbalancing:*   iam:*
eks:*                 rds:*                    kms:*
lambda:*              s3:*                     logs:*
cloudwatch:*          secretsmanager:*         sns:*   sqs:*
states:*              # Step Functions — the report workflow (REQUIRED, often missing)
events:*              # EventBridge — schedules + fan-out (REQUIRED, often missing)
ssm:GetParameter      # rogue.tf looks up the latest AL2023 AMI via a public SSM parameter
                      #   (ssm:* if you also want SSM Session Manager into the rogue box)
```

A `Deny` on `organizations:*`, `account:*`, `bedrock:*` is fine and does not affect the labs.

## Shared instructor stack (`lab_env_shared`) — once per account/region

Applied by the instructor, not students. Beyond the above it additionally needs:

```
cloudtrail:*          # the audit trail Lab 1's rogue hunt reads
config:*              # the AWS Config recorder + rules
```

Give the instructor/provisioning principal these (a student's policy does NOT need them).

## Ready-to-attach add-on policy

If your base training policy is missing the commonly-omitted services, attach this alongside
it (e.g. as an inline policy on the attendees group):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IO108AdditionalServices",
      "Effect": "Allow",
      "Action": [
        "states:*",
        "events:*",
        "scheduler:*",
        "ssm:*",
        "cloudtrail:*",
        "config:*"
      ],
      "Resource": "*"
    }
  ]
}
```

(`cloudtrail`/`config` are only needed by whoever runs `lab_env_shared`; students can omit them.)
