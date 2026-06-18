###############################################################################
# IO-108 Troubleshooting -- lab_env_student / reporting.tf
#
# Reporting path: EventBridge schedule -> Step Functions -> Lambda
# (report-generator, in-VPC) -> Aurora query -> JSON report in S3.
#
# The Lambda package is built OUT OF BAND into app/lambda_build/ (pg8000 and
# its deps vendored via `pip install pg8000 --target app/lambda_build/`, plus
# report_generator.py copied in). The build dir is COMMITTED so students
# never run pip -- archive_file just zips it deterministically.
###############################################################################

resource "random_string" "bucket_suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# ----------------------------------------------------------------------------
# Reports bucket
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "reports" {
  bucket        = "${local.name_prefix}-reports-${random_string.bucket_suffix.result}"
  force_destroy = true
  tags          = { Name = "${local.name_prefix}-reports" }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      # AWS managed aws/s3 default KMS key.
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------------------------------------------------------
# Lambda: report-generator
# ----------------------------------------------------------------------------

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-report-lambda-sg"
  description = "IO-108 report-generator Lambda -- egress only"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-report-lambda-sg" }
}

resource "aws_iam_role" "report_lambda" {
  name = "${local.name_prefix}-report-lambda-role"

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
resource "aws_iam_role_policy_attachment" "report_lambda_vpc" {
  role       = aws_iam_role.report_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "report_lambda" {
  name = "${local.name_prefix}-report-lambda-inline"
  role = aws_iam_role.report_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAuroraMasterSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_rds_cluster.main.master_user_secret[0].secret_arn
      },
      {
        Sid      = "WriteReports"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.reports.arn}/*"
      }
    ]
  })
}

data "archive_file" "report_generator" {
  type        = "zip"
  source_dir  = "${path.module}/app/lambda_build"
  output_path = "${path.module}/report_generator.zip"

  # Keep host build artifacts out of the Lambda package: pip leaves __pycache__
  # bytecode and Google Drive drops desktop.ini into synced folders. Build the
  # vendored deps with `pip install --target ... ` (no --compile) to avoid
  # nested __pycache__; this excludes the top-level pollution as a backstop.
  excludes = [
    "desktop.ini",
    "__pycache__",
  ]
}

resource "aws_lambda_function" "report_generator" {
  function_name = "${local.name_prefix}-report-generator"
  role          = aws_iam_role.report_lambda.arn
  runtime       = "python3.12"
  handler       = "report_generator.handler"
  timeout       = 60
  memory_size   = 256

  # Lab 3 (throttle_report_lambda): pin reserved concurrency to 0 so EVERY
  # invocation is throttled -- the Step Functions task fails its retries, the
  # workflow lands in ReportFailed, and no fresh report is written (reports_flowing
  # goes red; the report-error alarm fires and drives the fan-out). Healthy = null
  # (unreserved, drawn from the account pool). Fix = raise reserved concurrency
  # (e.g. to 5) in the Lambda console / CLI.
  reserved_concurrent_executions = local.fault_throttle_report ? 0 : -1

  filename         = data.archive_file.report_generator.output_path
  source_code_hash = data.archive_file.report_generator.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SECRET_ARN          = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_CLUSTER_ENDPOINT = aws_rds_cluster.main.endpoint # CLUSTER endpoint, never an instance endpoint
      DB_NAME             = aws_rds_cluster.main.database_name
      REPORTS_BUCKET      = aws_s3_bucket.reports.bucket
    }
  }

  depends_on = [aws_iam_role_policy_attachment.report_lambda_vpc]
}

# ----------------------------------------------------------------------------
# Step Functions: report workflow
# ----------------------------------------------------------------------------

resource "aws_iam_role" "sfn" {
  name = "${local.name_prefix}-report-workflow-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "${local.name_prefix}-report-workflow-inline"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.report_generator.arn]
    }]
  })
}

resource "aws_sfn_state_machine" "report_workflow" {
  name     = "${local.name_prefix}-report-workflow"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "IO-108 report workflow: invoke report-generator with retry"
    StartAt = "GenerateReport"
    States = {
      GenerateReport = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.report_generator.arn
          "Payload.$"  = "$"
        }
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 10
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "ReportFailed"
        }]
        End = true
      }
      ReportFailed = {
        Type  = "Fail"
        Error = "ReportGenerationFailed"
        Cause = "report-generator Lambda failed after retries"
      }
    }
  })
}

# ----------------------------------------------------------------------------
# EventBridge schedule -> Step Functions
# ----------------------------------------------------------------------------

resource "aws_iam_role" "eventbridge_sfn" {
  name = "${local.name_prefix}-events-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_sfn" {
  name = "${local.name_prefix}-events-sfn-inline"
  role = aws_iam_role.eventbridge_sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = [aws_sfn_state_machine.report_workflow.arn]
    }]
  })
}

resource "aws_cloudwatch_event_rule" "report_schedule" {
  name                = "${local.name_prefix}-report-schedule"
  description         = "IO-108 -- trigger the report workflow on a schedule"
  schedule_expression = var.report_schedule_expression
}

resource "aws_cloudwatch_event_target" "report_schedule" {
  rule     = aws_cloudwatch_event_rule.report_schedule.name
  arn      = aws_sfn_state_machine.report_workflow.arn
  role_arn = aws_iam_role.eventbridge_sfn.arn
}
