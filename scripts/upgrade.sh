#!/usr/bin/env bash
# HiTechCloudOmnichannel — nâng cấp / upgrade.
#
#   scripts/upgrade.sh 1.4.0        # ghim phiên bản / pin a release (git tag v1.4.0 -> image 1.4.0)
#   scripts/upgrade.sh              # pull lại tag hiện tại / re-pull the current tag (e.g. main)
#
# Steps: backup → set IMAGE_TAG → pull → run migrations (one-shot `migrate`)
# → restart services one by one, waiting for each to become healthy
# (javascript-executor → realtime → worker → builder → mcp → proxy).
# On a failed pull or migration IMAGE_TAG is reverted and the running
# containers are left untouched.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/upgrade.sh [NEW_TAG] [--skip-backup] [--prune] [--yes]

  NEW_TAG        main | X.Y.Z (không có "v" / without the "v" prefix)
  --skip-backup  Không sao lưu trước / skip the pre-upgrade backup (không khuyến nghị)
  --prune        Xoá image cũ không dùng / remove dangling images afterwards
  --yes          Không hỏi xác nhận / do not ask for confirmation
EOF
}

NEW_TAG=""
SKIP_BACKUP=false
PRUNE=false
ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-backup) SKIP_BACKUP=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "Tuỳ chọn không hợp lệ / unknown option: $1" ;;
    *) NEW_TAG="$1"; shift ;;
  esac
done

require_env_file
require_docker

OLD_TAG="$(env_get IMAGE_TAG)"
OLD_TAG="${OLD_TAG:-main}"
NEW_TAG="${NEW_TAG:-$OLD_TAG}"
case "$NEW_TAG" in
  v[0-9]*)
    warn "Image tag không có tiền tố 'v' (docker/metadata-action) — dùng ${NEW_TAG#v} / image tags have no 'v' prefix."
    NEW_TAG="${NEW_TAG#v}"
    ;;
esac

log "Nâng cấp / upgrading: $OLD_TAG -> $NEW_TAG"
if [ "$ASSUME_YES" = false ] && [ -r /dev/tty ]; then
  printf 'Tiếp tục? / Continue? [y/N] ' >/dev/tty
  IFS= read -r answer </dev/tty || true
  case "$answer" in y | Y | yes | YES) ;; *) die "Đã huỷ / aborted." ;; esac
fi

# ── 1. Backup ──────────────────────────────────────────────────────────────
if [ "$SKIP_BACKUP" = false ]; then
  "$ROOT_DIR/scripts/backup.sh"
else
  warn "Bỏ qua sao lưu / backup skipped"
fi

revert_tag() {
  env_set IMAGE_TAG "$OLD_TAG"
  warn "Đã trả IMAGE_TAG về / reverted IMAGE_TAG to $OLD_TAG"
}

# ── 2. Pull ────────────────────────────────────────────────────────────────
env_set IMAGE_TAG "$NEW_TAG"
log "Tải image / pulling images..."
if ! compose pull; then
  revert_tag
  ghcr_login_hint
  exit 1
fi

# ── 3. Migrate ─────────────────────────────────────────────────────────────
log "Chạy migration / running migrations..."
if ! compose run --rm migrate; then
  revert_tag
  cat >&2 <<EOF

Migration thất bại. Các container đang chạy vẫn là bản cũ ($OLD_TAG).
Migration failed. Running containers are still on $OLD_TAG.
Một số migration (CREATE INDEX CONCURRENTLY) không chạy trong transaction nên
có thể đã áp dụng một phần; nếu ứng dụng lỗi, khôi phục bản sao lưu vừa tạo:
Some migrations are non-transactional and may be partially applied; if the
app misbehaves, restore the backup that was just taken:
  scripts/restore.sh $(env_get BACKUP_DIR)/<newest>
EOF
  exit 1
fi

# ── 4. Rolling restart ─────────────────────────────────────────────────────
mapfile -t enabled < <(active_services)
is_enabled() {
  local s
  for s in "${enabled[@]}"; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

failed=()
for svc in filesystem-init javascript-executor realtime worker builder mcp proxy; do
  is_enabled "$svc" || continue
  if [ "$svc" = filesystem-init ]; then
    compose up -d --no-deps "$svc" >/dev/null
    continue
  fi
  log "Khởi động lại / restarting $svc..."
  compose up -d --no-deps "$svc"
  wait_healthy "$svc" 300 || failed+=("$svc")
done

# Anything else whose image/config changed (datastores are pinned, so this is
# normally a no-op).
compose up -d

if [ "$PRUNE" = true ]; then
  docker image prune -f >/dev/null
  ok "Đã dọn image cũ / pruned dangling images"
fi

compose ps
if [ "${#failed[@]}" -gt 0 ]; then
  warn "Chưa healthy / not healthy: ${failed[*]}"
  warn "Quay lại bản cũ / roll back: scripts/upgrade.sh $OLD_TAG --skip-backup  (và nếu cần / and if needed: scripts/restore.sh <backup>)"
  exit 1
fi
ok "Nâng cấp xong / upgrade finished: IMAGE_TAG=$NEW_TAG"
