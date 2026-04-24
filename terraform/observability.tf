# ─────────────────────────────────────────────────────────────────────────────
# Layer 4: Observability — aligned to Cell-Based Architecture
#
# Key principle: every metric, alarm, and log is scoped to a specific cell.
# This lets you:
#   - Detect a degraded cell without noise from healthy cells
#   - Correlate issues to blast radius (which tenants are affected)
#   - Make routing decisions based on cell health
# ─────────────────────────────────────────────────────────────────────────────

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
# Organized in sections: Global Entry → Router → Cell-001 → Cell-002
# Each section is independent — a red cell doesn't pollute others.

resource "aws_cloudwatch_dashboard" "cell_based" {
  dashboard_name = "${var.project}-${var.environment}-overview"

  dashboard_body = jsonencode({
    widgets = [

      # ── Header ──────────────────────────────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = "# Cell-Based Architecture — POC Dashboard\n\n**Blast radius principle**: each cell is independently observable. A degraded cell-002 shows errors ONLY in the Cell-002 section — cell-001 remains green.\n\n| Cell | Tenants | Status |\n|------|---------|--------|\n| cell-001 | tenant-acme, tenant-initech | Active |\n| cell-002 | tenant-globex | Active |"
        }
      },

      # ── Layer 1 + 2: Router metrics ─────────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 3
        width  = 24
        height = 1
        properties = {
          markdown = "## Layer 1 + 2 — Global Entry & Cell Router"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 8
        height = 6
        properties = {
          title   = "Router: Total Requests (all tenants)"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.router.function_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 4
        width  = 8
        height = 6
        properties = {
          title   = "Router: Errors (unroutable / 5xx)"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.router.function_name, { "color" = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 4
        width  = 8
        height = 6
        properties = {
          title   = "Router: Routing Latency (P50 / P95)"
          view    = "timeSeries"
          period  = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.router.function_name, { "stat" = "p50", "label" = "P50" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.router.function_name, { "stat" = "p95", "label" = "P95", "color" = "#ff7f0e" }]
          ]
        }
      },

      # ── Cell-001 ─────────────────────────────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 10
        width  = 24
        height = 1
        properties = {
          markdown = "## Layer 3 — Cell 001 | Tenants: tenant-acme, tenant-initech"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 11
        width  = 8
        height = 6
        properties = {
          title   = "Cell-001: Requests"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", module.cell_001.lambda_function_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 11
        width  = 8
        height = 6
        properties = {
          title   = "Cell-001: Errors"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", module.cell_001.lambda_function_name, { "color" = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 11
        width  = 8
        height = 6
        properties = {
          title   = "Cell-001: Latency P50 / P95"
          view    = "timeSeries"
          period  = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", module.cell_001.lambda_function_name, { "stat" = "p50", "label" = "P50" }],
            ["AWS/Lambda", "Duration", "FunctionName", module.cell_001.lambda_function_name, { "stat" = "p95", "label" = "P95", "color" = "#ff7f0e" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 17
        width  = 12
        height = 6
        properties = {
          title   = "Cell-001: DynamoDB Consumed RCU/WCU"
          view    = "timeSeries"
          period  = 60
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", module.cell_001.dynamodb_table_name, { "stat" = "Sum", "label" = "RCU" }],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", module.cell_001.dynamodb_table_name, { "stat" = "Sum", "label" = "WCU" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 17
        width  = 12
        height = 6
        properties = {
          title   = "Cell-001: Throttles (capacity pressure)"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Throttles", "FunctionName", module.cell_001.lambda_function_name, { "color" = "#9467bd" }]
          ]
        }
      },

      # ── Cell-002 ─────────────────────────────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 23
        width  = 24
        height = 1
        properties = {
          markdown = "## Layer 3 — Cell 002 | Tenants: tenant-globex"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 24
        width  = 8
        height = 6
        properties = {
          title   = "Cell-002: Requests"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", module.cell_002.lambda_function_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 24
        width  = 8
        height = 6
        properties = {
          title   = "Cell-002: Errors"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", module.cell_002.lambda_function_name, { "color" = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 24
        width  = 8
        height = 6
        properties = {
          title   = "Cell-002: Latency P50 / P95"
          view    = "timeSeries"
          period  = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", module.cell_002.lambda_function_name, { "stat" = "p50", "label" = "P50" }],
            ["AWS/Lambda", "Duration", "FunctionName", module.cell_002.lambda_function_name, { "stat" = "p95", "label" = "P95", "color" = "#ff7f0e" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 30
        width  = 12
        height = 6
        properties = {
          title   = "Cell-002: DynamoDB Consumed RCU/WCU"
          view    = "timeSeries"
          period  = 60
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", module.cell_002.dynamodb_table_name, { "stat" = "Sum", "label" = "RCU" }],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", module.cell_002.dynamodb_table_name, { "stat" = "Sum", "label" = "WCU" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 30
        width  = 12
        height = 6
        properties = {
          title   = "Cell-002: Throttles (capacity pressure)"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/Lambda", "Throttles", "FunctionName", module.cell_002.lambda_function_name, { "color" = "#9467bd" }]
          ]
        }
      }

    ]
  })
}
