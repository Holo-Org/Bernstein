#!/usr/bin/env bash
# Deploy the application to the Kubernetes cluster of the current kubectl context.
#
# Usage: scripts/deploy.sh
#
# The images must already be in the registry (scripts/build-push.sh): each one is deployed
# with the tag of its current sources, so only the services whose sources changed are rolled out.
# Secrets come from the environment (or .env): REDIS_PASSWORD, POSTGRES_PASSWORD.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAMESPACE=bernstein # must match k8s/kustomization.yaml

resolve_acr_name
require_env REDIS_PASSWORD POSTGRES_PASSWORD

if ! kubectl version --request-timeout=10s &>/dev/null; then
  echo "error: the cluster of kubectl context '$(kubectl config current-context)' is unreachable (see README.md)" >&2
  exit 1
fi

# Fail before touching the cluster rather than leave pods stuck pulling a missing image.
for service in "${SERVICES[@]}"; do
  tag="$(image_tag "$service")"
  if ! az acr manifest show --registry "$ACR_NAME" --name "$service:$tag" &>/dev/null; then
    echo "error: $service:$tag is not in the registry, run scripts/build-push.sh first" >&2
    exit 1
  fi
done

echo "==> Applying the namespace and secrets"
kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"
# Through stdin, so the password never appears on a command line.
kubectl create secret generic redis --namespace "$NAMESPACE" \
  --from-file=password=<(printf '%s' "$REDIS_PASSWORD") \
  --dry-run=client --output yaml | kubectl apply -f -
kubectl create secret generic postgres --namespace "$NAMESPACE" \
  --from-file=password=<(printf '%s' "$POSTGRES_PASSWORD") \
  --dry-run=client --output yaml | kubectl apply -f -

# Temporary overlay that points the images to the registry, so the committed manifests
# stay untouched. It lives in the repository because kustomize refuses absolute base paths.
overlay="$(mktemp -d "$ROOT_DIR/.deploy.XXXXXX")"
trap 'rm -rf "$overlay"' EXIT
{
  echo "resources: [../k8s]"
  echo "images:"
  for service in "${SERVICES[@]}"; do
    echo "  - {name: $service, newName: $ACR_NAME.azurecr.io/$service, newTag: $(image_tag "$service")}"
  done
} > "$overlay/kustomization.yaml"

echo "==> Applying the manifests"
# k8s/postgres reads schema.sql from the application sources, outside the kustomization.
kubectl kustomize --load-restrictor LoadRestrictionsNone "$overlay" | kubectl apply -f -

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
