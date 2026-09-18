#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x scripts/dashboard-state.sh ]] || { echo 'FAIL: dashboard state exporter missing'; exit 1; }
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/config" "$fixture/run" "$fixture/logs"
printf 'local|local|||||local|||1\ncloud|remote|root||192.0.2.1|22|password|SECRET||0\n' > "$fixture/config/hosts.conf"
printf 'echo SHOULD_NEVER_EXECUTE\nSECRET=SHOULD_NEVER_EXPOSE\n' > "$fixture/config/secrets.env"
cat > "$fixture/logs/keepalive.log" <<'LOG'
2026-09-18 10:00:00 [INFO] round=1 host=cloud action=start run_id=sample
2026-09-18 10:00:03 [INFO] round=1 host=cloud action=cpu cpu=69 target=70 duty=70
2026-09-18 10:00:04 [INFO] round=1 host=cloud action=disk disk_write_mb=64
2026-09-18 10:00:30 [INFO] round=1 host=cloud action=finish rc=0 run_id=sample
LOG
printf '2026-09-18 10:00:00 [FAIL] host=cloud reason=timeout\n' > "$fixture/logs/connectivity-1.log"
printf '2026-09-18 11:00:00 [PASS] host=cloud ssh_login=ok\n' > "$fixture/logs/connectivity-2.log"
KEEPALIVE_STATE_ROOT="$fixture" scripts/dashboard-state.sh > "$fixture/state.json"
jq -e '.controller.running == false and (.hosts|length)==2 and (.hosts[]|select(.name=="cloud")|.connection=="ok" and .cpu==69 and .disk_mb==64 and .enabled==false and .phase=="disabled")' "$fixture/state.json" >/dev/null
! grep -q SHOULD_NEVER "$fixture/state.json"
# A matching live process birth time is required; stale PID files must not report running.
read -r statline < /proc/$$/stat
statline=${statline##*) }; read -ra fields <<< "$statline"
printf '%s %s\n' "$$" "${fields[19]}" > "$fixture/run/keepalive.pid"
KEEPALIVE_STATE_ROOT="$fixture" scripts/dashboard-state.sh | jq -e '.controller.running == true' >/dev/null
printf '%s 1\n' "$$" > "$fixture/run/keepalive.pid"
KEEPALIVE_STATE_ROOT="$fixture" scripts/dashboard-state.sh | jq -e '.controller.running == false' >/dev/null
echo 'PASS: state, latest connectivity, historical samples, stale PID and secret isolation'
printf '2026-09-18 12:00:00 [WARN] round=2 host=cloud action=skip reason=ssh_unreachable\n' >> "$fixture/logs/keepalive.log"
KEEPALIVE_STATE_ROOT="$fixture" scripts/dashboard-state.sh | jq -e '.hosts[]|select(.name=="cloud")|.connection=="ssh_unreachable"' >/dev/null
echo 'PASS: newer scheduler connection failure overrides an old successful check'
