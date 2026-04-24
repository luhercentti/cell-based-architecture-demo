output "router_endpoint" {
  description = "Layer 1 — Global entry point. Send ALL requests here with x-tenant-id header."
  value       = aws_apigatewayv2_stage.global_stage.invoke_url
}

output "cell_001_endpoint" {
  description = "Direct cell-001 URL (for debugging/observability only — not for clients)"
  value       = module.cell_001.api_endpoint
}

output "cell_002_endpoint" {
  description = "Direct cell-002 URL (for debugging/observability only — not for clients)"
  value       = module.cell_002.api_endpoint
}

output "cell_registry_table" {
  description = "DynamoDB table — tenant-to-cell assignments (control plane)"
  value       = aws_dynamodb_table.cell_registry.name
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch Dashboard — observability per cell"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${var.project}-${var.environment}-overview"
}

output "test_commands" {
  description = "Ready-to-use curl commands to test cell routing"
  value       = <<-EOT

    ROUTER_URL="${aws_apigatewayv2_stage.global_stage.invoke_url}"

    # tenant-acme → routed to cell-001
    curl -s -X POST $ROUTER_URL/orders \
      -H "x-tenant-id: tenant-acme" \
      -H "Content-Type: application/json" \
      -d '{"product":"laptop","quantity":1}' | jq .

    # tenant-globex → routed to cell-002 (different isolated cell)
    curl -s -X POST $ROUTER_URL/orders \
      -H "x-tenant-id: tenant-globex" \
      -H "Content-Type: application/json" \
      -d '{"product":"chair","quantity":3}' | jq .

    # tenant-initech → routed to cell-001 (same cell as acme, different tenant)
    curl -s -X GET $ROUTER_URL/orders \
      -H "x-tenant-id: tenant-initech" | jq .

    # Unknown tenant → 404 from router (never reaches any cell)
    curl -s -X POST $ROUTER_URL/orders \
      -H "x-tenant-id: tenant-unknown" \
      -d '{}' | jq .

    # Missing header → 400 from router
    curl -s -X POST $ROUTER_URL/orders \
      -H "Content-Type: application/json" \
      -d '{"product":"mouse"}' | jq .

    # Health check (observe which cell responds)
    curl -s $ROUTER_URL/health \
      -H "x-tenant-id: tenant-acme" | jq .
  EOT
}
