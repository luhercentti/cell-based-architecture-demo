"""
Cell Handler — Layer 3 (Data Plane)

This Lambda runs inside a cell. It:
  - Handles business logic (orders in this POC)
  - Reads/writes only to THIS cell's DynamoDB table
  - Never knows about other cells or other tenants' data
  - Includes cell_id in every response so you can verify routing

Key Cell-Based Architecture principle demonstrated here:
  - Complete data isolation: TENANT#acme data lives ONLY in cell-001's table
  - cell-002's table only contains TENANT#globex data
  - A DynamoDB failure in cell-002 cannot affect cell-001's reads/writes
"""

import json
import os
import uuid
from datetime import datetime, timezone
import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["CELL_TABLE"])
CELL_ID = os.environ["CELL_ID"]


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath", "/")
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    tenant_id = headers.get("x-tenant-id", "unknown")

    if path == "/health":
        return _health_check()
    elif path == "/orders" and method == "POST":
        return _create_order(event, tenant_id)
    elif path == "/orders" and method == "GET":
        return _list_orders(tenant_id)
    else:
        return _response(404, {
            "error": "Route not found",
            "path": path,
            "method": method,
            "cell_id": CELL_ID
        })


def _create_order(event, tenant_id):
    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _response(400, {"error": "Invalid JSON body", "cell_id": CELL_ID})

    order_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    # Data is stored with tenant scope inside this cell's isolated table.
    # Another cell's table has zero knowledge of these records.
    item = {
        "pk": f"TENANT#{tenant_id}",
        "sk": f"ORDER#{order_id}",
        "order_id": order_id,
        "tenant_id": tenant_id,
        "cell_id": CELL_ID,            # Recorded for audit / routing verification
        "product": body.get("product", "unknown"),
        "quantity": int(body.get("quantity", 1)),
        "status": "pending",
        "created_at": now
    }

    table.put_item(Item=item)

    return _response(201, {
        "order_id": order_id,
        "tenant_id": tenant_id,
        "cell_id": CELL_ID,            # Client can verify which cell served this
        "status": "pending",
        "created_at": now,
        "message": f"Order created. Served by {CELL_ID}."
    })


def _list_orders(tenant_id):
    # Query is scoped to this tenant inside this cell's table only
    result = table.query(
        KeyConditionExpression=Key("pk").eq(f"TENANT#{tenant_id}") &
                               Key("sk").begins_with("ORDER#")
    )
    orders = result.get("Items", [])
    return _response(200, {
        "orders": orders,
        "count": len(orders),
        "tenant_id": tenant_id,
        "served_by_cell": CELL_ID     # Key field: shows which cell has this tenant's data
    })


def _health_check():
    return _response(200, {
        "status": "healthy",
        "cell_id": CELL_ID,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "table": os.environ["CELL_TABLE"]
    })


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "x-cell-id": CELL_ID       # Always present so you know where the response came from
        },
        "body": json.dumps(body, default=str)
    }
