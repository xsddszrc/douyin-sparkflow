#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PLAYWRIGHT_IMAGE_DEFAULT="mcr.microsoft.com/playwright/python:v1.56.0-jammy"
PLAYWRIGHT_IMAGE_LEGACY_MIRROR="swr.cn-north-4.myhuaweicloud.com/ddn-k8s/mcr.microsoft.com/playwright/python:v1.56.0-jammy"
NODE_RUNTIME_IMAGE_DEFAULT="node:22-bookworm-slim"
PROXY_IMAGE_DEFAULT="metacubex/mihomo:latest"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker with the Compose plugin is required." >&2
  exit 1
fi

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file"; then
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      $0 ~ "^" key "=" { print key "=" value; replaced = 1; next }
      { print }
      END { if (!replaced) print key "=" value }
    ' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- || true
}

normalize_arch() {
  case "$1" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64 | arm64v8) echo "arm64" ;;
    armv7l | armv7 | armhf) echo "arm/v7" ;;
    *) echo "$1" ;;
  esac
}

detect_host_arch() {
  local docker_arch
  docker_arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)"
  if [ -z "$docker_arch" ]; then
    docker_arch="$(uname -m)"
  fi
  normalize_arch "$docker_arch"
}

resolve_effective_env() {
  local key="$1"
  local default_value="$2"
  local from_file
  from_file="$(read_env_value ".env" "$key")"
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
  elif [ -n "$from_file" ]; then
    printf '%s' "$from_file"
  else
    printf '%s' "$default_value"
  fi
}

manifest_supports_arch() {
  local image="$1"
  local host_arch="$2"
  local inspect_out
  if ! inspect_out="$(docker buildx imagetools inspect "$image" 2>/dev/null)"; then
    return 2
  fi
  if printf '%s\n' "$inspect_out" | grep -Eq "Platform:[[:space:]]+linux/${host_arch}([[:space:]]|/|$)"; then
    return 0
  fi
  return 1
}

ensure_arch_aware_defaults() {
  local host_arch="$1"
  local playwright_from_file
  playwright_from_file="$(read_env_value ".env" "PLAYWRIGHT_BASE_IMAGE")"
  if [ "$host_arch" = "arm64" ] \
    && [ -z "${PLAYWRIGHT_BASE_IMAGE:-}" ] \
    && { [ -z "$playwright_from_file" ] || [ "$playwright_from_file" = "$PLAYWRIGHT_IMAGE_LEGACY_MIRROR" ]; }; then
    set_env_value ".env" "PLAYWRIGHT_BASE_IMAGE" "$PLAYWRIGHT_IMAGE_DEFAULT"
    echo "Detected ARM64 host; set PLAYWRIGHT_BASE_IMAGE to multi-arch default: $PLAYWRIGHT_IMAGE_DEFAULT"
  fi
}

validate_manifest_or_exit() {
  local component="$1"
  local image="$2"
  local host_arch="$3"
  local rc=0
  manifest_supports_arch "$image" "$host_arch" || rc=$?
  case "$rc" in
    0)
      return 0
      ;;
    1)
      echo "Image '$image' for component '$component' does not publish linux/$host_arch." >&2
      echo "Set a compatible image in .env and retry. Example:" >&2
      echo "  PLAYWRIGHT_BASE_IMAGE=$PLAYWRIGHT_IMAGE_DEFAULT" >&2
      echo "  NODE_RUNTIME_IMAGE=$NODE_RUNTIME_IMAGE_DEFAULT" >&2
      echo "  PROXY_IMAGE=$PROXY_IMAGE_DEFAULT" >&2
      if [ "$host_arch" = "arm64" ]; then
        echo "Fallback (slower, compatibility mode): enable amd64 emulation and force linux/amd64 builds." >&2
        echo "  docker run --privileged --rm tonistiigi/binfmt --install amd64" >&2
        echo "  export DOCKER_DEFAULT_PLATFORM=linux/amd64" >&2
      fi
      exit 1
      ;;
    2)
      echo "Warning: cannot inspect image manifest for '$component' ($image); continuing without architecture precheck." >&2
      ;;
  esac
}

preflight_image_architecture() {
  local host_arch="$1"
  local playwright_image node_image proxy_image
  playwright_image="$(resolve_effective_env PLAYWRIGHT_BASE_IMAGE "$PLAYWRIGHT_IMAGE_DEFAULT")"
  node_image="$(resolve_effective_env NODE_RUNTIME_IMAGE "$NODE_RUNTIME_IMAGE_DEFAULT")"
  proxy_image="$(resolve_effective_env PROXY_IMAGE "$PROXY_IMAGE_DEFAULT")"

  echo "Detected Docker architecture: $host_arch"
  echo "Preflight image compatibility check for linux/$host_arch..."
  validate_manifest_or_exit "playwright-base" "$playwright_image" "$host_arch"
  validate_manifest_or_exit "node-runtime" "$node_image" "$host_arch"
  validate_manifest_or_exit "proxy" "$proxy_image" "$host_arch"
}

if [ ! -f ".env" ]; then
  cp ".env.example" ".env"
fi

host_arch="$(detect_host_arch)"
ensure_arch_aware_defaults "$host_arch"

proxy_sub_url="${PROXY_SUB_URL:-${1:-}}"
if [ -n "$proxy_sub_url" ]; then
  set_env_value ".env" "PROXY_SUB_URL" "$proxy_sub_url"
fi

mkdir -p proxy state/cron state/login-api state/login-profile state/browser-profiles DouYinSparkFlow/logs
if [ ! -f "proxy/config.yaml" ]; then
  cp "proxy/config.example.yaml" "proxy/config.yaml"
fi
if [ ! -s "state/cron/root" ]; then
  cat > "state/cron/root" <<'CRON'
*/20 10-17 * * * cd /app && python main.py --doTask >> /app/logs/app.log 2>&1
0 18 * * * cd /app && python main.py --doTask >> /app/logs/app.log 2>&1
20 18 * * * cd /app && env SPARKFLOW_MANUAL_RUN=1 SPARKFLOW_MANUAL_UNSENT_ONLY=1 PYTHONUNBUFFERED=1 python main.py --doTask >> /app/logs/app.log 2>&1
CRON
fi

bash ./refresh_proxy.sh
preflight_image_architecture "$host_arch"
docker compose up -d --build

web_port="$(grep '^WEB_PORT=' .env | sed 's/^WEB_PORT=//')"
web_port="${web_port:-8787}"
url="http://localhost:${web_port}"
echo "Douyin SparkFlow is running: $url"
echo "Next: create the admin password, open the login desktop, scan the QR code, select target friends, and set the send window."

if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$url" >/dev/null 2>&1 || true
elif command -v open >/dev/null 2>&1; then
  open "$url" >/dev/null 2>&1 || true
fi
