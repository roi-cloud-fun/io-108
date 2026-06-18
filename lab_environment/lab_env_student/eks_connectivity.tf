###############################################################################
# IO-108 Troubleshooting -- lab_env_student / eks_connectivity.tf
#
# IRSA role for the IN-CLUSTER connectivity checker (the orders chart's
# `conncheck` CronJob). The CronJob runs every minute and publishes 1/0 custom
# metrics straight to IO108/Health for the pod-level probes the external
# health-checker Lambda cannot see from outside the cluster:
#
#     eks_pod_internet   pod -> https://example.com reachable
#     eks_pod_dns        in-cluster DNS resolves (kube-dns / a public name)
#
# Assumed by ServiceAccount orders:eks-health-checker (annotated by deploy_app.sh).
# Only permission needed is cloudwatch:PutMetricData -- the checker reaches the
# CloudWatch endpoint via NAT, the very egress path it is also testing, so when a
# default-deny NetworkPolicy (Lab 2 / capstone) cuts pod egress the metrics stop
# publishing and the tiles go red on missing data. That is the intended signal.
###############################################################################

resource "aws_iam_role" "eks_health_checker" {
  name = "${local.name_prefix}-eks-conncheck-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:orders:eks-health-checker"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { Name = "${local.name_prefix}-eks-conncheck-role" }
}

resource "aws_iam_role_policy" "eks_health_checker" {
  name = "${local.name_prefix}-eks-conncheck-inline"
  role = aws_iam_role.eks_health_checker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "PublishPodHealthMetrics"
      Effect = "Allow"
      Action = ["cloudwatch:PutMetricData"]
      # PutMetricData has no resource-level scoping; constrain to our namespace.
      Resource = "*"
      Condition = {
        StringEquals = { "cloudwatch:namespace" = "IO108/Health" }
      }
    }]
  })
}
