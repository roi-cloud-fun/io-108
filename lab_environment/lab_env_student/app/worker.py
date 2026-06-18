"""IO-108 orders-worker -- stdlib-only traffic generator.

POSTs a random order to the orders-api Service every 30 seconds and logs the
result to stdout. No pip dependencies, so it starts instantly.
"""
import json
import random
import time
import urllib.error
import urllib.request

API_URL = "http://orders-api:8080/orders"
ITEMS = ["widget", "gadget", "sprocket", "flange", "gizmo", "doohickey"]
INTERVAL_SECONDS = 30


def post_order():
    payload = json.dumps(
        {"item": random.choice(ITEMS), "quantity": random.randint(1, 5)}
    ).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status, resp.read().decode("utf-8")


def main():
    print(f"orders-worker started -- posting to {API_URL} every {INTERVAL_SECONDS}s", flush=True)
    while True:
        try:
            status, body = post_order()
            print(f"POST /orders -> {status}: {body.strip()}", flush=True)
        except urllib.error.HTTPError as exc:
            print(f"POST /orders -> HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')}", flush=True)
        except Exception as exc:  # noqa: BLE001 -- keep generating traffic regardless
            print(f"POST /orders FAILED: {exc}", flush=True)
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
