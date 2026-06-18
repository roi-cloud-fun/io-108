"""IO-108 orders-api -- minimal Flask + pg8000 service backed by Aurora PostgreSQL.

Runs in EKS (namespace `orders`, ServiceAccount `orders-api` with IRSA).
Deps (flask, pg8000, boto3) are pip-installed by the container command at
startup -- this file stays stdlib-importable until then.

Env: SECRET_ARN, DB_HOST (cluster endpoint), DB_NAME, REPORTS_BUCKET, PORT.
"""
import json
import logging
import os

import boto3
import pg8000.native
from flask import Flask, jsonify, request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("orders-api")

SECRET_ARN = os.environ["SECRET_ARN"]
DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ["DB_NAME"]
REPORTS_BUCKET = os.environ["REPORTS_BUCKET"]
PORT = int(os.environ.get("PORT", "8080"))


def _db_credentials():
    secret = boto3.client("secretsmanager").get_secret_value(SecretId=SECRET_ARN)
    creds = json.loads(secret["SecretString"])
    return creds["username"], creds["password"]


def _connect():
    user, password = _db_credentials()
    return pg8000.native.Connection(
        user, host=DB_HOST, database=DB_NAME, password=password, timeout=10
    )


def _init_schema():
    conn = _connect()
    try:
        conn.run(
            "CREATE TABLE IF NOT EXISTS orders ("
            "id serial primary key, item text, quantity int, "
            "created_at timestamptz default now())"
        )
        log.info("schema ready on %s/%s", DB_HOST, DB_NAME)
    finally:
        conn.close()


app = Flask(__name__)


@app.get("/health")
def health():
    try:
        conn = _connect()
        try:
            conn.run("SELECT 1")
        finally:
            conn.close()
        return jsonify(status="ok", database="connected")
    except Exception as exc:  # noqa: BLE001 -- health endpoint reports anything
        log.error("health check failed: %s", exc)
        return jsonify(status="error", detail=str(exc)), 503


@app.get("/orders")
def list_orders():
    conn = _connect()
    try:
        rows = conn.run(
            "SELECT id, item, quantity, created_at FROM orders "
            "ORDER BY created_at DESC LIMIT 20"
        )
    finally:
        conn.close()
    orders = [
        {"id": r[0], "item": r[1], "quantity": r[2], "created_at": r[3].isoformat()}
        for r in rows
    ]
    return jsonify(orders=orders, count=len(orders))


@app.post("/orders")
def create_order():
    body = request.get_json(silent=True) or {}
    item = body.get("item")
    quantity = body.get("quantity")
    if not item or not isinstance(quantity, int) or quantity < 1:
        return jsonify(error="body must be {\"item\": str, \"quantity\": int >= 1}"), 400
    conn = _connect()
    try:
        rows = conn.run(
            "INSERT INTO orders (item, quantity) VALUES (:item, :quantity) RETURNING id",
            item=item,
            quantity=quantity,
        )
    finally:
        conn.close()
    order_id = rows[0][0]
    log.info("created order %s: %s x%s", order_id, item, quantity)
    return jsonify(id=order_id, item=item, quantity=quantity), 201


@app.get("/reports")
def list_reports():
    try:
        resp = boto3.client("s3").list_objects_v2(
            Bucket=REPORTS_BUCKET, Prefix="reports/", MaxKeys=20
        )
        keys = [obj["Key"] for obj in resp.get("Contents", [])]
        return jsonify(bucket=REPORTS_BUCKET, reports=keys, count=len(keys))
    except Exception as exc:  # noqa: BLE001 -- Lab 1 breaks S3 access on purpose
        log.error("listing reports failed: %s", exc)
        return jsonify(error=str(exc)), 503


if __name__ == "__main__":
    _init_schema()
    app.run(host="0.0.0.0", port=PORT)
