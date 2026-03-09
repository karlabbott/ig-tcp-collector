#!/usr/bin/env bash
# deploy-dashboard.sh — Deploy the Grafana dashboard to Azure Managed Grafana
#
# Usage:
#   cp .env.example .env   # fill in your values
#   ./scripts/deploy-dashboard.sh
#
# The dashboard template uses placeholders which are replaced at deploy time:
#   __LAW_RESOURCE_ID__  → Log Analytics workspace resource ID
#   __DASHBOARD_UID__    → Unique dashboard identifier (derived from VM_NAME)
#   __DASHBOARD_TITLE__  → Dashboard display name
#   __HOST_FILTER__      → KQL filter clause scoping data to the target VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
TEMPLATE="${SCRIPT_DIR}/../dashboard/grafana-dashboard.json"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP LAW_NAME VM_NAME GRAFANA_NAME; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

LAW_RESOURCE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${LAW_NAME}"

DASHBOARD_UID="${DASHBOARD_UID:-ig-tcp-${VM_NAME}}"
DASHBOARD_TITLE="${DASHBOARD_TITLE:-Inspektor Gadget — TCP Monitoring (${VM_NAME})}"
HOST_FILTER="| where _ResourceId has \\\"${VM_NAME}\\\""

# Substitute placeholders in dashboard template
RENDERED=$(mktemp /tmp/dashboard-XXXXXX.json)
export LAW_RESOURCE_ID DASHBOARD_UID DASHBOARD_TITLE HOST_FILTER
python3 -c "
import os, sys
t = sys.stdin.read()
for key in ['LAW_RESOURCE_ID', 'DASHBOARD_UID', 'DASHBOARD_TITLE', 'HOST_FILTER']:
    t = t.replace('__' + key + '__', os.environ[key])
print(t, end='')
" < "$TEMPLATE" > "$RENDERED"

echo "==> Deploying dashboard to ${GRAFANA_NAME}..."
az grafana dashboard create \
    --name "$GRAFANA_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --definition @"$RENDERED" \
    --overwrite true \
    -o none

rm -f "$RENDERED"

ENDPOINT=$(az grafana show \
    --name "$GRAFANA_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query properties.endpoint -o tsv 2>/dev/null || echo "(could not retrieve endpoint)")

echo ""
echo "===== Dashboard Deployed ====="
echo "  Grafana:   ${ENDPOINT}"
echo "  Dashboard: ${DASHBOARD_TITLE}"
echo "  UID:       ${DASHBOARD_UID}"
