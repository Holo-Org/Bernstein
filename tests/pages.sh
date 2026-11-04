#!/usr/bin/env bash
# shellcheck disable=SC2329 # the functions below are called through check
# Checks how the public pages are found, with a stand-in for kubectl.
#
# Usage: tests/pages.sh
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stubs="$(mktemp -d)"
trap 'rm -rf "$stubs"' EXIT
export STUBS="$stubs"
export PATH="$stubs:$PATH"

# Each call answers with the next file of $STUBS/answers, and the last one repeats.
cat > "$stubs/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/calls"
calls="$(wc -l < "$STUBS/calls")"
answers=("$STUBS"/answers/*)
index=$(( calls <= ${#answers[@]} ? calls - 1 : ${#answers[@]} - 1 ))
cat "${answers[$index]}"
EOF
printf '#!/bin/sh\n' > "$stubs/sleep"
chmod +x "$stubs/kubectl" "$stubs/sleep"

answer() {
  mkdir -p "$stubs/answers"
  find "$stubs/answers" -type f -delete
  : > "$stubs/calls"
  local index=0 services
  for services in "$@"; do
    index=$((index + 1))
    printf '%b' "$services" > "$stubs/answers/$index"
  done
}

calls() {
  wc -l < "$stubs/calls" | tr -d ' '
}

prints_each_page() {
  answer 'poll 10.0.0.1\nresult 10.0.0.2\n'
  [[ "$("$root/scripts/pages.sh")" == $'poll http://10.0.0.1/\nresult http://10.0.0.2/' ]]
}

asks_about_the_namespace_of_the_kustomization() {
  answer 'poll 10.0.0.1\n'
  "$root/scripts/pages.sh" >/dev/null
  grep -q -- '--namespace bernstein ' "$stubs/calls"
}

waits_for_a_new_address() {
  answer 'poll \nresult 10.0.0.2\n' 'poll \nresult 10.0.0.2\n' 'poll 10.0.0.1\nresult 10.0.0.2\n'
  [[ "$("$root/scripts/pages.sh")" == $'poll http://10.0.0.1/\nresult http://10.0.0.2/' && "$(calls)" -eq 3 ]]
}

gives_up_on_a_missing_address() {
  answer 'poll \nresult 10.0.0.2\n'
  local message
  ! message="$("$root/scripts/pages.sh" 2>&1)" && [[ "$message" == "error: no address yet for poll" && "$(calls)" -eq 30 ]]
}

fails_at_once_without_a_page() {
  answer ''
  local message
  ! message="$("$root/scripts/pages.sh" 2>&1)" && [[ "$message" == "error: no LoadBalancer service in namespace bernstein" && "$(calls)" -eq 1 ]]
}

check "each page is printed with its URL" prints_each_page
check "the namespace comes from the kustomization" asks_about_the_namespace_of_the_kustomization
check "a new address is waited for" waits_for_a_new_address
check "a missing address is reported after the wait" gives_up_on_a_missing_address
check "no page is reported at once" fails_at_once_without_a_page

exit $((failures > 0))
