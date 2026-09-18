#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $BASE =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Installation path must not contain spaces or systemd specifiers.' >&2; exit 1; }
command -v systemctl >/dev/null
cat > /etc/systemd/system/keepalive.service <<UNIT
[Unit]
Description=Multi-host CPU and disk keepalive
Wants=network-online.target keepalive-dashboard.service
After=network-online.target keepalive-dashboard.service

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=$BASE/keepalive.sh run
Restart=on-failure
RestartSec=10
SuccessExitStatus=130 143
KillMode=mixed
TimeoutStopSec=45
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/keepalive-dashboard.service <<UNIT
[Unit]
Description=Keepalive read-only monitoring dashboard
After=network.target
PartOf=keepalive.service

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=$BASE/dashboard.sh run
Environment=DASHBOARD_BIND=0.0.0.0
Environment=DASHBOARD_PORT=3000
Restart=on-failure
RestartSec=3
SuccessExitStatus=130 143
KillMode=mixed
TimeoutStopSec=15
UMask=0077
UNIT
systemctl daemon-reload
# Remove the old independent boot entry; the main service now owns startup.
if [[ $(systemctl is-enabled keepalive-dashboard.service 2>/dev/null || true) == enabled ]]; then
    systemctl disable keepalive-dashboard.service
fi
systemctl enable keepalive.service
printf 'Installed linked services. Start/stop/restart both with: %s/keepalive.sh <command>\n' "$BASE"
