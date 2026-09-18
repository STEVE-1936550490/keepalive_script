#!/usr/bin/env bash
# Shared CLI routing. Foreground `run` and password changes never enter this path.
managed_service_installed() {
    command -v systemctl >/dev/null || return 1
    local installed_base
    installed_base=$(systemctl show --property=WorkingDirectory --value keepalive.service 2>/dev/null) || return 1
    [[ $installed_base == "$BASE" ]]
}
managed_service_status() {
    local unit label state pid
    for unit in keepalive.service keepalive-dashboard.service; do
        label=keepalive; [[ $unit != keepalive-dashboard.service ]] || label=dashboard
        state=$(systemctl show --property=ActiveState --value "$unit")
        pid=$(systemctl show --property=MainPID --value "$unit")
        case $state in
            active) printf '%s RUNNING pid=%s\n' "$label" "$pid";;
            inactive) printf '%s STOPPED\n' "$label";;
            *) printf '%s %s pid=%s\n' "$label" "${state^^}" "${pid:-0}";;
        esac
    done
}
managed_service_command() {
    local action=$1; shift
    if (($#)); then
        echo 'Managed start/stop/restart/status use config files. For one-off tests use: ./keepalive.sh run --once --duration 30' >&2
        return 2
    fi
    case $action in
        start|stop|restart) systemctl "$action" keepalive.service keepalive-dashboard.service || return $?;;
        status) ;;
        *) return 2;;
    esac
    managed_service_status
}
