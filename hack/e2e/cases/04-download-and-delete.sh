#!/usr/bin/env bash
# Two paths Velero uses that are easy to overlook and both touch s3warm
# directly: `velero backup download` (a presigned GET) and backup deletion.
#
# Deletion matters to this project specifically. Velero removes the objects, so
# the S3 view goes; the bytes stay on Swarm until their postage batch expires,
# and every pre-deletion commit root still describes them. That asymmetry is
# the ransomware-resistance claim in DESIGN §4, and it is also the compliance
# caveat, so the case demonstrates both halves.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/versions.env"
# shellcheck source=../lib.sh
source "$HERE/lib.sh"
export PATH="$HERE/bin:$PATH" S3_EP=http://localhost:8333
NS=wc-dl
BACKUP="dl-$(date +%s)"
WORK=$(mktemp -d)

trap 'kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

log "workload and backup"
new_ns "$NS"
kubectl -n "$NS" create configmap payload --from-literal=marker=downloadable >/dev/null
velero backup create "$BACKUP" --include-namespaces "$NS" --wait >/dev/null
[ "$(kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}')" = "Completed" ] || exit 1
echo "  $BACKUP Completed"

log "capture a commit root before deletion (what a card would hold)"
SNAP=$("$HERE/s3.sh" snapshot "$BSL_BUCKET" "velero-$BACKUP")
ROOT=$(sed -n 's/.*"root":"\([0-9a-f]*\)".*/\1/p' <<<"$SNAP")
echo "  root: $ROOT"
[ "${#ROOT}" -eq 64 ] || exit 1

log "velero backup download (presigned GET through s3warm)"
velero backup download "$BACKUP" --output "$WORK/$BACKUP.tar.gz" 2>&1 | sed 's/^/  /'
[ -s "$WORK/$BACKUP.tar.gz" ] || { echo "download produced nothing"; exit 1; }
gzip -t "$WORK/$BACKUP.tar.gz" || { echo "downloaded archive is not valid gzip"; exit 1; }
echo "  $(wc -c < "$WORK/$BACKUP.tar.gz") bytes, valid gzip"
# Captured first: `tar | head` closes the pipe, tar takes SIGPIPE, and under
# `set -o pipefail` that aborts the script with no message.
LIST=$(tar -tzf "$WORK/$BACKUP.tar.gz")
sed -n '1,5p' <<<"$LIST" | sed 's/^/    /'
grep -q 'configmaps' <<<"$LIST" || {
  echo "archive has no configmaps: presigned GET returned the wrong object"; exit 1; }

log "objects present before deletion"
BEFORE=$("$HERE/s3.sh" ls "$BSL_BUCKET" "backups/$BACKUP/" | wc -l)
echo "  $BEFORE objects under backups/$BACKUP/"
[ "$BEFORE" -gt 0 ] || exit 1

log "velero backup delete"
velero backup delete "$BACKUP" --confirm 2>&1 | sed 's/^/  /'
for _ in $(seq 1 60); do
  kubectl -n velero get backup "$BACKUP" >/dev/null 2>&1 || break
  sleep 2
done
kubectl -n velero get backup "$BACKUP" >/dev/null 2>&1 && { echo "Backup CR survived deletion"; exit 1; }
AFTER=$("$HERE/s3.sh" ls "$BSL_BUCKET" "backups/$BACKUP/" | wc -l)
echo "  $AFTER objects under backups/$BACKUP/ after deletion"
[ "$AFTER" -eq 0 ] || { echo "objects survived in the S3 view"; exit 1; }

log "but the pre-deletion root still describes them (DESIGN §4)"
# Restoring the bucket to that root brings the object set back: deletion on
# Swarm is stamp expiry, not an S3 DELETE.
"$HERE/s3.sh" restore "$BSL_BUCKET" "$ROOT" | sed 's/^/  /'
REVIVED=$("$HERE/s3.sh" ls "$BSL_BUCKET" "backups/$BACKUP/" | wc -l)
echo "  $REVIVED objects after restoring the bucket to the captured root"
[ "$REVIVED" -eq "$BEFORE" ] || { echo "rollback did not revive the deleted object set"; exit 1; }

printf '\nPASS: presigned download works; deletion clears the S3 view while a captured root still restores it\n'
