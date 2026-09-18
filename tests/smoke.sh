#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x keepalive.sh && -x worker.sh ]] || { echo 'FAIL: executable entrypoints missing'; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp keepalive.sh worker.sh "$work/"
mkdir "$work/config"
printf 'local|local|||||local|||1\n' > "$work/config/hosts.conf"
cd "$work"
output=$(./keepalive.sh run --once --dry-run --duration 600)
[[ $output == *'host=local'* && $output == *'duration=600'* ]] || { echo 'FAIL: dry-run'; exit 1; }
if ./keepalive.sh run --once --host absent --dry-run >/dev/null 2>&1; then echo 'FAIL: unknown host accepted'; exit 1; fi
if ./keepalive.sh run --duration nope >/dev/null 2>&1; then echo 'FAIL: invalid duration accepted'; exit 1; fi
if TARGET_CPU=90 ./worker.sh --duration 1 >/dev/null 2>&1; then echo 'FAIL: unsafe target accepted'; exit 1; fi
echo 'PASS: dry-run and invalid-input guards'
