#!/usr/bin/env bash
# Sourced by CGI handlers; contains no user-configurable code or credentials.
AUTH_ROOT=${KEEPALIVE_AUTH_ROOT:-$BASE}
SESSION_DIR=$AUTH_ROOT/run/dashboard-sessions
json_response() {
    printf 'Status: %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n%s\r\n%s\n' "$1" "${3:-}" "$2"
}
session_token() {
    TOKEN=
    local pair
    IFS=';' read -ra pairs <<< "${HTTP_COOKIE:-}"
    for pair in "${pairs[@]}"; do
        pair=${pair#"${pair%%[![:space:]]*}"}
        if [[ $pair =~ ^keepalive_session=([a-f0-9]{64})$ ]]; then TOKEN=${BASH_REMATCH[1]}; break; fi
    done
}
require_session() {
    session_token
    local expires=0
    if [[ -n $TOKEN && -f $SESSION_DIR/session-$TOKEN ]]; then
        read -r expires < "$SESSION_DIR/session-$TOKEN" || true
        if [[ $expires =~ ^[0-9]+$ ]] && ((expires > $(date +%s))); then return 0; fi
    fi
    json_response '401 Unauthorized' '{"error":"login_required"}'
    exit 0
}
