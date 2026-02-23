#!/usr/bin/env bash
# deploy-dashboard.sh — Deploy the Grafana dashboard to Azure Managed Grafana
#
# Usage:
#   cp .env.example .env   # fill in your values
#   ./scripts/deploy-dashboard.sh
#
# The dashboard template uses __LAW_RESOURCE_ID__ as a placeholder which is
# replaced with the actual Log Analytics workspace resource ID at deploy time.
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

for var in AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP LAW_NAME GRAFANA_NAME; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

LAW_RESOURCE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${LAW_NAME}"

# Substitute placeholder in dashboard template
RENDERED=$(mktemp /tmp/dashboard-XXXXXX.json)
sed "s|__LAW_RESOURCE_ID__|${LAW_RESOURCE_ID}|g" "$TEMPLATE" > "$RENDERED"

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
echo "  Dashboard: Inspektor Gadget — TCP Monitoring"
echo "  UID:       ig-tcp-monitoring"
