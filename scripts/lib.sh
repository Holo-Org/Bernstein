# Shared helpers, sourced by the other scripts.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/poll-application"
SERVICES=(poll worker result)

# Local settings (ACR_NAME, POSTGRES_PASSWORD...), never committed: see .env.example.
# Variables already set in the environment take precedence over the file.
if [[ -f "$ROOT_DIR/.env" ]]; then
  # `|| [[ -n $key ]]` keeps a last line that has no trailing newline.
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    value="${value%\"}" value="${value#\"}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ && -z "${!key:-}" ]] && export "$key=$value"
  done < "$ROOT_DIR/.env"
fi

# Without ACR_NAME, use the registry of the subscription if there is exactly one.
resolve_acr_name() {
  [[ -n "${ACR_NAME:-}" ]] && return
  local registries
  mapfile -t registries < <(az acr list --query "[].name" -o tsv)
  if [[ ${#registries[@]} -ne 1 ]]; then
    echo "error: ACR_NAME is not set and the subscription has ${#registries[@]} registries (see README.md)" >&2
    exit 1
  fi
  ACR_NAME="${registries[0]}"
  echo "==> Using registry $ACR_NAME"
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "error: $name is not set (see README.md)" >&2
      exit 1
    fi
  done
}

# Image tag of a service: hash of its source directory (build artifacts excluded).
# The same sources always give the same tag, and only a changed service gets a new one,
# so redeploying only rolls out what actually changed.
image_tag() {
  local dir="$APP_DIR/$1"
  (
    cd "$dir"
    find . -type f \
      -not -path './node_modules/*' -not -path './target/*' \
      -not -path './.venv/*' -not -path '*/__pycache__/*' -not -name '*.pyc' \
      -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  ) | sha256sum | cut -c1-12
}

image_ref() {
  echo "$ACR_NAME.azurecr.io/$1:$(image_tag "$1")"
}
