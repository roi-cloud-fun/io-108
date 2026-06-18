###############################################################################
# IO-108 Troubleshooting -- lab_env_student / network_diagnostics.tf
#
# Network-incident tooling + the Lab 5 capstone network break.
#
#   * VPC Flow Logs (ALWAYS ON) -> CloudWatch Logs. The primary AWS-native lens
#     for the connectivity labs: ACCEPT/REJECT records show the dropped path.
#     Reachability Analyzer is run ad hoc by the student (no resource to create).
#
#   * Capstone misroute (scenario=lab5): a more-specific route for the simulated
#     partner CIDR (var.partner_cidr) pointed at the internet gateway instead of
#     the NAT gateway. From the private subnets -- whose instances have no public
#     IP and rely on NAT for egress -- that is an asymmetric blackhole: the SYN
#     leaves via the IGW, the return never makes it back. Classic, Flow-Logs-
#     visible "account-to-partner path is down" incident. Fix = delete this route
#     so partner traffic falls back to the private RT's 0.0.0.0/0 -> NAT default.
###############################################################################

# ----------------------------------------------------------------------------
# VPC Flow Logs -> CloudWatch Logs
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/io108/${var.student_id}/vpc-flow-logs"
  retention_in_days = 3
  tags              = { Name = "${local.name_prefix}-vpc-flow-logs" }
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name_prefix}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${local.name_prefix}-flow-logs-inline"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  tags = { Name = "${local.name_prefix}-vpc-flow-log" }
}

# ----------------------------------------------------------------------------
# Capstone network break: partner-CIDR misroute (scenario=lab5 only)
# ----------------------------------------------------------------------------

resource "aws_route" "capstone_misroute" {
  count = local.fault_misroute ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.partner_cidr
  gateway_id             = aws_internet_gateway.main.id
}
