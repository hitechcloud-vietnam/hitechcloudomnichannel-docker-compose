#!/usr/bin/env bash
# HiTechCloudOmnichannel — khôi phục / restore a backup made by scripts/backup.sh.
#
#   scripts/restore.sh backups/20261014-023000
#   scripts/restore.sh backups/20261014-023000 --with-env --yes   # new server
#
# DESTRUCTIVE: the current database (and, unless --skip-files, all stored
# files and Redis data) are replaced by the backup.
#
# Steps: stop app services → recreate the database and pg_restore it with
# TimescaleDB pre/post-restore hooks → replace the filesystem / redis volumes
# → start everything (the migrate service then brings an older backup's schema
# up to the running IMAGE_TAG).
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/restore.sh <backup-dir> [--yes] [--with-env] [--skip-files] [--skip-db]

  --yes          Không hỏi xác nhận / do not ask for confirmation
  --with-env     Dùng .env trong bản sao lưu (server mới) / restore .env from the backup
  --skip-files   Không khôi phục volume file & redis / database only
  --skip-db      Không khôi phục database / files only
EOF
}

SRC=""
ASSUME_YES=false
WITH_ENV=false
SKIP_FILES=false
SKIP_DB=false
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=true; shift ;;
    --with-env) WITH_ENV=true; shift ;;
    --skip-files) SKIP_FILES=true; shift ;;
    --skip-db) SKIP_DB=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "Tuỳ chọn không hợp lệ / unknown option: $1" ;;
    *) SRC="$1"; shift ;;
  esac
done

[ -n "$SRC" ] || { usage >&2; exit 1; }
[ -d "$SRC" ] || die "Không tìm thấy / not found: $SRC"
SRC="$(cd "$SRC" && pwd)"

require_docker

# ── Integrity ──────────────────────────────────────────────────────────────
if [ -f "$SRC/SHA256SUMS" ]; then
  (cd "$SRC" && sha256sum --quiet -c SHA256SUMS) || die "Checksum không khớp / checksum mismatch in $SRC"
  ok "Checksum OK"
fi

# ── .env ───────────────────────────────────────────────────────────────────
if [ "$WITH_ENV" = true ]; then
  [ -f "$SRC/env" ] || die "Bản sao lưu không có file env / backup has no env file"
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$ENV_FILE.before-restore.$(date +%Y%m%d-%H%M%S)"
  fi
  cp "$SRC/env" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if [ -d "$SRC/sites-enabled" ]; then
    find "$SRC/sites-enabled" -maxdepth 1 -name '*.caddy' -exec cp {} "$ROOT_DIR/caddy/sites-enabled/" \;
  fi
  ok "Đã khôi phục / restored .env"
fi
require_env_file

if [ -f "$SRC/env" ] && [ "$WITH_ENV" = false ]; then
  backup_key="$(ENV_FILE="$SRC/env" env_get ENCRYPTION_KEY)"
  if [ -n "$backup_key" ] && [ "$backup_key" != "$(env_get ENCRYPTION_KEY)" ]; then
    warn "ENCRYPTION_KEY trong bản sao lưu KHÁC .env hiện tại: secret đã mã hoá (token kênh, API key) sẽ không giải mã được."
    warn "ENCRYPTION_KEY differs from the backup's: encrypted secrets will be unreadable. Use --with-env or copy the key over."
    [ "$ASSUME_YES" = true ] || die "Dừng lại để an toàn / aborting for safety (thêm --yes để bỏ qua / add --yes to override)."
  fi
fi

if [ "$ASSUME_YES" = false ]; then
  if ! [ -r /dev/tty ]; then
    die "Cần --yes khi chạy không tương tác / --yes is required when not interactive."
  fi
  printf 'Dữ liệu hiện tại của %s sẽ bị GHI ĐÈ. Gõ "restore" để tiếp tục / type "restore" to continue: ' "$(env_get DOMAIN)" >/dev/tty
  IFS= read -r answer </dev/tty || true
  [ "$answer" = restore ] || die "Đã huỷ / aborted."
fi

# ── Stop the application ───────────────────────────────────────────────────
log "Dừng ứng dụng / stopping application services..."
app_services=()
for svc in proxy builder worker realtime mcp; do
  if active_services | grep -qx "$svc"; then
    app_services+=("$svc")
  fi
done
compose stop "${app_services[@]}"
compose up -d postgres redis filesystem
wait_healthy postgres 180

# ── Database ───────────────────────────────────────────────────────────────
if [ "$SKIP_DB" = false ]; then
  [ -f "$SRC/postgres.dump" ] || die "Thiếu / missing $SRC/postgres.dump"
  log "Tạo lại database / recreating the database..."
  # shellcheck disable=SC2016 # expanded inside the container
  compose exec -T postgres sh -ec '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE)" \
      -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\""
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -c "CREATE EXTENSION IF NOT EXISTS timescaledb" \
      -c "SELECT timescaledb_pre_restore()"
  '
  log "pg_restore (có thể mất vài phút / may take a while)..."
  restore_status=0
  # shellcheck disable=SC2016 # expanded inside the container
  compose exec -T postgres sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner' \
    <"$SRC/postgres.dump" || restore_status=$?
  # shellcheck disable=SC2016 # expanded inside the container
  compose exec -T postgres sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT timescaledb_post_restore()"'
  if [ "$restore_status" -ne 0 ]; then
    warn "pg_restore báo lỗi (exit $restore_status). Thường là cảnh báo về extension/quyền và có thể bỏ qua — hãy đọc log ở trên."
    warn "pg_restore reported errors (exit $restore_status). Usually harmless extension/ownership notices — review the output above."
  fi
  ok "Database đã khôi phục / restored"
fi

# ── Volumes ────────────────────────────────────────────────────────────────
restore_volume() {
  local key="$1" vol
  [ -f "$SRC/$key.tar.gz" ] || { warn "Bỏ qua / skipping $key (không có trong bản sao lưu / not in backup)"; return 0; }
  vol="$(volume_name "$key")"
  [ -n "$vol" ] || die "Không tìm thấy volume / volume not found: $key"
  docker run --rm \
    -v "$vol:/data" \
    -v "$SRC:/backup:ro" \
    "$HELPER_IMAGE" sh -ec "find /data -mindepth 1 -delete; tar xzf /backup/$key.tar.gz -C /data"
  ok "$key đã khôi phục / restored"
}

if [ "$SKIP_FILES" = false ]; then
  log "Khôi phục volume / restoring volumes..."
  compose stop filesystem redis
  restore_volume filesystem-data
  restore_volume redis-data
fi

# ── Start ──────────────────────────────────────────────────────────────────
log "Khởi động lại / starting everything (migrate chạy trước / runs first)..."
compose up -d
wait_healthy builder 300 || true
wait_healthy proxy 120 || true
ok "Khôi phục xong / restore finished from $SRC"
