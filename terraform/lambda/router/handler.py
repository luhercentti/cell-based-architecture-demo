"""
Cell Router — Layer 2 (Control Plane)

Responsibilities:
  1. Extract tenant_id from incoming request header
  2. Look up the Cell Registry (DynamoDB) to find which cell owns this tenant
  3. Proxy the request to that cell's API Gateway endpoint
  4. Return the cell's response to the client

The client always calls a single global URL. Cell routing is transparent.

Key Cell-Based Architecture principle demonstrated here:
  - If tenant-globex's cell (cell-002) is down, requests for tenant-acme
    (cell-001) are completely unaffected — they never touch cell-002.
"""

import json
import os
import urllib.request
import urllib.error
import boto3
from datetime import datetime, timezone

dynamodb = boto3.resource("dynamodb")
registry_table = dynamodb.Table(os.environ["CELL_REGISTRY_TABLE"])


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    tenant_id = headers.get("x-tenant-id")

    # ── Validate input ──────────────────────────────────────────────────────
    if not tenant_id:
        return _response(400, {
            "error": "Missing required header: x-tenant-id",
            "hint": "All requests must identify the tenant via x-tenant-id header"
        })

    # ── Control Plane lookup: which cell owns this tenant? ──────────────────
    result = registry_table.get_item(Key={"tenant_id": tenant_id})
    item = result.get("Item")

    if not item:
        return _response(404, {
            "error": f"Tenant '{tenant_id}' not found in cell registry",
            "hint": "Tenant must be assigned to a cell before sending requests"
        })

    if item.get("status") != "active":
        return _response(503, {
            "error": f"Cell for tenant '{tenant_id}' is not active",
            "cell_id": item.get("cell_id"),
            "status": item.get("status")
        })

    cell_id = item["cell_id"]
    cell_endpoint = item["cell_endpoint"].rstrip("/")

    # ── Forward request to the cell (Data Plane) ────────────────────────────
    path = event.get("rawPath", "/")
    query_string = event.get("rawQueryString", "")
    url = f"{cell_endpoint}{path}"
    if query_string:
        url = f"{url}?{query_string}"

    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    body = event.get("body", "")
    encoded_body = body.encode("utf-8") if isinstance(body, str) and body else None

    req = urllib.request.Request(url, data=encoded_body, method=method)
    req.add_header("x-tenant-id", tenant_id)
    req.add_header("x-cell-id", cell_id)
    req.add_header("x-routed-by", "cell-router")
    if encoded_body:
        req.add_header("Content-Type", headers.get("content-type", "application/json"))

    try:
        start = datetime.now(timezone.utc)
        with urllib.request.urlopen(req, timeout=24) as resp:
            routing_ms = int((datetime.now(timezone.utc) - start).total_seconds() * 1000)
            cell_body = resp.read().decode("utf-8")
            return {
                "statusCode": resp.status,
                "headers": {
                    "Content-Type": "application/json",
                    "x-cell-id": cell_id,         # Tells client which cell served the request
                    "x-tenant-id": tenant_id,
                    "x-routing-latency-ms": str(routing_ms)
                },
                "body": cell_body
            }

    except urllib.error.HTTPError as e:
        # Cell returned an error — this is blast-radius contained to this cell
        cell_body = e.read().decode("utf-8")
        return {
            "statusCode": e.code,
            "headers": {
                "Content-Type": "application/json",
                "x-cell-id": cell_id
            },
            "body": cell_body
        }

    except Exception as e:
        # Cell unreachable — only tenants in this cell are affected
        return _response(502, {
            "error": f"Cell '{cell_id}' is unreachable",
            "detail": str(e),
            "affected_tenant": tenant_id,
            "blast_radius_note": f"Only tenants assigned to {cell_id} are affected"
        })


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body)
    }
