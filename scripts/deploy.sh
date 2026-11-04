#!/usr/bin/env bash
# Deploy the application to the Kubernetes cluster of the current kubectl context.
#
# Usage: scripts/deploy.sh
#
# The images must already be in the registry (scripts/build-push.sh): each one is deployed
# with the tag of its current sources, so only the services whose sources changed are rolled out.
# Secrets come from the environment (or .env): REDIS_PASSWORD, POSTGRES_PASSWORD.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

resolve_acr_name
require_env REDIS_PASSWORD POSTGRES_PASSWORD

if ! kubectl version --request-timeout=10s &>/dev/null; then
  echo "error: the cluster of kubectl context '$(kubectl config current-context)' is unreachable (see README.md)" >&2
  exit 1
fi

# Fail before touching the cluster rather than leave pods stuck pulling a missing image.
for service in "${SERVICES[@]}"; do
  if ! image_in_registry "$service"; then
    echo "error: $(image_ref "$service") is not in the registry, run scripts/build-push.sh first" >&2
    exit 1
  fi
done

echo "==> Applying the manifests"
"$ROOT_DIR/scripts/render.sh" | kubectl apply -f -

echo "==> Waiting for the rollouts"
for workload in $(kubectl get deployments,statefulsets --namespace "$NAMESPACE" --output name); do
  kubectl rollout status "$workload" --namespace "$NAMESPACE" --timeout=5m
done

echo "==> External addresses"
for service in $(kubectl get services --namespace "$NAMESPACE" --output name); do
  [[ "$(kubectl get "$service" --namespace "$NAMESPACE" -o jsonpath='{.spec.type}')" == LoadBalancer ]] || continue
  # Azure takes a moment to assign the public IP of a new LoadBalancer.
  for _ in {1..30}; do
    ip="$(kubectl get "$service" --namespace "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    [[ -n "$ip" ]] && break
    sleep 5
  done
  echo "${service#service/}: http://${ip:-<pending>}"
done
