# Shared helpers, sourced by the other scripts.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/poll-application"
SERVICES=(poll worker result)

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
