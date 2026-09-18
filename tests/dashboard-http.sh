#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Run only when the production dashboard is stopped; this test owns its process.
[[ $(./dashboard.sh status) == STOPPED ]] || { echo 'SKIP: dashboard already running'; exit 0; }
export DASHBOARD_PORT=13000
fixture=$(mktemp -d)
export KEEPALIVE_AUTH_ROOT=$fixture
trap './dashboard.sh stop >/dev/null 2>&1 || true; rm -rf -- "$fixture"' EXIT
printf 'test-dashboard-password-123\n' | scripts/dashboard-password.sh --stdin >/dev/null
./dashboard.sh start
./dashboard.sh start
./dashboard.sh status | grep '^RUNNING pid='
url=http://127.0.0.1:13000
curl --noproxy '*' -fsS "$url/" > /dev/null
curl --noproxy '*' -fsS "$url/app.js" > /dev/null
[[ $(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "$url/cgi-bin/state.sh") == 401 ]]
printf '%s' 'test-dashboard-password-123' | curl --noproxy '*' -fsS -c "$fixture/cookies" -H 'Content-Type: text/plain' --data-binary @- "$url/cgi-bin/login.sh" | jq -e '.ok' >/dev/null
curl --noproxy '*' -fsS -b "$fixture/cookies" "$url/cgi-bin/state.sh" | jq -e '.controller and (.hosts|length)>0' > /dev/null
for path in /config/secrets.env /config/hosts.conf /config/dashboard.password /config/dashboard.auth /logs/keepalive.log /scripts/dashboard-state.sh; do
    code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "$url$path")
    [[ $code == 404 ]] || { echo "FAIL: exposed $path ($code)"; exit 1; }
done
code=$(curl --noproxy '*' --path-as-is -s -o /dev/null -w '%{http_code}' "$url/../../config/secrets.env")
[[ $code == 400 || $code == 403 || $code == 404 ]]
[[ $(curl --noproxy '*' -s -X POST -o /dev/null -w '%{http_code}' "$url/cgi-bin/state.sh") == 405 ]]
./dashboard.sh stop
[[ $(./dashboard.sh status) == STOPPED ]]
if curl --noproxy '*' -fsS --max-time 2 "$url/" >/dev/null 2>&1; then echo 'FAIL: HTTP listener survived stop'; exit 1; fi
./dashboard.sh start
./dashboard.sh stop
echo 'PASS: HTTP, JSON, duplicate start, stop/restart, path isolation and read-only API'
