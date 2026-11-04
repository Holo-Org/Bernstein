#!/usr/bin/env bash
# Print the public pages of the deployment, one `<name> <url>` per line.
#
# Usage: scripts/pages.sh
#
# Azure takes a moment to assign the address of a new LoadBalancer: waits for it, up to 150 s.
# Exits 1 if the namespace has no LoadBalancer Service, or if one still has no address.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for _ in {1..30}; do
  services="$(kubectl get services --namespace "$NAMESPACE" \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name} {.status.loadBalancer.ingress[0].ip}{"\n"}{end}')"
  [[ -n "$services" ]] || { echo "error: no LoadBalancer service in namespace $NAMESPACE" >&2; exit 1; }
  if awk 'NF < 2 { exit 1 }' <<<"$services"; then
    awk '{ print $1, "http://" $2 "/" }' <<<"$services"
    exit 0
  fi
  sleep 5
done

echo "error: no address yet for $(awk 'NF < 2 { print $1 }' <<<"$services" | xargs)" >&2
exit 1
