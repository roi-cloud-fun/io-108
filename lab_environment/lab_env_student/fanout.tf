###############################################################################
# IO-108 Troubleshooting -- lab_env_student / fanout.tf
#
# LAB 3 ADD-ON: the event DISTRIBUTION / fan-out pipeline.
#
#   CloudWatch Alarm (report-generator errors)  ----\
#                                                     >--> EventBridge rule
#   EventBridge heartbeat (rate 2 min, synthetic) ---/         |
#                                                              v
#                            Step Functions state machine (Parallel state)
#                              |-- branch "newrelic"   --> SQS newrelic queue
#                              |-- branch "solarwinds" --> SQS solarwinds queue
#                                                              |
#                                            (SQS event source mapping)
#                                                              v
#                                   forwarder Lambda --> writes a fresh object to
#                                   each destination's S3 sink bucket
#                                   (aws_s3_bucket.sink[...] in healthcheck.tf)
#
# Writing a fresh object is exactly what flips the sink_newrelic / sink_solarwinds
# probes GREEN (the health-checker lists each bucket for a recent key). The
# heartbeat keeps them green while the pipeline is healthy; a real alarm fans the
# same way, demonstrating "one event -> many monitoring tools" without needing
# real NewRelic / SolarWinds integrations.
#
# Packaging: the forwarder needs only boto3 (Lambda runtime) + S3 over the public
# endpoint, so it is NOT in the VPC and has NO vendored deps -- a single-file
# archive of app/fanout_forwarder.py (lighter than reporting.tf's vendored zip).
###############################################################################

# ----------------------------------------------------------------------------
# Per-destination SQS queues (one branch of the Parallel state each)
# ----------------------------------------------------------------------------

resource "aws_sqs_queue" "fanout" {
  for_each = local.sink_buckets # { newrelic = ..., solarwinds = ... } keys reused

  name                       = "${local.name_prefix}-fanout-${each.key}"
  message_retention_seconds  = 3600
  visibility_timeout_seconds = 60

  tags = { Name = "${local.name_prefix}-fanout-${each.key}" }
}

# ----------------------------------------------------------------------------
# Forwarder Lambda  (SQS -> S3 sink)
# ----------------------------------------------------------------------------

resource "aws_iam_role" "fanout_forwarder" {
  name = "${local.name_prefix}-fanout-forwarder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fanout_forwarder_basic" {
  role       = aws_iam_role.fanout_forwarder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "fanout_forwarder" {
  name = "${local.name_prefix}-fanout-forwarder-inline"
  role = aws_iam_role.fanout_forwarder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeFanoutQueues"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [for q in aws_sqs_queue.fanout : q.arn]
      },
      {
        Sid      = "WriteToSinks"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = [for b in aws_s3_bucket.sink : "${b.arn}/*"]
      }
    ]
  })
}

data "archive_file" "fanout_forwarder" {
  type        = "zip"
  source_file = "${path.module}/app/fanout_forwarder.py"
  output_path = "${path.module}/fanout_forwarder.zip"
}

resource "aws_lambda_function" "fanout_forwarder" {
  function_name = "${local.name_prefix}-fanout-forwarder"
  role          = aws_iam_role.fanout_forwarder.arn
  runtime       = "python3.12"
  handler       = "fanout_forwarder.handler"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.fanout_forwarder.output_path
  source_code_hash = data.archive_file.fanout_forwarder.output_base64sha256

  environment {
    variables = {
      SINK_NEWRELIC_BUCKET   = aws_s3_bucket.sink["newrelic"].bucket
      SINK_SOLARWINDS_BUCKET = aws_s3_bucket.sink["solarwinds"].bucket
    }
  }

  depends_on = [aws_iam_role_policy_attachment.fanout_forwarder_basic]
}

resource "aws_lambda_event_source_mapping" "fanout" {
  for_each = aws_sqs_queue.fanout

  event_source_arn = each.value.arn
  function_name    = aws_lambda_function.fanout_forwarder.arn
  batch_size       = 10
  enabled          = true
}

# ----------------------------------------------------------------------------
# Step Functions: the Parallel fan-out
# ----------------------------------------------------------------------------

resource "aws_iam_role" "fanout_sfn" {
  name = "${local.name_prefix}-fanout-workflow-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fanout_sfn" {
  name = "${local.name_prefix}-fanout-workflow-inline"
  role = aws_iam_role.fanout_sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [for q in aws_sqs_queue.fanout : q.arn]
    }]
  })
}

resource "aws_sfn_state_machine" "fanout" {
  name     = "${local.name_prefix}-fanout-workflow"
  role_arn = aws_iam_role.fanout_sfn.arn

  definition = jsonencode({
    Comment = "IO-108 event fan-out: one incident -> N monitoring destinations"
    StartAt = "FanOut"
    States = {
      FanOut = {
        Type = "Parallel"
        End  = true
        Branches = [
          {
            StartAt = "ToNewRelic"
            States = {
              ToNewRelic = {
                Type     = "Task"
                Resource = "arn:aws:states:::sqs:sendMessage"
                Parameters = {
                  QueueUrl    = aws_sqs_queue.fanout["newrelic"].url
                  MessageBody = jsonencode({ destination = "newrelic", note = "io108 fan-out event" })
                }
                End = true
              }
            }
          },
          {
            StartAt = "ToSolarWinds"
            States = {
              ToSolarWinds = {
                Type     = "Task"
                Resource = "arn:aws:states:::sqs:sendMessage"
                Parameters = {
                  QueueUrl    = aws_sqs_queue.fanout["solarwinds"].url
                  MessageBody = jsonencode({ destination = "solarwinds", note = "io108 fan-out event" })
                }
                End = true
              }
            }
          }
        ]
      }
    }
  })
}

# ----------------------------------------------------------------------------
# Triggers: a CloudWatch alarm (real incident) + a heartbeat (steady-state green)
# ----------------------------------------------------------------------------

# Dedicated alarm that drives the fan-out. Fires on report-generator errors --
# which is what Lab 3's throttle ultimately produces once retries are exhausted.
resource "aws_cloudwatch_metric_alarm" "fanout_trigger" {
  alarm_name          = "${local.name_prefix}-fanout-trigger"
  alarm_description   = "IO-108 -- report pipeline incident; fan out to monitoring sinks"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.report_generator.function_name
  }
}

# Shared EventBridge -> Step Functions invocation role.
resource "aws_iam_role" "fanout_events" {
  name = "${local.name_prefix}-fanout-events-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fanout_events" {
  name = "${local.name_prefix}-fanout-events-inline"
  role = aws_iam_role.fanout_events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = [aws_sfn_state_machine.fanout.arn]
    }]
  })
}

# (1) Real incident path: CloudWatch Alarm state change -> ALARM -> fan-out.
resource "aws_cloudwatch_event_rule" "fanout_alarm" {
  name        = "${local.name_prefix}-fanout-alarm"
  description = "IO-108 -- fan out when the report pipeline alarm goes ALARM"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.fanout_trigger.alarm_name]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "fanout_alarm" {
  rule     = aws_cloudwatch_event_rule.fanout_alarm.name
  arn      = aws_sfn_state_machine.fanout.arn
  role_arn = aws_iam_role.fanout_events.arn
}

# (2) Heartbeat: keep the sink_* probes green while the pipeline is healthy.
resource "aws_cloudwatch_event_rule" "fanout_heartbeat" {
  name                = "${local.name_prefix}-fanout-heartbeat"
  description         = "IO-108 -- synthetic fan-out so the sinks stay fresh/green"
  schedule_expression = var.fanout_heartbeat_expression
}

resource "aws_cloudwatch_event_target" "fanout_heartbeat" {
  rule     = aws_cloudwatch_event_rule.fanout_heartbeat.name
  arn      = aws_sfn_state_machine.fanout.arn
  role_arn = aws_iam_role.fanout_events.arn

  input = jsonencode({ source = "heartbeat" })
}
