###############################################################################
# IO-108 Troubleshooting -- lab_env_student / outputs.tf
###############################################################################

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "region" {
  description = "AWS region of the stack."
  value       = var.region
}

output "student_id" {
  description = "Short student identifier prefixing every resource (and the IO108/Health metric dimension)."
  value       = var.student_id
}

output "aurora_cluster_endpoint" {
  description = "Aurora WRITER (cluster) endpoint -- the app must use this one."
  value       = aws_rds_cluster.main.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint."
  value       = aws_rds_cluster.main.reader_endpoint
}

output "aurora_master_secret_arn" {
  description = "Secrets Manager ARN of the managed Aurora master credentials."
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

output "reports_bucket" {
  description = "S3 bucket where report-generator writes JSON reports."
  value       = aws_s3_bucket.reports.bucket
}

output "sfn_state_machine_arn" {
  description = "Step Functions report workflow ARN."
  value       = aws_sfn_state_machine.report_workflow.arn
}

output "dashboard_name" {
  description = "CloudWatch incident dashboard name."
  value       = aws_cloudwatch_dashboard.incident.dashboard_name
}

output "irsa_role_arn" {
  description = "IAM role assumed by the orders-api ServiceAccount (IRSA)."
  value       = aws_iam_role.orders_api.arn
}

output "app_db_host" {
  description = "DB host the orders-api should use. Cluster (writer) endpoint when healthy; Aurora READER endpoint under scenario=lab4 (the failover break). deploy_app.sh wires this into the chart."
  value       = local.app_db_host
}

output "eks_conncheck_role_arn" {
  description = "IRSA role ARN for the in-cluster conncheck CronJob (publishes eks_pod_internet / eks_pod_dns)."
  value       = aws_iam_role.eks_health_checker.arn
}

output "network_policy_default_deny" {
  description = "Whether the chart should apply the default-deny egress NetworkPolicy (true under lab2 / capstone). Consumed by deploy_app.sh."
  value       = local.fault_pod_netpol_deny
}

output "next_step" {
  description = "What to run after apply completes."
  value       = "./deploy_app.sh ${var.student_id} ${var.region}"
}

# ---------------------------------------------------------------------------
# Scenario + fault contract (backbone)
# ---------------------------------------------------------------------------

output "scenario" {
  description = "Active incident scenario (healthy | lab1..lab5)."
  value       = var.scenario
}

output "faults" {
  description = "Per-scenario fault switches. All inert in the backbone; wired in the faults pass."
  value       = local.faults
}

# ---------------------------------------------------------------------------
# Health-check framework / red-green dashboard
# ---------------------------------------------------------------------------

output "incident_board_dashboard_name" {
  description = "CloudWatch red/green incident board dashboard name."
  value       = aws_cloudwatch_dashboard.incident_board.dashboard_name
}

output "health_checker_function_name" {
  description = "Health-checker Lambda that publishes the IO108/Health probe metrics."
  value       = aws_lambda_function.health_checker.function_name
}

output "health_checks" {
  description = "Probe id -> {lab, dashboard tile title}. Each maps to alarm io108-<id>-health-<probe>."
  value       = local.health_checks
}

output "sink_buckets" {
  description = "Simulated NewRelic / SolarWinds sink buckets (fed by the Lab 3 fan-out)."
  value       = { for k, b in aws_s3_bucket.sink : k => b.bucket }
}

# ---------------------------------------------------------------------------
# Lab 3 event fan-out
# ---------------------------------------------------------------------------

output "fanout_state_machine_arn" {
  description = "Step Functions Parallel fan-out state machine (CloudWatch alarm / heartbeat -> SQS x N -> forwarder Lambda -> sinks)."
  value       = aws_sfn_state_machine.fanout.arn
}

output "fanout_queue_urls" {
  description = "Per-destination SQS queue URLs the fan-out Parallel state writes to."
  value       = { for k, q in aws_sqs_queue.fanout : k => q.url }
}

output "fanout_forwarder_function_name" {
  description = "Forwarder Lambda that drains the fan-out queues into the S3 sinks."
  value       = aws_lambda_function.fanout_forwarder.function_name
}

output "fanout_trigger_alarm_name" {
  description = "CloudWatch alarm whose ALARM state change triggers the fan-out (report pipeline errors)."
  value       = aws_cloudwatch_metric_alarm.fanout_trigger.alarm_name
}

# ---------------------------------------------------------------------------
# Rogue through-line
# ---------------------------------------------------------------------------

output "rogue_private_ip" {
  description = "Private IP of the rogue instance -- the health-checker counts pg_stat_activity sessions from this address."
  value       = aws_instance.rogue.private_ip
}

output "rogue_instance_id" {
  description = "Rogue EC2 instance id (target of the Lab 1 hunt / containment)."
  value       = aws_instance.rogue.id
}

output "rogue_actor_role_arn" {
  description = "Discoverable rogue IAM principal (tagged Rogue=true) -- the identity Lab 1 hunts via CloudTrail/Config/Access Analyzer."
  value       = aws_iam_role.rogue_actor.arn
}
