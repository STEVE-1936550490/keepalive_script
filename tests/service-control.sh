#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp keepalive.sh dashboard.sh "$work/"
cp -r scripts "$work/"
mkdir -p "$work/bin" "$work/config"
export SERVICE_TEST_BASE=$work SERVICE_TEST_CALLS=$work/calls
cat > "$work/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    'show --property=WorkingDirectory --value keepalive.service') printf '%s\n' "$SERVICE_TEST_BASE";;
    'start keepalive.service keepalive-dashboard.service'|'stop keepalive.service keepalive-dashboard.service'|'restart keepalive.service keepalive-dashboard.service')
        printf '%s\n' "$*" >> "$SERVICE_TEST_CALLS"; exit "${SERVICE_TEST_FAILURE:-0}";;
    'show --property=ActiveState --value keepalive.service'|'show --property=ActiveState --value keepalive-dashboard.service') echo active;;
    'show --property=MainPID --value keepalive.service') echo 123;;
    'show --property=MainPID --value keepalive-dashboard.service') echo 456;;
    *) echo "unexpected systemctl call: $*" >&2; exit 2;;
esac
MOCK
chmod +x "$work/bin/systemctl"
export PATH="$work/bin:$PATH"
# A malformed secret file must never prevent stopping managed services.
printf "UNFINISHED='\n" > "$work/config/secrets.env"
for script in keepalive.sh dashboard.sh; do
    for action in start stop restart; do
        : > "$work/calls"
        "$work/$script" "$action" >/dev/null 2>&1 || { echo "FAIL: $script $action did not route to systemd"; exit 1; }
        [[ $(cat "$work/calls") == "$action keepalive.service keepalive-dashboard.service" ]]
    done
    output=$("$work/$script" status)
    [[ $output == *'keepalive RUNNING pid=123'* && $output == *'dashboard RUNNING pid=456'* ]]
done
: > "$work/calls"
if "$work/keepalive.sh" start --once >/dev/null 2>&1; then echo 'FAIL: managed start silently accepted unsupported arguments'; exit 1; fi
[[ ! -s $work/calls ]]
if SERVICE_TEST_FAILURE=7 "$work/keepalive.sh" start >/dev/null 2>&1; then echo 'FAIL: systemd error swallowed'; exit 1; fi
[[ ! -e $work/run/keepalive.pid ]]
echo 'PASS: unified command routing, combined status, stop despite bad config and no silent fallback'
