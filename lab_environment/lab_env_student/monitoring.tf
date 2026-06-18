###############################################################################
# IO-108 Troubleshooting -- lab_env_student / monitoring.tf
#
# The student's incident dashboard + 3 alarms. Every lab starts here:
# "look at your dashboard -- what changed?"
###############################################################################

resource "aws_cloudwatch_dashboard" "incident" {
  dashboard_name = "${local.name_prefix}-incident-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node CPU (Container Insights)"
          region = var.region
          stat   = "Average"
          period = 60
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", aws_eks_cluster.main.name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Aurora -- Connections / Replica Lag / CPU"
          region = var.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", aws_rds_cluster.main.cluster_identifier],
            ["AWS/RDS", "AuroraReplicaLag", "DBClusterIdentifier", aws_rds_cluster.main.cluster_identifier],
            ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", aws_rds_cluster.main.cluster_identifier]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lambda report-generator"
          region = var.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.report_generator.function_name],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.report_generator.function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", aws_lambda_function.report_generator.function_name],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.report_generator.function_name, { stat = "Average" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions -- Failed Executions"
          region = var.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.report_workflow.arn]
          ]
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name_prefix}-report-lambda-errors"
  alarm_description   = "IO-108 -- report-generator Lambda reported errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.report_generator.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "sfn_failed" {
  alarm_name          = "${local.name_prefix}-report-workflow-failed"
  alarm_description   = "IO-108 -- report workflow execution failed"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.report_workflow.arn
  }
}

resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  alarm_name          = "${local.name_prefix}-aurora-cpu-high"
  alarm_description   = "IO-108 -- Aurora cluster CPU above 80%"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.cluster_identifier
  }
}
