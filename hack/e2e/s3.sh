#!/usr/bin/env bash
# Minimal sigv4 S3 client for the harness. Exists so the harness needs no aws
# CLI or boto3, and so bucket setup uses the same HTTP surface Velero does.
#
#   s3.sh mb <bucket> [recovery-recipient]
#   s3.sh ls <bucket> [prefix]
#   s3.sh snapshot <bucket> <label>
#   s3.sh head <bucket>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/versions.env"
exec python3 "$HERE/s3.py" "$@"
