output "api_endpoint" {
  description = "HTTP API endpoint for this cell (used by router, not by clients)"
  value       = aws_apigatewayv2_stage.cell_stage.invoke_url
}

output "cell_id" {
  description = "The cell identifier"
  value       = var.cell_id
}

output "lambda_function_name" {
  description = "Lambda function name — use as dimension in CloudWatch metrics"
  value       = aws_lambda_function.cell.function_name
}

output "dynamodb_table_name" {
  description = "DynamoDB table name — scoped to this cell only"
  value       = aws_dynamodb_table.cell_data.name
}
