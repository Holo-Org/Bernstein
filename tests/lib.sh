# shellcheck shell=bash
# Shared by the tests: `check <description> <command>` reports one check.

# shellcheck disable=SC2034 # used by the tests that source this file
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok    $name"
  else
    echo "FAIL  $name"
    failures=$((failures + 1))
  fi
}
