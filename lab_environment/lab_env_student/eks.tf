###############################################################################
# IO-108 Troubleshooting -- lab_env_student / eks.tf
#
# EKS cluster + managed node group + IRSA (OIDC) + addons.
# Public endpoint stays ON so students reach the API from classroom laptops
# / CloudShell; nodes live in private subnets.
###############################################################################

data "aws_caller_identity" "current" {}

# Derive the IAM principal of whoever runs `terraform apply` so we can grant
# them cluster admin via an access entry (IO-107 lesson: assumed-role ARNs
# must be mapped back to the underlying role ARN).
locals {
  _caller_arn = data.aws_caller_identity.current.arn
  apply_host_principal_arn = (
    can(regex(":assumed-role/", local._caller_arn))
    ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${split("/", local._caller_arn)[1]}"
    : local._caller_arn
  )
}

resource "aws_iam_role" "eks_cluster" {
  name = "${local.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = "${local.name_prefix}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # False so OUR explicit access entry below is the single source of admin
    # access -- avoids the create/adopt collision IO-107 hit when the
    # auto-created bootstrap entry clashed with an explicit one.
    bootstrap_cluster_creator_admin_permissions = false
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_eks_access_entry" "apply_host" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.apply_host_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "apply_host_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.apply_host_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.apply_host]
}

# ----------------------------------------------------------------------------
# Managed node group
# ----------------------------------------------------------------------------

resource "aws_iam_role" "eks_nodes" {
  name = "${local.name_prefix}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Required by the amazon-cloudwatch-observability addon (Container Insights).
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])
  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

# Launch template used ONLY to put a Name tag on the worker EC2 instances + their
# EBS volumes. EKS managed node groups don't tag the underlying instances by
# default, so they show up blank in the console. EKS still injects the AMI and
# bootstrap; we only supply tag_specifications (no image_id / instance type here,
# so ami_type + instance_types on the node group still drive those).
resource "aws_launch_template" "nodes" {
  name_prefix = "${local.name_prefix}-nodes-"

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name_prefix}-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name_prefix}-node" }
  }

  tags = { Name = "${local.name_prefix}-nodes-lt" }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  # Lab 2 (break_eks_node_capacity): scale the managed node group to ZERO nodes
  # so every pod -- orders-api, worker, coredns -- goes Pending / Unschedulable
  # for lack of capacity. Healthy = 2 nodes (min 2, max 3). The student diagnoses
  # "why are my pods Pending?" and remediates with
  #   aws eks update-nodegroup-config --scaling-config minSize=2,desiredSize=2,maxSize=3
  # The eks_pods_schedulable probe (health-checker, DescribeNodegroup) flips green
  # once desiredSize is back up.
  scaling_config {
    desired_size = local.fault_break_eks_capacity ? 0 : 2
    min_size     = local.fault_break_eks_capacity ? 0 : 2
    max_size     = 3
  }

  # NOTE: desired_size is deliberately terraform-managed (NOT under
  # ignore_changes) so `scenario=lab2` actually scales the group to 0 and
  # `scenario=healthy`/any other scenario scales it back to 2. The student's
  # Lab 2 remediation is the EKS API call `aws eks update-nodegroup-config
  # --scaling-config ...desiredSize=2`; that fix holds for the rest of the lab.
  # (Re-running `terraform apply` while still on scenario=lab2 would re-inject
  # the fault -- that is expected, not a regression.)

  depends_on = [aws_iam_role_policy_attachment.eks_nodes]
}

# ----------------------------------------------------------------------------
# Addons
# ----------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  # Turn on the VPC CNI's Kubernetes NetworkPolicy enforcement so the chart's
  # default-deny / selective-allow manifests are actually enforced (Lab 2
  # connectivity add-on + capstone). Without this flag NetworkPolicies are
  # silently ignored by the AWS CNI.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  # coredns pods need somewhere to schedule.
  depends_on = [aws_eks_node_group.main]
}

# Container Insights -- node/pod metrics feed the incident dashboard.
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "amazon-cloudwatch-observability"

  depends_on = [aws_eks_node_group.main]
}

# ----------------------------------------------------------------------------
# IRSA: OIDC provider + orders-api role
# ----------------------------------------------------------------------------

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# Assumed by ServiceAccount orders:orders-api (Lab 1 breaks this on purpose
# later -- this is the HEALTHY baseline policy).
resource "aws_iam_role" "orders_api" {
  name = "${local.name_prefix}-orders-api-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:orders:orders-api"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Lab 1 (break_orders_api_irsa, also active in the capstone): swap the orders-api
# IRSA policy for one that is MISSING the Aurora-secret read and the S3 object
# permissions. The pod then gets AccessDenied reading the DB credentials (and the
# reports bucket), exactly the symptom Lab 1 investigates. Healthy = the full
# policy below. The fix is restoring the missing permissions to this role.
#
# The broken variant keeps a single harmless ListBucket statement so the policy
# document is still valid (an empty Statement array is rejected by IAM).
locals {
  orders_api_policy_healthy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReportsBucketObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.reports.arn}/*"
      },
      {
        Sid      = "ReportsBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.reports.arn
      },
      {
        Sid      = "ReadAuroraMasterSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_rds_cluster.main.master_user_secret[0].secret_arn
      }
    ]
  }

  orders_api_policy_broken = {
    Version = "2012-10-17"
    Statement = [
      {
        # Deliberately harmless: lets the bucket be listed but grants NEITHER the
        # secret read NOR object access -> the app can't fetch DB creds.
        Sid      = "ReportsBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.reports.arn
      }
    ]
  }
}

resource "aws_iam_role_policy" "orders_api" {
  name = "${local.name_prefix}-orders-api-inline"
  role = aws_iam_role.orders_api.id

  policy = jsonencode(
    local.fault_break_orders_api_irsa
    ? local.orders_api_policy_broken
    : local.orders_api_policy_healthy
  )
}
