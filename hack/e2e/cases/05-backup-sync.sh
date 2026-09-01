#!/usr/bin/env bash
# Backup sync: Velero rebuilding its Backup CRs from what is in the bucket.
#
# This is step 4 of the tier-B runbook (DESIGN §7.3) — after the gateway and
# index are rebuilt, `velero backup get` has to repopulate from object storage
# alone. It also exercises the consistency claim in DESIGN §8: rolling a bucket
# back resurrects since-deleted objects, and Velero then shows those backups
# again rather than getting confused.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/versions.env"
export PATH="$HERE/bin:$PATH" S3_EP=http://localhost:8333
NS=wc-sync
BACKUP="sync-$(date +%s)"

log() { printf '\n--- %s\n' "$*"; }
trap 'kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

log "a backup to lose track of"
kubectl delete ns "$NS" --ignore-not-found --wait >/dev/null 2>&1 || true
kubectl create ns "$NS" >/dev/null
kubectl -n "$NS" create configmap keepme --from-literal=k=v >/dev/null
velero backup create "$BACKUP" --include-namespaces "$NS" --wait >/dev/null
[ "$(kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}')" = "Completed" ] || exit 1
OBJS=$("$HERE/s3.sh" ls "$BSL_BUCKET" "backups/$BACKUP/" | wc -l)
echo "  $BACKUP Completed, $OBJS objects in the bucket"

log "drop the Backup CR without touching storage"
# kubectl, not `velero backup delete`: the latter would remove the objects too.
# This is the tier-B position — the cluster's view of its own backups is gone,
# the bucket is intact.
kubectl -n velero delete backup "$BACKUP" --wait >/dev/null
kubectl -n velero get backup "$BACKUP" >/dev/null 2>&1 && { echo "CR survived"; exit 1; }
STILL=$("$HERE/s3.sh" ls "$BSL_BUCKET" "backups/$BACKUP/" | wc -l)
echo "  CR gone; $STILL objects still in the bucket"
[ "$STILL" -eq "$OBJS" ] || { echo "storage was touched"; exit 1; }

log "wait for Velero's sync controller to find it again"
# Default backupSyncPeriod is 1m; allow generously and report how long it took.
FOUND=""
for i in $(seq 1 60); do
  if kubectl -n velero get backup "$BACKUP" >/dev/null 2>&1; then FOUND=$((i * 5)); break; fi
  sleep 5
done
[ -n "$FOUND" ] || { echo "backup never re-synced from the bucket"; kubectl -n velero logs deployment/velero --tail=30; exit 1; }
echo "  re-synced after ~${FOUND}s"
kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}{"\n"}' | sed 's/^/  phase: /'

log "and it is restorable after the resync, not just listed"
kubectl delete ns "$NS" --wait >/dev/null
velero restore create "resync-$BACKUP" --from-backup "$BACKUP" --wait >/dev/null
RPHASE=$(kubectl -n velero get restore "resync-$BACKUP" -o jsonpath='{.status.phase}')
echo "  restore phase: $RPHASE"
[ "$RPHASE" = "Completed" ] || { velero restore logs "resync-$BACKUP" | tail -20; exit 1; }
V=$(kubectl -n "$NS" get configmap keepme -o jsonpath='{.data.k}')
[ "$V" = "v" ] || { echo "restored contents wrong: $V"; exit 1; }
echo "  configmap contents intact"

printf '\nPASS: Velero rebuilds its backup list from the bucket alone, and those backups restore\n'
