#!/usr/bin/env bash
# Send many requests to the application pages, to make the autoscalers add replicas: run it
# in a terminal, and `kubectl get hpa,pods --namespace bernstein --watch` in another one.
#
# Usage: scripts/load.sh [URL...]
#
# Without URL, loads every LoadBalancer Service of the namespace (poll and result).
# CONCURRENCY requests at a time per page, for DURATION seconds; prints the status codes.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DURATION="${DURATION:-180}"
CONCURRENCY="${CONCURRENCY:-20}"

urls=("$@")
if [[ ${#urls[@]} -eq 0 ]]; then
  pages="$("$ROOT_DIR/scripts/pages.sh")"
  mapfile -t urls < <(cut -d' ' -f2 <<<"$pages")
fi

load() {
  # One curl per page: it keeps CONCURRENCY connections open and reuses them, so the load
  # is on the pods, not on this machine. The query string only makes each URL distinct.
  timeout "$DURATION" curl --silent --parallel --parallel-max "$CONCURRENCY" --max-time 10 \
    --output /dev/null --write-out '%{http_code}\n' "$1?n=[1-100000000]" || true
}

echo "==> Loading ${urls[*]} for ${DURATION}s, $CONCURRENCY requests at a time"
for url in "${urls[@]}"; do
  load "$url" | sort | uniq -c | sed "s|^|$url |" &
done
wait
