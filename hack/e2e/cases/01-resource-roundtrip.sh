#!/usr/bin/env bash
# Resource-only backup and restore: the cheapest thing Velero does, and the
# "get the cluster's brain back" half of a disaster (DESIGN §9).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/versions.env"
export PATH="$HERE/bin:$PATH"
NS=wc-resources
BACKUP="resources-$(date +%s)"

log() { printf '\n--- %s\n' "$*"; }
trap 'kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

log "workload with known contents"
kubectl delete ns "$NS" --ignore-not-found --wait >/dev/null 2>&1 || true
kubectl create ns "$NS"
kubectl -n "$NS" create configmap app-config --from-literal=greeting=hello-winter
kubectl -n "$NS" create secret generic app-secret --from-literal=password=hunter2
kubectl -n "$NS" create deployment web --image=registry.k8s.io/pause:3.10 --replicas=2
kubectl -n "$NS" rollout status deployment/web --timeout=120s

log "backup $BACKUP"
velero backup create "$BACKUP" --include-namespaces "$NS" --wait
velero backup describe "$BACKUP" --details > "${TMPDESC:=$(mktemp)}"; sed -n '1,12p' "$TMPDESC"
PHASE=$(kubectl -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}')
[ "$PHASE" = "Completed" ] || { echo "backup phase=$PHASE"; velero backup logs "$BACKUP" | tail -30; exit 1; }

log "what landed in the bucket"
"$HERE/s3.sh" ls "$BSL_BUCKET" "backups/$BACKUP/" | sed 's/^/  /'

log "destroy the namespace"
kubectl delete ns "$NS" --wait
kubectl get ns "$NS" >/dev/null 2>&1 && { echo "namespace survived"; exit 1; }

log "restore"
velero restore create "restore-$BACKUP" --from-backup "$BACKUP" --wait
RPHASE=$(kubectl -n velero get restore "restore-$BACKUP" -o jsonpath='{.status.phase}')
[ "$RPHASE" = "Completed" ] || { echo "restore phase=$RPHASE"; velero restore logs "restore-$BACKUP" | tail -30; exit 1; }

log "verify contents, not just existence"
kubectl -n "$NS" rollout status deployment/web --timeout=120s
GREETING=$(kubectl -n "$NS" get configmap app-config -o jsonpath='{.data.greeting}')
PASSWORD=$(kubectl -n "$NS" get secret app-secret -o jsonpath='{.data.password}' | base64 -d)
REPLICAS=$(kubectl -n "$NS" get deployment web -o jsonpath='{.spec.replicas}')
echo "  configmap greeting = $GREETING"
echo "  secret password    = $PASSWORD"
echo "  deployment replicas= $REPLICAS"
[ "$GREETING" = "hello-winter" ] || { echo "configmap not restored"; exit 1; }
[ "$PASSWORD" = "hunter2" ]      || { echo "secret not restored"; exit 1; }
[ "$REPLICAS" = "2" ]            || { echo "deployment not restored"; exit 1; }

printf '\nPASS: resource-only backup and restore round-trips through s3warm\n'
