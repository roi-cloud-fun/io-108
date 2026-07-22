###############################################################################
# IO-108 -- lab_hosts / variables.tf
###############################################################################

variable "region" {
  description = "AWS region (must match where students deploy their stacks)."
  type        = string
  default     = "us-east-1"
}

variable "student_ids" {
  description = "One lab host is created per id here. Use the SAME ids students pass as -var student_id (e.g. [\"s01\",\"s02\",...])."
  type        = list(string)
  default     = ["s01", "s02", "s03", "s04", "s05", "s06", "s07", "s08"]
}

variable "student_regions" {
  description = "Optional per-student region for their LAB STACK (e.g. {s01=\"us-east-1\", s02=\"us-west-2\", ...}). Put each student in their own region so dashboards/Container Insights don't collide in one region. Any id not listed falls back to var.region. The lab HOST itself stays in var.region regardless -- it drives the student's region via `terraform apply -var region=...`, baked into the host's welcome note."
  type        = map(string)
  default     = {}
}

variable "instance_type" {
  description = "Lab host size. t3.small is plenty -- it only runs terraform/kubectl/helm, not the workload."
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "Root EBS size. 20 GB comfortably holds the ~700 MB AWS provider + repo + tools."
  type        = number
  default     = 20
}

variable "repo_url" {
  description = "Git repo cloned onto each host at ~/io-108."
  type        = string
  default     = "https://github.com/roi-cloud-fun/io-108.git"
}

variable "vpc_cidr" {
  description = "CIDR for the small shared VPC the lab hosts live in (independent of each student's io108 VPC)."
  type        = string
  default     = "10.150.0.0/16"
}
