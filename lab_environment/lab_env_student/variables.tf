###############################################################################
# IO-108 Troubleshooting -- lab_env_student / variables.tf
###############################################################################

variable "student_id" {
  description = "Short student identifier (e.g. s01). Lowercase alphanumeric, 2-12 chars. Prefixes every named resource."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.student_id))
    error_message = "student_id must be lowercase alphanumeric, 2-12 characters."
  }
}

variable "region" {
  description = "AWS region for the student stack."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = <<-EOT
    Which incident scenario to materialize. "healthy" is the green baseline
    (backbone). lab1..lab5 are the per-lab fault injections wired in a LATER
    pass -- today they all plan/apply identically to "healthy" (no faults yet),
    but the toggle and its validation are in place so the contract is fixed.
    See locals.tf `faults` for the per-scenario breakage contract.
  EOT
  type        = string
  default     = "healthy"

  validation {
    condition     = contains(["healthy", "lab1", "lab2", "lab3", "lab4", "lab5"], var.scenario)
    error_message = "scenario must be one of: healthy, lab1, lab2, lab3, lab4, lab5."
  }
}

variable "rogue_instance_type" {
  description = "Instance type for the rogue EC2 instance (the security through-line)."
  type        = string
  default     = "t3.micro"
}

variable "health_check_schedule_expression" {
  description = "EventBridge schedule expression that drives the health-checker Lambda (the red/green dashboard)."
  type        = string
  default     = "rate(1 minute)"
}

variable "vpc_cidr" {
  description = "CIDR for the student VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "eks_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Instance type for the EKS managed node group."
  type        = string
  default     = "t3.medium"
}

variable "db_instance_class" {
  description = "Instance class for the Aurora writer and reader."
  type        = string
  default     = "db.t4g.medium"
}

variable "report_schedule_expression" {
  description = "EventBridge schedule expression that triggers the report workflow."
  type        = string
  default     = "rate(5 minutes)"
}

variable "fanout_heartbeat_expression" {
  description = <<-EOT
    EventBridge schedule expression for the Lab 3 fan-out heartbeat. A synthetic
    event is fanned out to the simulated NewRelic / SolarWinds sinks on this
    cadence so the sink_* probes stay GREEN while the distribution pipeline is
    healthy; a real CloudWatch alarm also triggers the same fan-out.
  EOT
  type        = string
  default     = "rate(2 minutes)"
}

variable "partner_cidr" {
  description = <<-EOT
    Simulated "partner / datacenter" destination CIDR used by the Lab 5 capstone
    network break. Under scenario=lab5 a more-specific route for this CIDR is
    pointed at the internet gateway (a blackhole from the private subnets); the
    app_path_reachable probe + the in-cluster connectivity check watch it.
    Defaults to TEST-NET-3 (RFC 5737) so it never collides with real traffic.
  EOT
  type        = string
  default     = "203.0.113.0/24"
}

variable "tags" {
  description = "Extra tags merged into every resource via provider default_tags."
  type        = map(string)
  default     = {}
}
