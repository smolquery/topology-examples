#!/usr/bin/env bash
# Applies one example's kustomization into its namespace (named after the
# example) and waits for every workload in it to roll out.
set -euo pipefail

cd "$(dirname "$0")/.."

EXAMPLE="${1:?usage: $0 <example>   (one of: $(ls examples | tr '\n' ' '))}"
DIR="examples/$EXAMPLE"
[ -f "$DIR/kustomization.yaml" ] || { echo "no example at $DIR" >&2; exit 1; }

export KUBECONFIG="$PWD/.kube/config"
kubectl() { command kubectl --context kind-topology-examples "$@"; }

kind get clusters 2>/dev/null | grep -qx topology-examples || {
  echo "the kind cluster is not up: run 'mise run kind-up' first" >&2
  exit 1
}

if [ -x "$DIR/pre-apply.sh" ]; then
  echo "==> $DIR/pre-apply.sh"
  "$DIR/pre-apply.sh"
fi

echo "==> applying $DIR"
kubectl apply -k "$DIR"

for workload in $(kubectl -n "$EXAMPLE" get statefulsets,deployments -o name); do
  echo "==> waiting for $workload"
  kubectl -n "$EXAMPLE" rollout status "$workload" --timeout=300s
done

for job in $(kubectl -n "$EXAMPLE" get jobs -o name 2>/dev/null); do
  echo "==> waiting for $job"
  kubectl -n "$EXAMPLE" wait --for=condition=complete "$job" --timeout=300s
done

echo "==> $EXAMPLE is up"
kubectl -n "$EXAMPLE" get pods
echo "==> host ports and credentials: see $DIR/README.md; test it with: mise run test $EXAMPLE"
