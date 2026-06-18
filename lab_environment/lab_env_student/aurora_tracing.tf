###############################################################################
# IO-108 Troubleshooting -- lab_env_student / aurora_tracing.tf
#
# Lab 4 QUERY-TRACING ADD-ON (always on -- it is observability, not a fault).
#
# A custom Aurora PostgreSQL cluster parameter group that turns on connection
# logging so the guide can show, in the postgresql log, every session opening
# and closing -- including the rogue instance's client_addr. Pairs with
# Performance Insights (enabled on the instances in aurora.tf) and the live
# `pg_stat_activity` query the aurora_no_rogue probe already runs.
#
# log_connections / log_disconnections are STATIC-but-dynamic in Aurora PG
# (apply_method = pending-reboot would force a reboot); they apply immediately,
# so apply_method = immediate keeps the lab deployable without a DB bounce.
###############################################################################

resource "aws_rds_cluster_parameter_group" "main" {
  name        = "${local.name_prefix}-aurora-pg16"
  family      = "aurora-postgresql16"
  description = "IO-108 Aurora PG16 -- connection/disconnection logging for query tracing (Lab 4)"

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  # Log any statement running longer than 1s -- surfaces the rogue's queries and
  # any slow app query in the postgresql log group.
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  tags = { Name = "${local.name_prefix}-aurora-pg16" }
}
