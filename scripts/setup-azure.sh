#!/usr/bin/env bash
# setup-azure.sh — Create Azure Monitor pipeline for Inspektor Gadget TCP data
#
# Creates: Data Collection Endpoint, custom Log Analytics tables,
#          Data Collection Rule with KQL transforms, installs AMA, and associates DCR.
#
# Usage:
#   cp .env.example .env   # fill in your values
#   ./scripts/setup-azure.sh
#
# Prerequisites:
#   - Azure CLI (az) authenticated
#   - Contributor role on the resource group
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required variables
for var in AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_LOCATION LAW_NAME VM_NAME DCE_NAME DCR_NAME; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

LAW_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${LAW_NAME}"
VM_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/${VM_NAME}"

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
echo "==> Using subscription: $AZURE_SUBSCRIPTION_ID"

# ─── Step 1: Create Data Collection Endpoint ─────────────────────────────────
echo "==> Creating Data Collection Endpoint: ${DCE_NAME}..."
DCE_ID=$(az monitor data-collection endpoint create \
    --name "$DCE_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --location "$AZURE_LOCATION" \
    --public-network-access Enabled \
    --query id -o tsv 2>/dev/null || \
    az monitor data-collection endpoint show \
        --name "$DCE_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --query id -o tsv)
echo "    DCE ID: $DCE_ID"

# ─── Step 2: Create custom log tables ────────────────────────────────────────
echo "==> Creating custom table: TraceTcpDrop_CL..."
az monitor log-analytics workspace table create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --workspace-name "$LAW_NAME" \
    --name "TraceTcpDrop_CL" \
    --columns \
        TimeGenerated=datetime \
        Src=string \
        Dst=string \
        Comm=string \
        Pid=int \
        Tid=int \
        State=string \
        TcpFlags=string \
        Reason=string \
        MountNsId=long \
    --plan Analytics \
    -o none 2>/dev/null || echo "    Table may already exist, continuing..."

echo "==> Creating custom table: TraceTcp_CL..."
az monitor log-analytics workspace table create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --workspace-name "$LAW_NAME" \
    --name "TraceTcp_CL" \
    --columns \
        TimeGenerated=datetime \
        Src=string \
        Dst=string \
        Comm=string \
        Pid=int \
        Tid=int \
        Uid=int \
        Gid=int \
        TcpEventType=string \
        MountNsId=long \
    --plan Analytics \
    -o none 2>/dev/null || echo "    Table may already exist, continuing..."

# ─── Step 3: Create Data Collection Rule ─────────────────────────────────────
echo "==> Creating Data Collection Rule: ${DCR_NAME}..."

DCR_TEMP=$(mktemp /tmp/dcr-XXXXXX.json)
cat > "$DCR_TEMP" <<DCEOF
{
    "location": "${AZURE_LOCATION}",
    "properties": {
        "dataCollectionEndpointId": "${DCE_ID}",
        "streamDeclarations": {
            "Custom-TraceTcpDrop_CL": {
                "columns": [
                    { "name": "TimeGenerated", "type": "datetime" },
                    { "name": "RawData", "type": "string" }
                ]
            },
            "Custom-TraceTcp_CL": {
                "columns": [
                    { "name": "TimeGenerated", "type": "datetime" },
                    { "name": "RawData", "type": "string" }
                ]
            }
        },
        "dataSources": {
            "logFiles": [
                {
                    "streams": ["Custom-TraceTcpDrop_CL"],
                    "filePatterns": ["/var/log/inspektor-gadget/trace_tcpdrop*.log"],
                    "format": "text",
                    "settings": {
                        "text": {
                            "recordStartTimestampFormat": "ISO 8601"
                        }
                    },
                    "name": "TraceTcpDropSource"
                },
                {
                    "streams": ["Custom-TraceTcp_CL"],
                    "filePatterns": ["/var/log/inspektor-gadget/trace_tcp.log"],
                    "format": "text",
                    "settings": {
                        "text": {
                            "recordStartTimestampFormat": "ISO 8601"
                        }
                    },
                    "name": "TraceTcpSource"
                }
            ]
        },
        "destinations": {
            "logAnalytics": [
                {
                    "workspaceResourceId": "${LAW_ID}",
                    "name": "lawDest"
                }
            ]
        },
        "dataFlows": [
            {
                "streams": ["Custom-TraceTcpDrop_CL"],
                "destinations": ["lawDest"],
                "transformKql": "source | extend j = parse_json(RawData) | project TimeGenerated = todatetime(j.timestamp), Src = strcat(tostring(j.src.addr), ':', tostring(j.src.port)), Dst = strcat(tostring(j.dst.addr), ':', tostring(j.dst.port)), Comm = tostring(j.comm), Pid = toint(j.pid), Tid = toint(j.tid), State = tostring(j.state), TcpFlags = tostring(j.tcpflags), Reason = tostring(j.reason), MountNsId = tolong(j.mount_ns_id)",
                "outputStream": "Custom-TraceTcpDrop_CL"
            },
            {
                "streams": ["Custom-TraceTcp_CL"],
                "destinations": ["lawDest"],
                "transformKql": "source | extend j = parse_json(RawData) | project TimeGenerated = todatetime(j.timestamp), Src = strcat(tostring(j.src.addr), ':', tostring(j.src.port)), Dst = strcat(tostring(j.dst.addr), ':', tostring(j.dst.port)), Comm = tostring(j.proc.comm), Pid = toint(j.proc.pid), Tid = toint(j.proc.tid), Uid = toint(j.proc.creds.uid), Gid = toint(j.proc.creds.gid), TcpEventType = tostring(j.type), MountNsId = tolong(j.proc.mntns_id)",
                "outputStream": "Custom-TraceTcp_CL"
            }
        ]
    }
}
DCEOF

az monitor data-collection rule create \
    --name "$DCR_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --location "$AZURE_LOCATION" \
    --rule-file "$DCR_TEMP" \
    -o none 2>/dev/null || echo "    DCR may already exist, continuing..."

rm -f "$DCR_TEMP"

DCR_ID=$(az monitor data-collection rule show \
    --name "$DCR_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query id -o tsv)
echo "    DCR ID: $DCR_ID"

# ─── Step 4: Ensure VM has a system-assigned managed identity ────────────────
echo "==> Assigning system-managed identity to ${VM_NAME}..."
az vm identity assign \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$VM_NAME" \
    -o none 2>/dev/null || echo "    Identity may already be assigned, continuing..."

# ─── Step 5: Install Azure Monitor Agent on the VM ──────────────────────────
echo "==> Installing Azure Monitor Agent extension on ${VM_NAME}..."
az vm extension set \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --vm-name "$VM_NAME" \
    --name AzureMonitorLinuxAgent \
    --publisher Microsoft.Azure.Monitor \
    --enable-auto-upgrade true \
    -o none 2>/dev/null || echo "    AMA may already be installed, continuing..."

# ─── Step 6: Associate DCE and DCR with VM ──────────────────────────────────
echo "==> Associating DCE with VM..."
az monitor data-collection rule association create \
    --name "configurationAccessEndpoint" \
    --resource "$VM_ID" \
    --data-collection-endpoint-id "$DCE_ID" \
    -o none 2>/dev/null || echo "    DCE association may already exist, continuing..."

echo "==> Associating DCR with VM..."
az monitor data-collection rule association create \
    --name "${DCR_NAME}-association" \
    --resource "$VM_ID" \
    --rule-id "$DCR_ID" \
    -o none 2>/dev/null || echo "    DCR association may already exist, continuing..."

echo ""
echo "===== Azure Pipeline Setup Complete ====="
echo "  DCE:    ${DCE_NAME}"
echo "  DCR:    ${DCR_NAME}"
echo "  Tables: TraceTcpDrop_CL, TraceTcp_CL"
echo "  AMA:    installed on ${VM_NAME}"
echo ""
echo "Data should appear in Log Analytics within 5-10 minutes."
echo "Test: az monitor log-analytics query -w '${LAW_ID}' --analytics-query 'TraceTcpDrop_CL | take 5'"
