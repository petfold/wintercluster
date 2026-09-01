#!/usr/bin/env bash
# Tear the harness down. Safe to run when nothing is up.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/versions.env"
export PATH="$HERE/bin:$PATH"
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
docker rm -f wc-s3warm wc-fakebee >/dev/null 2>&1 || true
rm -f "$HERE/.credentials" "$HERE/.s3url" "$HERE/.batch"
echo "harness down"
