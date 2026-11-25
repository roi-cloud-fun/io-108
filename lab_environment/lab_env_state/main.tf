###############################################################################
# IO-108 -- lab_env_state / main.tf
#
# INSTRUCTOR-RUN, ONCE per account, BEFORE any student runs Lab 0.
# Creates the shared Terraform state bucket with a random suffix (S3 names are
# global, so a fixed name collides across accounts/classes) and publishes the
# name to SSM so students look it up instead of hardcoding it.
#
# This module's own state is local: keep it until the class is torn down.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.74"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

# Fixed region: students read the parameter and bucket from here even when
# their own stack is in another region.
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Course      = "IO-108"
      Environment = "training"
      ManagedBy   = "terraform"
      Scope       = "shared"
    }
  }
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "aws_s3_bucket" "state" {
  bucket        = "io108-tfstate-${random_string.suffix.result}"
  force_destroy = true # versioned bucket: teardown must remove old state versions
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ssm_parameter" "state_bucket" {
  name  = "/io108/tfstate-bucket"
  type  = "String"
  value = aws_s3_bucket.state.id
}

output "state_bucket" {
  description = "Shared Terraform state bucket (also in SSM as /io108/tfstate-bucket)."
  value       = aws_s3_bucket.state.id
}
