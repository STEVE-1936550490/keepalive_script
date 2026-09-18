#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./keepalive.sh start --once --host local --duration 30
./keepalive.sh start --once --host local --duration 30
./keepalive.sh status | grep '^RUNNING pid='
sleep 5
./keepalive.sh stop
[[ $(./keepalive.sh status) == STOPPED ]]
[[ ! -e run/keepalive.pid ]]
[[ -z $(find /tmp/keepalive_io -mindepth 1 -print -quit) ]]
[[ -z $(find /tmp -maxdepth 1 -name 'keepalive_ctl_*' -print -quit) ]]
# Stop during a long scheduler wait must also release the flock.
./keepalive.sh start
./keepalive.sh stop
./keepalive.sh run --once --dry-run >/dev/null
echo 'PASS: start, duplicate start, stop during activity/wait, cleanup and lock release'
