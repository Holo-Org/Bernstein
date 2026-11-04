#!/usr/bin/env bash
# Cast one vote on the Poll page and wait for the Result page to count it: the only check that
# crosses Poll, Redis, the Worker, PostgreSQL and Result. It adds one vote to the tally.
#
# Usage: scripts/check-vote.sh [POLL_URL RESULT_URL]
#
# Without URLs, uses the LoadBalancer Services of the namespace.
# Reads the tally the way the page does, through Socket.IO long-polling.
# Exits 1 if the vote is not counted within TIMEOUT seconds (30 by default).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMEOUT="${TIMEOUT:-30}"

if [[ $# -eq 2 ]]; then
  poll="$1" result="$2"
else
  pages="$("$ROOT_DIR/scripts/pages.sh")"
  poll="$(sed -n 's/^poll //p' <<<"$pages")"
  result="$(sed -n 's/^result //p' <<<"$pages")"
fi

socket="${result%/}/socket.io/?EIO=4&transport=polling"
session="$(curl --silent --fail --max-time 5 "$socket" | sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' || true)"
[[ -n "$session" ]] || { echo "error: no Socket.IO session from $result" >&2; exit 1; }
curl --silent --show-error --fail --max-time 5 --data 40 "$socket&sid=$session" >/dev/null

# Sum of the four options in the next `scores` event, such as {"a":1,"b":0,"c":2,"d":0}.
tally() {
  local counts
  for _ in {1..10}; do
    counts="$(curl --silent --fail --max-time 5 "$socket&sid=$session" | tr '\036' '\n' |
      sed -n 's/^42\["scores",//p' | tail -1 | grep -o ':[0-9]*' | tr -d ':')"
    if [[ -n "$counts" ]]; then
      echo $(( ${counts//$'\n'/+} ))
      return
    fi
  done
  echo "error: no tally from $result" >&2
  exit 1
}

before="$(tally)"
voter="check-$(date +%s)-$RANDOM"
curl --silent --show-error --fail --max-time 5 --output /dev/null --cookie "voter_id=$voter" --data vote=a "$poll"
echo "==> Voted as $voter, the tally was $before"

deadline=$(( SECONDS + TIMEOUT ))
while (( SECONDS < deadline )); do
  now="$(tally)"
  if (( now > before )); then
    echo "==> Counted: the tally is now $now"
    exit 0
  fi
done
echo "error: the vote is not counted after ${TIMEOUT}s (tally: $now)" >&2
exit 1
