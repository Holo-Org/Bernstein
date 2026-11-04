#!/usr/bin/env bash
# Create the private registry if it does not exist, and let the cluster pull from it.
#
# Usage: AKS_RESOURCE_GROUP=<group> AKS_CLUSTER=<cluster> scripts/registry.sh
#
# The registry is ACR_NAME (environment or .env), or the only registry of the subscription.
# Attaching it creates a role assignment, which needs `Owner` on the registry (see README.md).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_env AKS_RESOURCE_GROUP AKS_CLUSTER
resolve_acr_name

existing="$(az acr list --query "[?name=='$ACR_NAME'].name" -o tsv)"
if [[ -n "$existing" ]]; then
  echo "==> Registry $ACR_NAME already exists"
else
  echo "==> Creating registry $ACR_NAME"
  az acr create --resource-group "$AKS_RESOURCE_GROUP" --name "$ACR_NAME" --sku Basic
fi

echo "==> Attaching $ACR_NAME to $AKS_CLUSTER"
az aks update --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER" --attach-acr "$ACR_NAME"
