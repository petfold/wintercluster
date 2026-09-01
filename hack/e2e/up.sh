#!/usr/bin/env bash
# Bring up the M1 harness: a kind cluster, an s3warm gateway it can reach, and
# Velero configured to back up to that gateway.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$HERE/versions.env"
export PATH="$HERE/bin:$PATH"

log() { printf '\n=== %s\n' "$*"; }

log "toolchain"
"$HERE/tools.sh" >/dev/null
kind version

log "kind cluster: $CLUSTER_NAME"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "  already exists"
else
  kind create cluster --name "$CLUSTER_NAME" --wait 120s
fi
kubectl cluster-info --context "kind-$CLUSTER_NAME" | head -2

# The gateway runs on kind's own docker network so cluster pods can reach it.
# Pods cannot resolve docker container names (no Kubernetes DNS entry for
# them), so the BSL is pointed at the container's IP on that network.
log "s3warm gateway (from $S3WARM_REPO)"
[ -d "$S3WARM_REPO" ] || { echo "s3warm checkout not found at $S3WARM_REPO; set S3WARM_REPO" >&2; exit 1; }
docker rm -f wc-fakebee wc-s3warm >/dev/null 2>&1 || true
docker build -q -t wintercluster/s3warm:e2e "$S3WARM_REPO" >/dev/null

# BEE_MODE=fake (default) runs the in-tree stand-in, which is what CI uses.
# BEE_MODE=live points the gateway at a real Bee node on the host: backups then
# land on Swarm proper, which is the only way to know the whole thing works
# rather than that it works against a model of Bee.
BEE_EXTRA=()
if [ "${BEE_MODE:-fake}" = "live" ]; then
  BEE_HOST_API=${BEE_HOST_API:-http://localhost:1633}
  curl -sf -m 10 "$BEE_HOST_API/health" >/dev/null || {
    echo "no Bee node answering at $BEE_HOST_API" >&2; exit 1; }
  # Pick a usable batch with real capacity rather than buying one: real
  # postage costs real BZZ, and the harness must never spend it silently.
  BATCH=$(curl -sf -m 15 "$BEE_HOST_API/stamps" | python3 -c '
import json, sys
best = None
for b in json.load(sys.stdin)["stamps"]:
    if not b["usable"]:
        continue
    free = 2 ** (b["depth"] - 16) - b["utilization"]
    if b["batchTTL"] > 1800 and free > 0 and (best is None or free > best[1]):
        best = (b["batchID"], free)
print(best[0] if best else "")')
  [ -n "$BATCH" ] || { echo "no usable batch with capacity and >30m TTL on $BEE_HOST_API" >&2; exit 1; }
  echo "  live Bee at $BEE_HOST_API, batch ${BATCH:0:16}..."
  # A Bee node normally binds its API to 127.0.0.1, so a container on a bridge
  # network cannot reach it (connection refused via host-gateway). Run the
  # gateway on the host network instead; pods then reach it through kind's own
  # network gateway, which is the host.
  BEE_EXTRA=(--network host -e "S3WARM_BEE_API=$BEE_HOST_API")
  GATEWAY_ON_HOST=1
else
  docker run -d --name wc-fakebee --network kind --entrypoint fakebee \
    wintercluster/s3warm:e2e >/dev/null
  until docker exec wc-fakebee wget -qO- http://localhost:1633/health >/dev/null 2>&1; do sleep 1; done
  BATCH=$(docker run --rm --network kind curlimages/curl:8.11.1 -sf \
    -X POST "http://wc-fakebee:1633/stamps/100000000000/24" \
    | sed -n 's/.*"batchID":"\([0-9a-f]*\)".*/\1/p')
  [ -n "$BATCH" ] || { echo "could not buy a dev postage batch" >&2; exit 1; }
  echo "  fakebee, batch: $BATCH"
  BEE_EXTRA=(--network kind -e "S3WARM_BEE_API=http://wc-fakebee:1633")
  GATEWAY_ON_HOST=0
fi

docker run -d --name wc-s3warm \
  "${BEE_EXTRA[@]}" \
  -e S3WARM_BATCH_ID="$BATCH" \
  -e S3WARM_ACCESS_KEY="$S3_ACCESS_KEY" \
  -e S3WARM_SECRET_KEY="$S3_SECRET_KEY" \
  -e S3WARM_DB=/data/s3warm.db \
  $( [ "$GATEWAY_ON_HOST" = 1 ] || echo "-p 8333:8333" ) \
  wintercluster/s3warm:e2e >/dev/null
until curl -sf -o /dev/null http://localhost:8333/_s3warm/ready 2>/dev/null; do sleep 1; done

if [ "$GATEWAY_ON_HOST" = 1 ]; then
  # kind's network gateway is the host, so this is where pods find the gateway.
  # kind's network is dual-stack; take the IPv4 gateway. An IPv6 literal would
  # also need brackets in the URL, and Velero's config takes a plain string.
  S3WARM_IP=$(docker network inspect kind \
    -f '{{range .IPAM.Config}}{{if not (regexMatch ":" .Gateway)}}{{.Gateway}}{{end}}{{end}}' 2>/dev/null)
  [ -n "$S3WARM_IP" ] || S3WARM_IP=$(docker network inspect kind \
    --format '{{json .IPAM.Config}}' | python3 -c 'import json,sys; print(next(c["Gateway"] for c in json.load(sys.stdin) if ":" not in c.get("Gateway","")))')
else
  S3WARM_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' wc-s3warm)
fi
S3_URL="http://${S3WARM_IP}:8333"
echo "  reachable from pods at $S3_URL"
echo "$S3_URL" > "$HERE/.s3url"
echo "$BATCH"  > "$HERE/.batch"

# DESIGN §5.4 mandates SSE-S3 on the BSL bucket: Velero does not client-side
# encrypt its resource tarballs, and they contain every Secret in the cluster.
# That means the bucket also needs a recovery recipient, or its commit chain
# cannot carry the encrypted references and stops — which would silently
# remove the thing wintercluster is built on. Testing any other shape would be
# testing a configuration nobody should deploy.
log "recovery keypair"
if [ ! -s "$HERE/.recovery-identity" ]; then
  ( cd "$HERE/agekeygen" && go run . ) > "$HERE/.recovery-keys"
  head -1 "$HERE/.recovery-keys" > "$HERE/.recovery-recipient"
  tail -1 "$HERE/.recovery-keys" > "$HERE/.recovery-identity"
  chmod 600 "$HERE/.recovery-keys" "$HERE/.recovery-identity"
  rm -f "$HERE/.recovery-keys"
  echo "  generated"
else
  echo "  reusing existing"
fi
RECIPIENT=$(cat "$HERE/.recovery-recipient")
echo "  recipient: $RECIPIENT"

log "BSL bucket: $BSL_BUCKET (SSE-S3, sealed chain)"
"$HERE/s3.sh" mb "$BSL_BUCKET" "$RECIPIENT"
"$HERE/s3.sh" sse-on "$BSL_BUCKET"
"$HERE/s3.sh" head "$BSL_BUCKET" | sed "s/^/  /"

log "velero $VELERO_VERSION"
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
cat > "$HERE/.credentials" <<CRED
[default]
aws_access_key_id=$S3_ACCESS_KEY
aws_secret_access_key=$S3_SECRET_KEY
CRED
velero install \
  --provider aws \
  --plugins "velero/velero-plugin-for-aws:${VELERO_PLUGIN_AWS_VERSION}" \
  --bucket "$BSL_BUCKET" \
  --secret-file "$HERE/.credentials" \
  --use-volume-snapshots=false \
  --use-node-agent \
  --backup-location-config "region=us-east-1,s3ForcePathStyle=true,s3Url=${S3_URL}" \
  --wait

log "ready"
kubectl -n velero get pods
velero backup-location get
