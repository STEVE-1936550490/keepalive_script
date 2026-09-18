#!/usr/bin/env bash
set -euo pipefail
umask 077
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$BASE/scripts/dashboard-auth.sh"
if [[ ${REQUEST_METHOD:-} != POST ]]; then json_response '405 Method Not Allowed' '{"error":"method_not_allowed"}'; exit; fi
require_session
rm -f -- "$SESSION_DIR/session-$TOKEN"
json_response '200 OK' '{"ok":true}' 'Set-Cookie: keepalive_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0'$'\r\n'
