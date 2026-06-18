"""IO-108 report-generator -- Lambda handler.

Queries Aurora (via the CLUSTER endpoint) for order stats and writes a small
JSON report to s3://REPORTS_BUCKET/reports/<iso-timestamp>.json.

Packaged from app/lambda_build/ where pg8000 (pure Python) is vendored --
see reporting.tf.

Env: SECRET_ARN, DB_CLUSTER_ENDPOINT, DB_NAME, REPORTS_BUCKET.
"""
import datetime
import json
import logging
import os

import boto3
import pg8000.native

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    secret_arn = os.environ["SECRET_ARN"]
    db_host = os.environ["DB_CLUSTER_ENDPOINT"]
    db_name = os.environ["DB_NAME"]
    bucket = os.environ["REPORTS_BUCKET"]

    secret = boto3.client("secretsmanager").get_secret_value(SecretId=secret_arn)
    creds = json.loads(secret["SecretString"])

    conn = pg8000.native.Connection(
        creds["username"],
        host=db_host,
        database=db_name,
        password=creds["password"],
        timeout=10,
    )
    try:
        rows = conn.run("SELECT count(*), max(created_at) FROM orders")
    finally:
        conn.close()
    order_count, latest = rows[0]

    now = datetime.datetime.now(datetime.timezone.utc)
    report = {
        "generated_at": now.isoformat(),
        "order_count": order_count,
        "latest_order_at": latest.isoformat() if latest else None,
    }
    key = f"reports/{now.strftime('%Y-%m-%dT%H-%M-%SZ')}.json"

    boto3.client("s3").put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(report).encode("utf-8"),
        ContentType="application/json",
    )
    logger.info("wrote report s3://%s/%s (%s orders)", bucket, key, order_count)
    return {"report_key": key, "order_count": order_count}
