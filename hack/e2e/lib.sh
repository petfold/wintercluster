#!/usr/bin/env bash
# Shared helpers for the cases.

log() { printf '\n--- %s\n' "$*"; }

# new_ns <namespace>
# Create a namespace and wait for its default ServiceAccount. Without the wait,
# a pod applied immediately after `create ns` is rejected with
# "serviceaccount \"default\" not found" — the controller has not caught up.
new_ns() {
  local ns=$1
  kubectl delete ns "$ns" --ignore-not-found --wait >/dev/null 2>&1 || true
  kubectl create ns "$ns" >/dev/null
  local i
  for i in $(seq 1 60); do
    kubectl -n "$ns" get serviceaccount default >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "default ServiceAccount never appeared in $ns" >&2
  return 1
}
