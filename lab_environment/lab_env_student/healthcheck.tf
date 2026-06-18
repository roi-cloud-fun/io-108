###############################################################################
# IO-108 Troubleshooting -- lab_env_student / healthcheck.tf
#
# THE RED/GREEN HEALTH DASHBOARD FRAMEWORK.
#
#   EventBridge (rate 1 min) -> health-checker Lambda (in-VPC, vendored pg8000)
#     -> runs N probes -> publishes 1 (healthy) / 0 (broken) per probe to the
#        IO108/Health custom-metric namespace, dimension Student=<id>
#     -> one CloudWatch alarm per probe (ALARM when metric < 1)
#     -> one alarm-status tile per probe on the io108-<id>-incident-board
#        dashboard, grouped by lab. Green = OK, red = ALARM.
#
# Faults (next pass) flip probes to 0 -> tiles go red; the student's fix flips
# them back to 1 -> green. "Here are N broken things -- fix them, watch them go
# green." The rogue through-line means aurora_no_rogue / rogue_contained are
# red from the first apply.
#
# Packaging mirrors reporting.tf: app/lambda_build/ holds vendored pg8000 +
# the handler (health_checker.py copied in, committed); archive_file zips it.
###############################################################################

# ----------------------------------------------------------------------------
# Probe registry  -- keep in lock-step with PROBES in app/health_checker.py.
# Drives the alarms (for_each) and the dashboard tiles (grouped by lab).
# ----------------------------------------------------------------------------
locals {
  health_checks = {
    # Lab 1 -- IAM access denial + rogue hunt
    orders_api_db_access = { lab = "lab1", title = "orders-api DB access (IRSA)" }
    rogue_contained      = { lab = "lab1", title = "Rogue contained" }
    # Lab 2 -- EKS pod failure + connectivity (eks_pod_* published by the CronJob)
    eks_pods_schedulable = { lab = "lab2", title = "EKS pods schedulable" }
    eks_pod_internet     = { lab = "lab2", title = "Pod -> internet" }
    eks_pod_dns          = { lab = "lab2", title = "Pod -> DNS" }
    # Lab 3 -- Lambda/SFN performance + event fan-out
    reports_flowing = { lab = "lab3", title = "Reports flowing" }
    sink_newrelic   = { lab = "lab3", title = "Sink: NewRelic (fan-out)" }
    sink_solarwinds = { lab = "lab3", title = "Sink: SolarWinds (fan-out)" }
    # Lab 4 -- Aurora failover + connectivity
    aurora_reachable = { lab = "lab4", title = "Aurora reachable" }
    aurora_writable  = { lab = "lab4", title = "Aurora writable (writer endpoint)" }
    aurora_no_rogue  = { lab = "lab4", title = "Aurora: no rogue sessions" }
    # Lab 5 -- capstone / network
    app_path_reachable = { lab = "lab5", title = "Partner path reachable" }
    tgw_or_network_ok  = { lab = "lab5", title = "Network path OK" }
  }
}

# ----------------------------------------------------------------------------
# Simulated monitoring sinks  -- "NewRelic" and "SolarWinds" destinations.
#
# The Lab 3 event fan-out (CloudWatch Alarm -> EventBridge -> SFN Parallel ->
# SQS x N -> forwarder Lambda, built in fanout.tf) lands events here. A heartbeat
# rule fans a synthetic event every couple of minutes so these tiles are GREEN
# while the distribution pipeline is healthy; a real report-pipeline alarm fans
# the same way. The buckets are listed by the sink_* probes for a fresh object.
# ----------------------------------------------------------------------------
locals {
  sink_buckets = {
    newrelic   = "${local.name_prefix}-sink-newrelic-${random_string.bucket_suffix.result}"
    solarwinds = "${local.name_prefix}-sink-solarwinds-${random_string.bucket_suffix.result}"
  }
}

resource "aws_s3_bucket" "sink" {
  for_each      = local.sink_buckets
  bucket        = each.value
  force_destroy = true
  tags          = { Name = each.value }
}

resource "aws_s3_bucket_versioning" "sink" {
  for_each = aws_s3_bucket.sink
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sink" {
  for_each = aws_s3_bucket.sink
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "sink" {
  for_each = aws_s3_bucket.sink
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------------------------------------------------------
# Health-checker Lambda
# ----------------------------------------------------------------------------

resource "aws_security_group" "health_checker" {
  name        = "${local.name_prefix}-health-checker-sg"
  description = "IO-108 health-checker Lambda -- egress only (Aurora 5432 + AWS APIs via NAT)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-health-checker-sg" }
}

# Let the checker reach Aurora on 5432. Standalone rule so aurora.tf is untouched.
resource "aws_vpc_security_group_ingress_rule" "aurora_from_health_checker" {
  security_group_id            = aws_security_group.aurora.id
  referenced_security_group_id = aws_security_group.health_checker.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from the health-checker Lambda"

  tags = { Name = "${local.name_prefix}-aurora-from-health-checker" }
}

resource "aws_iam_role" "health_checker" {
  name = "${local.name_prefix}-health-checker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Logs + ENI create/delete for in-VPC execution.
resource "aws_iam_role_policy_attachment" "health_checker_vpc" {
  role       = aws_iam_role.health_checker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "health_checker" {
  name = "${local.name_prefix}-health-checker-inline"
  role = aws_iam_role.health_checker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishHealthMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid      = "ReadAuroraMasterSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_rds_cluster.main.master_user_secret[0].secret_arn
      },
      {
        Sid    = "ListProbeBuckets"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = concat(
          [aws_s3_bucket.reports.arn],
          [for b in aws_s3_bucket.sink : b.arn]
        )
      },
      {
        Sid    = "ReadProbeObjects"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = concat(
          ["${aws_s3_bucket.reports.arn}/*"],
          [for b in aws_s3_bucket.sink : "${b.arn}/*"]
        )
      },
      {
        Sid    = "DescribeForNetworkAndRogueProbes"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeNatGateways",
          "ec2:DescribeRouteTables",
          "rds:DescribeDBClusters",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        # orders_api_db_access probe: simulate the orders-api IRSA role rather
        # than assume it. SimulatePrincipalPolicy needs no resource scoping.
        Sid      = "SimulateOrdersApiAccess"
        Effect   = "Allow"
        Action   = ["iam:SimulatePrincipalPolicy"]
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "health_checker" {
  type        = "zip"
  source_dir  = "${path.module}/app/lambda_build"
  output_path = "${path.module}/health_checker.zip"

  # Same host-pollution backstop as reporting.tf's archive.
  excludes = [
    "desktop.ini",
    "__pycache__",
  ]
}

resource "aws_lambda_function" "health_checker" {
  function_name = "${local.name_prefix}-health-checker"
  role          = aws_iam_role.health_checker.arn
  runtime       = "python3.12"
  handler       = "health_checker.handler"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.health_checker.output_path
  source_code_hash = data.archive_file.health_checker.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.health_checker.id]
  }

  environment {
    variables = {
      STUDENT_ID             = var.student_id
      METRIC_NAMESPACE       = "IO108/Health"
      SECRET_ARN             = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_CLUSTER_ENDPOINT    = aws_rds_cluster.main.endpoint # CLUSTER endpoint, never an instance endpoint
      DB_NAME                = aws_rds_cluster.main.database_name
      ROGUE_IP               = aws_instance.rogue.private_ip
      ROGUE_INSTANCE_ID      = aws_instance.rogue.id
      ROGUE_SG_ID            = aws_security_group.rogue.id
      REPORTS_BUCKET         = aws_s3_bucket.reports.bucket
      SINK_NEWRELIC_BUCKET   = aws_s3_bucket.sink["newrelic"].bucket
      SINK_SOLARWINDS_BUCKET = aws_s3_bucket.sink["solarwinds"].bucket
      VPC_ID                 = aws_vpc.main.id
      FRESH_SECONDS          = "600"
      # Faults pass additions:
      ORDERS_API_ROLE_ARN = aws_iam_role.orders_api.arn             # orders_api_db_access
      EKS_CLUSTER_NAME    = aws_eks_cluster.main.name               # eks_pods_schedulable
      EKS_NODEGROUP_NAME  = aws_eks_node_group.main.node_group_name # eks_pods_schedulable
      APP_DB_HOST         = local.app_db_host                       # aurora_writable (reader under lab4)
      PRIVATE_RT_ID       = aws_route_table.private.id              # app_path_reachable
      PARTNER_CIDR        = var.partner_cidr                        # app_path_reachable
    }
  }

  depends_on = [aws_iam_role_policy_attachment.health_checker_vpc]
}

# ----------------------------------------------------------------------------
# EventBridge schedule -> health-checker (every minute)
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "health_schedule" {
  name                = "${local.name_prefix}-health-schedule"
  description         = "IO-108 -- run the health-checker probes every minute"
  schedule_expression = var.health_check_schedule_expression
}

resource "aws_cloudwatch_event_target" "health_schedule" {
  rule = aws_cloudwatch_event_rule.health_schedule.name
  arn  = aws_lambda_function.health_checker.arn
}

resource "aws_lambda_permission" "health_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_schedule.arn
}

# ----------------------------------------------------------------------------
# One alarm per probe  -- ALARM when the metric drops below 1 (broken).
# Missing data breaches: if the checker stops publishing, the tile goes red too.
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "health" {
  for_each = local.health_checks

  alarm_name          = "${local.name_prefix}-health-${each.key}"
  alarm_description   = "IO-108 health probe '${each.key}' is broken (metric < 1)."
  namespace           = "IO108/Health"
  metric_name         = each.key
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    Student = var.student_id
  }

  tags = { Lab = each.value.lab }
}

# ----------------------------------------------------------------------------
# The incident board  -- alarm-status tiles grouped by lab via text headers.
# Existing monitoring.tf dashboard (io108-<id>-incident-dashboard) + its 3
# alarms are kept as-is (NO DELETION); this board is the red/green map.
#
# Tiles are generated from local.health_checks so adding a probe to the registry
# adds its tile automatically. x/y are omitted on purpose: CloudWatch auto-flows
# widgets left-to-right, and a full-width (24) text header forces a new row, so
# each lab's header + tiles land on their own band without hand-managed coords.
# ----------------------------------------------------------------------------

locals {
  _board_lab_order = ["lab1", "lab2", "lab3", "lab4", "lab5"]
  _board_lab_titles = {
    lab1 = "Lab 1 -- IAM Access Denial and Rogue Hunt"
    lab2 = "Lab 2 -- EKS Pod Failure and Connectivity"
    lab3 = "Lab 3 -- Lambda and Step Functions Performance + Event Fan-out"
    lab4 = "Lab 4 -- Aurora Failover and Connectivity"
    lab5 = "Lab 5 -- Multi-Layered Capstone (Network; everything green, rogue contained)"
  }

  # Probe ids per lab, sorted for a stable tile order.
  _board_probes_by_lab = {
    for lab in local._board_lab_order :
    lab => sort([for k, v in local.health_checks : k if v.lab == lab])
  }

  # Banner + per-lab (header + alarm tiles), flattened into one widget list.
  _board_widgets = concat(
    [{
      type   = "text"
      width  = 24
      height = 2
      properties = {
        markdown = "# IO-108 Incident Board -- ${var.student_id}\nGreen = healthy, **red = broken**. Each tile is a probe published ~every minute (health-checker Lambda + in-cluster conncheck CronJob). Scenario: **${var.scenario}**. Use the tools to diagnose and fix -- watch the tiles go green."
      }
    }],
    flatten([
      for lab in local._board_lab_order : concat(
        [{
          type       = "text"
          width      = 24
          height     = 1
          properties = { markdown = "## ${local._board_lab_titles[lab]}" }
        }],
        [for probe in local._board_probes_by_lab[lab] : {
          type   = "alarm"
          width  = 6
          height = 3
          properties = {
            title  = local.health_checks[probe].title
            alarms = [aws_cloudwatch_metric_alarm.health[probe].arn]
          }
        }]
      )
    ])
  )
}

resource "aws_cloudwatch_dashboard" "incident_board" {
  dashboard_name = "${local.name_prefix}-incident-board"

  dashboard_body = jsonencode({
    widgets = local._board_widgets
  })
}
