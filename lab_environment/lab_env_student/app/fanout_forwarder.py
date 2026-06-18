"""IO-108 fan-out forwarder -- the last hop of the Lab 3 event-distribution demo.

Pipeline:
    CloudWatch Alarm (report errors)  --\
                                         >-- EventBridge --> Step Functions
    EventBridge heartbeat (synthetic) --/        (Parallel: one branch per
                                                  destination) --> SQS x N -->
    THIS Lambda --> the destination's S3 "sink" bucket (simulated NewRelic /
    SolarWinds ingestion endpoint).

One Lambda serves every destination. Each SQS message carries a "destination"
field (newrelic | solarwinds); the matching sink bucket name is read from the
SINK_<DEST>_BUCKET env vars. Writing a fresh object is what flips the
sink_<dest> probe GREEN (the health-checker lists the bucket for a recent key).

No VPC, no vendored deps: boto3 ships in the Lambda runtime and S3 is reached
over the public AWS endpoint.

Env:
  SINK_NEWRELIC_BUCKET     simulated NewRelic sink bucket
  SINK_SOLARWINDS_BUCKET   simulated SolarWinds sink bucket
"""
import datetime
import json
import logging
import os
import uuid

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_s3 = boto3.client("s3")


def _bucket_for(destination):
    key = "SINK_{}_BUCKET".format(destination.upper())
    return os.environ.get(key)


def _deliver(record_body):
    """Write one event to its destination sink bucket. Returns the S3 key."""
    try:
        payload = json.loads(record_body)
    except (ValueError, TypeError):
        payload = {"raw": record_body}

    destination = (payload.get("destination") or "unknown").lower()
    bucket = _bucket_for(destination)
    if not bucket:
        logger.error("no sink bucket configured for destination=%s", destination)
        return None

    now = datetime.datetime.now(datetime.timezone.utc)
    key = "incidents/{}/{}-{}.json".format(
        now.strftime("%Y/%m/%d"), now.strftime("%H%M%S"), uuid.uuid4().hex[:8]
    )

    enriched = {
        "destination": destination,
        "forwarded_at": now.isoformat(),
        "event": payload,
    }
    _s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(enriched).encode("utf-8"),
        ContentType="application/json",
    )
    logger.info("delivered event to %s/%s (destination=%s)", bucket, key, destination)
    return key


def handler(event, context):
    """SQS-triggered. Each record is one fanned-out branch for one destination."""
    delivered = []
    for record in event.get("Records", []):
        key = _deliver(record.get("body", "{}"))
        if key:
            delivered.append(key)
    return {"delivered": delivered, "count": len(delivered)}
