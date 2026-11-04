#!/usr/bin/env bash
# Print the complete manifests of a deployment, Secrets included: what `kubectl apply` receives.
# It needs no cluster, and no Azure account when ACR_NAME is set.
#
# Usage: scripts/render.sh
#
# Each image points to the registry with the tag of its current sources.
# Secrets come from the environment (or .env): REDIS_PASSWORD, POSTGRES_PASSWORD.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

resolve_acr_name
require_env REDIS_PASSWORD POSTGRES_PASSWORD

# Temporary overlay, so the committed manifests stay untouched. It lives in the repository
# because kustomize refuses absolute base paths.
overlay="$(mktemp -d "$ROOT_DIR/.deploy.XXXXXX")"
trap 'rm -rf "$overlay"' EXIT

printf '%s' "$REDIS_PASSWORD" > "$overlay/redis-password"
printf '%s' "$POSTGRES_PASSWORD" > "$overlay/postgres-password"
# Kustomize only loads the files below the kustomization that names them.
cp "$APP_DIR/schema.sql" "$overlay/"

{
  echo "resources: [../k8s]"
  echo "namespace: $NAMESPACE"
  echo "labels: [{pairs: {app.kubernetes.io/part-of: poll-app}}]"
  # The schema is only applied when the database is created: changing it must not restart PostgreSQL.
  echo "generatorOptions: {disableNameSuffixHash: true}"
  echo "configMapGenerator:"
  echo "  - {name: postgres-schema, files: [schema.sql]}"
  echo "secretGenerator:"
  echo "  - {name: redis, files: [password=redis-password]}"
  echo "  - {name: postgres, files: [password=postgres-password]}"
  echo "images:"
  for service in "${SERVICES[@]}"; do
    echo "  - {name: $service, newName: $(image_repository "$service"), newTag: \"$(image_tag "$service")\"}"
  done
} > "$overlay/kustomization.yaml"

kubectl kustomize "$overlay"
