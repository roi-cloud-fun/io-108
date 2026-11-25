###############################################################################
# IO-108 Troubleshooting -- lab_env_student / versions.tf
#
# Per-student healthy stack: VPC + EKS + Aurora + reporting pipeline +
# monitoring. One `terraform apply` per student.
#
# DELIBERATE: no kubernetes/helm providers. The in-cluster app is deployed
# by ./deploy_app.sh (kubeconfig + helm) AFTER apply -- this avoids the
# provider-credential chicken-and-egg and the apply-time races IO-107 hit.
# tls is required only to read the EKS OIDC issuer thumbprint for IRSA.
###############################################################################

terraform {
  required_version = ">= 1.10"

  # Central per-student remote state. The bucket (random suffix) is created by
  # lab_env_state and published to SSM; bucket + key are passed at init:
  #   STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 \
  #     --name /io108/tfstate-bucket --query Parameter.Value --output text)
  #   terraform init -backend-config="bucket=$STATE_BUCKET" \
  #     -backend-config="key=io108/<student_id>/terraform.tfstate"
  backend "s3" {
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.74"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(local.common_tags, var.tags)
  }
}
