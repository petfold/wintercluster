#!/usr/bin/env bash
# The agent's capture step (DESIGN §5.2, step 2), against real Velero output:
# after a backup reaches a terminal phase, a snapshot barrier must force a
# commit and hand back a root that covers it.
#
# This is the case that could not pass before s3warm v0.5.0: the BSL bucket is
# SSE-S3 per DESIGN §5.4, and a bucket holding encrypted objects could not
# commit at all.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/versions.env"
# shellcheck source=../lib.sh
source "$HERE/lib.sh"
export PATH="$HERE/bin:$PATH" S3_EP=http://localhost:8333
NS=wc-barrier
BACKUP="barrier-$(date +%s)"

trap 'kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

log "bucket must be encrypted and sealable, or this proves nothing"
HEAD=$("$HERE/s3.sh" head "$BSL_BUCKET")
echo "  $HEAD"
case "$HEAD" in
  *recipient=age1*) ;;
  *) echo "bucket has no recovery recipient; up.sh should have set one"; exit 1 ;;
esac
SEQ_BEFORE=$(sed -n 's/.*seq=\([0-9]*\).*/\1/p' <<<"$HEAD")

log "workload and backup"
new_ns "$NS"
kubectl -n "$NS" create configmap marker --from-literal=k=v >/dev/null
velero backup create "$BACKUP" --include-namespaces "$NS" --wait >/dev/null
PHASE=$(kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}')
echo "  backup phase: $PHASE"
[ "$PHASE" = "Completed" ] || exit 1

log "objects are encrypted (Velero does not encrypt its own tarballs)"
KEY=$("$HERE/s3.sh" ls "$BSL_BUCKET" "backups/$BACKUP/" | head -1)
SSE=$("$HERE/s3.sh" objhead "$BSL_BUCKET" "$KEY")
echo "  $KEY"
echo "  $SSE"
grep -q 'sse=AES256' <<<"$SSE" || { echo "backup objects are not encrypted"; exit 1; }
grep -q 'ref=<SUPPRESSED>' <<<"$SSE" || { echo "an encrypted object exposed its reference"; exit 1; }

log "snapshot barrier: PUT ?x-swarm-snapshot=velero-$BACKUP"
OUT=$("$HERE/s3.sh" snapshot "$BSL_BUCKET" "velero-$BACKUP")
echo "  $OUT"
ROOT=$(sed -n 's/.*"root":"\([0-9a-f]*\)".*/\1/p' <<<"$OUT")
SEQ=$(sed -n 's/.*"seq":\([0-9]*\).*/\1/p' <<<"$OUT")
[ -n "$ROOT" ] || { echo "no root returned: the chain did not commit"; exit 1; }
[ "${#ROOT}" -eq 64 ] || { echo "root is not a 32-byte reference: $ROOT"; exit 1; }
[ "$SEQ" -gt "${SEQ_BEFORE:-0}" ] || { echo "commit seq did not advance ($SEQ_BEFORE -> $SEQ)"; exit 1; }
echo "  root advanced: seq $SEQ_BEFORE -> $SEQ"

log "the head now points at that root"
"$HERE/s3.sh" head "$BSL_BUCKET" | sed 's/^/  /'
"$HERE/s3.sh" head "$BSL_BUCKET" | grep -q "root=$ROOT" || { echo "head does not match the snapshot root"; exit 1; }

printf '\nPASS: an encrypted BSL bucket commits, and the barrier captures a root covering the backup\n'
