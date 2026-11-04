#!/usr/bin/env bash
# shellcheck disable=SC2329 # the functions below are called through check
# Checks what a deployment would apply, with no cluster and no Azure account.
#
# Usage: tests/render.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

export ACR_NAME=test-registry
export REDIS_PASSWORD='redis "pass" word'
export POSTGRES_PASSWORD=postgres-password
export KUBECONFIG=/dev/null

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

rendered="$("$root/scripts/render.sh")"

first_kind_is_namespace() {
  [[ "$(awk '/^kind:/ { print $2; exit }' <<<"$rendered")" == Namespace ]]
}

no_unresolved_image() {
  ! grep -qE '^ +image: (poll|worker|result)$' <<<"$rendered"
}

images_point_to_the_registry() {
  local application
  for application in poll worker result; do
    grep -qE "image: test-registry\.azurecr\.io/$application:[0-9a-f]{12}$" <<<"$rendered" || return 1
  done
}

secret_holds() {
  grep -qF "password: $(printf '%s' "$2" | base64)" <<<"$rendered" && grep -qE "^  name: $1$" <<<"$rendered"
}

referenced_secrets_exist() {
  local name
  while read -r name; do
    awk -v RS='\n---\n' -v name="  name: $name\n" '/kind: Secret/ && index($0 "\n", name) { found = 1 } END { exit !found }' \
      <<<"$rendered" || return 1
  done < <(grep -A2 secretKeyRef <<<"$rendered" | sed -n 's/^ *name: //p' | sort -u)
}

schema_is_in_its_configmap() {
  grep -qF "$(head -1 "$root/poll-application/schema.sql")" <<<"$rendered"
}

overlay_is_gone() {
  ! compgen -G "$root/.deploy.*" >/dev/null
}

everything_but_the_namespace_is_namespaced() {
  [[ "$(grep -c '^  namespace: bernstein$' <<<"$rendered")" -eq "$(($(grep -c '^kind:' <<<"$rendered") - 1))" ]]
}

numeric_tag_renders() {
  local stubs
  stubs="$(mktemp -d)"
  printf '#!/bin/sh\ncat >/dev/null\necho 362935617393\n' > "$stubs/sha256sum"
  chmod +x "$stubs/sha256sum"
  PATH="$stubs:$PATH" "$root/scripts/render.sh" | grep -q 'azurecr.io/poll:362935617393$'
}

schemas_are_valid() {
  command -v kubeconform >/dev/null || { echo "      kubeconform is not installed, skipped"; return 0; }
  kubeconform -strict -summary -ignore-missing-schemas <<<"$rendered" >/dev/null
}

check "the namespace comes first" first_kind_is_namespace
check "no image is left unresolved" no_unresolved_image
check "the images point to the registry" images_point_to_the_registry
check "the redis Secret holds its password" secret_holds redis "$REDIS_PASSWORD"
check "the postgres Secret holds its password" secret_holds postgres "$POSTGRES_PASSWORD"
check "every referenced Secret exists" referenced_secrets_exist
check "the schema is in its ConfigMap" schema_is_in_its_configmap
check "the overlay does not outlive the render" overlay_is_gone
check "everything but the namespace is in it" everything_but_the_namespace_is_namespaced
check "a tag that reads as a number renders" numeric_tag_renders
check "the manifests match their schemas" schemas_are_valid

exit $((failures > 0))
