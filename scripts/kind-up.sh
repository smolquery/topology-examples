#!/usr/bin/env bash
# Creates the kind cluster every example deploys into, or adopts the one
# already there, and writes the repo-scoped kubeconfig mise points KUBECONFIG
# at. Idempotent: run it as often as you like.
set -euo pipefail

cd "$(dirname "$0")/.."

CLUSTER=topology-examples

mkdir -p .kube
export KUBECONFIG="$PWD/.kube/config"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind export kubeconfig --name "$CLUSTER"
else
  kind create cluster --config kind/cluster.yaml
fi

kubectl --context "kind-$CLUSTER" cluster-info
echo "==> cluster $CLUSTER is up; deploy an example with: mise run up <example>"
