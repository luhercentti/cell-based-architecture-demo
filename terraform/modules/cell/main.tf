# ─────────────────────────────────────────────────────────────────────────────
# Cell Module — reusable, isolated unit of the data plane
#
# Every resource here is prefixed with cell_id. Instantiating this module
# twice produces two completely independent cells:
#
#   module "cell_001" { cell_id = "cell-001" ... }
#   module "cell_002" { cell_id = "cell-002" ... }
#
# Resources per cell:
#   - IAM Role (scoped to its own DynamoDB table)
#   - DynamoDB table (isolated data — no cross-cell queries)
#   - Lambda function (isolated compute)
#   - API Gateway HTTP API (isolated entry point)
#   - CloudWatch Log Group + Alarms (isolated observability)
# ─────────────────────────────────────────────────────────────────────────────

locals {
  name_prefix = "${var.project}-${var.environment}-${var.cell_id}"
}

# ── IAM ───────────────────────────────────────────────────────────────────────
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

resource "aws_iam_role" "cell" {
  name               = "${local.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "cell" {
  name = "cell-policy"
  role = aws_iam_role.cell.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to THIS cell's table only — cannot touch other cells' data
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.cell_data.arn
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

# ── DynamoDB (isolated per cell) ──────────────────────────────────────────────
# Each cell owns its data. No shared tables, no cross-cell reads.
# Schema: pk = TENANT#<id>, sk = ORDER#<uuid>

resource "aws_dynamodb_table" "cell_data" {
  name         = "${local.name_prefix}-data"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ── Lambda (isolated per cell) ────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "cell" {
  name              = "/aws/lambda/${local.name_prefix}"
  retention_in_days = 7
}

data "archive_file" "cell_zip" {
  type        = "zip"
  source_file = "${path.root}/lambda/cell/handler.py"
  output_path = "${path.root}/lambda/cell/${var.cell_id}.zip"
}

resource "aws_lambda_function" "cell" {
  function_name    = "${local.name_prefix}-handler"
  filename         = data.archive_file.cell_zip.output_path
  source_code_hash = data.archive_file.cell_zip.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  role             = aws_iam_role.cell.arn
  timeout          = 25

  environment {
    variables = {
      CELL_ID    = var.cell_id
      CELL_TABLE = aws_dynamodb_table.cell_data.name
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.cell]
}

# ── API Gateway (isolated per cell) ───────────────────────────────────────────
# The router knows this endpoint but clients never call it directly.

resource "aws_apigatewayv2_api" "cell" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "Cell-isolated API — blast radius limited to this cell's tenants"
}

resource "aws_apigatewayv2_integration" "cell" {
  api_id                 = aws_apigatewayv2_api.cell.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.cell.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "cell_default" {
  api_id    = aws_apigatewayv2_api.cell.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.cell.id}"
}

resource "aws_apigatewayv2_stage" "cell_stage" {
  api_id      = aws_apigatewayv2_api.cell.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "cell_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cell.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.cell.execution_arn}/*/*"
}

# ── CloudWatch Alarms (per cell — observability isolation) ────────────────────
# Alarms fire ONLY for this cell. A degraded cell-002 never triggers cell-001 alarms.

resource "aws_cloudwatch_metric_alarm" "cell_high_error_rate" {
  alarm_name          = "${local.name_prefix}-high-error-rate"
  alarm_description   = "Cell ${var.cell_id} error rate exceeded threshold — check blast radius (which tenants are affected)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.cell.function_name
  }

  alarm_actions = [var.alarm_sns_arn]
  ok_actions    = [var.alarm_sns_arn]
}

resource "aws_cloudwatch_metric_alarm" "cell_high_latency" {
  alarm_name          = "${local.name_prefix}-high-latency"
  alarm_description   = "Cell ${var.cell_id} P95 latency > 1000ms — cell may be degrading"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  extended_statistic  = "p95"
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  threshold           = 1000
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.cell.function_name
  }

  alarm_actions = [var.alarm_sns_arn]
}
