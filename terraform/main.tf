terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Architecture = "cell-based"
    }
  }
}

# Data sources used across the module
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 3: Data Plane — Cells (each is fully isolated)
#
# Key concept: instantiating the same module N times creates N independent cells.
# A blast radius is limited to the tenants assigned to that cell.
# ─────────────────────────────────────────────────────────────────────────────

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
  environment   = var.environment
  project       = var.project
  alarm_sns_arn = aws_sns_topic.cell_alerts.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# Tenant → Cell assignments (seed data in the Cell Registry)
#
# In production, this mapping is managed dynamically by a cell-assignment service.
# For this POC, we pre-assign tenants at deploy time.
#
#   tenant-acme    → cell-001
#   tenant-initech → cell-001  (two tenants sharing one cell)
#   tenant-globex  → cell-002
#
# Blast radius demo: if cell-002 degrades, only tenant-globex is affected.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "tenant_acme" {
  table_name = aws_dynamodb_table.cell_registry.name
  hash_key   = aws_dynamodb_table.cell_registry.hash_key

  item = jsonencode({
    tenant_id     = { S = "tenant-acme" }
    cell_id       = { S = "cell-001" }
    cell_endpoint = { S = module.cell_001.api_endpoint }
    status        = { S = "active" }
    assigned_at   = { S = "2026-04-24T00:00:00Z" }
  })
}

resource "aws_dynamodb_table_item" "tenant_initech" {
  table_name = aws_dynamodb_table.cell_registry.name
  hash_key   = aws_dynamodb_table.cell_registry.hash_key

  item = jsonencode({
    tenant_id     = { S = "tenant-initech" }
    cell_id       = { S = "cell-001" }
    cell_endpoint = { S = module.cell_001.api_endpoint }
    status        = { S = "active" }
    assigned_at   = { S = "2026-04-24T00:00:00Z" }
  })
}

resource "aws_dynamodb_table_item" "tenant_globex" {
  table_name = aws_dynamodb_table.cell_registry.name
  hash_key   = aws_dynamodb_table.cell_registry.hash_key

  item = jsonencode({
    tenant_id     = { S = "tenant-globex" }
    cell_id       = { S = "cell-002" }
    cell_endpoint = { S = module.cell_002.api_endpoint }
    status        = { S = "active" }
    assigned_at   = { S = "2026-04-24T00:00:00Z" }
  })
}
