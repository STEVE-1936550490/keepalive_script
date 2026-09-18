#!/usr/bin/env bash
set -euo pipefail
if [[ ${REQUEST_METHOD:-GET} != GET ]]; then
    printf 'Status: 405 Method Not Allowed\r\nAllow: GET\r\nContent-Type: application/json\r\n\r\n{"error":"method_not_allowed"}\n'
    exit
fi
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$BASE/scripts/dashboard-auth.sh"
require_session
if output=$("$BASE/scripts/dashboard-state.sh"); then
    printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n%s\n' "$output"
else
    printf 'Status: 503 Service Unavailable\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"error":"state_unavailable"}\n'
fi
