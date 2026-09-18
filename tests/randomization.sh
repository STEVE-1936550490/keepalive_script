#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp keepalive.sh worker.sh "$work/"
mkdir "$work/config"
for ((n=1;n<=20;n++)); do printf 'host%02d|local|||||local|||1\n' "$n"; done > "$work/config/hosts.conf"
printf 'ACTIVE_DURATION_MIN=60\nACTIVE_DURATION_SPREAD_MIN=15\n' > "$work/config/settings.env"
# Fixed seed makes the random sample reproducible, without asserting implementation values.
bash -c 'RANDOM=42; source "$1" run --dry-run' _ "$work/keepalive.sh" > "$work/plan"
awk '
/offset_sec=/ {
    for(i=1;i<=NF;i++) {
        split($i,f,"=")
        if(f[1]=="duration") duration=f[2]+0
        if(f[1]=="offset_sec") offset=f[2]+0
    }
    if(duration<2700 || duration>4500 || (n && offset<=previous)) bad=1
    seen[duration]=1; previous=offset; n++
}
END {for(x in seen) distinct++; if(bad || n!=20 || distinct<2) exit 1}
' "$work/plan" || { echo 'FAIL: durations must vary per host within 45–75 minutes'; exit 1; }
awk '/offset_sec=/ {
    for(i=1;i<=NF;i++) if($i ~ /^host=/) {split($i,f,"="); name=f[2]; indexnum=substr(name,5)+0}
    if(seen[name]++) bad=1
    if(n && indexnum!=previous%20+1) shuffled=1
    previous=indexnum; n++
} END {if(bad || n!=20 || !shuffled) exit 1}' "$work/plan" || { echo 'FAIL: host order must be shuffled, not only rotated'; exit 1; }
# Explicit CLI and environment durations override randomization.
"$work/keepalive.sh" run --once --dry-run --duration 30 > "$work/fixed"
ACTIVE_DURATION_SEC=17 "$work/keepalive.sh" run --once --dry-run > "$work/env"
for item in fixed:30 env:17; do
    file=${item%:*}; expected=${item#*:}
    awk -v expected="$expected" '/offset_sec=/ {for(i=1;i<=NF;i++) if($i ~ /^duration=/) {split($i,f,"="); if(f[2]!=expected) bad=1; n++}} END {if(bad || n!=20) exit 1}' "$work/$file"
done
printf 'ACTIVE_DURATION_MIN=60\nACTIVE_DURATION_SPREAD_MIN=0\n' > "$work/config/settings.env"
"$work/keepalive.sh" run --once --dry-run > "$work/no-spread"
awk '/offset_sec=/ {for(i=1;i<=NF;i++) if($i ~ /^duration=/ && $i!="duration=3600") bad=1} END {exit bad}' "$work/no-spread"
printf 'ACTIVE_DURATION_MIN=60\nACTIVE_DURATION_SPREAD_MIN=60\n' > "$work/config/settings.env"
if "$work/keepalive.sh" run --dry-run > /dev/null 2>&1; then echo 'FAIL: invalid spread accepted'; exit 1; fi
printf 'ACTIVE_DURATION_MIN=60\nACTIVE_DURATION_SPREAD_MIN=15\nTARGET_CPU=1\nWORK_DIR=%s/io\n' "$work" > "$work/config/settings.env"
"$work/keepalive.sh" run --once --host host01 --duration 3 > "$work/actual"
awk '/action=start / && /duration=3 / {started=1} /action=finish rc=0 / {finished=1} END {if(!started || !finished) exit 1}' "$work/actual"
echo 'PASS: variable bounded durations, shuffled host order, explicit overrides, zero spread and invalid-spread guard'
