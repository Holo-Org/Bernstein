#!/usr/bin/env bash
# Spread the replicas over the nodes again, e.g. after the cluster starts.
#
# Usage: scripts/rebalance.sh
#
# When the cluster starts, its nodes do not become ready at the same time, and the pods are all
# recreated on the first one. The spread constraints are only a preference (see
# docs/technical-choices.md), and Kubernetes never moves a running pod: this script restarts
# (with a no-downtime rollout) every Deployment whose replicas share fewer nodes than they could.
set -euo pipefail

NAMESPACE=bernstein # must match k8s/kustomization.yaml

# Right after a start, the DNS name of the API server only resolves some of the time, for a
# few minutes: wait until it answers several times in a row.
echo "==> Waiting for the API server"
streak=0
for _ in {1..150}; do
  if kubectl version --request-timeout=10s &>/dev/null; then (( ++streak )); else streak=0; fi
  (( streak == 5 )) && break
  sleep 2
done
(( streak == 5 )) || { echo "error: the API server is still unreachable" >&2; exit 1; }

echo "==> Waiting for the nodes"
kubectl wait node --all --for=condition=Ready --timeout=10m >/dev/null
nodes="$(kubectl get nodes --no-headers | wc -l)"

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "==> Nothing deployed yet"
  exit 0
fi

for deployment in $(kubectl get deployments --namespace "$NAMESPACE" --output name); do
  kubectl rollout status "$deployment" --namespace "$NAMESPACE" --timeout=5m >/dev/null
  replicas="$(kubectl get "$deployment" --namespace "$NAMESPACE" -o jsonpath='{.spec.replicas}')"
  (( replicas > 1 )) || continue
  # Every Deployment selects its pods with `app: <name>`.
  used="$(kubectl get pods --namespace "$NAMESPACE" --selector "app=${deployment#*/}" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)"
  if (( used < (replicas < nodes ? replicas : nodes) )); then
    echo "==> ${deployment#*/}: $replicas replicas on $used node(s), restarting it"
    kubectl rollout restart "$deployment" --namespace "$NAMESPACE"
    kubectl rollout status "$deployment" --namespace "$NAMESPACE" --timeout=5m
  else
    echo "==> ${deployment#*/}: $replicas replicas on $used nodes"
  fi
done
