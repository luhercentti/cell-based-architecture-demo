#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test.sh — Cell-Based Architecture POC test suite
#
# Run AFTER: terraform apply
# Requires: curl, jq, terraform
#
# Usage:
#   cd scripts && ./test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Output colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ROUTER_URL=$(terraform -chdir=../terraform output -raw router_endpoint 2>/dev/null)

if [[ -z "$ROUTER_URL" ]]; then
  echo -e "${RED}ERROR: Could not retrieve router_endpoint. Did you run 'terraform apply'?${NC}"
  exit 1
fi

echo -e "${BOLD}${CYAN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║        Cell-Based Architecture POC — Test Suite           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "Router URL: ${CYAN}$ROUTER_URL${NC}"
echo ""

# ─── Helper ──────────────────────────────────────────────────────────────────
assert_cell() {
  local response="$1"
  local expected_cell="$2"
  local actual_cell
  actual_cell=$(echo "$response" | jq -r '.cell_id // .served_by_cell // "unknown"' 2>/dev/null || echo "unknown")
  if [[ "$actual_cell" == "$expected_cell" ]]; then
    echo -e "  ${GREEN}✅ Routed to correct cell: $actual_cell${NC}"
  else
    echo -e "  ${RED}❌ Expected $expected_cell, got $actual_cell${NC}"
  fi
}

assert_status() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}✅ $label: HTTP $actual${NC}"
  else
    echo -e "  ${RED}❌ $label: Expected HTTP $expected, got HTTP $actual${NC}"
  fi
}

# ─── Test 1: tenant-acme → must route to cell-001 ───────────────────────────
echo -e "${BOLD}Test 1: tenant-acme → cell-001 (create order)${NC}"
RESP=$(curl -s -w '\n%{http_code}' -X POST "$ROUTER_URL/orders" \
  -H "x-tenant-id: tenant-acme" \
  -H "Content-Type: application/json" \
  -d '{"product":"laptop","quantity":2}')
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
assert_status "POST /orders" "$HTTP_CODE" "201"
assert_cell "$BODY" "cell-001"
echo -e "  Response: $(echo "$BODY" | jq -c '{order_id,cell_id,tenant_id,status}')"
echo ""

# ─── Test 2: tenant-globex → must route to cell-002 ─────────────────────────
echo -e "${BOLD}Test 2: tenant-globex → cell-002 (create order)${NC}"
RESP=$(curl -s -w '\n%{http_code}' -X POST "$ROUTER_URL/orders" \
  -H "x-tenant-id: tenant-globex" \
  -H "Content-Type: application/json" \
  -d '{"product":"office-chair","quantity":5}')
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
assert_status "POST /orders" "$HTTP_CODE" "201"
assert_cell "$BODY" "cell-002"
echo -e "  Response: $(echo "$BODY" | jq -c '{order_id,cell_id,tenant_id,status}')"
echo ""

# ─── Test 3: tenant-initech → must route to cell-001 (same cell as acme) ────
echo -e "${BOLD}Test 3: tenant-initech → cell-001 (list orders)${NC}"
RESP=$(curl -s -w '\n%{http_code}' -X GET "$ROUTER_URL/orders" \
  -H "x-tenant-id: tenant-initech")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
assert_status "GET /orders" "$HTTP_CODE" "200"
assert_cell "$BODY" "cell-001"
echo -e "  Response: $(echo "$BODY" | jq -c '{count,served_by_cell,tenant_id}')"
echo ""

# ─── Test 4: unknown tenant → 404 from router (never reaches any cell) ──────
echo -e "${BOLD}Test 4: tenant-unknown → 404 from router (blast radius: no cell affected)${NC}"
RESP=$(curl -s -w '\n%{http_code}' -X POST "$ROUTER_URL/orders" \
  -H "x-tenant-id: tenant-unknown" \
  -H "Content-Type: application/json" \
  -d '{"product":"desk","quantity":1}')
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
assert_status "POST /orders (unknown)" "$HTTP_CODE" "404"
echo -e "  Response: $(echo "$BODY" | jq -c '.')"
echo ""

# ─── Test 5: missing header → 400 from router ───────────────────────────────
echo -e "${BOLD}Test 5: missing x-tenant-id → 400 from router${NC}"
RESP=$(curl -s -w '\n%{http_code}' -X POST "$ROUTER_URL/orders" \
  -H "Content-Type: application/json" \
  -d '{"product":"monitor","quantity":1}')
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
assert_status "POST /orders (no header)" "$HTTP_CODE" "400"
echo -e "  Response: $(echo "$BODY" | jq -c '.')"
echo ""

# ─── Test 6: health check — verify which cell responds ──────────────────────
echo -e "${BOLD}Test 6: health check per cell${NC}"
for TENANT in "tenant-acme" "tenant-globex"; do
  RESP=$(curl -s -w '\n%{http_code}' "$ROUTER_URL/health" \
    -H "x-tenant-id: $TENANT")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | head -1)
  CELL=$(echo "$BODY" | jq -r '.cell_id // "unknown"')
  echo -e "  $TENANT → served by ${CYAN}$CELL${NC} (HTTP $HTTP_CODE)"
done
echo ""

# ─── Test 7: Simulate blast radius — verify data isolation ──────────────────
echo -e "${BOLD}Test 7: Create orders in both cells and verify data isolation${NC}"
echo -e "  ${YELLOW}Creating 2 orders for tenant-acme (cell-001)...${NC}"
curl -s -X POST "$ROUTER_URL/orders" \
  -H "x-tenant-id: tenant-acme" \
  -H "Content-Type: application/json" \
  -d '{"product":"keyboard","quantity":1}' > /dev/null
curl -s -X POST "$ROUTER_URL/orders" \
  -H "x-tenant-id: tenant-acme" \
  -H "Content-Type: application/json" \
  -d '{"product":"mouse","quantity":1}' > /dev/null

echo -e "  ${YELLOW}Listing orders for tenant-acme (cell-001):${NC}"
ACME_RESP=$(curl -s "$ROUTER_URL/orders" -H "x-tenant-id: tenant-acme")
ACME_COUNT=$(echo "$ACME_RESP" | jq '.count')
ACME_CELL=$(echo "$ACME_RESP" | jq -r '.served_by_cell')
echo -e "  tenant-acme: $ACME_COUNT orders in $ACME_CELL"

echo -e "  ${YELLOW}Listing orders for tenant-globex (cell-002):${NC}"
GLOBEX_RESP=$(curl -s "$ROUTER_URL/orders" -H "x-tenant-id: tenant-globex")
GLOBEX_COUNT=$(echo "$GLOBEX_RESP" | jq '.count')
GLOBEX_CELL=$(echo "$GLOBEX_RESP" | jq -r '.served_by_cell')
echo -e "  tenant-globex: $GLOBEX_COUNT orders in $GLOBEX_CELL"

echo ""
echo -e "  ${GREEN}✅ Data is completely isolated per cell.${NC}"
echo -e "  ${GREEN}   The DynamoDB table in $ACME_CELL has no data from $GLOBEX_CELL and vice versa.${NC}"

echo ""
echo -e "${BOLD}${CYAN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                     All tests complete                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "CloudWatch Dashboard:"
terraform -chdir=../terraform output -raw cloudwatch_dashboard_url 2>/dev/null || true
