###############################################################################
# IO-108 Troubleshooting -- lab_env_student / locals.tf
###############################################################################

locals {
  name_prefix = "io108-${var.student_id}"

  common_tags = {
    Course      = "IO-108"
    Student     = var.student_id
    Environment = "training"
    ManagedBy   = "terraform"
    # Active scenario stamped on every resource (default_tags) so an instructor
    # can see at a glance which fault set a student's stack is carrying.
    Scenario = var.scenario
  }

  # ---------------------------------------------------------------------------
  # SCENARIO TOGGLE  (backbone establishes it; faults wired in a LATER pass)
  # ---------------------------------------------------------------------------
  # One boolean per lab so resource files can branch with a single, readable
  # flag instead of re-comparing var.scenario everywhere.
  is_healthy = var.scenario == "healthy"
  is_lab1    = var.scenario == "lab1"
  is_lab2    = var.scenario == "lab2"
  is_lab3    = var.scenario == "lab3"
  is_lab4    = var.scenario == "lab4"
  is_lab5    = var.scenario == "lab5"

  # ---------------------------------------------------------------------------
  # FAULT CONTRACT  -- the spec for the next (faults) pass. Each boolean is the
  # switch a future resource will read to BREAK something. TODAY every switch is
  # inert: the backbone references `local.faults` (see outputs.tf) but no
  # resource consumes the booleans yet, so `scenario=lab1..lab5` plans/applies
  # exactly like `healthy`. The red/green dashboard tile each fault flips is
  # noted so the dashboard and the faults stay in lock-step.
  #
  #   lab1 (IAM Access Denial + rogue hunt)
  #     break_orders_api_irsa    -> strip orders-api IRSA S3/secret perms.
  #                                 Tile: (orders-api access) + hunt rogue_actor.
  #     Through-line: rogue is ALWAYS present -> aurora_no_rogue / rogue_contained
  #                   are RED from day one until the student contains it.
  #   lab2 (EKS Pod Failure)
  #     break_eks_node_capacity  -> shrink/again cordon nodes so pods go
  #                                 Pending/unschedulable. Tile: (eks pod health).
  #   lab3 (Lambda + Step Functions Performance)
  #     throttle_report_lambda   -> reserved concurrency 0 / tiny timeout so the
  #                                 report workflow fails. Tiles: reports_flowing
  #                                 + (once fan-out built) sink_newrelic /
  #                                 sink_solarwinds.
  #   lab4 (Aurora Failover + Connectivity)
  #     force_aurora_failover    -> failover / stale endpoint so the app can't
  #                                 reach the DB. Tiles: aurora_reachable,
  #                                 aurora_no_rogue (RDS query tracing of rogue).
  #   lab5 (Capstone)
  #     capstone_multi           -> combination of the above + network breakage
  #                                 (route/TGW/Reachability). Tile:
  #                                 tgw_or_network_ok + everything green, rogue
  #                                 contained.
  # ---------------------------------------------------------------------------
  faults = {
    break_orders_api_irsa   = local.is_lab1
    break_eks_node_capacity = local.is_lab2
    throttle_report_lambda  = local.is_lab3
    force_aurora_failover   = local.is_lab4
    capstone_multi          = local.is_lab5
  }
}
