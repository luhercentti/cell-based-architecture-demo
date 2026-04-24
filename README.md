# Cell-Based Architecture — POC

A real-world implementation of Cell-Based Architecture on AWS using Terraform. Use case: **multi-tenant SaaS e-commerce platform** (similar to Shopify).

---

## What is Cell-Based Architecture?

Cell-Based Architecture is a design pattern where the system is divided into **independent, isolated units called "cells"**. Each cell is a complete infrastructure stack that serves a subset of tenants.

The core principle is **blast radius isolation**:

> If cell-002 fails, **only the tenants assigned to cell-002 are affected**. Tenants in cell-001 continue operating normally, as if nothing happened.

This contrasts with a monolithic or shared multi-tenant architecture, where a database or server failure affects **all** tenants simultaneously.

```
Shared Architecture (traditional):           Cell-Based Architecture:

   All tenants                                  tenant-acme   tenant-initech
         ↓                                            ↓              ↓
   [ API Gateway ]   ← fails →               [ Cell 001 ]  ← fails only here
   [  Lambda   ]      all down               [ Cell 002 ]  ← stays healthy
   [ DynamoDB  ]                                    ↑
                                               tenant-globex
```

---

## The 4 Architecture Layers

### Layer 1 — Global Entry Point

A single public API Gateway that receives **all** requests from all tenants. Clients always use this URL, regardless of which cell their tenant is in.

```
https://xyz.execute-api.us-east-1.amazonaws.com
```

**Why does this matter?** The client knows nothing about cells. Their URL does not change when a tenant is migrated to a different cell. Routing is completely transparent.

---

### Layer 2 — Control Plane (Cell Router + Cell Registry)

The heart of the pattern. It has two components:

#### Cell Registry

A DynamoDB table that is the **single source of truth** for knowing which tenant lives in which cell:

| tenant_id | cell_id | cell_endpoint | status |
|-----------|---------|---------------|--------|
| tenant-acme | cell-001 | https://cell-001.execute-api... | active |
| tenant-initech | cell-001 | https://cell-001.execute-api... | active |
| tenant-globex | cell-002 | https://cell-002.execute-api... | active |

This table is the only place an entry is changed when a tenant is **migrated** or **assigned** to a new cell.

#### Cell Router

A Lambda that executes the following logic on every request:

```
1. Read the x-tenant-id header from the incoming request
2. GetItem(tenant_id) from Cell Registry → retrieve cell_endpoint
3. Proxy the request to that cell's endpoint
4. Return the cell's response to the client
```

The router never touches business data. Its only responsibility is routing.

---

### Layer 3 — Data Plane (The Cells)

Each cell is a **completely independent** stack:

```
Cell 001                          Cell 002
├── API Gateway (internal)        ├── API Gateway (internal)
├── Lambda Function               ├── Lambda Function
├── DynamoDB Table                ├── DynamoDB Table
│   ├── TENANT#acme/ORDER#...     │   └── TENANT#globex/ORDER#...
│   └── TENANT#initech/ORDER#...  └── IAM Role (scoped)
└── IAM Role (scoped)
```

**Isolation rules:**
- The cell-001 Lambda **only has permissions** over the cell-001 table
- No cross-cell queries. tenant-acme data is never in cell-002
- A DynamoDB throttle in cell-002 does not affect cell-001

In Terraform, a cell is a reusable module. Instantiating two cells is as simple as:

```hcl
module "cell_001" {
  source        = "./modules/cell"
  cell_id       = "cell-001"
  environment   = var.environment
  project       = var.project
  alarm_sns_arn = aws_sns_topic.cell_alerts.arn
}

module "cell_002" {
  source        = "./modules/cell"
  cell_id       = "cell-002"
  ...
}
```

---

### Layer 4 — Observability (Per Cell)

Every metric, alarm and log is **tagged to its cell**. The CloudWatch Dashboard has independent sections per cell:

- **Router**: total invocations, routing errors, P95 latency
- **Cell-001**: requests, errors, P50/P95 latency, DynamoDB RCU/WCU
- **Cell-002**: same metrics, completely independent

If cell-002 is red and cell-001 is green, the team knows within seconds what the blast radius is (which tenants are affected) without any investigation.

---

## Project Structure

```
cell-based-architecture-demo/
├── terraform/
│   ├── main.tf              → Instantiates cells + assigns tenants to cells
│   ├── variables.tf         → aws_region, environment, project
│   ├── outputs.tf           → router_endpoint, test_commands, dashboard URL
│   ├── control_plane.tf     → Layer 1 + Layer 2 (Registry + Router + Global API GW)
│   ├── observability.tf     → Layer 4 (Dashboard + Alarms per cell)
│   └── modules/
│       └── cell/            → Reusable module — 1 instance = 1 complete cell
│           ├── main.tf      → IAM + DynamoDB + Lambda + API GW + Alarms
│           ├── variables.tf → cell_id, environment, project, alarm_sns_arn
│           └── outputs.tf   → api_endpoint, lambda_function_name, dynamodb_table_name
├── terraform/lambda/
│   ├── router/handler.py    → Control plane: lookup registry → proxy to cell
│   └── cell/handler.py      → Data plane: orders CRUD, data isolated per cell
├── docs/
│   └── architecture.md      → 5 Mermaid diagrams
└── scripts/
    └── test.sh              → 7 automated tests post-deploy
```

---

## Initial Deployment

### Prerequisites

- Terraform >= 1.5
- AWS CLI configured (`aws configure`)
- AWS account with permissions to create Lambda, API GW, DynamoDB, IAM, CloudWatch

### Commands

```bash
cd terraform

# Copy the example variables file
cp terraform.tfvars.example terraform.tfvars
# Edit if you need to change the region or project name

terraform init
terraform plan    # Review what will be created
terraform apply   # Create all infrastructure (~2 minutes)

# Print the endpoint and ready-to-use test commands
terraform output
```

### What `terraform apply` creates

| Resource | Count | Purpose |
|----------|-------|---------|
| API Gateway | 3 | 1 global (Layer 1) + 1 per cell (Layer 3) |
| Lambda | 3 | 1 router (Layer 2) + 1 per cell (Layer 3) |
| DynamoDB | 3 | 1 cell registry (Layer 2) + 1 per cell (Layer 3) |
| IAM Roles | 3 | 1 per Lambda, scoped to its own resource |
| CloudWatch Alarms | 4 | 2 per cell (error rate + latency) |
| CloudWatch Dashboard | 1 | All metrics organized by layer/cell |
| SNS Topic | 1 | Alarm notifications |

---

## How to Onboard a New Tenant

Onboarding a tenant involves **two decisions**:

1. Does it go into an existing cell that has available capacity?
2. Does it need its own new cell (large tenant, premium SLA, full isolation)?

### Option A — Assign to an Existing Cell

If `cell-001` has capacity, simply register the tenant in the Cell Registry:

**Step 1:** Add the entry in `terraform/main.tf`:

```hcl
resource "aws_dynamodb_table_item" "tenant_nuevocliente" {
  table_name = aws_dynamodb_table.cell_registry.name
  hash_key   = aws_dynamodb_table.cell_registry.hash_key

  item = jsonencode({
    tenant_id     = { S = "tenant-nuevocliente" }
    cell_id       = { S = "cell-001" }
    cell_endpoint = { S = module.cell_001.api_endpoint }
    status        = { S = "active" }
    assigned_at   = { S = "2026-04-24T00:00:00Z" }
  })
}
```

**Step 2:** Apply the change:

```bash
terraform apply -target=aws_dynamodb_table_item.tenant_nuevocliente
```

**Result:** Within seconds, `tenant-nuevocliente` can send requests to the router and will be directed to `cell-001`. No changes were made to the cell infrastructure itself.

---

### Option B — Create a New Cell for the Tenant

When a tenant requires **full isolation** (due to SLA, compliance, traffic volume, or simply because cell-001 and cell-002 are at their capacity limit).

**Step 1:** Declare the new cell in `terraform/main.tf`:

```hcl
module "cell_003" {
  source        = "./modules/cell"
  cell_id       = "cell-003"
  environment   = var.environment
  project       = var.project
  alarm_sns_arn = aws_sns_topic.cell_alerts.arn
}
```

**Step 2:** Register the tenant pointing to the new cell:

```hcl
resource "aws_dynamodb_table_item" "tenant_enterprise" {
  table_name = aws_dynamodb_table.cell_registry.name
  hash_key   = aws_dynamodb_table.cell_registry.hash_key

  item = jsonencode({
    tenant_id     = { S = "tenant-enterprise" }
    cell_id       = { S = "cell-003" }
    cell_endpoint = { S = module.cell_003.api_endpoint }
    status        = { S = "active" }
    assigned_at   = { S = "2026-04-24T00:00:00Z" }
  })
}
```

**Step 3:** Also add cell-003 metrics to the dashboard in `observability.tf` (copy the cell-002 block and change the cell_id).

**Step 4:** Apply:

```bash
terraform plan   # You will see only cell-003 resources being created; cell-001/002 are untouched
terraform apply
```

**Result:** A completely new cell with its own API GW, Lambda, DynamoDB and alarms. `tenant-enterprise` has **zero** shared resources with other tenants.

---

## How to Migrate a Tenant Between Cells

Scenario: `tenant-acme` has grown significantly and you want to move it from `cell-001` to a new `cell-004`.

**Step 1:** Create `cell-004` (same as Option B, without assigning the tenant yet).

**Step 2:** Migrate `tenant-acme` data from DynamoDB `cell-001-data` to `cell-004-data` (offline migration script or using DynamoDB Streams).

**Step 3:** Update the Cell Registry to point to the new endpoint:

```hcl
resource "aws_dynamodb_table_item" "tenant_acme" {
  item = jsonencode({
    tenant_id     = { S = "tenant-acme" }
    cell_id       = { S = "cell-004" }          # ← cambio aquí
    cell_endpoint = { S = module.cell_004.api_endpoint }
    status        = { S = "active" }
    assigned_at   = { S = "2026-04-24T00:00:00Z" }
  })
}
```

**Step 4:** `terraform apply`. From that point on, all new requests from `tenant-acme` go to `cell-004`. The router performs the lookup on every request, so the switch is **immediate**.

---

## Post-Deploy Tests

```bash
# Run the full test suite (7 tests)
cd scripts && chmod +x test.sh && ./test.sh
```

What each test validates:

| Test | Concept validated |
|------|-------------------|
| 1 | tenant-acme → routed to cell-001 (201 with `cell_id: "cell-001"`) |
| 2 | tenant-globex → routed to cell-002 (201 with `cell_id: "cell-002"`) |
| 3 | tenant-initech → routed to cell-001 (same cell as acme) |
| 4 | tenant-unknown → 404 from router (never reaches any cell) |
| 5 | Missing x-tenant-id header → 400 (router validation) |
| 6 | Health check shows which cell responds for each tenant |
| 7 | Data fully isolated: cell-001 DynamoDB ≠ cell-002 DynamoDB |

You can also use the curl commands directly:

```bash
ROUTER_URL=$(cd terraform && terraform output -raw router_endpoint)

# Create an order for tenant-acme (will go to cell-001)
curl -s -X POST $ROUTER_URL/orders \
  -H "x-tenant-id: tenant-acme" \
  -H "Content-Type: application/json" \
  -d '{"product":"laptop","quantity":1}' | jq .

# Note the "cell_id" field in the response — confirms which cell served the request
```

---

## Diagnostic Headers

The router adds headers to every response so you can verify routing without opening the AWS console:

| Header | Example value | What it indicates |
|--------|---------------|-------------------|
| `x-cell-id` | `cell-001` | Which cell processed the request |
| `x-tenant-id` | `tenant-acme` | The tenant that made the request |
| `x-routing-latency-ms` | `42` | Time spent by the router alone (registry lookup + proxy) |

---

## Observability

After deploying, the CloudWatch Dashboard is accessible at:

```bash
terraform -chdir=terraform output -raw cloudwatch_dashboard_url
```

**What to observe to validate the pattern:**

1. Generate traffic using the test script
2. Open the dashboard — you will see metrics separated by cell
3. Notice that the cell-001 and cell-002 sections are **completely independent**
4. Alarms are configured per cell: if cell-002 exceeds 5 errors/min, **only** the cell-002 alarm fires

---

## Clean Up

```bash
cd terraform && terraform destroy
```

This removes **all** infrastructure created by this POC (no recurring costs once destroyed).

---

## FAQ

**How many tenants per cell?**
It depends on the expected load per tenant. In this POC there is no limit. In production, cell capacity is monitored (CPU, throttles, latency) and tenants are migrated when a cell approaches its limit.

**What if the Cell Router fails?**
The router is the single point of failure of the control plane. In production this is mitigated with: Lambda reserved concurrency, DynamoDB DAX (registry cache), and circuit breakers. Optionally, premium clients can be given their cell endpoint directly to bypass the router in an emergency.

**Does the router add latency?**
Yes. In this POC the router performs an HTTP proxy that adds ~20-80ms. In production this can be optimized with: in-memory registry cache (short TTL), VPC endpoints for DynamoDB, or using API GW with a direct DynamoDB integration for the lookup.

**Can I deploy cells in different AWS regions?**
Yes. That is a natural extension of the pattern: `cell-us-east-001`, `cell-eu-west-001`. The Cell Registry simply stores the full endpoint URL (which includes the region). This is how geographic isolation is achieved on top of blast radius isolation.
