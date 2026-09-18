#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export KEEPALIVE_AUTH_ROOT=$fixture
mkdir -p "$fixture/config" "$fixture/run"
response=$(REQUEST_METHOD=GET dashboard/www/cgi-bin/state.sh)
[[ $response == *'Status: 401 Unauthorized'* ]] || { echo 'FAIL: anonymous state access was not denied'; exit 1; }
printf 'test-dashboard-password-123\n' | scripts/dashboard-password.sh --stdin >/dev/null
wrong=$(printf 'wrong' | REQUEST_METHOD=POST CONTENT_LENGTH=5 REMOTE_ADDR=127.0.0.1 dashboard/www/cgi-bin/login.sh)
[[ $wrong == *'Status: 401 Unauthorized'* ]]
password=test-dashboard-password-123
response=$(printf '%s' "$password" | REQUEST_METHOD=POST CONTENT_LENGTH=${#password} REMOTE_ADDR=127.0.0.1 dashboard/www/cgi-bin/login.sh)
[[ $response == *'"ok":true'* ]]
cookie=$(printf '%s\n' "$response" | sed -n 's/^Set-Cookie: \([^;]*\);.*/\1/p')
[[ $cookie == keepalive_session=* ]]
REQUEST_METHOD=GET HTTP_COOKIE="$cookie" dashboard/www/cgi-bin/state.sh | sed '1,/^\r$/d' | jq -e '.hosts' >/dev/null
REQUEST_METHOD=POST HTTP_COOKIE="$cookie" dashboard/www/cgi-bin/logout.sh >/dev/null
response=$(REQUEST_METHOD=GET HTTP_COOKIE="$cookie" dashboard/www/cgi-bin/state.sh)
[[ $response == *'Status: 401 Unauthorized'* ]]
for ((i=0;i<10;i++)); do printf 'wrong' | REQUEST_METHOD=POST CONTENT_LENGTH=5 REMOTE_ADDR=192.0.2.8 dashboard/www/cgi-bin/login.sh >/dev/null; done
response=$(printf '%s' "$password" | REQUEST_METHOD=POST CONTENT_LENGTH=${#password} REMOTE_ADDR=192.0.2.8 dashboard/www/cgi-bin/login.sh)
[[ $response == *'Status: 429 Too Many Requests'* ]]
[[ $(stat -c %a "$fixture/config/dashboard.auth") == 600 ]]
! grep -q "$password" "$fixture/config/dashboard.auth"
echo 'PASS: anonymous/wrong-password rejection, login cookie, logout, throttling and hash storage'
