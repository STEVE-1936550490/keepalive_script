#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
BASE=${KEEPALIVE_AUTH_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
mkdir -p "$BASE/config" "$BASE/run/dashboard-sessions"
exec 8> "$BASE/run/dashboard-auth.lock"; flock 8
case ${1:-interactive} in
    --init)
        [[ ! -s $BASE/config/dashboard.auth ]] || exit 0
        password=$(openssl rand -hex 12)
        printf '%s\n' "$password" > "$BASE/config/dashboard.password";;
    --stdin) IFS= read -r password;;
    interactive)
        IFS= read -rs -p 'Dashboard 新密码（至少 12 字符）: ' password; printf '\n'
        IFS= read -rs -p '再次输入: ' confirm; printf '\n'
        [[ $password == "$confirm" ]] || { echo 'Passwords do not match' >&2; exit 2; };;
    *) echo 'Usage: dashboard-password.sh [--init|--stdin]' >&2; exit 2;;
esac
((${#password}>=12 && ${#password}<=256)) || { echo 'Password must be 12–256 characters' >&2; exit 2; }
salt=$(openssl rand -hex 8)
hash=$(printf '%s\n' "$password" | openssl passwd -6 -salt "$salt" -stdin)
printf '%s\n' "$hash" > "$BASE/config/dashboard.auth.new"
chmod 600 "$BASE/config/dashboard.auth.new"
mv -f "$BASE/config/dashboard.auth.new" "$BASE/config/dashboard.auth"
if [[ ${1:-interactive} != --init ]]; then rm -f -- "$BASE/config/dashboard.password"; fi
# Invalidate only this dashboard's existing sessions.
find "$BASE/run/dashboard-sessions" -maxdepth 1 -type f -name 'session-*' -delete
unset password hash
printf 'Dashboard password saved; existing sessions invalidated.\n'
