###############################################################################
# IO-108 Troubleshooting -- lab_env_student / rogue.tf
#
# THE SECURITY THROUGH-LINE. A "rogue" EC2 instance sits in a private subnet
# and -- using credentials it should not have -- opens a periodic Postgres
# connection to Aurora alongside the legit app. It is present in the HEALTHY
# baseline on purpose: the dashboard's `aurora_no_rogue` and `rogue_contained`
# tiles are RED from the very first apply until the student hunts it down
# (Lab 1) and locks it out (Lab 4 / capstone).
#
# Backbone scope: build the rogue, its discoverable IAM principal, and the
# Aurora ingress that lets it connect. The CloudTrail / Config / Access
# Analyzer "hunt" UX is built around the tagged role in a LATER pass.
#
# No SSH. Access is via SSM only (SSM instance profile + SSM agent on AL2023).
#
# AWS CONFIG (Lab 1 rogue-resource hunt) -- DOCUMENTATION ONLY, no resource here:
#   The Lab 1 add-on hunts the rogue with CloudTrail (who created/queried it,
#   attributable to aws_iam_role.rogue_actor) + AWS Config (what it spun up) +
#   IAM Access Analyzer (external/unused access). CloudTrail and Access Analyzer
#   need no per-student resources for the hunt. AWS Config requires a recording
#   setup which is an ACCOUNT-LEVEL singleton (one configuration recorder per
#   account per region) -- it is expected to live in the shared lab_env_shared
#   stack, NOT here. Per the NO-second-recorder rule we deliberately do not add a
#   recorder in this per-student module; if Config queries return nothing in
#   class, confirm the shared recorder is enabled. The rogue role + instance are
#   tagged Rogue=true / Note=... so a Config advanced query or tag search finds
#   them once recording is on.
###############################################################################

# Latest Amazon Linux 2023 AMI (x86_64) -- public SSM public parameter, no AMI
# id to hard-code or rot.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ----------------------------------------------------------------------------
# Rogue IAM principal  -- io108-<id>-rogue-actor
#
# This is the principal Lab 1 hunts: it carries stolen Aurora creds and is the
# identity CloudTrail will show "creating" / querying. Tagged so the Lab 1
# hunt (Config advanced query / Access Analyzer / tag search) can discover it.
# Doubles as the rogue instance's profile so its API + DB activity is genuinely
# attributable to this role in CloudTrail.
# ----------------------------------------------------------------------------

resource "aws_iam_role" "rogue_actor" {
  name = "${local.name_prefix}-rogue-actor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-rogue-actor"
    # Discoverability hooks for the Lab 1 rogue hunt. Deliberately obvious.
    Rogue       = "true"
    DataClass   = "unmanaged"
    Provisioner = "unknown"
    Note        = "unauthorized-principal-investigate-in-lab1"
  }
}

# SSM access (so the rogue is reachable for inspection without SSH).
resource "aws_iam_role_policy_attachment" "rogue_ssm" {
  role       = aws_iam_role.rogue_actor.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The "stolen" Aurora master credentials. In the SYF story this is over-broad
# access the rogue should never have had -- exactly what Lab 1 surfaces.
resource "aws_iam_role_policy" "rogue_actor" {
  name = "${local.name_prefix}-rogue-actor-inline"
  role = aws_iam_role.rogue_actor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StolenAuroraSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_rds_cluster.main.master_user_secret[0].secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "rogue" {
  name = "${local.name_prefix}-rogue-actor"
  role = aws_iam_role.rogue_actor.name
}

# ----------------------------------------------------------------------------
# Rogue security group
#
# Egress-only. In the un-contained (healthy baseline) state it can reach the
# world via NAT (dnf, AWS APIs) and Aurora 5432. "Contained" (Lab 1/4/capstone)
# means the student stops/terminates the instance OR swaps this SG off the
# instance -- see the `rogue_contained` probe in healthcheck.tf.
# ----------------------------------------------------------------------------

resource "aws_security_group" "rogue" {
  name        = "${local.name_prefix}-rogue-sg"
  description = "IO-108 rogue instance -- egress only (NAT + Aurora 5432)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-rogue-sg" }
}

# Let the rogue reach Aurora. Standalone rule (not folded into aurora.tf) so the
# baseline Aurora SG stays untouched and the rogue path is self-contained and
# easy for a future lab to remove. THIS is what makes aurora_no_rogue red.
resource "aws_vpc_security_group_ingress_rule" "aurora_from_rogue" {
  security_group_id            = aws_security_group.aurora.id
  referenced_security_group_id = aws_security_group.rogue.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from the ROGUE instance (security through-line)"

  tags = { Name = "${local.name_prefix}-aurora-from-rogue" }
}

# ----------------------------------------------------------------------------
# Rogue instance  -- io108-<id>-rogue
#
# Boots, installs psql + AWS CLI, then a systemd timer fires every minute:
# pull the master secret, connect to Aurora, run a benign `SELECT 1`. That
# connection shows up in pg_stat_activity with client_addr = this instance's
# private IP, which is exactly what the aurora_no_rogue probe counts.
# ----------------------------------------------------------------------------

resource "aws_instance" "rogue" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.rogue_instance_type
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.rogue.id]
  iam_instance_profile        = aws_iam_instance_profile.rogue.name
  associate_public_ip_address = false

  # Periodic benign Aurora query so the rogue is visible in pg_stat_activity.
  # Inner heredoc is single-quoted ('ROGUE') so the shell writes it verbatim;
  # Terraform still fills the ${...} interpolations below at plan time.
  user_data = <<-EOT
    #!/bin/bash
    set -xe
    dnf install -y postgresql15 unzip

    # AWS CLI v2 (not shipped on AL2023 by default).
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
    unzip -q /tmp/awscli.zip -d /tmp
    /tmp/aws/install

    cat > /usr/local/bin/rogue_query.sh <<'ROGUE'
    #!/bin/bash
    REGION="${var.region}"
    SECRET_ARN="${aws_rds_cluster.main.master_user_secret[0].secret_arn}"
    DB_HOST="${aws_rds_cluster.main.endpoint}"
    DB_NAME="${aws_rds_cluster.main.database_name}"
    # Hold a PERSISTENT Aurora session so the rogue is continuously visible in
    # pg_stat_activity (client_addr = this instance's private IP). Each pg_sleep
    # keeps one connection open ~5 min; the loop reconnects within seconds if it
    # drops. This persistent rogue session is exactly what Lab 4 hunts and the
    # aurora_no_rogue health check detects.
    while true; do
      SECRET=$(/usr/local/bin/aws secretsmanager get-secret-value \
        --secret-id "$SECRET_ARN" --query SecretString --output text --region "$REGION")
      PGUSER=$(echo "$SECRET" | python3 -c 'import sys,json;print(json.load(sys.stdin)["username"])')
      PGPASSWORD=$(echo "$SECRET" | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
      export PGPASSWORD
      psql -h "$DB_HOST" -U "$PGUSER" -d "$DB_NAME" -tAc "SELECT pg_sleep(300)" >/dev/null 2>&1 || true
      sleep 2
    done
    ROGUE
    chmod +x /usr/local/bin/rogue_query.sh

    cat > /etc/systemd/system/rogue-query.service <<'UNIT'
    [Unit]
    Description=IO-108 rogue persistent Aurora session
    After=network-online.target
    [Service]
    Type=simple
    ExecStart=/usr/local/bin/rogue_query.sh
    Restart=always
    RestartSec=5
    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now rogue-query.service
  EOT

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name_prefix}-rogue"
    # Same discoverability hooks as the role -- this is the asset Lab 1 finds.
    Rogue = "true"
    Note  = "unauthorized-instance-investigate-in-lab1"
  }
}
