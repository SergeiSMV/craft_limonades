#!/usr/bin/env bash
# Craft WMS · бэкап PostgreSQL из прод-контейнера с ротацией.
# Делает pg_dump внутри контейнера БД, кладёт сжатый дамп в каталог бэкапов,
# удаляет дампы старше N дней.
#
# Ручной запуск:  bash deploy/pg-backup.sh
# По расписанию (cron, ежедневно в 03:30) — добавьте в crontab пользователя с доступом к docker:
#   30 3 * * * /bin/bash /path/to/repo/deploy/pg-backup.sh >> /var/log/craft-wms-backup.log 2>&1
#
# Каталог и срок хранения настраиваются переменными окружения:
#   BACKUP_DIR   (по умолчанию $REPO_ROOT/backups)
#   KEEP_DAYS    (по умолчанию 14)
set -euo pipefail

log()  { printf '\033[1;36m[backup]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[backup] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/infra/.env.prod"
COMPOSE_FILE="$REPO_ROOT/infra/docker-compose.prod.yml"
BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"

[[ -f "$ENV_FILE" ]] || die "нет $ENV_FILE."
COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

get_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- ; }
PG_USER="$(get_env POSTGRES_USER)"
PG_DB="$(get_env POSTGRES_DB)"
[[ -n "$PG_USER" && -n "$PG_DB" ]] || die "POSTGRES_USER/POSTGRES_DB не заданы в $ENV_FILE."

cid="$("${COMPOSE[@]}" ps -q db)"
[[ -n "$cid" ]] || die "контейнер БД не запущен (сначала deploy/20-deploy.sh)."

mkdir -p "$BACKUP_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
out="$BACKUP_DIR/craft_wms-$stamp.sql.gz"

log "Дамп $PG_DB → $out"
# pg_dump внутри контейнера; поток сжимаем на хосте. PGPASSWORD не нужен — локальный trust внутри контейнера.
docker exec "$cid" pg_dump -U "$PG_USER" -d "$PG_DB" | gzip -c > "$out"
[[ -s "$out" ]] || die "дамп пустой — проверьте доступ к БД."
log "Готово: $(du -h "$out" | cut -f1)"

# Ротация: удаляем дампы старше KEEP_DAYS.
log "Ротация: удаляю дампы старше $KEEP_DAYS дн. в $BACKUP_DIR"
find "$BACKUP_DIR" -name 'craft_wms-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete || true

log "Бэкап завершён."
