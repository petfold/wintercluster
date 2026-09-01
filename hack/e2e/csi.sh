#!/usr/bin/env bash
# Install csi-driver-host-path and a StorageClass that uses it, so PVCs get
# real CSI volumes rather than the hostPath volumes Velero's file-system backup
# silently skips.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/versions.env"
export PATH="$HERE/bin:$PATH"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "=== csi-driver-host-path $CSI_HOSTPATH_VERSION"
if kubectl get sc csi-hostpath-sc >/dev/null 2>&1; then
  echo "  already installed"
  exit 0
fi

# The driver's own deploy script is the supported path; it pins its sidecar
# images to versions it was tested with.
curl -fsSL --retry 3 -o "$WORK/src.tgz" \
  "https://github.com/kubernetes-csi/csi-driver-host-path/archive/refs/tags/${CSI_HOSTPATH_VERSION}.tar.gz"
tar -xzf "$WORK/src.tgz" -C "$WORK"
SRC="$WORK/csi-driver-host-path-${CSI_HOSTPATH_VERSION#v}"

# Snapshot CRDs and controller: the driver's deploy expects them present.
# Pinned rather than scraped out of the deploy script — that script builds the
# reference with shell functions, so a regex over it yields shell, not a tag.
SNAP_REF=${SNAP_REF:-v8.2.0}
echo "  snapshot CRDs ($SNAP_REF)"
for f in snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
         snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
         snapshot.storage.k8s.io_volumesnapshots.yaml; do
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAP_REF}/client/config/crd/$f" >/dev/null
done
kubectl wait --for=condition=Established --timeout=60s \
  crd/volumesnapshots.snapshot.storage.k8s.io >/dev/null
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAP_REF}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" >/dev/null
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAP_REF}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" >/dev/null

echo "  driver"
"$SRC/deploy/kubernetes-latest/deploy.sh" >/dev/null 2>&1 || \
  "$SRC/deploy/kubernetes-1.30/deploy.sh" >/dev/null 2>&1 || {
    echo "driver deploy script failed" >&2; exit 1; }

kubectl apply -f "$SRC/examples/csi-storageclass.yaml" >/dev/null
kubectl -n default rollout status statefulset/csi-hostpathplugin --timeout=300s 2>/dev/null || \
  kubectl rollout status statefulset/csi-hostpathplugin --timeout=300s
echo "  ready:"
kubectl get sc | sed 's/^/    /'
