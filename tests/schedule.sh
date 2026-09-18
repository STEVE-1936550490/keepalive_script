#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cfg=$(mktemp -d)
trap 'rm -rf -- "$cfg"' EXIT
cp keepalive.sh worker.sh "$cfg/"
cat > "$cfg/hosts.conf" <<'HOSTS'
a|local|||||local|||1
b|local|||||local|||1
c|local|||||local|||1
HOSTS
printf 'INTERVAL_MEAN_MIN=120\nINTERVAL_SPREAD_MIN=35\n' > "$cfg/settings.env"
KEEPALIVE_CONFIG_DIR=$cfg "$cfg/keepalive.sh" run --dry-run > "$cfg/output"
awk '
/offset_sec=/ {
    for(i=1;i<=NF;i++) if($i ~ /^offset_sec=/) {split($i,a,"="); x=a[2]}
    if(x<5100 || x>9303 || (n && x<=prev)) exit 1
    prev=x; n++
}
END {if(n!=3) exit 1}
' "$cfg/output"
echo 'PASS: three hosts, distinct sorted offsets within configured window'
