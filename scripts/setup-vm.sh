#!/usr/bin/env bash
# setup-vm.sh — Install Inspektor Gadget trace_tcpdrop and trace_tcp as systemd services
# Run this script on the target VM as root (or with sudo).
#
# Usage:
#   sudo ./scripts/setup-vm.sh
#
# Prerequisites:
#   - Inspektor Gadget (ig) binary installed
#   - Linux kernel with eBPF support
set -euo pipefail

LOG_DIR="/var/log/inspektor-gadget"
IG_BIN=$(command -v ig 2>/dev/null || echo "/usr/local/bin/ig")

echo "==> Verifying ig binary..."
if [[ ! -x "$IG_BIN" ]]; then
    echo "ERROR: ig binary not found. Install Inspektor Gadget first:"
    echo "  https://github.com/inspektor-gadget/inspektor-gadget/releases"
    exit 1
fi
echo "    Found: $IG_BIN ($(${IG_BIN} version 2>/dev/null || echo 'unknown version'))"

echo "==> Creating log directory: ${LOG_DIR}"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

# --- trace_tcpdrop service ---
echo "==> Installing ig-trace-tcpdrop.service..."
cat > /etc/systemd/system/ig-trace-tcpdrop.service <<EOF
[Unit]
Description=Inspektor Gadget trace_tcpdrop (JSON logging)
After=network.target

[Service]
Type=simple
ExecStart=${IG_BIN} run trace_tcpdrop -o json --host
StandardOutput=append:${LOG_DIR}/trace_tcpdrop.log
StandardError=journal
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- trace_tcp service ---
echo "==> Installing ig-trace-tcp.service..."
cat > /etc/systemd/system/ig-trace-tcp.service <<EOF
[Unit]
Description=Inspektor Gadget trace_tcp (JSON logging)
After=network.target

[Service]
Type=simple
ExecStart=${IG_BIN} run trace_tcp -o json --host
StandardOutput=append:${LOG_DIR}/trace_tcp.log
StandardError=journal
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- Logrotate ---
echo "==> Installing logrotate config..."
cat > /etc/logrotate.d/inspektor-gadget <<'EOF'
/var/log/inspektor-gadget/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    maxsize 100M
}
EOF

# --- Enable and start ---
echo "==> Reloading systemd and starting services..."
systemctl daemon-reload
systemctl enable --now ig-trace-tcpdrop.service
systemctl enable --now ig-trace-tcp.service

echo "==> Verifying services..."
echo "    ig-trace-tcpdrop: $(systemctl is-active ig-trace-tcpdrop.service)"
echo "    ig-trace-tcp:     $(systemctl is-active ig-trace-tcp.service)"

echo ""
echo "Done! Gadget logs will appear at:"
echo "  ${LOG_DIR}/trace_tcpdrop.log"
echo "  ${LOG_DIR}/trace_tcp.log"
