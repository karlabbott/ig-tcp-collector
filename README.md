# ig-tcp-collector

Collect TCP connection events and packet drops from Linux VMs using [Inspektor Gadget](https://github.com/inspektor-gadget/inspektor-gadget), ship them to Azure Log Analytics, and visualize them in Azure Managed Grafana.

## What it does

This repo sets up an end-to-end observability pipeline:

```
Inspektor Gadget (eBPF) → JSON log files → Azure Monitor Agent → Log Analytics → Grafana
```

Two gadgets are collected:

| Gadget | Table | Data |
|--------|-------|------|
| `trace_tcpdrop` | `TraceTcpDrop_CL` | TCP packet drops with kernel reason, TCP state, flags |
| `trace_tcp` | `TraceTcp_CL` | TCP connect, accept, and close events with process info |

The Grafana dashboard includes 20 panels across two sections — TCP drops (stats, time series, pie charts by reason/state, top IPs, event table) and TCP events (connect/accept/close counts, events over time, top processes/destinations/ports, event log).

## Prerequisites

- **Azure CLI** (`az`) authenticated with Contributor access
- **Azure Managed Grafana** instance with an Azure Monitor datasource
- **Log Analytics workspace** in the same resource group
- **Linux VM** (RHEL, Ubuntu, etc.) with:
  - [Inspektor Gadget](https://github.com/inspektor-gadget/inspektor-gadget/releases) (`ig`) installed
  - Kernel with eBPF support

## Quick start

### 1. Configure

```bash
cp .env.example .env
# Edit .env with your Azure resource details
```

### 2. Set up the VM

Copy and run the VM setup script on your target machine:

```bash
scp scripts/setup-vm.sh user@your-vm:/tmp/
ssh user@your-vm "sudo bash /tmp/setup-vm.sh"
```

This installs two systemd services (`ig-trace-tcpdrop`, `ig-trace-tcp`) that write JSON logs to `/var/log/inspektor-gadget/`.

### 3. Set up the Azure pipeline

From any machine with `az` CLI:

```bash
./scripts/setup-azure.sh
```

This creates:
- A Data Collection Endpoint (DCE)
- Custom log tables (`TraceTcpDrop_CL`, `TraceTcp_CL`)
- A Data Collection Rule (DCR) with KQL transforms to parse nested JSON
- A system-assigned managed identity on the VM (required for AMA authentication)
- Installs Azure Monitor Agent on the VM
- Associates the DCE and DCR with the VM

### 4. Deploy the Grafana dashboard

```bash
./scripts/deploy-dashboard.sh
```

Each deployment creates a per-VM dashboard (UID and title derived from `VM_NAME`) with queries scoped to that VM's data. You can deploy multiple VMs into the same resource group and each will get its own dashboard without collisions. Override the defaults with `DASHBOARD_TITLE` and `DASHBOARD_UID` in `.env`.

## Configuration

All configuration is in `.env` (see `.env.example`):

| Variable | Required | Description |
|----------|----------|-------------|
| `AZURE_SUBSCRIPTION_ID` | Yes | Azure subscription ID |
| `AZURE_RESOURCE_GROUP` | Yes | Resource group containing all resources |
| `AZURE_LOCATION` | Yes | Azure region (e.g., `eastus`) |
| `LAW_NAME` | Yes | Log Analytics workspace name |
| `VM_NAME` | Yes | Target VM name |
| `DCE_NAME` | No | Data Collection Endpoint name (default: `ig-tcp-dce`) |
| `DCR_NAME` | No | Data Collection Rule name (default: `ig-tcp-dcr`) |
| `GRAFANA_NAME` | Yes | Azure Managed Grafana instance name |
| `DASHBOARD_TITLE` | No | Dashboard display name (default: `Inspektor Gadget — TCP Monitoring (<VM_NAME>)`) |
| `DASHBOARD_UID` | No | Grafana dashboard UID (default: `ig-tcp-<VM_NAME>`) |

## Repository structure

```
ig-tcp-collector/
├── .env.example                      # Configuration template
├── dashboard/
│   └── grafana-dashboard.json        # Grafana dashboard (templated)
├── scripts/
│   ├── setup-vm.sh                   # VM systemd service installer
│   ├── setup-azure.sh                # Azure pipeline provisioner
│   └── deploy-dashboard.sh           # Grafana dashboard deployer
└── README.md
```

## Data flow

1. **eBPF tracing** — `ig run trace_tcpdrop --host` and `ig run trace_tcp --host` capture kernel TCP events via eBPF
2. **JSON logging** — Events are written as one JSON object per line to `/var/log/inspektor-gadget/`
3. **Collection** — Azure Monitor Agent tails the log files and streams them to the DCR
4. **Transform** — DCR applies KQL transforms to parse nested JSON into flat columns
5. **Storage** — Parsed events land in `TraceTcpDrop_CL` and `TraceTcp_CL` tables
6. **Visualization** — Grafana queries Log Analytics via the Azure Monitor datasource

## Notes

- **Inspektor Gadget v0.49+** uses `ig run <gadget>` syntax (older versions used `ig trace <gadget>`)
- The `--host` flag is required on bare-metal VMs to trace host network events
- Initial data ingestion takes 5–10 minutes after setup
- Log rotation is configured at 100MB / 7 days
- The dashboard auto-refreshes every 30 seconds with a default 6-hour time window

## License

MIT
