#!/usr/bin/env bash
# File-system backup of a stateful workload (Velero's node-agent + Kopia).
# This is the volume path and the MVP per TASKS.md M1, and the one that puts
# real load on s3warm: Kopia writes many pack blobs, reads them back with
# range GETs, and its repository sits on composite (multipart) objects.
#
# The data is checksummed, so a restore that returns *something* is not
# mistaken for a restore that returns the right bytes.
#
# The volume is an emptyDir, not a PVC, and that is deliberate: kind's default
# storage class (rancher.io/local-path) provisions **hostPath** PVs, and
# Velero's file-system backup skips hostPath volumes outright — no
# PodVolumeBackup is created and the backup still reports Completed, having
# silently captured no data. Covering PVC-backed volumes needs a CSI driver in
# the cluster; see docs/COMPAT.md. What this case exercises — Kopia's
# repository on s3warm, its pack blobs, and a byte-exact restore — is identical
# either way.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/versions.env"
export PATH="$HERE/bin:$PATH" S3_EP=http://localhost:8333
NS=wc-volume
BACKUP="volume-$(date +%s)"

log() { printf '\n--- %s\n' "$*"; }
trap 'kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

log "stateful workload with checksummable data"
kubectl delete ns "$NS" --ignore-not-found --wait >/dev/null 2>&1 || true
kubectl create ns "$NS" >/dev/null
kubectl -n "$NS" apply -f - >/dev/null <<'YAML'
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
      emptyDir: {}
YAML
kubectl -n "$NS" wait --for=condition=Ready pod/writer --timeout=180s

# ~40 MiB of incompressible data: enough to make Kopia produce several pack
# blobs rather than one, so the read path is exercised for real.
kubectl -n "$NS" exec writer -- sh -c \
  'dd if=/dev/urandom of=/data/blob.bin bs=1M count=40 2>/dev/null;
   echo hello-winter > /data/marker.txt;
   md5sum /data/blob.bin /data/marker.txt > /data/CHECKSUMS'
BEFORE=$(kubectl -n "$NS" exec writer -- cat /data/CHECKSUMS)
echo "  checksums before:"; sed 's/^/    /' <<<"$BEFORE"

log "backup with file-system backup (Kopia)"
velero backup create "$BACKUP" --include-namespaces "$NS" \
  --default-volumes-to-fs-backup --wait
kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}{"\n"}' | sed 's/^/  phase: /'
PHASE=$(kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}')
if [ "$PHASE" != "Completed" ]; then
  velero backup logs "$BACKUP" 2>/dev/null | tail -40
  kubectl -n velero get podvolumebackups -o wide 2>/dev/null | tail -5
  exit 1
fi

log "file-system backup actually ran (a skipped volume still reports Completed)"
PVB=$(kubectl -n velero get podvolumebackups \
  -o jsonpath="{range .items[?(@.spec.tag.backup=='$BACKUP')]}{.status.phase} {.status.progress.totalBytes}{'\n'}{end}" 2>/dev/null | head -1)
[ -n "$PVB" ] || PVB=$(kubectl -n velero get podvolumebackups --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].status.phase} {.items[-1:].status.progress.totalBytes}' 2>/dev/null)
echo "  PodVolumeBackup: $PVB"
grep -q '^Completed' <<<"$PVB" || { echo "no completed PodVolumeBackup: the volume was skipped, not backed up"; exit 1; }
BYTES=$(awk '{print $2}' <<<"$PVB")
[ "${BYTES:-0}" -gt $((30 * 1024 * 1024)) ] || { echo "PodVolumeBackup moved only ${BYTES:-0} bytes"; exit 1; }

log "what Kopia wrote to the bucket"
"$HERE/s3.sh" ls "$BSL_BUCKET" "kopia/" | head -12 | sed 's/^/  /'
echo "  ... $("$HERE/s3.sh" ls "$BSL_BUCKET" "kopia/" | wc -l) objects under kopia/"

log "destroy the namespace and its volume"
kubectl delete ns "$NS" --wait
kubectl get ns "$NS" >/dev/null 2>&1 && { echo "namespace survived"; exit 1; }

log "restore"
velero restore create "restore-$BACKUP" --from-backup "$BACKUP" --wait
RPHASE=$(kubectl -n velero get restore "restore-$BACKUP" -o jsonpath='{.status.phase}')
echo "  phase: $RPHASE"
if [ "$RPHASE" != "Completed" ]; then
  velero restore logs "restore-$BACKUP" 2>/dev/null | tail -40
  exit 1
fi
kubectl -n "$NS" wait --for=condition=Ready pod/writer --timeout=300s

log "byte-compare, not existence-check"
AFTER=$(kubectl -n "$NS" exec writer -- md5sum /data/blob.bin /data/marker.txt)
echo "  checksums after:"; sed 's/^/    /' <<<"$AFTER"
if [ "$BEFORE" != "$AFTER" ]; then
  echo "MISMATCH: restored volume data differs"
  diff <(echo "$BEFORE") <(echo "$AFTER") || true
  exit 1
fi
kubectl -n "$NS" exec writer -- sh -c 'md5sum -c /data/CHECKSUMS' | sed 's/^/  /'

printf '\nPASS: Kopia file-system backup and restore is byte-identical through s3warm\n'
