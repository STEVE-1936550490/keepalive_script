#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $BASE =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Unsupported installation path' >&2; exit 1; }
command -v systemctl >/dev/null
cat > /etc/systemd/system/keepalive-dashboard.service <<UNIT
[Unit]
Description=Keepalive read-only monitoring dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=$BASE/dashboard.sh run
Environment=DASHBOARD_BIND=0.0.0.0
Environment=DASHBOARD_PORT=3000
Restart=on-failure
RestartSec=3
KillMode=mixed
TimeoutStopSec=15
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable keepalive-dashboard.service
printf 'Installed. Start with: systemctl start keepalive-dashboard.service\n'
