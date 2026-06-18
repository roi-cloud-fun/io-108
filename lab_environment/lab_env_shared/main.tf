###############################################################################
# IO-108 Troubleshooting -- lab_env_shared / main.tf
#
# Instructor applies this ONCE per training account/region. Provides the
# change-audit layer every lab leans on:
#   - CloudTrail: multi-region trail -> dedicated S3 bucket
#   - AWS Config: recorder (all supported) -> dedicated S3 bucket + 2 rules
#
# Both are toggleable (var.enable_cloudtrail / var.enable_config) because a
# shared training account often already has a trail and Config allows only
# ONE recorder per region.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  trail_name     = "io108-trail"
  cloudtrail_arn = "arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
  trail_bucket   = "io108-cloudtrail-${local.account_id}-${var.region}"
  config_bucket  = "io108-config-${local.account_id}-${var.region}"
}

# ============================================================================
# CLOUDTRAIL
# ============================================================================

resource "aws_s3_bucket" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket        = local.trail_bucket
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    apply_server_side_encryption_by_default {
      # AWS managed aws/s3 key (no kms_master_key_id = default KMS key).
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail[0].arn
        Condition = {
          StringEquals = { "aws:SourceArn" = local.cloudtrail_arn }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${local.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.cloudtrail_arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ============================================================================
# AWS CONFIG
# ============================================================================

resource "aws_s3_bucket" "config" {
  count = var.enable_config ? 1 : 0

  bucket        = local.config_bucket
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count  = var.enable_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count  = var.enable_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.enable_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
        Condition = {
          StringEquals = { "AWS:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "AWS:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0

  name = "io108-config-recorder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "AWS:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_config ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_config ? 1 : 0
  name  = "io108-config-s3-delivery"
  role  = aws_iam_role.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config[0].arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config[0].arn
      }
    ]
  })
}

resource "aws_config_configuration_recorder" "main" {
  count = var.enable_config ? 1 : 0

  name     = "io108-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  count = var.enable_config ? 1 : 0

  name           = "io108-delivery"
  s3_bucket_name = aws_s3_bucket.config[0].bucket

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_s3_bucket_policy.config,
  ]
}

resource "aws_config_configuration_recorder_status" "main" {
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_config_config_rule" "required_tags" {
  count = var.enable_config ? 1 : 0

  name = "io108-required-tags"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({ tag1Key = "Environment" })

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "rds_public_access" {
  count = var.enable_config ? 1 : 0

  name = "io108-rds-instance-public-access-check"

  source {
    owner             = "AWS"
    source_identifier = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
