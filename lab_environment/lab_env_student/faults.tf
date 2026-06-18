###############################################################################
# IO-108 Troubleshooting -- lab_env_student / faults.tf
#
# EFFECTIVE FAULT LAYER.
#
# locals.tf documents the immutable per-lab `faults` CONTRACT (one boolean per
# lab, RHS never changed here). This file derives the EFFECTIVE switch each
# resource actually reads, so the capstone (lab5) can COMPOSE several of the
# single-lab faults without mutating the contract map. Resources branch on
# these `fault_*` locals, never on var.scenario directly.
#
#   healthy            -> every fault_* is false -> the whole stack is green
#                         (except the always-present rogue, which is the
#                         security through-line and is red until contained).
#   lab1               -> fault_break_orders_api_irsa
#   lab2               -> fault_break_eks_capacity
#   lab3               -> fault_throttle_report
#   lab4               -> fault_app_db_reader
#   lab5 (capstone)    -> fault_misroute  +  fault_break_orders_api_irsa
#                         (compound: a network path break PLUS the IAM break,
#                         on top of the always-on rogue -> several red tiles to
#                         "clear the board").
###############################################################################

locals {
  # ---- Lab 1: orders-api IRSA access denial -------------------------------
  # Broken under lab1 AND folded into the capstone so lab5 carries a second,
  # independent red tile beyond the network break.
  fault_break_orders_api_irsa = local.faults.break_orders_api_irsa || local.faults.capstone_multi

  # ---- Lab 2: EKS node capacity -------------------------------------------
  fault_break_eks_capacity = local.faults.break_eks_node_capacity

  # ---- Lab 2 add-on: in-cluster NetworkPolicy default-deny ----------------
  # Drives the Helm `networkPolicy.defaultDeny` value via deploy_app.sh. Breaks
  # pod->internet / pod->DNS (eks_pod_internet / eks_pod_dns probes). Offered as
  # the Lab 2 connectivity add-on and reused in the capstone.
  fault_pod_netpol_deny = local.faults.break_eks_node_capacity || local.faults.capstone_multi

  # ---- Lab 3: report Lambda throttle --------------------------------------
  fault_throttle_report = local.faults.throttle_report_lambda

  # ---- Lab 4: app pinned to the Aurora READER endpoint --------------------
  # "Failover/connectivity" break: the app (and the writability probe) are
  # pointed at the read-only reader endpoint, so writes fail. Fix = repoint to
  # the cluster (writer) endpoint.
  fault_app_db_reader = local.faults.force_aurora_failover

  # ---- Lab 5: capstone network misroute -----------------------------------
  # A more-specific route for the "partner" CIDR sent to the IGW instead of the
  # NAT gateway. From the private (no-public-IP) subnets that is a blackhole:
  # an asymmetric, Flow-Logs / Reachability-Analyzer-diagnosable break of the
  # account-to-partner path. Fix = remove the misroute (path falls back to NAT).
  fault_misroute = local.faults.capstone_multi

  # ---- App DB host the orders-api + writability probe should use ----------
  # Cluster (writer) endpoint when healthy; reader endpoint under lab4.
  app_db_host = (
    local.fault_app_db_reader
    ? aws_rds_cluster.main.reader_endpoint
    : aws_rds_cluster.main.endpoint
  )
}
