#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$BASE/scripts/dashboard-auth.sh"
if [[ ${REQUEST_METHOD:-GET} != GET ]]; then
    json_response '405 Method Not Allowed' '{"error":"method_not_allowed"}' $'Allow: GET\r\n'
    exit
fi
require_session
if output=$("$BASE/scripts/dashboard-state.sh"); then
    json_response '200 OK' "$output"
else
    json_response '503 Service Unavailable' '{"error":"state_unavailable"}'
fi
