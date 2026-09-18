#!/usr/bin/env bash
set -euo pipefail
set +x
export LC_ALL=C
umask 077
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$BASE/scripts/dashboard-auth.sh"
if [[ ${REQUEST_METHOD:-} != POST ]]; then json_response '405 Method Not Allowed' '{"error":"method_not_allowed"}'; exit; fi
if [[ ! ${CONTENT_LENGTH:-} =~ ^[1-9][0-9]{0,3}$ ]] || ((CONTENT_LENGTH>1024)); then json_response '400 Bad Request' '{"error":"invalid_password_length"}'; exit; fi
if [[ ! -s $AUTH_ROOT/config/dashboard.auth ]]; then json_response '503 Service Unavailable' '{"error":"auth_not_configured"}'; exit; fi
mkdir -p "$SESSION_DIR"
exec 8> "$AUTH_ROOT/run/dashboard-auth.lock"; flock -w 5 8 || { json_response '503 Service Unavailable' '{"error":"busy"}'; exit; }
ip=${REMOTE_ADDR:-local}; [[ $ip =~ ^[a-fA-F0-9.:]+$ ]] || ip=local
rate=$AUTH_ROOT/run/dashboard-login-$ip
now=$(date +%s); since=$now; attempts=0
if [[ -r $rate ]]; then read -r since attempts < "$rate" || true; fi
if [[ ! $since =~ ^[0-9]+$ || ! $attempts =~ ^[0-9]+$ ]]; then since=$now; attempts=0; fi
if ((now-since>=300)); then since=$now; attempts=0; fi
if ((attempts>=10)); then json_response '429 Too Many Requests' '{"error":"too_many_attempts"}'; exit; fi
password=
IFS= read -r -N "$CONTENT_LENGTH" -t 5 password || true
if ((${#password}!=CONTENT_LENGTH)) || [[ $password == *$'\n'* || $password == *$'\r'* ]]; then json_response '400 Bad Request' '{"error":"invalid_body"}'; exit; fi
IFS= read -r stored < "$AUTH_ROOT/config/dashboard.auth"
[[ $stored == '$6$'* ]] || { json_response '503 Service Unavailable' '{"error":"invalid_auth_config"}'; exit; }
remainder=${stored#\$6\$}; salt=${remainder%%\$*}
actual=$(printf '%s\n' "$password" | openssl passwd -6 -salt "$salt" -stdin)
unset password
if [[ $actual != "$stored" ]]; then
    printf '%s %s\n' "$since" "$((attempts+1))" > "$rate"
    json_response '401 Unauthorized' '{"error":"wrong_password"}'; exit
fi
printf '%s 0\n' "$now" > "$rate"
# Prune expired sessions; filenames contain only random hex tokens.
for file in "$SESSION_DIR"/session-*; do
    [[ -f $file ]] || continue
    read -r expiry < "$file" || expiry=0
    if [[ ! $expiry =~ ^[0-9]+$ ]] || ((expiry<=now)); then rm -f -- "$file"; fi
done
token=$(openssl rand -hex 32)
printf '%s\n' "$((now+28800))" > "$SESSION_DIR/session-$token"
json_response '200 OK' '{"ok":true}' "Set-Cookie: keepalive_session=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800"$'\r\n'
