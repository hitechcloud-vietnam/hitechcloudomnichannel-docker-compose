#!/usr/bin/env bash
# HiTechCloudOmnichannel — cài đặt production trên một server / single-server install.
#
#   scripts/install.sh                      # hỏi tương tác / interactive
#   scripts/install.sh --domain app.example.com --acme-email ops@example.com \
#       --admin-email admin@example.com \
#       --smtp-server 'smtps://user:pass@smtp.example.com:465' \
#       --smtp-from 'HiTechCloudOmnichannel <no-reply@example.com>' \
#       --non-interactive
#
# Steps: check prerequisites → create/complete .env (secrets generated with
# openssl, never overwritten) → validate compose → pull images (ghcr.io login
# hint on failure) → start datastores → run migrations → start everything.
# Safe to re-run: existing values and secrets in .env are kept.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [options]

  --domain HOST          Tên miền ứng dụng / app host (DOMAIN)
  --s3-domain HOST       Tên miền S3 / object-storage host (S3_DOMAIN, default s3.<domain>)
  --acme-email EMAIL     Email Let's Encrypt (ACME_EMAIL)
  --admin-email EMAIL    Email quản trị nền tảng / platform admin (PLATFORM_ADMIN_EMAIL)
  --smtp-server URL      smtp[s]://user:pass@host:port (SMTP_SERVER)
  --smtp-from TEXT       Người gửi / sender (SMTP_FROM)
  --image-tag TAG        main | X.Y.Z (IMAGE_TAG, default main)
  --enable-mcp           Bật MCP server / enable the MCP server (profile "mcp")
  --mcp-domain HOST      Tên miền MCP / MCP host (default mcp.<domain>)
  --non-interactive      Không hỏi; thiếu giá trị bắt buộc thì dừng / never prompt
  --env-only             Chỉ tạo/hoàn thiện .env rồi dừng / only write .env
  --skip-pull            Không pull image / do not pull images
  -h, --help             Trợ giúp / this help

Mọi tuỳ chọn cũng đọc được từ biến môi trường cùng tên viết hoa
(DOMAIN, S3_DOMAIN, ACME_EMAIL, PLATFORM_ADMIN_EMAIL, SMTP_SERVER, SMTP_FROM,
IMAGE_TAG, MCP_DOMAIN). Every option can also come from the matching
upper-case environment variable.
EOF
}

OPT_DOMAIN="${DOMAIN:-}"
OPT_S3_DOMAIN="${S3_DOMAIN:-}"
OPT_ACME_EMAIL="${ACME_EMAIL:-}"
OPT_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-}"
OPT_SMTP_SERVER="${SMTP_SERVER:-}"
OPT_SMTP_FROM="${SMTP_FROM:-}"
OPT_IMAGE_TAG="${IMAGE_TAG:-}"
OPT_MCP_DOMAIN="${MCP_DOMAIN:-}"
ENABLE_MCP=false
INTERACTIVE=true
ENV_ONLY=false
SKIP_PULL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) OPT_DOMAIN="${2:?}"; shift 2 ;;
    --s3-domain) OPT_S3_DOMAIN="${2:?}"; shift 2 ;;
    --acme-email) OPT_ACME_EMAIL="${2:?}"; shift 2 ;;
    --admin-email) OPT_ADMIN_EMAIL="${2:?}"; shift 2 ;;
    --smtp-server) OPT_SMTP_SERVER="${2:?}"; shift 2 ;;
    --smtp-from) OPT_SMTP_FROM="${2:?}"; shift 2 ;;
    --image-tag) OPT_IMAGE_TAG="${2:?}"; shift 2 ;;
    --enable-mcp) ENABLE_MCP=true; shift ;;
    --mcp-domain) OPT_MCP_DOMAIN="${2:?}"; ENABLE_MCP=true; shift 2 ;;
    --non-interactive) INTERACTIVE=false; shift ;;
    --env-only) ENV_ONLY=true; shift ;;
    --skip-pull) SKIP_PULL=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Tuỳ chọn không hợp lệ / unknown option: $1" ;;
  esac
done

if [ "$INTERACTIVE" = true ] && ! [ -r /dev/tty ]; then
  INTERACTIVE=false
fi

# A value counts as "unset" when empty or still the example placeholder.
is_placeholder() {
  case "$1" in
    "" | *example.com* | *user:password@*) return 0 ;;
    *) return 1 ;;
  esac
}

# ask VAR_LABEL DEFAULT -> prints the answer (reads from /dev/tty).
ask() {
  local label="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >/dev/tty
  else
    printf '%s: ' "$label" >/dev/tty
  fi
  IFS= read -r answer </dev/tty || true
  printf '%s' "${answer:-$default}"
}

# resolve KEY FLAG_VALUE LABEL [DEFAULT] [required|optional]
# Order: command-line/env flag > existing .env value > prompt > default.
resolve() {
  local key="$1" flag="$2" label="$3" default="${4:-}" need="${5:-required}" current value
  current="$(env_get "$key")"
  if [ -n "$flag" ]; then
    value="$flag"
  elif ! is_placeholder "$current"; then
    value="$current"
  elif [ "$INTERACTIVE" = true ]; then
    value="$(ask "$label" "$default")"
  else
    value="$default"
  fi
  if is_placeholder "$value"; then
    if [ "$need" = required ]; then
      die "Thiếu giá trị cho $key ($label) / missing value for $key. Dùng --help."
    fi
    warn "$key vẫn là giá trị mẫu / still a placeholder: '${value}'"
    return 0
  fi
  env_set "$key" "$value"
}

gen_secret_if_empty() {
  local key="$1" kind="$2" bytes="$3" value
  value="$(env_get "$key")"
  if [ -n "$value" ] && [ "$value" != "change-me-in-production-at-least-32-chars" ]; then
    return 0
  fi
  if [ "$kind" = base64 ]; then
    value="$(openssl rand -base64 "$bytes" | tr -d '\n')"
  else
    value="$(openssl rand -hex "$bytes")"
  fi
  env_set "$key" "$value"
  log "Đã sinh / generated $key"
}

check_host_resources() {
  local mem_kb disk_kb
  if [ -r /proc/meminfo ]; then
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    if [ "${mem_kb:-0}" -lt 3800000 ]; then
      warn "RAM < 4 GB ($((mem_kb / 1024)) MB). Khuyến nghị >= 8 GB / 8 GB+ recommended."
    fi
  fi
  disk_kb="$(df -Pk "$ROOT_DIR" | awk 'NR==2 {print $4}')"
  if [ "${disk_kb:-0}" -lt 20000000 ]; then
    warn "Ổ đĩa trống < 20 GB / less than 20 GB free disk space."
  fi
  if [ "$(uname -m)" != "x86_64" ]; then
    warn "Image chỉ build cho linux/amd64; máy $(uname -m) sẽ phải giả lập (rất chậm) / images are amd64-only."
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)(80|443)$'; then
      if ! compose ps -q proxy 2>/dev/null | grep -q .; then
        warn "Cổng 80/443 đang bị chiếm bởi tiến trình khác (nginx/apache?) / ports 80/443 already in use."
      fi
    fi
  fi
}

check_dns() {
  local host ips
  for host in "$@"; do
    [ -n "$host" ] || continue
    ips="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    if [ -z "$ips" ]; then
      warn "DNS: $host chưa phân giải được — Caddy sẽ không xin được chứng chỉ HTTPS / does not resolve yet."
    else
      log "DNS: $host -> $ips"
    fi
  done
  if command -v hostname >/dev/null 2>&1; then
    log "IP của server / server addresses: $(hostname -I 2>/dev/null || true)"
  fi
}

# ── 1. Prerequisites ───────────────────────────────────────────────────────
require_cmd openssl
require_cmd awk
if [ "$ENV_ONLY" = false ]; then
  require_docker
fi

# ── 2. .env ────────────────────────────────────────────────────────────────
umask 077
if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "Đã tạo / created $ENV_FILE từ .env.production.example"
else
  chmod 600 "$ENV_FILE"
  log "Dùng lại / reusing $ENV_FILE (giữ nguyên secret hiện có / existing secrets are kept)"
fi

resolve DOMAIN "$OPT_DOMAIN" "Tên miền ứng dụng / app domain (vd. app.congty.vn)"
DOMAIN_VALUE="$(env_get DOMAIN)"
case "$DOMAIN_VALUE" in
  http://* | https://* | */*) die "DOMAIN chỉ là tên miền, không có http(s):// hay '/' / DOMAIN must be a bare host name." ;;
esac
resolve S3_DOMAIN "$OPT_S3_DOMAIN" "Tên miền object storage / S3 domain" "s3.$DOMAIN_VALUE"
resolve ACME_EMAIL "$OPT_ACME_EMAIL" "Email Let's Encrypt / ACME e-mail"
resolve PLATFORM_ADMIN_EMAIL "$OPT_ADMIN_EMAIL" "Email quản trị nền tảng / platform admin e-mail" "$(env_get ACME_EMAIL)"
resolve SMTP_SERVER "$OPT_SMTP_SERVER" "SMTP URL (smtps://user:pass@host:465)" "" optional
resolve SMTP_FROM "$OPT_SMTP_FROM" "Người gửi email / SMTP from" "HiTechCloudOmnichannel <no-reply@$DOMAIN_VALUE>" optional
if [ -n "$OPT_IMAGE_TAG" ]; then
  env_set IMAGE_TAG "$OPT_IMAGE_TAG"
elif [ -z "$(env_get IMAGE_TAG)" ]; then
  env_set IMAGE_TAG main
fi
[ -n "$(env_get COMPOSE_PROJECT_NAME)" ] || env_set COMPOSE_PROJECT_NAME hitechcloudomnichannel

if is_placeholder "$(env_get SMTP_SERVER)"; then
  warn "SMTP chưa cấu hình: đăng ký tài khoản cần email xác minh nên sẽ KHÔNG đăng ký được."
  warn "SMTP is not configured: sign-up requires e-mail verification, so nobody can register until it is."
fi

gen_secret_if_empty BETTER_AUTH_SECRET base64 32
gen_secret_if_empty ENCRYPTION_KEY hex 32
gen_secret_if_empty REALTIME_BROADCAST_SECRET hex 32
gen_secret_if_empty JAVASCRIPT_EXECUTOR_TOKEN hex 32
gen_secret_if_empty POSTGRES_PASSWORD hex 24
gen_secret_if_empty REDIS_PASSWORD hex 24
gen_secret_if_empty S3_SECRET_ACCESS_KEY hex 24

if [ "$ENABLE_MCP" = true ]; then
  resolve MCP_DOMAIN "$OPT_MCP_DOMAIN" "Tên miền MCP / MCP domain" "mcp.$DOMAIN_VALUE"
  profiles="$(env_get COMPOSE_PROFILES)"
  case ",$profiles," in
    *,mcp,*) ;;
    *) env_set COMPOSE_PROFILES "${profiles:+$profiles,}mcp" ;;
  esac
  cp "$ROOT_DIR/caddy/sites-available/mcp.caddy" "$ROOT_DIR/caddy/sites-enabled/mcp.caddy"
  chmod 644 "$ROOT_DIR/caddy/sites-enabled/mcp.caddy"
  log "Đã bật MCP / MCP enabled at https://$(env_get MCP_DOMAIN)/sse"
fi

ok "Đã ghi cấu hình / configuration written to $ENV_FILE (chmod 600)"
warn "Hãy sao lưu $ENV_FILE ở nơi an toàn: mất ENCRYPTION_KEY = mất dữ liệu đã mã hoá."
warn "Back up $ENV_FILE somewhere safe: losing ENCRYPTION_KEY means losing encrypted data."

if [ "$ENV_ONLY" = true ]; then
  exit 0
fi

# ── 3. Validate ────────────────────────────────────────────────────────────
compose config -q || die "docker compose config thất bại — kiểm tra .env / compose validation failed — check .env."
ok "docker compose config hợp lệ / valid"
check_host_resources
check_dns "$DOMAIN_VALUE" "$(env_get S3_DOMAIN)" "$([ "$ENABLE_MCP" = true ] && env_get MCP_DOMAIN || true)"

# ── 4. Pull ────────────────────────────────────────────────────────────────
if [ "$SKIP_PULL" = false ]; then
  log "Tải image / pulling images (IMAGE_TAG=$(env_get IMAGE_TAG))..."
  if ! compose pull; then
    ghcr_login_hint
    exit 1
  fi
fi

# ── 5. Datastores + migrations ─────────────────────────────────────────────
log "Khởi động cơ sở dữ liệu / starting datastores..."
compose up -d postgres redis filesystem
wait_healthy postgres 180
wait_healthy redis 120
wait_healthy filesystem 180
log "Tạo bucket / creating bucket..."
compose run --rm filesystem-init
log "Chạy migration / running database migrations..."
compose run --rm migrate

# ── 6. Everything else ─────────────────────────────────────────────────────
log "Khởi động toàn bộ / starting all services..."
compose up -d
wait_healthy javascript-executor 180 || true
wait_healthy realtime 240 || true
wait_healthy builder 300 || true
wait_healthy worker 120 || true
wait_healthy proxy 120 || true

cat <<EOF

${C_GREEN}Hoàn tất / Done.${C_RESET}

  Ứng dụng / App:         https://${DOMAIN_VALUE}
  Object storage (S3):    https://$(env_get S3_DOMAIN)
  Trạng thái / Status:    scripts/compose.sh ps
  Log:                    scripts/compose.sh logs -f --tail=100 builder worker

Bước tiếp theo / Next steps:
  1. Mở https://${DOMAIN_VALUE}/auth/sign-up và đăng ký bằng $(env_get PLATFORM_ADMIN_EMAIL)
     (cần SMTP để nhận email xác minh). Sign up with the platform admin e-mail.
  2. Vào https://${DOMAIN_VALUE}/admin để cấu hình credentials nền tảng & kênh
     (Facebook/Messenger, Instagram, WhatsApp, Zalo, TikTok...).
  3. Cài lịch sao lưu / schedule backups: xem docs/trien-khai-production.md (cron + scripts/backup.sh).
EOF
