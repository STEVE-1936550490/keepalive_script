#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
cp keepalive.sh worker.sh "$work/"
mkdir "$work/config"
printf 'local|local|||||local|||1\n' > "$work/config/hosts.conf"
printf 'TARGET_CPU=1\nWORK_DIR=%s/io\n' "$work" > "$work/config/settings.env"
trap 'rc=$?; if ((rc)); then cat "$work/logs/keepalive.log"; fi; "$work/keepalive.sh" stop >/dev/null 2>&1 || true; rm -rf -- "$work"' EXIT
cd "$work"
./keepalive.sh start --once --host local --duration 30
./keepalive.sh start --once --host local --duration 30
./keepalive.sh status | grep '^RUNNING pid='
sleep 5
./keepalive.sh stop
[[ $(./keepalive.sh status) == STOPPED ]]
[[ ! -e run/keepalive.pid ]]
[[ -z $(find "$work/io" -mindepth 1 -print -quit) ]]
grep -q 'host=local action=finish rc=143' logs/keepalive.log
! grep -q 'reason=worker_failure' logs/keepalive.log
# Stop during a long scheduler wait must also release the flock.
./keepalive.sh start
./keepalive.sh stop
./keepalive.sh run --once --dry-run >/dev/null
echo 'PASS: start, duplicate start, stop during activity/wait, cleanup and lock release'
