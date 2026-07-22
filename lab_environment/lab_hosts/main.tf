###############################################################################
# IO-108 -- lab_hosts / main.tf
#
# INSTRUCTOR-RUN, ONCE per account. Provisions one pre-tooled EC2 "lab host" per
# student so nobody has to fight AWS CloudShell's 1 GB limit installing
# terraform/kubectl/helm. Each host:
#   * is named io108-<id>-lab-host and carries its own role io108-<id>-lab-host-role
#   * has terraform, kubectl, helm, aws cli v2, git, jq preinstalled + the repo cloned
#   * is reached over SSM Session Manager (no SSH keys -- important on a shared account)
#
# Because the student stack's EKS access entry follows the caller identity
# (lab_env_student/eks.tf apply_host_principal_arn), running `terraform apply`
# FROM the host makes that host's role a cluster admin automatically -> kubectl
# works with no extra wiring. Students must run EVERYTHING (including the first
# apply) from their host, not from CloudShell, or the access entry points at the
# wrong principal.
###############################################################################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# Small shared VPC for the hosts (independent of each student's io108 VPC).
# One public subnet + IGW; SSM works over the instance's outbound path.
# ---------------------------------------------------------------------------
resource "aws_vpc" "hosts" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "io108-lab-hosts-vpc" }
}

resource "aws_internet_gateway" "hosts" {
  vpc_id = aws_vpc.hosts.id
  tags   = { Name = "io108-lab-hosts-igw" }
}

resource "aws_subnet" "hosts" {
  vpc_id                  = aws_vpc.hosts.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  map_public_ip_on_launch = true
  tags                    = { Name = "io108-lab-hosts-public" }
}

resource "aws_route_table" "hosts" {
  vpc_id = aws_vpc.hosts.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hosts.id
  }
  tags = { Name = "io108-lab-hosts-rt" }
}

resource "aws_route_table_association" "hosts" {
  subnet_id      = aws_subnet.hosts.id
  route_table_id = aws_route_table.hosts.id
}

resource "aws_security_group" "hosts" {
  name        = "io108-lab-hosts-sg"
  description = "IO-108 lab hosts -- egress only (SSM is outbound; no inbound needed)"
  vpc_id      = aws_vpc.hosts.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "io108-lab-hosts-sg" }
}

# ---------------------------------------------------------------------------
# Per-student IAM role (the identity that runs the labs from the host).
# Broad training permissions -- Resource "*" on a disposable shared account.
# The Deny mirrors the account's own guardrails.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lab_host_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lab_host" {
  for_each           = toset(var.student_ids)
  name               = "io108-${each.key}-lab-host-role"
  assume_role_policy = data.aws_iam_policy_document.lab_host_assume.json
  tags               = { Name = "io108-${each.key}-lab-host-role", Student = each.key }
}

resource "aws_iam_role_policy_attachment" "lab_host_ssm" {
  for_each   = aws_iam_role.lab_host
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "lab_host_perms" {
  for_each = aws_iam_role.lab_host
  name     = "io108-${each.key}-lab-host-perms"
  role     = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunTheLabs"
        Effect = "Allow"
        Action = [
          "ec2:*", "eks:*", "rds:*", "lambda:*", "s3:*", "iam:*", "kms:*",
          "logs:*", "cloudwatch:*", "sns:*", "sqs:*", "secretsmanager:*",
          "states:*", "events:*", "scheduler:*", "ssm:*", "cloudtrail:*",
          "config:*", "elasticloadbalancing:*", "autoscaling:*", "dynamodb:*",
          "ec2-instance-connect:*", "sts:*"
        ]
        Resource = "*"
      },
      {
        Sid      = "GuardrailsDeny"
        Effect   = "Deny"
        Action   = ["organizations:*", "account:*", "bedrock:*"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "lab_host" {
  for_each = aws_iam_role.lab_host
  name     = "io108-${each.key}-lab-host"
  role     = each.value.name
}

# ---------------------------------------------------------------------------
# Per-student EC2 lab host.
# ---------------------------------------------------------------------------
resource "aws_instance" "lab_host" {
  for_each = toset(var.student_ids)

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.hosts.id
  vpc_security_group_ids = [aws_security_group.hosts.id]
  iam_instance_profile   = aws_iam_instance_profile.lab_host[each.key].name

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  # Tools + repo. No bash ${} used -- $(...) is command substitution (Terraform
  # only interpolates ${...}); ${each.key} / ${var.repo_url} are Terraform.
  user_data = <<-EOT
    #!/bin/bash
    set -xe
    dnf install -y git jq unzip tar

    # AWS CLI v2 (AL2023 does not ship it)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update

    # Terraform (>= 1.10 required by the stack's versions.tf + S3 backend)
    curl -fsSL https://releases.hashicorp.com/terraform/1.11.2/terraform_1.11.2_linux_amd64.zip -o /tmp/tf.zip
    unzip -q -o /tmp/tf.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/terraform

    # kubectl (latest stable -- version-skew tolerant with EKS 1.35)
    curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
    chmod +x /usr/local/bin/kubectl

    # Helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # Repo for this student
    sudo -u ec2-user git clone ${var.repo_url} /home/ec2-user/io-108

    cat > /home/ec2-user/README-LAB-HOST.txt <<'HINT'
    IO-108 lab host for student ${each.key}.  Your assigned region: ${lookup(var.student_regions, each.key, var.region)}

    Run EVERYTHING from here. Your stack is already deployed (Lab 0 done); connect to your
    remote state and run the incident labs:

      cd ~/io-108/lab_environment/lab_env_student
      cp terraform.tfvars.example terraform.tfvars     # set student_id=${each.key}, region=${lookup(var.student_regions, each.key, var.region)}
      terraform init -backend-config="key=io108/${each.key}/terraform.tfstate"
      terraform plan  -var scenario=lab1               # then: terraform apply -var scenario=lab1
      ./deploy_app.sh                                  # for labs that need it (2/4/5)

    This host and your stack are BOTH in ${lookup(var.student_regions, each.key, var.region)};
    AWS_DEFAULT_REGION is already set to it, so no --region needed.
    Board: CloudWatch > Dashboards > io108-${each.key}-incident-board
    HINT
    chown -R ec2-user:ec2-user /home/ec2-user/io-108 /home/ec2-user/README-LAB-HOST.txt

    # Default the student's region so aws / kubectl "just work" (host IS in this region).
    echo "export AWS_DEFAULT_REGION=${lookup(var.student_regions, each.key, var.region)}" >> /home/ec2-user/.bashrc

    # Ready marker (SSM can grep this to confirm bootstrap finished)
    echo "io108 lab host ready for ${each.key}" > /home/ec2-user/BOOTSTRAP_DONE
    chown ec2-user:ec2-user /home/ec2-user/BOOTSTRAP_DONE
  EOT

  user_data_replace_on_change = true

  tags = {
    Name    = "io108-${each.key}-lab-host"
    Student = each.key
  }
}
