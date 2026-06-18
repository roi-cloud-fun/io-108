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

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
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
