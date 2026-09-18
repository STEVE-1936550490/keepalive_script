#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cfg=$(mktemp -d)
controller=
trap 'if [[ -n $controller ]]; then kill -TERM "$controller" 2>/dev/null || :; wait "$controller" 2>/dev/null || :; fi; rm -rf -- "$cfg"' EXIT
cp keepalive.sh "$cfg/"
# The scheduler invokes its real activation path; only the load generator is replaced.
cat > "$cfg/worker.sh" <<'WORKER'
#!/usr/bin/env bash
printf 'activation\n' >> "${BASH_SOURCE[0]%/*}/activations"
WORKER
printf 'INTERVAL_MEAN_MIN=120\nINTERVAL_SPREAD_MIN=35\n' > "$cfg/settings.env"
for count in 3 1; do
    : > "$cfg/hosts.conf"
    : > "$cfg/activations"
    for ((i=1;i<=count;i++)); do printf 'host%s|local|||||local|||1\n' "$i"; done > "$cfg/hosts.conf"
KEEPALIVE_CONFIG_DIR=$cfg "$cfg/keepalive.sh" run --dry-run > "$cfg/output"
awk -v count="$count" '
/offset_sec=/ {
    for(i=1;i<=NF;i++) {split($i,a,"="); if(a[1]=="offset_sec") x=a[2]+0; if(a[1]=="duration") d=a[2]+0}
    if(x!=expected) bad=1
    expected+=d; n++
}
END {if(bad || n!=count) exit 1}
' "$cfg/output" || { echo 'FAIL: startup plan must begin immediately and estimate serial durations'; exit 1; }
    KEEPALIVE_CONFIG_DIR=$cfg "$cfg/keepalive.sh" run > "$cfg/live" 2>&1 & controller=$!
    ready=0
    for ((i=0;i<100;i++)); do
        if [[ $(grep -c 'round=2 .*offset_sec=' "$cfg/live" || :) == "$count" ]]; then ready=1; break; fi
        sleep 0.05
    done
    ((ready)) || { echo 'FAIL: startup round inserted a delay between hosts'; exit 1; }
    sleep 0.2
    [[ $(wc -l < "$cfg/activations") == "$count" ]] || { echo 'FAIL: second round did not retain its wait'; exit 1; }
    awk -v count="$count" '
    /round=2 .*offset_sec=/ {
        for(i=1;i<=NF;i++) if($i ~ /^offset_sec=/) {split($i,a,"="); x=a[2]+0}
        if(x<5100 || x>9303 || (n && x<=prev)) bad=1
        prev=x; n++
    }
    END {if(bad || n!=count) exit 1}
    ' "$cfg/live"
    kill -TERM "$controller"; wait "$controller" || :; controller=
done
echo 'PASS: immediate serial startup, estimated plan and retained round-two delays for one/multiple hosts'
