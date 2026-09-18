#!/usr/bin/env bash
# Explicit live integration test: briefly stops/restarts the linked production services.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/dashboard-state.sh | jq -e '[.hosts[]|select(.phase=="active")]|length==0' >/dev/null || { echo 'SKIP: wait until no host is actively generating load'; exit 0; }
trap 'systemctl start keepalive.service >/dev/null 2>&1 || true' EXIT
for entry in keepalive.sh dashboard.sh; do
    "./$entry" stop
    for unit in keepalive.service keepalive-dashboard.service; do
        [[ $(systemctl show --property=ActiveState --value "$unit") == inactive ]]
    done
    if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:3000/ >/dev/null 2>&1; then echo 'FAIL: dashboard listener survived stop'; exit 1; fi
    "./$entry" start
    curl --noproxy '*' -fsS --retry 5 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:3000/ >/dev/null
    systemctl is-active --quiet keepalive.service
    systemctl is-active --quiet keepalive-dashboard.service
    [[ $(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/cgi-bin/state.sh) == 401 ]]
done
old_controller=$(systemctl show --property=MainPID --value keepalive.service)
old_dashboard=$(systemctl show --property=MainPID --value keepalive-dashboard.service)
./keepalive.sh restart
[[ $(systemctl show --property=MainPID --value keepalive.service) != "$old_controller" ]]
[[ $(systemctl show --property=MainPID --value keepalive-dashboard.service) != "$old_dashboard" ]]
curl --noproxy '*' -fsS --retry 5 --retry-connrefused --retry-delay 1 --max-time 3 http://127.0.0.1:3000/ >/dev/null
printf 'PASS: both CLI entrypoints start/stop both services; restart replaces both processes; API remains protected\n'
