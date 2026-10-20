#!/usr/bin/env bash
# Build the application images and push them to the private Azure Container Registry.
#
# Usage: ACR_NAME=<registry> scripts/build-push.sh [service...]
#   service: poll, worker and/or result (default: all of them)
#
# An image whose tag already exists in the registry is not rebuilt (set FORCE=1 to override).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_env ACR_NAME

services=("$@")
[[ ${#services[@]} -eq 0 ]] && services=("${SERVICES[@]}")

az acr login --name "$ACR_NAME"

revision="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

for service in "${services[@]}"; do
  if [[ ! -f "$APP_DIR/$service/Dockerfile" ]]; then
    echo "error: unknown service '$service' (expected one of: ${SERVICES[*]})" >&2
    exit 1
  fi

  ref="$(image_ref "$service")"

  if [[ "${FORCE:-0}" != 1 ]] && az acr manifest show --registry "$ACR_NAME" --name "$service:${ref##*:}" &>/dev/null; then
    echo "==> $ref already in the registry, skipping"
    continue
  fi

  echo "==> Building $ref"
  # The AKS nodes are x86_64: build for that platform whatever the local machine is.
  docker build \
    --platform linux/amd64 \
    --label "org.opencontainers.image.revision=$revision" \
    --tag "$ref" \
    "$APP_DIR/$service"

  echo "==> Pushing $ref"
  docker push "$ref"
done
