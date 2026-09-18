#!/usr/bin/env bash
set -euo pipefail
umask 077
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $BASE/scripts/systemd-control.sh ]]; then
    source "$BASE/scripts/systemd-control.sh"
    case ${1:-status} in
        start|stop|restart|status)
            if managed_service_installed; then managed_service_command "${1:-status}" "${@:2}"; exit; fi;;
    esac
fi
PIDFILE=$BASE/run/dashboard.pid
mkdir -p "$BASE/run" "$BASE/logs"
identity() { local line; read -r line < "/proc/$1/stat" || return 1; line=${line##*) }; local parts; read -ra parts <<< "$line"; [[ ${parts[0]} != Z ]] || return 1; printf '%s' "${parts[19]}"; }
running() {
    [[ -r $PIDFILE ]] || return 1
    read -r SERVICE_PID birth < "$PIDFILE" || return 1
    [[ $SERVICE_PID =~ ^[1-9][0-9]*$ && -r /proc/$SERVICE_PID/stat ]] || return 1
    [[ $(identity "$SERVICE_PID") == "$birth" ]] && kill -0 "$SERVICE_PID" 2>/dev/null
}
stop() {
    if ! running; then echo STOPPED; return; fi
    kill -TERM "$SERVICE_PID"
    for ((i=0;i<100;i++)); do if ! running; then echo STOPPED; return; fi; sleep 0.1; done
    echo 'ERROR: dashboard did not stop' >&2; return 1
}
case ${1:-status} in
    status) if running; then echo "RUNNING pid=$SERVICE_PID"; else echo STOPPED; fi; exit;;
    stop) stop; exit;;
    restart) stop; exec "$0" start;;
    password) exec "$BASE/scripts/dashboard-password.sh";;
    start)
        if running; then echo "RUNNING pid=$SERVICE_PID"; exit; fi
        nohup "$BASE/dashboard.sh" run > "$BASE/logs/dashboard.log" 2>&1 < /dev/null &
        for ((i=0;i<30;i++)); do if running; then echo "RUNNING pid=$SERVICE_PID"; exit; fi; sleep 0.1; done
        echo "ERROR: see $BASE/logs/dashboard.log" >&2; exit 1;;
    run) ;;
    *) echo 'Usage: ./dashboard.sh {start|stop|restart|status|run|password}' >&2; exit 2;;
esac
BIND=${DASHBOARD_BIND:-0.0.0.0}; PORT=${DASHBOARD_PORT:-3000}
[[ $BIND =~ ^[0-9.]+$ && $PORT =~ ^[1-9][0-9]{0,4}$ ]] && ((PORT<=65535)) || { echo 'Invalid bind/port' >&2; exit 2; }
command -v busybox >/dev/null
busybox --list | grep -qx httpd || { echo 'BusyBox httpd is required' >&2; exit 1; }
command -v openssl >/dev/null
"$BASE/scripts/dashboard-password.sh" --init
config=$BASE/run/dashboard.httpd.conf
printf '# Authentication is enforced by CGI session checks.\n' > "$config"
exec 9> "$BASE/run/dashboard.lock"
flock -n 9 || { echo 'Dashboard already running' >&2; exit 1; }
child=
cleanup() {
    trap - EXIT TERM INT HUP
    [[ -z $child ]] || kill -TERM "$child" 2>/dev/null || true
    [[ -z $child ]] || wait "$child" 2>/dev/null || true
    rm -f -- "$PIDFILE"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
busybox httpd -f -p "$BIND:$PORT" -h "$BASE/dashboard/www" -c "$config" 9>&- & child=$!
sleep 0.2
kill -0 "$child" 2>/dev/null || { echo 'HTTP server failed; check address and port' >&2; exit 1; }
printf '%s %s\n' "$$" "$(identity "$$")" > "$PIDFILE"
printf 'Dashboard listening on http://%s:%s\n' "$BIND" "$PORT"
wait "$child"
