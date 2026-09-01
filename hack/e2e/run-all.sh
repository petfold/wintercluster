#!/usr/bin/env bash
# Run every case against a harness that is already up.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for c in "$HERE"/cases/*.sh; do
  printf '\n========== %s\n' "$(basename "$c")"
  if "$c"; then echo "PASS $(basename "$c")"; else echo "FAIL $(basename "$c")"; fail=1; fi
done
exit $fail
