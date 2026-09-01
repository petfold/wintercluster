#!/usr/bin/env bash
# CSI snapshot data movement: Velero takes a CSI VolumeSnapshot, then the node
# agent moves the snapshot's data to the BSL (DataUpload), and reverses it on
# restore (DataDownload).
#
# This case exists to check an assumption the agent depends on, not merely to
# add coverage. DESIGN §5.2 triggers card capture when a Backup reaches a
# terminal phase, and asserts that by then *every* object of that backup has
# landed in the bucket. With data movement, the bytes are written by a separate
# DataUpload that runs while the Backup is Finalizing — so if a DataUpload could
# still be running at terminal phase, the agent would snapshot a bucket that is
# missing the backup's volume data, and the card would name a root that cannot
# restore it. The case therefore compares completion timestamps.
#
# Requires hack/e2e/csi.sh and a VolumeSnapshotClass labelled
# velero.io/csi-volumesnapshot-class=true.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/versions.env"
# shellcheck source=../lib.sh
source "$HERE/lib.sh"
export PATH="$HERE/bin:$PATH" S3_EP=http://localhost:8333
NS=wc-csi
BACKUP="csi-$(date +%s)"
SC=${SC:-csi-hostpath-sc}

trap 'kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

log "preconditions"
kubectl get sc "$SC" >/dev/null 2>&1 || { echo "storage class $SC missing; run hack/e2e/csi.sh"; exit 1; }
VSC=$(kubectl get volumesnapshotclass -l velero.io/csi-volumesnapshot-class=true -o name 2>/dev/null | head -1)
[ -n "$VSC" ] || { echo "no VolumeSnapshotClass labelled velero.io/csi-volumesnapshot-class=true"; exit 1; }
echo "  storage class: $SC"
echo "  snapshot class: $VSC"

log "stateful workload with checksummable data"
new_ns "$NS"
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $SC
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: writer
spec:
  containers:
    - name: shell
      image: busybox:1.37
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data
YAML
kubectl -n "$NS" wait --for=condition=Ready pod/writer --timeout=300s
kubectl -n "$NS" exec writer -- sh -c \
  'dd if=/dev/urandom of=/data/blob.bin bs=1M count=20 2>/dev/null;
   echo csi-moved > /data/marker.txt;
   md5sum /data/blob.bin /data/marker.txt > /data/CHECKSUMS'
BEFORE=$(kubectl -n "$NS" exec writer -- cat /data/CHECKSUMS)
sed 's/^/    /' <<<"$BEFORE"

log "backup with --snapshot-move-data"
velero backup create "$BACKUP" --include-namespaces "$NS" --snapshot-move-data --wait
PHASE=$(kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}')
echo "  backup phase: $PHASE"
[ "$PHASE" = "Completed" ] || { velero backup logs "$BACKUP" 2>/dev/null | tail -30; exit 1; }

log "a DataUpload actually ran (a snapshot alone would move no bytes)"
kubectl -n velero get datauploads -o custom-columns=\
'NAME:.metadata.name,PHASE:.status.phase,BYTES:.status.progress.totalBytes,DONE:.status.completionTimestamp' | tail -3 | sed 's/^/  /'
DU=$(kubectl -n velero get datauploads -o jsonpath="{range .items[?(@.metadata.labels.velero\.io/backup-name=='$BACKUP')]}{.status.phase}{'\n'}{end}" | head -1)
[ "$DU" = "Completed" ] || { echo "DataUpload phase=$DU"; kubectl -n velero get datauploads -o yaml | tail -40; exit 1; }

log "does DataUpload finish before the Backup reaches a terminal phase? (DESIGN §5.2)"
BACKUP_DONE=$(kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.completionTimestamp}')
DU_DONE=$(kubectl -n velero get datauploads \
  -o jsonpath="{range .items[?(@.metadata.labels.velero\.io/backup-name=='$BACKUP')]}{.status.completionTimestamp}{'\n'}{end}" | sort | tail -1)
echo "  DataUpload completed: $DU_DONE"
echo "  Backup    completed: $BACKUP_DONE"
python3 - "$DU_DONE" "$BACKUP_DONE" <<'PY'
import sys, datetime
du, bk = (datetime.datetime.fromisoformat(x.replace("Z", "+00:00")) for x in sys.argv[1:3])
if du > bk:
    print(f"  VIOLATION: data landed {(du-bk).total_seconds():.1f}s AFTER the backup went terminal")
    print("  The agent must not trigger on terminal phase alone; DESIGN §5.2 needs revising.")
    sys.exit(1)
print(f"  OK: data landed {(bk-du).total_seconds():.1f}s before the backup went terminal")
PY

log "destroy everything and restore"
kubectl delete ns "$NS" --wait
velero restore create "restore-$BACKUP" --from-backup "$BACKUP" --wait
RPHASE=$(kubectl -n velero get restore "restore-$BACKUP" -o jsonpath='{.status.phase}')
echo "  restore phase: $RPHASE"
[ "$RPHASE" = "Completed" ] || { velero restore logs "restore-$BACKUP" 2>/dev/null | tail -30; exit 1; }
kubectl -n velero get datadownloads -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' 2>/dev/null | tail -2 | sed 's/^/  /'
kubectl -n "$NS" wait --for=condition=Ready pod/writer --timeout=300s

log "byte-compare"
AFTER=$(kubectl -n "$NS" exec writer -- md5sum /data/blob.bin /data/marker.txt)
sed 's/^/    /' <<<"$AFTER"
[ "$BEFORE" = "$AFTER" ] || { echo "MISMATCH"; exit 1; }

printf '\nPASS: CSI snapshot data movement round-trips, and data lands before terminal phase\n'
