###############################################################################
# IO-108 -- lab_hosts / versions.tf
###############################################################################
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
      Component   = "lab-host"
    }
  }
}
