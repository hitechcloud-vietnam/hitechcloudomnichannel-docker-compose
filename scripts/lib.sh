#!/usr/bin/env bash
# Shared helpers for the HiTechCloudOmnichannel production scripts.
# Sourced by install.sh, backup.sh, restore.sh, upgrade.sh and compose.sh.
# shellcheck shell=bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
# shellcheck disable=SC2034 # used by install.sh
ENV_EXAMPLE="$ROOT_DIR/.env.production.example"
COMPOSE_FILES=(-f "$ROOT_DIR/docker-compose.yml" -f "$ROOT_DIR/docker-compose.prod.yml")
MIN_COMPOSE_VERSION="2.24.4"
# Small image used for volume tar/untar (has tar + find via busybox).
HELPER_IMAGE="${HELPER_IMAGE:-alpine:3.22}"

if [ -t 1 ]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""; C_RESET=""
fi

log() { printf '%s[%s]%s %s\n' "$C_BLUE" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[CẢNH BÁO / WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  printf '%s[LỖI / ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

# docker compose with the production file set and .env.
compose() {
  docker compose --project-directory "$ROOT_DIR" "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" "$@"
}

# version_ge A B  -> true when A >= B (dotted versions).
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Thiếu lệnh '$1' / '$1' is required but not installed."
}

require_docker() {
  require_cmd docker
  docker info >/dev/null 2>&1 ||
    die "Không kết nối được Docker daemon (chạy bằng root hoặc thêm user vào nhóm docker) / cannot reach the Docker daemon (run as root or join the docker group)."
  docker compose version >/dev/null 2>&1 ||
    die "Cần Docker Compose v2 plugin ('docker compose') / Docker Compose v2 plugin is required."
  local v
  v="$(docker compose version --short 2>/dev/null || true)"
  v="${v#v}"
  if [ -n "$v" ] && ! version_ge "$v" "$MIN_COMPOSE_VERSION"; then
    die "Docker Compose $v quá cũ, cần >= $MIN_COMPOSE_VERSION / Docker Compose $v is too old, need >= $MIN_COMPOSE_VERSION."
  fi
}

require_env_file() {
  [ -f "$ENV_FILE" ] || die "Không tìm thấy $ENV_FILE — chạy scripts/install.sh trước / $ENV_FILE not found — run scripts/install.sh first."
}

# env_get KEY -> value of the last uncommented KEY= line in $ENV_FILE
# (surrounding single/double quotes removed). Empty when absent.
env_get() {
  local key="$1" line val
  [ -f "$ENV_FILE" ] || return 0
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 || true)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

# env_set KEY VALUE -> replace KEY= in $ENV_FILE (or append it), keep mode 600.
env_set() {
  local key="$1" value="$2" tmp
  case "$value" in
    *'$'* | *$'\n'*) die "Giá trị của $key không được chứa '\$' hoặc xuống dòng / value of $key must not contain '\$' or newlines." ;;
  esac
  case "$value" in
    *' '* | *'<'* | *'>'* | *'#'*) value="\"$value\"" ;;
  esac
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    K="$key" V="$value" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' "$ENV_FILE" >"$tmp"
  else
    cat "$ENV_FILE" >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

project_name() {
  local p
  p="$(env_get COMPOSE_PROJECT_NAME)"
  [ -n "$p" ] || die "COMPOSE_PROJECT_NAME chưa được đặt trong $ENV_FILE / COMPOSE_PROJECT_NAME is not set in $ENV_FILE."
  printf '%s' "$p"
}

# volume_name <compose volume key> -> real Docker volume name.
volume_name() {
  docker volume ls -q \
    --filter "label=com.docker.compose.project=$(project_name)" \
    --filter "label=com.docker.compose.volume=$1" | head -n1
}

# container_status <service> -> healthy | unhealthy | starting | running | exited | missing
container_status() {
  local id
  id="$(compose ps -q "$1" 2>/dev/null | head -n1 || true)"
  if [ -z "$id" ]; then
    echo missing
    return 0
  fi
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing
}

# wait_healthy <service> [timeout seconds]
wait_healthy() {
  local svc="$1" timeout="${2:-300}" start status
  start="$(date +%s)"
  while :; do
    status="$(container_status "$svc")"
    case "$status" in
      healthy | running)
        ok "$svc: $status"
        return 0
        ;;
    esac
    if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
      warn "$svc chưa sẵn sàng sau ${timeout}s (trạng thái: $status). Xem log: scripts/compose.sh logs --tail=200 $svc"
      warn "$svc is not ready after ${timeout}s (status: $status). Check: scripts/compose.sh logs --tail=200 $svc"
      return 1
    fi
    sleep 5
  done
}

# Services in the compose project that are enabled by the active profiles.
active_services() {
  compose config --services
}

ghcr_login_hint() {
  cat >&2 <<'EOF'

Không tải được image từ ghcr.io. Nếu package là private, đăng nhập trước:
Could not pull from ghcr.io. If the packages are private, log in first:

  1. GitHub → Settings → Developer settings → Personal access tokens (classic)
     → Generate new token, scope: read:packages (bấm "Configure SSO" nếu org
     bật SSO / authorize SSO if the org enforces it).
  2. echo '<TOKEN>' | docker login ghcr.io -u <github-username> --password-stdin
  3. Chạy lại / re-run the script.

Kiểm tra tag có tồn tại (IMAGE_TAG trong .env): main, hoặc X.Y.Z (không có "v").
Also check that IMAGE_TAG in .env exists: main, or X.Y.Z (no "v" prefix).
EOF
}
