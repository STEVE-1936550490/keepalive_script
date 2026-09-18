#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $BASE =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'Installation path must not contain spaces or systemd specifiers.' >&2; exit 1; }
command -v systemctl >/dev/null
cat > /etc/systemd/system/keepalive.service <<UNIT
[Unit]
Description=Multi-host CPU and disk keepalive
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=$BASE/keepalive.sh run
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=45
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable keepalive.service
printf 'Installed. Start with: systemctl start keepalive.service\n'
