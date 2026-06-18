###############################################################################
# IO-108 Troubleshooting -- lab_env_shared / variables.tf
###############################################################################

variable "region" {
  description = "AWS region for the shared audit infrastructure."
  type        = string
  default     = "us-east-1"
}

variable "enable_cloudtrail" {
  description = "Create the multi-region CloudTrail trail + log bucket. Set false if the training account already has a trail."
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "Create the AWS Config recorder, delivery channel, and managed rules. Set false if the account already has a Config recorder (one recorder per region)."
  type        = bool
  default     = true
}
