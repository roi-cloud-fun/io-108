###############################################################################
# IO-108 Troubleshooting -- lab_env_student / aurora.tf
#
# Aurora PostgreSQL: 1 writer + 1 reader (Lab 4 forces a failover, so the
# reader must exist). Master password managed by Secrets Manager.
###############################################################################

resource "aws_db_subnet_group" "aurora" {
  name        = "${local.name_prefix}-aurora"
  description = "IO-108 Aurora -- private subnets (${var.student_id})"
  subnet_ids  = aws_subnet.private[*].id
  tags        = { Name = "${local.name_prefix}-aurora" }
}

resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-aurora-sg"
  description = "IO-108 Aurora -- Postgres from EKS nodes and report Lambda only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from EKS cluster security group (nodes/pods)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  ingress {
    description     = "Postgres from report-generator Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-aurora-sg" }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = "${local.name_prefix}-aurora"
  engine             = "aurora-postgresql"
  engine_version     = "16.6"
  database_name      = "orders"

  master_username             = "orders_admin"
  manage_master_user_password = true

  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  storage_encrypted               = true
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name

  enabled_cloudwatch_logs_exports     = ["postgresql"]
  iam_database_authentication_enabled = true

  # Training stack: easy teardown beats durability.
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true

  tags = { Name = "${local.name_prefix}-aurora" }
}

resource "aws_rds_cluster_instance" "main" {
  count = 2

  identifier         = "${local.name_prefix}-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.main.id
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version
  instance_class     = var.db_instance_class
  apply_immediately  = true

  # Lab 4 add-on: Performance Insights so the guide can show top SQL / waits and
  # corroborate the pg_stat_activity rogue hunt. 7-day retention is free tier.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = { Name = "${local.name_prefix}-aurora-${count.index}" }
}
