#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $(nproc) < 16 )); then
    echo 'SKIP: threshold test needs at least 16 CPUs to keep its single busy loop lightweight'
    exit 0
fi
# One owned busy process adds only about 3% on this 32-core machine.
# Use a low test threshold to exercise pause without stressing CPU to 80%.
pid=
trap '[[ -z $pid ]] || kill "$pid" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
( while :; do :; done ) & pid=$!
TARGET_CPU=1 MAX_CPU=2 MIN_FREE_MB=99999999 ./worker.sh --duration 8 --run-id "guard-$$" > logs/guard-test.log
grep 'action=cpu_pause' logs/guard-test.log
grep 'action=disk_skip' logs/guard-test.log
grep 'action=finish rc=0' logs/guard-test.log
kill "$pid"; wait "$pid" 2>/dev/null || true; pid=
[[ -z $(find /tmp/keepalive_io -mindepth 1 -print -quit) ]]
echo 'PASS: CPU pause, low disk space skip and cleanup'
