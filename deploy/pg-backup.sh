#!/usr/bin/env bash
# Craft WMS · бэкап PostgreSQL с ротацией. pg_dump из контейнера БД → сжатый файл,
# удаление дампов старше KEEP_DAYS.
#
# Ручной запуск:  bash deploy/pg-backup.sh
# По расписанию (ежедневно 03:30) — в crontab пользователя с доступом к docker:
#   30 3 * * * /bin/bash /opt/craft-wms/app/deploy/pg-backup.sh >> /var/log/craft-wms-backup.log 2>&1
#
# Переменные: BACKUP_DIR (по умолчанию рядом с .env.prod → ../backups), KEEP_DAYS (14).
set -euo pipefail
SCRIPT_NAME=backup
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env_file
BACKUP_DIR="${BACKUP_DIR:-$(cd "$REPO_ROOT/.." && pwd)/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"

PG_USER="$(get_env POSTGRES_USER)"; PG_DB="$(get_env POSTGRES_DB)"
[[ -n "$PG_USER" && -n "$PG_DB" ]] || die "POSTGRES_USER/POSTGRES_DB не заданы в $ENV_FILE."

cid="$(compose ps -q db)"
[[ -n "$cid" ]] || die "контейнер БД не запущен (сначала deploy/install.sh)."

mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/craft_wms-$(date +%Y%m%d-%H%M%S).sql.gz"
log "Дамп $PG_DB → $out"
docker exec "$cid" pg_dump -U "$PG_USER" -d "$PG_DB" | gzip -c > "$out"
[[ -s "$out" ]] || die "дамп пустой — проверьте доступ к БД."
log "Готово: $(du -h "$out" | cut -f1)"

log "Ротация: удаляю дампы старше $KEEP_DAYS дн."
find "$BACKUP_DIR" -name 'craft_wms-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete || true
log "Бэкап завершён."
