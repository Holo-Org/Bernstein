#!/usr/bin/env bash
# Request the application pages continuously and count the failed requests, to show that an
# update causes no downtime: run it in a terminal, then `make all` in another one.
#
# Usage: scripts/watch.sh [URL...]
#
# Without URL, watches every LoadBalancer Service of the namespace (poll and result).
# Stops after DURATION seconds if set, otherwise on Ctrl-C; exits 1 if any request failed.
set -euo pipefail

NAMESPACE=bernstein # must match k8s/kustomization.yaml
DURATION="${DURATION:-0}"
INTERVAL="${INTERVAL:-0.2}" # pause between two rounds of requests
TIMEOUT=5                   # a request slower than this counts as failed
REPORT_EVERY=5              # seconds between two progress lines

declare -A urls ok errors pods
if [[ $# -gt 0 ]]; then
  for url in "$@"; do urls[$url]="$url"; done
else
  while read -r name ip; do
    [[ -n "$ip" ]] || { echo "error: service $name has no external IP yet" >&2; exit 1; }
    urls[$name]="http://$ip/"
  done < <(kubectl get services --namespace "$NAMESPACE" \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name} {.status.loadBalancer.ingress[0].ip}{"\n"}{end}')
  [[ ${#urls[@]} -gt 0 ]] || { echo "error: no LoadBalancer service in namespace $NAMESPACE" >&2; exit 1; }
fi
names=($(printf '%s\n' "${!urls[@]}" | sort))
for name in "${names[@]}"; do
  ok[$name]=0 errors[$name]=0
  [[ "$name" == "${urls[$name]}" ]] && echo "==> Watching $name" || echo "==> Watching $name: ${urls[$name]}"
done

summary() {
  local name failed=0
  echo
  for name in "${names[@]}"; do
    echo "$name: ${ok[$name]} OK, ${errors[$name]} errors"
    (( failed += errors[$name] )) || true
  done
  [[ $failed -eq 0 ]] && echo "==> No failed request" || echo "==> $failed failed requests"
  exit $(( failed > 0 ))
}
trap summary INT TERM

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
start=$SECONDS last=$SECONDS
while [[ $DURATION -eq 0 || $(( SECONDS - start )) -lt $DURATION ]]; do
  for name in "${names[@]}"; do
    code="$(curl --silent --output "$body" --write-out '%{http_code}' --max-time "$TIMEOUT" "${urls[$name]}" || true)"
    if [[ "$code" == 200 ]]; then
      (( ++ok[$name] ))
      # The poll page names the pod that served it: show each new one, so the rollout is visible.
      pod="$(sed -n 's/.*container ID \([^ <]*\).*/\1/p' "$body")"
      if [[ -n "$pod" && -z "${pods[$pod]:-}" ]]; then
        pods[$pod]=1
        echo "$(date +%T)  $name: served by $pod"
      fi
    else
      (( ++errors[$name] ))
      echo "$(date +%T)  ERROR $name: ${code/#000/no response (timeout or connection error)}"
    fi
  done
  if (( SECONDS - last >= REPORT_EVERY )); then
    last=$SECONDS line=""
    for name in "${names[@]}"; do line+="  $name ${ok[$name]} OK / ${errors[$name]} errors"; done
    echo "$(date +%T)$line"
  fi
  sleep "$INTERVAL"
done
summary
