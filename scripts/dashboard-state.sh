#!/usr/bin/env bash
# Read-only: deliberately never source settings.env or secrets.env.
set -euo pipefail
BASE=${KEEPALIVE_STATE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
RUNNING=0; PID=0; STARTED=0
if [[ -r $BASE/run/keepalive.pid ]]; then
    read -r candidate birth < "$BASE/run/keepalive.pid" || true
    if [[ ${candidate:-} =~ ^[1-9][0-9]*$ && ${birth:-} =~ ^[0-9]+$ && -r /proc/$candidate/stat ]]; then
        if read -r statline < "/proc/$candidate/stat"; then
            statline=${statline##*) }; read -ra fields <<< "$statline"
            if [[ ${fields[19]:-} == "$birth" && ${fields[0]:-} != Z ]] && kill -0 "$candidate" 2>/dev/null; then
                RUNNING=1; PID=$candidate
                boot=$(awk '$1=="btime" {print $2}' /proc/stat)
                ticks=$(getconf CLK_TCK)
                STARTED=$((boot+birth/ticks))
            fi
        fi
    fi
fi
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
{
    printf '@hosts\n'; [[ ! -r $BASE/config/hosts.conf ]] || cat "$BASE/config/hosts.conf"
    printf '@events\n'
    for log in "$BASE/logs/keepalive.log.1" "$BASE/logs/keepalive.log"; do
        [[ ! -r $log ]] || tail -n 2000 "$log"
    done
    printf '@connections\n'
    # Files use sortable timestamps; bound work as connection history grows.
    shopt -s nullglob
    logs=("$BASE"/logs/connectivity-*.log)
    begin=$((${#logs[@]}-30)); ((begin >= 0)) || begin=0
    for ((i=begin; i<${#logs[@]}; i++)); do tail -n 200 "${logs[i]}"; done
} | awk -v running="$RUNNING" -v pid="$PID" -v started="$STARTED" -v now="$(date +%s)" -f "$SCRIPT_DIR/dashboard-state.awk"
