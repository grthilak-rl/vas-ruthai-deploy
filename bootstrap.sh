#!/usr/bin/env bash
# =============================================================================
# vas-ruthai-deploy bootstrap
# =============================================================================
# Ensures the sibling repos are present and .env is configured before
# running `docker compose up -d`. Idempotent.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

# TODO(operator): replace these with the real upstream URLs once they exist.
VAS_REPO_URL="${VAS_REPO_URL:-PLACEHOLDER_VAS_GIT_URL}"
RUTH_REPO_URL="${RUTH_REPO_URL:-PLACEHOLDER_RUTH_AI_GIT_URL}"

clone_if_missing() {
  local target_dir="$1"
  local url="$2"
  local name="$3"
  if [ -d "$target_dir/.git" ]; then
    echo "✓ $name already cloned at $target_dir"
    return
  fi
  if [ "$url" = "PLACEHOLDER_VAS_GIT_URL" ] || [ "$url" = "PLACEHOLDER_RUTH_AI_GIT_URL" ]; then
    echo "✗ $name not present at $target_dir, and no URL configured."
    echo "  Either:"
    echo "  - Clone manually:  git clone <url> $target_dir"
    echo "  - Or set VAS_REPO_URL / RUTH_REPO_URL and re-run this script."
    exit 1
  fi
  echo "→ Cloning $name from $url"
  git clone "$url" "$target_dir"
}

# Ensure sibling repos are present.
clone_if_missing "../vas-ms-v2" "$VAS_REPO_URL" "vas-ms-v2"
clone_if_missing "../ruth-ai-vas-ms-v2" "$RUTH_REPO_URL" "ruth-ai-vas-ms-v2"

# Ensure .env exists (copied from .env.example on first run).
if [ ! -f .env ]; then
  echo "→ Creating .env from .env.example"
  cp .env.example .env
  echo
  echo "✗ .env was just created from the template."
  echo "  Edit it now to set MEDIASOUP_ANNOUNCED_IP, the secrets (VAS_DB_PASSWORD,"
  echo "  VAS_API_KEY, VAS_JWT_SECRET, RUTH_POSTGRES_PASSWORD, RUTH_JWT_SECRET,"
  echo "  VAS_CLIENT_SECRET), and HOST_IP. Then re-run this script."
  exit 1
fi

echo "→ Bringing up the merged stack"
docker compose up -d

echo
echo "✓ Deployment up. Tail logs with:"
echo "    docker compose logs -f"
echo "  Or hit:"
echo "    http://\${HOST_IP}:\${VAS_HTTP_PORT:-8086}     # VAS"
echo "    http://\${HOST_IP}:3300                       # Ruth AI"
