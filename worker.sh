#!/usr/bin/env bash
# Bash 5+; only processes started by this worker are terminated.
set -Eeuo pipefail
set +x
umask 077
TARGET_CPU=${TARGET_CPU:-70}; MAX_CPU=${MAX_CPU:-80}
MIN_FREE_MB=${MIN_FREE_MB:-1024}; WORK_DIR=${WORK_DIR:-/tmp/keepalive_io}
DURATION=${ACTIVE_DURATION_SEC:-600}; HOST_NAME=local; ROUND=0; RUN_ID="manual-$$-$RANDOM"
while (($#)); do
    case $1 in
        --duration) DURATION=${2:?}; shift 2;;
        --host) HOST_NAME=${2:?}; shift 2;;
        --round) ROUND=${2:?}; shift 2;;
        --run-id) RUN_ID=${2:?}; shift 2;;
        *) echo 'invalid worker option' >&2; exit 2;;
    esac
done
log() { printf '%(%Y-%m-%d %H:%M:%S)T [%s] round=%s host=%s %s\n' -1 "$1" "$ROUND" "$HOST_NAME" "$2"; }
for number in "$DURATION" "$TARGET_CPU" "$MAX_CPU" "$MIN_FREE_MB"; do
    [[ $number =~ ^[1-9][0-9]{0,7}$ ]] || { log ERROR 'action=error reason=invalid_number'; exit 2; }
done
((TARGET_CPU < MAX_CPU && MAX_CPU <= 80)) || { log ERROR 'action=error reason=unsafe_cpu_limit'; exit 2; }
[[ $RUN_ID =~ ^[a-zA-Z0-9_-]+$ && $HOST_NAME =~ ^[a-zA-Z0-9_-]+$ && $ROUND =~ ^[0-9]+$ ]] || exit 2
[[ ${BASH_VERSINFO[0]} -ge 5 ]] || { log ERROR 'action=error reason=bash5_required'; exit 2; }
CPU_PIDS=(); DISK_PID=; TIMER_PID=; WAIT_PID=; TASK_DIR=; CONTROL_DIR=
cleanup() {
    local rc=$?
    trap - EXIT ERR
    # timeout can signal the process group while we are already cleaning up.
    # A repeated TERM must not interrupt child reaping or temporary-file removal.
    trap '' INT TERM HUP
    for pid in "${CPU_PIDS[@]}" "$DISK_PID" "$TIMER_PID" "$WAIT_PID"; do
        [[ -n $pid ]] && kill -TERM "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    [[ -z $TASK_DIR ]] || rm -rf -- "$TASK_DIR"
    [[ -z $CONTROL_DIR ]] || rm -rf -- "$CONTROL_DIR"
    log INFO "action=finish rc=$rc run_id=$RUN_ID"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
trap 'log ERROR "action=error reason=worker_failure line=$LINENO"' ERR
control="/tmp/keepalive_ctl_${UID}_${RUN_ID}"
mkdir -m 700 -- "$control"
CONTROL_DIR=$control
printf '%s\n' "$$" > "$CONTROL_DIR/pid"
[[ ! -L $WORK_DIR ]] || { log ERROR 'action=error reason=symlink_work_dir'; exit 1; }
mkdir -p -m 700 -- "$WORK_DIR"
[[ -O $WORK_DIR && -d $WORK_DIR ]] || { log ERROR 'action=error reason=work_dir_owner'; exit 1; }
TASK_DIR=$(mktemp -d "$WORK_DIR/task.XXXXXXXX")
printf '0\n' > "$TASK_DIR/duty"
# Explicit hard deadline also protects direct worker invocations and disconnected SSH.
owner=$BASHPID
( child=; trap '[[ -z $child ]] || kill "$child" 2>/dev/null || :; exit 0' TERM INT HUP; sleep "$((DURATION + 10))" & child=$!; wait "$child"; kill -TERM "$owner" 2>/dev/null ) & TIMER_PID=$!
nap() { sleep "$1" & WAIT_PID=$!; wait "$WAIT_PID"; WAIT_PID=; }
snapshot() {
    local label u n s idle io irq soft steal guest guestnice rest
    read -r label u n s idle io irq soft steal guest guestnice rest < /proc/stat
    TOTAL=$((u+n+s+idle+io+irq+soft+steal)); IDLE=$((idle+io))
}
cpu_loop() {
    local sleeper= duty now until_us cycle_end rest_us delay
    trap '[[ -z $sleeper ]] || kill "$sleeper" 2>/dev/null || :; exit 0' TERM INT HUP
    # Phase offsets prevent every core entering the busy part simultaneously.
    printf -v delay '0.%03d' "$((RANDOM % 200))"
    sleep "$delay" & sleeper=$!; wait "$sleeper" || :; sleeper=
    while :; do
        read -r duty < "$TASK_DIR/duty" || duty=0
        now=${EPOCHREALTIME/./}; cycle_end=$((now+200000)); until_us=$((now+duty*2000))
        while (( ${EPOCHREALTIME/./} < until_us )); do :; done
        rest_us=$((cycle_end-${EPOCHREALTIME/./}))
        if ((rest_us > 0)); then
            printf -v delay '0.%06d' "$rest_us"
            sleep "$delay" & sleeper=$!; wait "$sleeper" || :; sleeper=
        fi
    done
}
write_duty() { printf '%s\n' "$1" > "$TASK_DIR/duty.new"; mv -f "$TASK_DIR/duty.new" "$TASK_DIR/duty"; }
disk_cycle() {
    local free size
    free=$(df -Pm -- "$TASK_DIR" | awk 'NR==2 {print $4}')
    size=$((32 + RANDOM % 97))
    if [[ ! $free =~ ^[0-9]+$ ]] || ((free < MIN_FREE_MB + size)); then
        log WARN "action=disk_skip free_mb=${free:-unknown} min_free_mb=$MIN_FREE_MB"; return
    fi
    # timeout owns and terminates its dd child; the parent records this subshell too.
    local io_pid=
    trap '[[ -z $io_pid ]] || kill -TERM "$io_pid" 2>/dev/null; wait 2>/dev/null || :; exit 143' TERM INT HUP
    timeout -k 2 15 dd if=/dev/zero of="$TASK_DIR/io.bin" bs=1M count="$size" conv=fdatasync status=none & io_pid=$!
    wait "$io_pid" || { log WARN 'action=error reason=disk_write_failed'; return 1; }
    timeout -k 2 15 dd if="$TASK_DIR/io.bin" of=/dev/null bs=1M status=none & io_pid=$!
    wait "$io_pid" || { log WARN 'action=error reason=disk_read_failed'; return 1; }
    rm -f -- "$TASK_DIR/io.bin"
    log INFO "action=disk disk_write_mb=$size"
}
CORES=$(nproc)
log INFO "action=start run_id=$RUN_ID duration=$DURATION cores=$CORES target=$TARGET_CPU max_cpu=$MAX_CPU"
start=$SECONDS
snapshot; previous_total=$TOTAL; previous_idle=$IDLE
nap 1
snapshot
cpu=$((100*(TOTAL-previous_total-IDLE+previous_idle)/(TOTAL-previous_total+1)))
# /proc/stat uses all online CPUs. Report affinity/container restrictions honestly.
online=$(grep -c '^cpu[0-9]' /proc/stat)
if ((CORES < online)); then log WARN "reason=restricted_cpu_capacity allowed=$CORES online=$online target_may_be_unreachable=1"; fi
duty=0
if ((cpu < TARGET_CPU)); then duty=$(((TARGET_CPU-cpu)*online/CORES)); fi
((duty <= TARGET_CPU)) || duty=$TARGET_CPU
write_duty "$duty"
for ((i=0; i<CORES; i++)); do cpu_loop & CPU_PIDS+=("$!"); done
previous_total=$TOTAL; previous_idle=$IDLE; next_sample=$((SECONDS+3)); next_disk=$((SECONDS+2))
while ((SECONDS-start < DURATION)); do
    [[ ! -e $CONTROL_DIR/cancel ]] || { log INFO 'action=cancel'; exit 143; }
    if ((SECONDS >= next_sample)); then
        snapshot; delta=$((TOTAL-previous_total))
        cpu=$((100*(delta-IDLE+previous_idle)/(delta+1)))
        if ((cpu >= MAX_CPU)); then duty=0; log WARN "action=cpu_pause cpu=$cpu max_cpu=$MAX_CPU"
        else
            duty=$((duty + (TARGET_CPU-cpu)*online*3/(CORES*4)))
            ((duty >= 0)) || duty=0
            ((duty <= TARGET_CPU)) || duty=$TARGET_CPU
        fi
        write_duty "$duty"
        log INFO "action=cpu cpu=$cpu target=$TARGET_CPU duty=$duty"
        previous_total=$TOTAL; previous_idle=$IDLE; next_sample=$((SECONDS+3))
    fi
    if [[ -n $DISK_PID ]] && ! kill -0 "$DISK_PID" 2>/dev/null; then wait "$DISK_PID" || :; DISK_PID=; fi
    if ((SECONDS >= next_disk)) && [[ -z $DISK_PID ]]; then
        disk_cycle & DISK_PID=$!; next_disk=$((SECONDS+30+RANDOM%61))
    fi
    nap 0.2
done
