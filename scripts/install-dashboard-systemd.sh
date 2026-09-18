#!/usr/bin/env bash
# Compatibility entrypoint: install the linked service pair.
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "$BASE/scripts/install-systemd.sh" "$@"
