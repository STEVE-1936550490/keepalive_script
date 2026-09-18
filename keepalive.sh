#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $BASE/scripts/systemd-control.sh ]]; then
    source "$BASE/scripts/systemd-control.sh"
    case ${1:-help} in
        start|stop|restart|status)
            if managed_service_installed; then managed_service_command "$@"; exit; fi;;
    esac
fi
CONFIG_DIR=${KEEPALIVE_CONFIG_DIR:-$BASE/config}
mkdir -p "$BASE/run" "$BASE/logs"
# These are trusted local Bash files, never printed or passed as command arguments.
[[ ! -f $CONFIG_DIR/settings.env ]] || source "$CONFIG_DIR/settings.env"
if [[ -f $CONFIG_DIR/secrets.env ]]; then
    chmod 600 "$CONFIG_DIR/secrets.env"
    source "$CONFIG_DIR/secrets.env"
fi
set +x
TARGET_CPU=${TARGET_CPU:-70}; MAX_CPU=${MAX_CPU:-80}; MIN_FREE_MB=${MIN_FREE_MB:-1024}
WORK_DIR=${WORK_DIR:-/tmp/keepalive_io}; ACTIVE_DURATION_MIN=${ACTIVE_DURATION_MIN:-60}
ACTIVE_DURATION_SPREAD_MIN=${ACTIVE_DURATION_SPREAD_MIN:-15}
INTERVAL_MEAN_MIN=${INTERVAL_MEAN_MIN:-120}; INTERVAL_SPREAD_MIN=${INTERVAL_SPREAD_MIN:-35}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-10485760}
DURATION=${ACTIVE_DURATION_SEC:-}; DURATION_FIXED=0
[[ -z $DURATION ]] || DURATION_FIXED=1
ONCE=0; DRY=0; FILTER=; ROUND=0; ACTIVE_PID=; LOGGER_PID=; WAIT_PID=; REMOTE_ACTIVE=0; FIFO=
PIDFILE=$BASE/run/keepalive.pid
usage() { echo 'Usage: ./keepalive.sh {start|stop|restart|status|run} [--once] [--duration SEC] [--host NAME] [--dry-run]'; }
log_line() {
    local line=$1 size=0
    (
        flock 8
        [[ ! -f $BASE/logs/keepalive.log ]] || size=$(stat -c %s "$BASE/logs/keepalive.log")
        if ((size >= LOG_MAX_BYTES)); then mv -f "$BASE/logs/keepalive.log" "$BASE/logs/keepalive.log.1"; fi
        printf '%s\n' "$line" >> "$BASE/logs/keepalive.log"
    ) 8> "$BASE/run/log.lock"
    printf '%s\n' "$line"
}
log() { local line; printf -v line '%(%Y-%m-%d %H:%M:%S)T [%s] round=%s %s' -1 "$1" "$ROUND" "$2"; log_line "$line"; }
die() { log ERROR "$1"; exit 2; }
identity() {
    local statline
    [[ -r /proc/$1/stat ]] || return 1
    read -r statline < "/proc/$1/stat"
    statline=${statline##*) }
    local fields; read -ra fields <<< "$statline"
    printf '%s' "${fields[19]}"
}
running() {
    local recorded
    [[ -f $PIDFILE ]] || return 1
    read -r SERVICE_PID recorded < "$PIDFILE"
    [[ $SERVICE_PID =~ ^[0-9]+$ && -n $recorded ]] || return 1
    [[ $(identity "$SERVICE_PID") == "$recorded" ]] && kill -0 "$SERVICE_PID" 2>/dev/null
}
stop_service() {
    if ! running; then echo STOPPED; return; fi
    kill -TERM "$SERVICE_PID"
    for ((i=0; i<200; i++)); do
        if ! running; then echo STOPPED; return; fi
        sleep 0.2
    done
    log ERROR 'action=stop_timeout'; return 1
}
command=${1:-help}; (($# == 0)) || shift
case $command in
    status) if running; then echo "RUNNING pid=$SERVICE_PID"; else echo STOPPED; fi; exit;;
    stop) stop_service; exit;;
    restart) stop_service; exec "$BASE/keepalive.sh" start "$@";;
    start|run) ;;
    *) usage; [[ $command == help || $command == --help ]]; exit;;
esac
ORIGINAL_ARGS=("$@")
while (($#)); do
    case $1 in
        --once) ONCE=1; shift;;
        --dry-run) DRY=1; shift;;
        --duration) DURATION=${2:?}; DURATION_FIXED=1; shift 2;;
        --host) FILTER=${2:?}; shift 2;;
        *) die 'reason=invalid_option';;
    esac
done
[[ $ACTIVE_DURATION_MIN =~ ^[1-9][0-9]{0,7}$ ]] || die 'reason=invalid_active_duration'
[[ $ACTIVE_DURATION_SPREAD_MIN =~ ^(0|[1-9][0-9]{0,7})$ ]] || die 'reason=invalid_duration_spread'
((ACTIVE_DURATION_SPREAD_MIN < ACTIVE_DURATION_MIN)) || die 'reason=invalid_duration_spread'
((DURATION_FIXED)) || DURATION=$((ACTIVE_DURATION_MIN*60))
for value in "$DURATION" "$TARGET_CPU" "$MAX_CPU" "$MIN_FREE_MB" "$INTERVAL_MEAN_MIN" "$LOG_MAX_BYTES"; do
    [[ $value =~ ^[1-9][0-9]{0,7}$ ]] || die 'reason=invalid_numeric_setting'
done
[[ $INTERVAL_SPREAD_MIN =~ ^[0-9]{1,7}$ ]] || die 'reason=invalid_spread'
((INTERVAL_SPREAD_MIN < INTERVAL_MEAN_MIN && TARGET_CPU < MAX_CPU && MAX_CPU <= 80)) || die 'reason=unsafe_settings'
[[ $WORK_DIR =~ ^/[a-zA-Z0-9_./-]+$ ]] || die 'reason=invalid_work_dir'
ROWS=(); declare -A NAMES=()
[[ -f $CONFIG_DIR/hosts.conf ]] || die 'reason=missing_hosts_config'
while IFS= read -r row || [[ -n $row ]]; do
    [[ -z $row || $row == \#* ]] && continue
    IFS='|' read -r NAME TYPE USER_NAME PRIVATE_IP PUBLIC_IP PORT AUTH PASSWORD_ENV KEY_FILE ENABLED EXTRA <<< "$row"
    [[ $ENABLED == 0 ]] && continue
    [[ $ENABLED == 1 && -z $EXTRA && $NAME =~ ^[a-zA-Z0-9_-]+$ && -z ${NAMES[$NAME]:-} ]] || die 'reason=invalid_or_duplicate_host'
    NAMES[$NAME]=1
    [[ -z $FILTER || $FILTER == "$NAME" ]] || continue
    case $TYPE in
        local) [[ $AUTH == local ]] || die "host=$NAME reason=invalid_auth";;
        remote)
            [[ $USER_NAME =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ && $PORT =~ ^[1-9][0-9]{0,4}$ ]] || die "host=$NAME reason=invalid_remote"
            ((PORT <= 65535)) || die "host=$NAME reason=invalid_port"
            [[ -n $PRIVATE_IP || -n $PUBLIC_IP ]] || die "host=$NAME reason=missing_ip"
            for address in "$PRIVATE_IP" "$PUBLIC_IP"; do
                [[ -z $address || $address =~ ^[a-zA-Z0-9:][a-zA-Z0-9_.:-]*$ ]] || die "host=$NAME reason=invalid_address"
            done
            [[ $AUTH == key || $AUTH == password ]] || die "host=$NAME reason=invalid_auth"
            [[ $AUTH != password || $PASSWORD_ENV =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "host=$NAME reason=invalid_password_variable";;
        *) die "host=$NAME reason=invalid_type";;
    esac
    ROWS+=("$row")
done < "$CONFIG_DIR/hosts.conf"
((${#ROWS[@]})) || die 'reason=no_matching_enabled_hosts'
if [[ $command == start ]]; then
    if running; then echo "RUNNING pid=$SERVICE_PID"; exit; fi
    nohup "$BASE/keepalive.sh" run "${ORIGINAL_ARGS[@]}" > /dev/null 2>&1 < /dev/null &
    for ((i=0; i<30; i++)); do
        if running; then echo "RUNNING pid=$SERVICE_PID"; exit; fi
        sleep 0.1
    done
    die 'action=start_failed see=logs/keepalive.log'
fi
exec 9> "$BASE/run/keepalive.lock"
flock -n 9 || die 'reason=already_running'
printf '%s %s\n' "$$" "$(identity "$$")" > "$PIDFILE"
ssh_call() {
    if [[ $AUTH == password ]]; then
        SSHPASS=${!PASSWORD_ENV} timeout -k 2 "$1" sshpass -e "${SSH[@]}" "${@:2}" 9>&-
    else timeout -k 2 "$1" "${SSH[@]}" "${@:2}" 9>&-; fi
}
cleanup() {
    local rc=$?
    trap - EXIT TERM INT HUP ERR
    if ((REMOTE_ACTIVE)); then
        # Cancellation is scoped to an unpredictable run id and checked by the worker.
        ssh_call 8 "$USER_NAME@$SELECTED_IP" "d=/tmp/keepalive_ctl_\$(id -u)_$RUN_ID; if test -d \"\$d\"; then : > \"\$d/cancel\"; fi" >/dev/null 2>&1 || :
    fi
    for pid in "$ACTIVE_PID" "$WAIT_PID"; do [[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || :; done
    [[ -z $ACTIVE_PID ]] || wait "$ACTIVE_PID" 2>/dev/null || :
    [[ -z $LOGGER_PID ]] || wait "$LOGGER_PID" 2>/dev/null || :
    [[ -z $FIFO ]] || rm -f -- "$FIFO"
    rm -f -- "$PIDFILE"
    log INFO "action=controller_finish rc=$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
trap 'log ERROR "action=error reason=controller_failure line=$LINENO"' ERR
prepare_ssh() {
    SSH=(ssh -T -p "$PORT" -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
    if [[ $AUTH == password ]]; then
        command -v sshpass >/dev/null && [[ -n ${!PASSWORD_ENV:-} ]] || { log WARN "host=$NAME reason=missing_sshpass_or_password"; return 1; }
        SSH+=(-o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
    else
        [[ -f $KEY_FILE ]] || { log WARN "host=$NAME reason=missing_key"; return 1; }
        SSH+=(-i "$KEY_FILE" -o IdentitiesOnly=yes -o BatchMode=yes)
    fi
    SELECTED_IP=
    for address in "$PRIVATE_IP" "$PUBLIC_IP"; do
        [[ -n $address ]] || continue
        if ssh_call 8 "$USER_NAME@$address" 'true' </dev/null >/dev/null 2>&1; then
            SELECTED_IP=$address
            fallback=; [[ $address != "$PUBLIC_IP" || -z $PRIVATE_IP || $address == "$PRIVATE_IP" ]] || fallback=' fallback=public'
            log INFO "host=$NAME selected_ip=$address$fallback"; return 0
        fi
        log WARN "host=$NAME address=$address action=connect_failed"
    done
    log WARN "host=$NAME action=skip reason=ssh_unreachable"; return 1
}
activate() {
    local rc=0 remote_cmd
    RUN_ID="$(date +%s)-$$-$RANDOM-$RANDOM"
    FIFO=$BASE/run/output.$RUN_ID
    mkfifo -m 600 "$FIFO"
    ( while IFS= read -r line; do log_line "$line"; done < "$FIFO" ) 9>&- & LOGGER_PID=$!
    if [[ $TYPE == local ]]; then
        timeout -k 5 "$((DURATION+15))" env TARGET_CPU="$TARGET_CPU" MAX_CPU="$MAX_CPU" MIN_FREE_MB="$MIN_FREE_MB" WORK_DIR="$WORK_DIR" bash "$BASE/worker.sh" --duration "$DURATION" --host "$NAME" --round "$ROUND" --run-id "$RUN_ID" > "$FIFO" 2>&1 9>&- & ACTIVE_PID=$!
    else
        REMOTE_ACTIVE=1
        printf -v remote_cmd 'TARGET_CPU=%q MAX_CPU=%q MIN_FREE_MB=%q WORK_DIR=%q timeout -k 5 %q bash -s -- --duration %q --host %q --round %q --run-id %q' "$TARGET_CPU" "$MAX_CPU" "$MIN_FREE_MB" "$WORK_DIR" "$((DURATION+15))" "$DURATION" "$NAME" "$ROUND" "$RUN_ID"
        # exec through a subshell so ACTIVE_PID is the timeout process, not a shell wrapper.
        if [[ $AUTH == password ]]; then
            SSHPASS=${!PASSWORD_ENV} timeout -k 5 "$((DURATION+30))" sshpass -e "${SSH[@]}" "$USER_NAME@$SELECTED_IP" "$remote_cmd" < "$BASE/worker.sh" > "$FIFO" 2>&1 9>&- & ACTIVE_PID=$!
        else
            timeout -k 5 "$((DURATION+30))" "${SSH[@]}" "$USER_NAME@$SELECTED_IP" "$remote_cmd" < "$BASE/worker.sh" > "$FIFO" 2>&1 9>&- & ACTIVE_PID=$!
        fi
    fi
    wait "$ACTIVE_PID" || rc=$?
    ACTIVE_PID=; REMOTE_ACTIVE=0
    wait "$LOGGER_PID" || :; LOGGER_PID=
    rm -f -- "$FIFO"; FIFO=
    if ((rc)); then log WARN "host=$NAME action=activation_failed rc=$rc"; return 1; fi
}
normalish_random() { local sum=0; for ((j=0;j<6;j++)); do sum=$((sum+RANDOM)); done; NORMAL=$((sum/6)); }
failures=0
while :; do
    ROUND=$((ROUND+1)); round_start=$SECONDS; count=${#ROWS[@]}; offsets=(); durations=()
    # Stratified slots with central jitter: guaranteed separation, no fixed 90/125/160.
    for ((i=0;i<count;i++)); do
        normalish_random
        if ((ONCE)); then offset=$((i*2 + NORMAL/16384))
        elif ((count == 1)); then offset=$(((INTERVAL_MEAN_MIN-INTERVAL_SPREAD_MIN)*60 + 2*INTERVAL_SPREAD_MIN*60*NORMAL/32768))
        else offset=$(((INTERVAL_MEAN_MIN-INTERVAL_SPREAD_MIN)*60 + (2*INTERVAL_SPREAD_MIN*60*(i*32768+NORMAL))/(count*32768) + i)); fi
        ((ONCE == 0 || i != 0)) || offset=0
        offsets+=("$offset")
        if ((DURATION_FIXED)); then durations+=("$DURATION")
        else
            normalish_random
            durations+=("$(((ACTIVE_DURATION_MIN-ACTIVE_DURATION_SPREAD_MIN)*60 + 2*ACTIVE_DURATION_SPREAD_MIN*60*NORMAL/32768))")
        fi
    done
    # Fisher-Yates shuffle: every permutation is possible, with one activation per host.
    host_order=("${ROWS[@]}")
    for ((i=count-1;i>0;i--)); do
        pick=$((RANDOM%(i+1))); swap=${host_order[i]}
        host_order[i]=${host_order[pick]}; host_order[pick]=$swap
    done
    for ((i=0;i<count;i++)); do
        IFS='|' read -r NAME TYPE USER_NAME PRIVATE_IP PUBLIC_IP PORT AUTH PASSWORD_ENV KEY_FILE ENABLED <<< "${host_order[i]}"
        delay=${offsets[i]}; DURATION=${durations[i]}
        log INFO "host=$NAME next_delay=$((delay/60))m offset_sec=$delay duration=$DURATION target=$TARGET_CPU max_cpu=$MAX_CPU dry_run=$DRY"
    done
    for ((i=0;i<count;i++)); do
        IFS='|' read -r NAME TYPE USER_NAME PRIVATE_IP PUBLIC_IP PORT AUTH PASSWORD_ENV KEY_FILE ENABLED <<< "${host_order[i]}"
        DURATION=${durations[i]}
        delay=$((round_start+offsets[i]-SECONDS))
        if ((DRY == 0 && delay > 0)); then sleep "$delay" 9>&- & WAIT_PID=$!; wait "$WAIT_PID"; WAIT_PID=; fi
        if [[ $TYPE == remote ]]; then
            if ! prepare_ssh; then failures=$((failures+1)); continue; fi
        else log INFO "host=$NAME selected_ip=local"; fi
        ((DRY)) || { activate || failures=$((failures+1)); }
    done
    ((ONCE || DRY)) && break
done
((failures == 0))
