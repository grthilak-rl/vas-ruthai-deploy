#!/usr/bin/env bash
# =============================================================================
# vas-ruthai-deploy bootstrap
# =============================================================================
# First-time setup helper for the integrated VAS + Ruth AI deploy.
#
# What it does, in order:
#   1. Verifies the two sibling repos exist (or clones them if URLs are
#      provided via VAS_REPO_URL / RUTH_REPO_URL env vars).
#   2. Creates .env from .env.example if missing, generating the six
#      cryptographic secrets via `openssl rand -hex 32` and prompting
#      for HOST_IP. Existing .env files are left alone.
#   3. Brings up the stack. Pass --gpu to layer the GPU overlay (for
#      hosts with NVIDIA NVENC); omit for CPU mode.
#
# This script is convenience. The fully manual procedure is in
# DEPLOYMENT.md and remains the authoritative reference.
#
# Idempotent: safe to re-run.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Args: --gpu enables the GPU overlay
# ---------------------------------------------------------------------------
USE_GPU=0
for arg in "$@"; do
  case "$arg" in
    --gpu) USE_GPU=1 ;;
    --cpu) USE_GPU=0 ;;
    *) echo "Unknown arg: $arg (expected --gpu or --cpu)"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Sibling repos
# ---------------------------------------------------------------------------
VAS_REPO_URL="${VAS_REPO_URL:-}"
RUTH_REPO_URL="${RUTH_REPO_URL:-}"

clone_if_missing() {
  local target_dir="$1"
  local url="$2"
  local name="$3"
  if [ -d "$target_dir/.git" ]; then
    echo "✓ $name already cloned at $target_dir"
    return
  fi
  if [ -z "$url" ]; then
    echo "✗ $name not present at $target_dir, and no clone URL configured."
    echo "  Either:"
    echo "    - Clone manually:  git clone <url> $target_dir"
    echo "    - Or re-run with the URL exported:"
    echo "        ${name//-/_}_URL='https://...' ./bootstrap.sh"
    exit 1
  fi
  echo "→ Cloning $name from $url"
  git clone "$url" "$target_dir"
}

clone_if_missing "../vas-ms-v2"          "$VAS_REPO_URL"   "vas-ms-v2"
clone_if_missing "../ruth-ai-vas-ms-v2"  "$RUTH_REPO_URL"  "ruth-ai-vas-ms-v2"

# ---------------------------------------------------------------------------
# 2. .env — create if missing, with generated secrets
# ---------------------------------------------------------------------------
if [ -f .env ]; then
  echo "✓ .env already present — leaving it untouched."
else
  if ! command -v openssl >/dev/null 2>&1; then
    echo "✗ openssl is required to generate secrets. Install openssl and re-run."
    exit 1
  fi
  echo "→ Creating .env from .env.example with generated secrets"
  cp .env.example .env

  # Prompt for HOST_IP — the one value openssl can't produce. Detect a
  # sensible default from the host's first non-loopback IPv4.
  default_ip=$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [ -n "${default_ip:-}" ]; then
    read -r -p "HOST_IP (host IP browsers reach on LAN) [${default_ip}]: " host_ip
    host_ip="${host_ip:-$default_ip}"
  else
    read -r -p "HOST_IP (host IP browsers reach on LAN): " host_ip
  fi
  if [ -z "${host_ip:-}" ]; then
    echo "✗ HOST_IP is required; aborting."
    exit 1
  fi

  # In-place rewrite. The .env.example has blank `KEY=` lines for each
  # required value; we substitute them with generated or prompted values.
  gen() { openssl rand -hex 32; }

  python3 - "$host_ip" .env <<'PY'
import re, sys, secrets

host_ip = sys.argv[1]
env_path = sys.argv[2]

with open(env_path) as f:
    text = f.read()

def gen(): return secrets.token_hex(32)

# (env_var_name, value-generator)
required = [
    ("HOST_IP",                 lambda: host_ip),
    ("VAS_DB_PASSWORD",         gen),
    ("VAS_API_KEY",             gen),
    ("VAS_JWT_SECRET",          gen),
    ("RUTH_POSTGRES_PASSWORD",  gen),
    ("RUTH_JWT_SECRET",         gen),
    ("VAS_CLIENT_SECRET",       gen),
]

# Replace lines of the form `KEY=` (no value) with `KEY=<generated>`.
# A line like `KEY=foo` is left alone.
for key, value_fn in required:
    pattern = rf"(?m)^{re.escape(key)}=\s*$"
    if re.search(pattern, text):
        text = re.sub(pattern, f"{key}={value_fn()}", text, count=1)
    elif not re.search(rf"(?m)^{re.escape(key)}=", text):
        # Key not present at all — append it. .env.example should always
        # have these lines, but be defensive.
        text += f"\n{key}={value_fn()}\n"

with open(env_path, "w") as f:
    f.write(text)
PY

  chmod 600 .env
  echo "✓ .env created. Edit it now to review/override any optional knobs."
  echo "  All required secrets were generated via openssl rand."
fi

# ---------------------------------------------------------------------------
# 3. Bring up the stack
# ---------------------------------------------------------------------------
if [ "$USE_GPU" -eq 1 ]; then
  echo "→ Bringing up the merged stack (GPU mode, NVENC)"
  docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
else
  echo "→ Bringing up the merged stack (CPU mode, libx264)"
  docker compose up -d
fi

# ---------------------------------------------------------------------------
# Final hints
# ---------------------------------------------------------------------------
host_ip_show=$(grep '^HOST_IP=' .env | cut -d= -f2-)
ruth_port=$(grep '^RUTH_FRONTEND_HOST_PORT=' .env | cut -d= -f2-)
vas_http_port=$(grep '^VAS_HTTP_PORT=' .env | cut -d= -f2- || true)
ruth_port="${ruth_port:-80}"
vas_http_port="${vas_http_port:-8086}"

echo
echo "✓ Deployment up. Tail logs with:"
echo "    docker compose logs -f"
echo "  Endpoints:"
echo "    VAS  portal:  http://${host_ip_show}:${vas_http_port}"
echo "    Ruth portal:  http://${host_ip_show}:${ruth_port}"
echo
echo "  See DEPLOYMENT.md for the verification checklist."
