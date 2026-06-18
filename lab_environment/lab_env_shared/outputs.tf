###############################################################################
# IO-108 Troubleshooting -- lab_env_shared / outputs.tf
###############################################################################

output "cloudtrail_arn" {
  description = "ARN of the multi-region trail (null if enable_cloudtrail = false)."
  value       = var.enable_cloudtrail ? aws_cloudtrail.main[0].arn : null
}

output "cloudtrail_bucket" {
  description = "CloudTrail log bucket name (null if enable_cloudtrail = false)."
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail[0].bucket : null
}

output "config_recorder_name" {
  description = "AWS Config recorder name (null if enable_config = false)."
  value       = var.enable_config ? aws_config_configuration_recorder.main[0].name : null
}

output "config_bucket" {
  description = "AWS Config delivery bucket name (null if enable_config = false)."
  value       = var.enable_config ? aws_s3_bucket.config[0].bucket : null
}
