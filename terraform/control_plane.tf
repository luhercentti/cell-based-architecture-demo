# ─────────────────────────────────────────────────────────────────────────────
# Layer 2: Control Plane
#
# The control plane has two responsibilities:
#   1. CELL REGISTRY  — tracks which tenant lives in which cell
#   2. CELL ROUTER    — receives all requests, looks up the cell, forwards them
#
# The router is the only public surface. Cell endpoints are internal.
# ─────────────────────────────────────────────────────────────────────────────

# ── Cell Registry ────────────────────────────────────────────────────────────
# Single source of truth for tenant→cell assignments.
# Schema: { tenant_id (PK), cell_id, cell_endpoint, status }

resource "aws_dynamodb_table" "cell_registry" {
  name         = "${var.project}-${var.environment}-cell-registry"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ── SNS Topic for cell alerts ─────────────────────────────────────────────────
resource "aws_sns_topic" "cell_alerts" {
  name = "${var.project}-${var.environment}-cell-alerts"
}

# ── IAM Role for Router Lambda ────────────────────────────────────────────────
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "router" {
  name               = "${var.project}-${var.environment}-router-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "router" {
  name = "router-policy"
  role = aws_iam_role.router.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read which cell a tenant belongs to
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.cell_registry.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        # Publish routing metrics (unrouted_requests, routing_latency)
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect  = "Allow"
        Action  = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# ── Router Lambda ─────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "router" {
  name              = "/aws/lambda/${var.project}-${var.environment}-router"
  retention_in_days = 7
}

data "archive_file" "router_zip" {
  type        = "zip"
  source_file = "${path.root}/lambda/router/handler.py"
  output_path = "${path.root}/lambda/router/handler.zip"
}

resource "aws_lambda_function" "router" {
  function_name    = "${var.project}-${var.environment}-router"
  filename         = data.archive_file.router_zip.output_path
  source_code_hash = data.archive_file.router_zip.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  role             = aws_iam_role.router.arn
  timeout          = 29  # Must be < API GW 30s timeout

  environment {
    variables = {
      CELL_REGISTRY_TABLE = aws_dynamodb_table.cell_registry.name
      POWERTOOLS_SERVICE_NAME = "cell-router"
    }
  }

  tracing_config {
    mode = "Active"  # X-Ray tracing per request
  }

  depends_on = [aws_cloudwatch_log_group.router]
}

# ── Layer 1: Global Entry — API Gateway ──────────────────────────────────────
# Single public URL. All tenants send requests here.
# The router Lambda handles routing transparently.

resource "aws_apigatewayv2_api" "global" {
  name          = "${var.project}-${var.environment}-global-entry"
  protocol_type = "HTTP"
  description   = "Layer 1: Global Entry Point — single URL for all tenants"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Content-Type", "x-tenant-id"]
  }
}

resource "aws_apigatewayv2_integration" "router" {
  api_id                 = aws_apigatewayv2_api.global.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.router.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "catch_all" {
  api_id    = aws_apigatewayv2_api.global.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_stage" "global_stage" {
  api_id      = aws_apigatewayv2_api.global.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "global_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.global.execution_arn}/*/*"
}
