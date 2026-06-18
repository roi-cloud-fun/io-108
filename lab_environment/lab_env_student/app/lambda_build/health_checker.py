"""IO-108 health-checker -- Lambda handler (the red/green dashboard engine).

Runs every ~1 minute (EventBridge). For each probe it publishes a single
CloudWatch datapoint to namespace IO108/Health, dimension Student=<id>, metric
name = the probe id, value 1 (healthy) or 0 (broken). Each metric has a paired
CloudWatch alarm (see healthcheck.tf) that goes ALARM when the metric < 1; the
dashboard renders those alarms as green (OK) / red (ALARM) tiles.

Design rules:
  * Every probe is wrapped in try/except in the handler loop -- one probe
    blowing up must never stop the others, and an exception publishes 0 (red)
    plus a log line, never a gap.
  * PROBES is a plain dict so the next (faults) pass just adds entries.
  * In-VPC like report_generator: AWS API calls egress via NAT; Aurora is
    reached on 5432 through the checker SG. pg8000 is vendored (app/lambda_build).

Env:
  STUDENT_ID            metric dimension value
  METRIC_NAMESPACE      default IO108/Health
  SECRET_ARN            Aurora master secret (aurora_reachable / aurora_no_rogue)
  DB_CLUSTER_ENDPOINT   Aurora CLUSTER (writer) endpoint -- never an instance one
  DB_NAME               Aurora database name
  ROGUE_IP              rogue instance private IP (aurora_no_rogue)
  ROGUE_INSTANCE_ID     rogue instance id (rogue_contained)
  ROGUE_SG_ID           rogue security group id (rogue_contained)
  REPORTS_BUCKET        reports bucket (reports_flowing)
  SINK_NEWRELIC_BUCKET  simulated NewRelic sink bucket (sink_newrelic)
  SINK_SOLARWINDS_BUCKET simulated SolarWinds sink bucket (sink_solarwinds)
  VPC_ID                VPC id (tgw_or_network_ok)
  FRESH_SECONDS         "recent object" window for S3 probes (default 600)
  ORDERS_API_ROLE_ARN   orders-api IRSA role (orders_api_db_access)
  EKS_CLUSTER_NAME      EKS cluster name (eks_pods_schedulable)
  EKS_NODEGROUP_NAME    managed node group name (eks_pods_schedulable)
  APP_DB_HOST           DB host the APP uses -- reader under lab4 (aurora_writable)
  PRIVATE_RT_ID         private route table id (app_path_reachable)
  PARTNER_CIDR          simulated partner CIDR (app_path_reachable)

NOTE on what this Lambda can and cannot see: it probes from OUTSIDE the cluster,
so pod-level connectivity (eks_pod_internet / eks_pod_dns) is published by the
in-cluster `conncheck` CronJob, not here. eks_pods_schedulable is inferred from
the node group's desired size (DescribeNodegroup), and aurora_writable reflects
the TF-intended app DB target (APP_DB_HOST) rather than the live in-cluster env.
"""
import datetime
import json
import logging
import os

import boto3
import pg8000.native

logger = logging.getLogger()
logger.setLevel(logging.INFO)

NAMESPACE = os.environ.get("METRIC_NAMESPACE", "IO108/Health")
STUDENT_ID = os.environ.get("STUDENT_ID", "unknown")
FRESH_SECONDS = int(os.environ.get("FRESH_SECONDS", "600"))

_cw = boto3.client("cloudwatch")
_ec2 = boto3.client("ec2")
_s3 = boto3.client("s3")
_sm = boto3.client("secretsmanager")
_iam = boto3.client("iam")
_eks = boto3.client("eks")


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _aurora_connection(host=None):
    """Open a pg8000 connection to Aurora using the master secret.

    host defaults to the cluster (writer) endpoint; pass APP_DB_HOST to probe
    whatever endpoint the app is pointed at (reader under lab4)."""
    secret = _sm.get_secret_value(SecretId=os.environ["SECRET_ARN"])
    creds = json.loads(secret["SecretString"])
    return pg8000.native.Connection(
        creds["username"],
        host=host or os.environ["DB_CLUSTER_ENDPOINT"],
        database=os.environ["DB_NAME"],
        password=creds["password"],
        timeout=8,
    )


def _bucket_has_recent_object(bucket, prefix="", max_age=None):
    """1 if the bucket has any object newer than max_age seconds, else 0."""
    if not bucket:
        return 0
    max_age = FRESH_SECONDS if max_age is None else max_age
    resp = _s3.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=1000)
    contents = resp.get("Contents") or []
    if not contents:
        return 0
    # Training stacks never hold >1000 recent objects, so the first page's
    # newest LastModified is a sound freshness signal.
    newest = max(o["LastModified"] for o in contents)
    age = (_now() - newest).total_seconds()
    return 1 if age <= max_age else 0


# ---------------------------------------------------------------------------
# Probes  -- each returns 1 (healthy/green) or 0 (broken/red).
# ---------------------------------------------------------------------------

def probe_aurora_reachable():
    """Can we connect to Aurora and run a trivial query?"""
    conn = _aurora_connection()
    try:
        conn.run("SELECT 1")
    finally:
        conn.close()
    return 1


def probe_aurora_no_rogue():
    """0 rogue connections in pg_stat_activity = healthy.

    Counts sessions whose client_addr matches the rogue instance's private IP.
    In the healthy baseline the rogue IS querying, so this stays RED until the
    student contains it (Lab 1 / Lab 4)."""
    rogue_ip = os.environ.get("ROGUE_IP", "").strip()
    if not rogue_ip:
        # No rogue IP wired -> nothing to detect; treat as healthy.
        return 1
    conn = _aurora_connection()
    try:
        rows = conn.run(
            "SELECT count(*) FROM pg_stat_activity WHERE client_addr = :ip",
            ip=rogue_ip,
        )
    finally:
        conn.close()
    return 1 if rows[0][0] == 0 else 0


def probe_reports_flowing():
    """Reports bucket has a fresh object = the reporting pipeline is alive."""
    return _bucket_has_recent_object(os.environ.get("REPORTS_BUCKET", ""), prefix="reports/")


def probe_sink_newrelic():
    """Simulated NewRelic sink has a fresh object.

    Wired by the Lab 3 event fan-out (CloudWatch Alarm/X-Ray -> EventBridge ->
    SFN Parallel -> SQS -> forwarder Lambda -> this bucket). Until then the
    bucket is empty and this tile is intentionally RED."""
    return _bucket_has_recent_object(os.environ.get("SINK_NEWRELIC_BUCKET", ""))


def probe_sink_solarwinds():
    """Simulated SolarWinds sink has a fresh object. RED until the Lab 3 fan-out
    is wired (see probe_sink_newrelic)."""
    return _bucket_has_recent_object(os.environ.get("SINK_SOLARWINDS_BUCKET", ""))


def probe_rogue_contained():
    """Healthy(1) when the rogue is CONTAINED.

    Contained == instance is not running (stopped/stopping/terminated/...) OR
    the rogue security group has been detached from it. Either is a concrete,
    student-driven remediation the dashboard can verify from DescribeInstances
    alone."""
    instance_id = os.environ.get("ROGUE_INSTANCE_ID", "").strip()
    rogue_sg_id = os.environ.get("ROGUE_SG_ID", "").strip()
    if not instance_id:
        return 1
    resp = _ec2.describe_instances(InstanceIds=[instance_id])
    reservations = resp.get("Reservations") or []
    if not reservations:
        # Instance gone entirely -> contained.
        return 1
    instance = reservations[0]["Instances"][0]
    state = instance["State"]["Name"]
    if state != "running":
        return 1
    attached_sgs = {g["GroupId"] for g in instance.get("SecurityGroups", [])}
    if rogue_sg_id and rogue_sg_id not in attached_sgs:
        # Student swapped the permissive rogue SG for a deny/quarantine SG.
        return 1
    return 0


def probe_orders_api_db_access():
    """1 when the orders-api IRSA role is ALLOWED to read the Aurora secret.

    Lab 1 (break_orders_api_irsa) strips this permission, so the pod gets
    AccessDenied fetching DB creds. Rather than assume the IRSA role, we ask IAM
    to simulate it -- iam:SimulatePrincipalPolicy on the role for
    secretsmanager:GetSecretValue against the secret. Restoring the policy
    (the fix) flips the decision back to 'allowed'."""
    role_arn = os.environ.get("ORDERS_API_ROLE_ARN", "").strip()
    secret_arn = os.environ.get("SECRET_ARN", "").strip()
    if not role_arn or not secret_arn:
        return 1
    resp = _iam.simulate_principal_policy(
        PolicySourceArn=role_arn,
        ActionNames=["secretsmanager:GetSecretValue"],
        ResourceArns=[secret_arn],
    )
    decision = resp["EvaluationResults"][0]["EvalDecision"]
    return 1 if decision == "allowed" else 0


def probe_eks_pods_schedulable():
    """1 when the managed node group has capacity (desiredSize >= 1).

    Lab 2 (break_eks_node_capacity) scales the node group to 0, so all pods go
    Pending. From outside the cluster we infer schedulability from the node
    group's desired size (DescribeNodegroup) -- a documented approximation of
    'are there nodes for pods to land on?'. Fix = scale the node group back up."""
    cluster = os.environ.get("EKS_CLUSTER_NAME", "").strip()
    nodegroup = os.environ.get("EKS_NODEGROUP_NAME", "").strip()
    if not cluster or not nodegroup:
        return 1
    resp = _eks.describe_nodegroup(clusterName=cluster, nodegroupName=nodegroup)
    desired = resp["nodegroup"]["scalingConfig"]["desiredSize"]
    return 1 if desired >= 1 else 0


def probe_aurora_writable():
    """1 when the app's DB endpoint accepts WRITES (not a read-only replica).

    Lab 4 (force_aurora_failover) points the app -- and APP_DB_HOST -- at the
    reader endpoint, where pg_is_in_recovery() is true and writes fail. Healthy
    (cluster/writer endpoint) -> pg_is_in_recovery() false. Reflects the
    TF-intended app target; the student verifies the live fix in-cluster."""
    host = os.environ.get("APP_DB_HOST", "").strip() or os.environ.get("DB_CLUSTER_ENDPOINT")
    conn = _aurora_connection(host=host)
    try:
        rows = conn.run("SELECT pg_is_in_recovery()")
    finally:
        conn.close()
    in_recovery = bool(rows[0][0])
    return 0 if in_recovery else 1


def probe_app_path_reachable():
    """1 when the private route table has NO partner-CIDR blackhole misroute.

    Lab 5 (capstone) adds a more-specific route for PARTNER_CIDR pointed at the
    internet gateway -- from the private (no-public-IP) subnets that is a
    blackhole. We detect it via DescribeRouteTables: a route for PARTNER_CIDR
    whose target is an igw-* means the account-to-partner path is broken. Fix =
    remove the misroute so traffic falls back to the NAT default."""
    rt_id = os.environ.get("PRIVATE_RT_ID", "").strip()
    partner = os.environ.get("PARTNER_CIDR", "").strip()
    if not rt_id or not partner:
        return 1
    resp = _ec2.describe_route_tables(RouteTableIds=[rt_id])
    tables = resp.get("RouteTables") or []
    if not tables:
        return 1
    for route in tables[0].get("Routes", []):
        if route.get("DestinationCidrBlock") == partner and str(
            route.get("GatewayId", "")
        ).startswith("igw-"):
            return 0
    return 1


def probe_tgw_or_network_ok():
    """Basic egress-path health: the VPC has at least one available NAT gateway.

    Keep-it-simple network reachability signal derivable from a single describe
    call. Lab 5 / capstone extends this into Reachability-Analyzer + route/TGW
    checks; for the backbone, "the path off the VPC is up" is enough."""
    vpc_id = os.environ.get("VPC_ID", "").strip()
    if not vpc_id:
        return 1
    resp = _ec2.describe_nat_gateways(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "state", "Values": ["available"]},
        ]
    )
    return 1 if resp.get("NatGateways") else 0


# Ordered probe registry. Metric name == alarm suffix == dashboard tile title.
#
# eks_pod_internet / eks_pod_dns are deliberately NOT here -- they are published
# by the in-cluster `conncheck` CronJob (the Lambda can't run pod-level probes).
# Their alarms/tiles exist in healthcheck.tf and stay red on missing data until
# the CronJob publishes, which is the intended behaviour.
PROBES = {
    "aurora_reachable": probe_aurora_reachable,
    "aurora_writable": probe_aurora_writable,
    "aurora_no_rogue": probe_aurora_no_rogue,
    "reports_flowing": probe_reports_flowing,
    "sink_newrelic": probe_sink_newrelic,
    "sink_solarwinds": probe_sink_solarwinds,
    "rogue_contained": probe_rogue_contained,
    "orders_api_db_access": probe_orders_api_db_access,
    "eks_pods_schedulable": probe_eks_pods_schedulable,
    "app_path_reachable": probe_app_path_reachable,
    "tgw_or_network_ok": probe_tgw_or_network_ok,
}


def _publish(name, value):
    try:
        _cw.put_metric_data(
            Namespace=NAMESPACE,
            MetricData=[
                {
                    "MetricName": name,
                    "Dimensions": [{"Name": "Student", "Value": STUDENT_ID}],
                    "Value": float(value),
                    "Unit": "None",
                }
            ],
        )
    except Exception:
        logger.exception("put_metric_data failed for probe %s", name)


def handler(event, context):
    results = {}
    for name, fn in PROBES.items():
        try:
            value = fn()
        except Exception:
            logger.exception("probe %s raised -- publishing 0 (red)", name)
            value = 0
        results[name] = value
        _publish(name, value)
    logger.info("health probes: %s", json.dumps(results))
    return results
