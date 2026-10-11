#!/usr/bin/env bash
# Deletes one example: its namespace, and with it every pod, PVC and secret
# it created. The kind cluster stays up for the other examples.
set -euo pipefail

cd "$(dirname "$0")/.."

EXAMPLE="${1:?usage: $0 <example>}"
export KUBECONFIG="$PWD/.kube/config"

kubectl --context kind-topology-examples delete namespace "$EXAMPLE" --ignore-not-found --wait=true
echo "==> $EXAMPLE is down"
