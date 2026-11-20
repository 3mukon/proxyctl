#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
for script in "$root"/scripts/*.sh; do /bin/sh -n "$script"; done
/bin/sh "$root/scripts/build.sh" "${1:-}"
/usr/bin/python3 -I -B "$root/Tests/smoke.py" "$root/.build/release"
