###############################################################################
# IO-108 Troubleshooting -- lab_env_shared / versions.tf
#
# Account/region-level audit plumbing: CloudTrail + AWS Config.
# Applied ONCE per training account/region by the instructor.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Course      = "IO-108"
      Environment = "training"
      ManagedBy   = "terraform"
      Scope       = "shared"
    }
  }
}
