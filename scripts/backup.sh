#!/usr/bin/env bash
# HiTechCloudOmnichannel — sao lưu / backup.
#
#   scripts/backup.sh                     # -> $BACKUP_DIR/YYYYmmdd-HHMMSS/
#   scripts/backup.sh --dir /mnt/backup --retention-days 14
#
# Each backup directory contains:
#   postgres.dump            pg_dump custom format (TimescaleDB-aware restore in restore.sh)
#   filesystem-data.tar.gz   RustFS volume (all uploaded files / media)
#   redis-data.tar.gz        Redis volume (BullMQ queues, AOF + RDB)
#   env                      copy of .env (SECRETS, incl. ENCRYPTION_KEY!)
#   sites-enabled/           enabled extra Caddy sites
#   MANIFEST, SHA256SUMS
#
# The database dump is consistent (single pg_dump snapshot). Volumes are
# copied while running (objects are write-once, Redis keeps an AOF); use
# --stop-storage for a fully quiesced copy (short storage/redis downtime).
# Old backups (> BACKUP_RETENTION_DAYS days) are deleted afterwards.
# Cron example (02:30 every night):
#   30 2 * * * cd /opt/hitechcloudomnichannel-docker-compose && scripts/backup.sh >> backups/backup.log 2>&1
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/backup.sh [--dir DIR] [--retention-days N] [--no-files] [--stop-storage]

  --dir DIR             Thư mục đích / target directory (default: BACKUP_DIR in .env, else ./backups)
  --retention-days N    Xoá bản cũ hơn N ngày / delete backups older than N days (0 = keep all)
  --no-files            Chỉ sao lưu database + .env / database and .env only
  --stop-storage        Dừng filesystem + redis khi copy volume / stop them while copying
EOF
}

require_env_file
BACKUP_ROOT="$(env_get BACKUP_DIR)"
BACKUP_ROOT="${BACKUP_ROOT:-./backups}"
RETENTION_DAYS="$(env_get BACKUP_RETENTION_DAYS)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
WITH_FILES=true
STOP_STORAGE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) BACKUP_ROOT="${2:?}"; shift 2 ;;
    --retention-days) RETENTION_DAYS="${2:?}"; shift 2 ;;
    --no-files) WITH_FILES=false; shift ;;
    --stop-storage) STOP_STORAGE=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Tuỳ chọn không hợp lệ / unknown option: $1" ;;
  esac
done

case "$RETENTION_DAYS" in
  '' | *[!0-9]*) die "--retention-days phải là số / must be a number" ;;
esac

require_docker
umask 077

case "$BACKUP_ROOT" in
  /*) ;;
  *) BACKUP_ROOT="$ROOT_DIR/${BACKUP_ROOT#./}" ;;
esac
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$STAMP"
mkdir -p "$DEST"
log "Sao lưu vào / backing up to $DEST"

# ── PostgreSQL ─────────────────────────────────────────────────────────────
[ "$(container_status postgres)" = healthy ] || die "postgres không chạy / is not running (scripts/compose.sh up -d postgres)."
log "pg_dump..."
# Credentials are expanded inside the container from its own environment.
# shellcheck disable=SC2016
compose exec -T postgres sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  >"$DEST/postgres.dump"
# Verify the archive is readable.
compose exec -T postgres pg_restore -l <"$DEST/postgres.dump" >/dev/null ||
  die "postgres.dump hỏng / is not a valid archive."
ok "postgres.dump ($(du -h "$DEST/postgres.dump" | cut -f1))"

# ── Volumes ────────────────────────────────────────────────────────────────
backup_volume() {
  local key="$1" vol
  vol="$(volume_name "$key")"
  if [ -z "$vol" ]; then
    warn "Không tìm thấy volume / volume not found: $key — bỏ qua / skipped"
    return 0
  fi
  docker run --rm \
    -v "$vol:/data:ro" \
    -v "$DEST:/backup" \
    "$HELPER_IMAGE" tar czf "/backup/$key.tar.gz" -C /data .
  ok "$key.tar.gz ($(du -h "$DEST/$key.tar.gz" | cut -f1))"
}

if [ "$WITH_FILES" = true ]; then
  if [ "$STOP_STORAGE" = true ]; then
    log "Tạm dừng / stopping worker, filesystem, redis..."
    compose stop worker filesystem redis
    trap 'compose start redis filesystem worker >/dev/null 2>&1 || true' EXIT
  else
    # Flush Redis to disk first so the RDB snapshot is current.
    compose exec -T redis redis-cli SAVE >/dev/null 2>&1 || warn "redis SAVE thất bại / failed (tiếp tục / continuing)"
  fi
  backup_volume filesystem-data
  backup_volume redis-data
  if [ "$STOP_STORAGE" = true ]; then
    compose start redis filesystem worker
    trap - EXIT
  fi
fi

# ── Config ─────────────────────────────────────────────────────────────────
cp "$ENV_FILE" "$DEST/env"
chmod 600 "$DEST/env"
mkdir -p "$DEST/sites-enabled"
find "$ROOT_DIR/caddy/sites-enabled" -maxdepth 1 -name '*.caddy' -exec cp {} "$DEST/sites-enabled/" \;

{
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "project=$(project_name)"
  echo "image_tag=$(env_get IMAGE_TAG)"
  echo "domain=$(env_get DOMAIN)"
  echo "with_files=$WITH_FILES"
  for svc in builder worker realtime; do
    id="$(compose ps -q "$svc" 2>/dev/null | head -n1 || true)"
    if [ -n "$id" ]; then
      echo "image_$svc=$(docker inspect -f '{{.Image}}' "$id" 2>/dev/null || true)"
    fi
  done
} >"$DEST/MANIFEST"
sums="$(cd "$DEST" && find . -maxdepth 1 -type f -exec sha256sum {} +)"
printf '%s\n' "$sums" >"$DEST/SHA256SUMS"
ok "Hoàn tất / done: $DEST ($(du -sh "$DEST" | cut -f1))"
warn "Bản sao lưu chứa secret (.env). Hãy chép ra ngoài server (rsync/rclone) và mã hoá nếu cần."
warn "The backup contains secrets (.env). Copy it off the server and encrypt it if needed."

# ── Rotation ───────────────────────────────────────────────────────────────
if [ "$RETENTION_DAYS" -gt 0 ]; then
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    log "Xoá bản cũ / removing old backup $old"
    rm -rf -- "$old"
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' -mtime "+$RETENTION_DAYS")
fi
