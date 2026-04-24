# Cell-Based Architecture — Diagrams

## Diagram 1: The 4 Architecture Layers

```mermaid
graph TB
    Client(["👤 Client\n(any tenant)"])

    subgraph L1["Layer 1 — Global Entry"]
        APIGW_G["API Gateway\nhttps://xyz.execute-api.us-east-1.amazonaws.com\n(single URL for ALL tenants)"]
    end

    subgraph L2["Layer 2 — Control Plane"]
        direction LR
        ROUTER["🔀 Router Lambda\n(reads x-tenant-id)"]
        REGISTRY[("📋 Cell Registry\nDynamoDB\ntenant_id → cell_id\ntenant_id → cell_endpoint")]
    end

    subgraph L3["Layer 3 — Data Plane (Cells)"]
        direction LR
        subgraph CELL1["🟢 Cell 001"]
            APIGW1["API GW\ncell-001"]
            LAMBDA1["⚡ Lambda\ncell-001-handler"]
            DDB1[("🗄️ DynamoDB\ncell-001-data\n\nTENANT#acme/ORDER#...\nTENANT#initech/ORDER#...")]
            APIGW1 --> LAMBDA1 --> DDB1
        end
        subgraph CELL2["🔵 Cell 002"]
            APIGW2["API GW\ncell-002"]
            LAMBDA2["⚡ Lambda\ncell-002-handler"]
            DDB2[("🗄️ DynamoDB\ncell-002-data\n\nTENANT#globex/ORDER#...")]
            APIGW2 --> LAMBDA2 --> DDB2
        end
    end

    subgraph L4["Layer 4 — Observability (per cell)"]
        direction LR
        CW["📊 CloudWatch\nDashboard\n(section per cell)"]
        ALARMS["🔔 Alarms\ncell-001-high-error-rate\ncell-002-high-error-rate\ncell-001-high-latency\ncell-002-high-latency"]
        SNS["📣 SNS Topic\ncell-alerts"]
        CW --> ALARMS --> SNS
    end

    Client --> APIGW_G
    APIGW_G --> ROUTER
    ROUTER -- "1. lookup(tenant_id)" --> REGISTRY
    REGISTRY -- "2. cell_endpoint" --> ROUTER
    ROUTER -- "tenant-acme\ntenant-initech" --> APIGW1
    ROUTER -- "tenant-globex" --> APIGW2
    CELL1 -. "metrics" .-> CW
    CELL2 -. "metrics" .-> CW
    ROUTER -. "metrics" .-> CW
```

---

## Diagram 2: Blast Radius Isolation (Cell Failure)

Scenario: **cell-002 starts failing**. What happens?

```mermaid
graph LR
    T_ACME(["tenant-acme"])
    T_INIT(["tenant-initech"])
    T_GLOB(["tenant-globex"])

    ROUTER["🔀 Router"]

    subgraph CELL1["🟢 Cell 001 — HEALTHY"]
        direction TB
        L1["Lambda OK"]
        D1[("DynamoDB OK")]
        L1 --> D1
    end

    subgraph CELL2["🔴 Cell 002 — DEGRADED"]
        direction TB
        L2["Lambda ERROR"]
        D2[("DynamoDB\nThrottling")]
        L2 -. "fails" .-> D2
    end

    T_ACME -- "x-tenant-id: tenant-acme" --> ROUTER
    T_INIT -- "x-tenant-id: tenant-initech" --> ROUTER
    T_GLOB -- "x-tenant-id: tenant-globex" --> ROUTER

    ROUTER -- "✅ routes to cell-001" --> CELL1
    ROUTER -- "❌ routes to cell-002\n(blast radius contained here)" --> CELL2

    CELL1 --> OK(["✅ 200 OK\nOrders work normally"])
    CELL2 --> ERR(["❌ 502 Error\nOnly tenant-globex affected"])
```

> **Blast radius = ONLY the tenants assigned to cell-002**.
> tenant-acme and tenant-initech never see the error.

---

## Diagram 3: Cell Router Request Flow (Control Plane)

```mermaid
sequenceDiagram
    participant Client
    participant GlobalAPIG as API Gateway (Layer 1)
    participant Router as Router Lambda (Layer 2)
    participant Registry as Cell Registry DynamoDB
    participant CellAPIG as Cell API Gateway (Layer 3)
    participant CellLambda as Cell Lambda

    Client->>GlobalAPIG: POST /orders\nx-tenant-id: tenant-acme
    GlobalAPIG->>Router: invoke Lambda (payload v2)

    Router->>Registry: GetItem(tenant_id="tenant-acme")
    Registry-->>Router: { cell_id: "cell-001", cell_endpoint: "https://..." }

    Note over Router: Tenant found → active → forward

    Router->>CellAPIG: POST /orders (proxy)\nx-tenant-id: tenant-acme\nx-cell-id: cell-001

    CellAPIG->>CellLambda: invoke Lambda
    CellLambda->>CellLambda: write to DynamoDB cell-001-data
    CellLambda-->>CellAPIG: 201 { order_id, cell_id: "cell-001" }
    CellAPIG-->>Router: 201 response

    Router-->>GlobalAPIG: 201 response\nx-cell-id: cell-001\nx-routing-latency-ms: 45
    GlobalAPIG-->>Client: 201 { order_id, cell_id: "cell-001" }

    Note over Client: Client reads x-cell-id header\nto verify which cell served the request
```

---

## Diagram 4: How the Terraform Module Works (IaC)

```mermaid
graph TD
    subgraph TF["Terraform Root Module"]
        MAIN["main.tf"]
        CP["control_plane.tf\n(Registry + Router + Global APIGW)"]
        OBS["observability.tf\n(Dashboard + Alarms)"]

        MAIN -- "module cell_001\ncell_id=cell-001" --> MOD
        MAIN -- "module cell_002\ncell_id=cell-002" --> MOD

        subgraph MOD["modules/cell/ (reusable)"]
            direction TB
            IAM["IAM Role\n(scoped to cell table)"]
            DDB_M["DynamoDB Table"]
            LAMBDA_M["Lambda Function\nCELL_ID env var"]
            APIGW_M["API Gateway"]
            ALARM_M["CW Alarms\n(per cell)"]
        end
    end

    MAIN -- "aws_dynamodb_table_item\n(tenant → cell assignment)" --> CP

    MOD -- "outputs:\napi_endpoint\nlambda_function_name\ndynamodb_table_name" --> OBS
    MOD -- "outputs:\napi_endpoint" --> MAIN
```

> Adding a **new cell** is as simple as:
> ```hcl
> module "cell_003" {
>   source        = "./modules/cell"
>   cell_id       = "cell-003"
>   environment   = var.environment
>   project       = var.project
>   alarm_sns_arn = aws_sns_topic.cell_alerts.arn
> }
> ```

---

## Diagram 5: Observability Aligned to Cell-Based Architecture

```mermaid
graph TB
    subgraph OBS["Layer 4 — Observability Stack"]
        direction TB

        subgraph DASH["CloudWatch Dashboard"]
            R_INV["Router: Invocations"]
            R_ERR["Router: Errors"]
            R_LAT["Router: Latency P50/P95"]

            C1_INV["Cell-001: Invocations"]
            C1_ERR["Cell-001: Errors"]
            C1_LAT["Cell-001: Latency P50/P95"]
            C1_DDB["Cell-001: DynamoDB RCU/WCU"]

            C2_INV["Cell-002: Invocations"]
            C2_ERR["Cell-002: Errors"]
            C2_LAT["Cell-002: Latency P50/P95"]
            C2_DDB["Cell-002: DynamoDB RCU/WCU"]
        end

        subgraph ALARMS["CloudWatch Alarms (per cell)"]
            A1_ERR["⚠️ cell-001-high-error-rate\n> 5 errors / 60s"]
            A1_LAT["⚠️ cell-001-high-latency\nP95 > 1000ms"]
            A2_ERR["⚠️ cell-002-high-error-rate\n> 5 errors / 60s"]
            A2_LAT["⚠️ cell-002-high-latency\nP95 > 1000ms"]
        end

        subgraph XRAY["X-Ray Tracing"]
            TRACE["Full trace:\nRouter → Cell APIG → Cell Lambda"]
        end

        SNS_T["SNS Topic\ncell-alerts"]
    end

    A1_ERR --> SNS_T
    A1_LAT --> SNS_T
    A2_ERR --> SNS_T
    A2_LAT --> SNS_T

    NOTE["🔑 Key principle:\nEach alarm knows which cell it belongs to.\nA failure in cell-002 triggers\nONLY the cell-002 alarms.\nEngineering can identify\nthe blast radius in seconds."]
```

---

## Project Structure

```
cell-based-architecture-demo/
├── terraform/
│   ├── main.tf                  # Provider + instantiates cells + seeds tenants
│   ├── variables.tf             # aws_region, environment, project
│   ├── outputs.tf               # router_endpoint, test_commands
│   ├── control_plane.tf         # Cell Registry + Router Lambda + Global API GW
│   ├── observability.tf         # CloudWatch Dashboard + Alarms per cell
│   └── modules/
│       └── cell/                # Reusable module — 1 instance = 1 complete cell
│           ├── main.tf          # IAM + DynamoDB + Lambda + API GW + Alarms
│           ├── variables.tf     # cell_id, environment, project, alarm_sns_arn
│           └── outputs.tf       # api_endpoint, lambda_function_name, etc.
├── terraform/lambda/
│   ├── router/handler.py        # Control plane: lookup registry → proxy to cell
│   └── cell/handler.py          # Data plane: orders CRUD (isolated per cell)
├── docs/
│   └── architecture.md          # This file (Mermaid diagrams)
└── scripts/
    └── test.sh                  # Automated tests post-deploy
```
