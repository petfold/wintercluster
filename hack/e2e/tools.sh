#!/usr/bin/env bash
# Fetch the pinned toolchain into hack/e2e/bin/. Idempotent: a binary that is
# already the right version is left alone.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$HERE/versions.env"
BIN="$HERE/bin"
mkdir -p "$BIN"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; esac

have() { # have <binary> <expected-version-substring>
  [ -x "$BIN/$1" ] && "$BIN/$1" version 2>/dev/null | grep -q "$2"
}

fetch() { # fetch <url> <dest>
  echo "  fetching $(basename "$1")"
  curl -fsSL --retry 3 -o "$2" "$1"
}

echo "toolchain -> $BIN"

if ! have kind "$KIND_VERSION"; then
  fetch "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" "$BIN/kind"
  chmod +x "$BIN/kind"
fi

if ! have kubectl "$KUBECTL_VERSION"; then
  fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl" "$BIN/kubectl"
  chmod +x "$BIN/kubectl"
fi

if ! have helm "$HELM_VERSION"; then
  tmp=$(mktemp -d)
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" "$tmp/helm.tgz"
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  mv "$tmp/${OS}-${ARCH}/helm" "$BIN/helm"
  rm -rf "$tmp"
fi

if ! have velero "$VELERO_VERSION"; then
  tmp=$(mktemp -d)
  fetch "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-${OS}-${ARCH}.tar.gz" "$tmp/velero.tgz"
  tar -xzf "$tmp/velero.tgz" -C "$tmp"
  mv "$tmp/velero-${VELERO_VERSION}-${OS}-${ARCH}/velero" "$BIN/velero"
  rm -rf "$tmp"
fi

echo "versions:"
"$BIN/kind" version    | sed 's/^/  /'
"$BIN/kubectl" version --client 2>/dev/null | head -1 | sed 's/^/  /'
"$BIN/helm" version --short 2>/dev/null | sed 's/^/  /'
"$BIN/velero" version --client-only 2>/dev/null | head -2 | sed 's/^/  /'
