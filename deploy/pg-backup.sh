#!/usr/bin/env bash
# Craft WMS · бэкап PostgreSQL с ротацией, шифрованием и внешней копией.
# pg_dump из контейнера БД → сжатый файл → шифрование паролем → отправка во внешнюю копию,
# удаление дампов старше KEEP_DAYS.
#
# Ручной запуск:  bash deploy/pg-backup.sh
# По расписанию — systemd-таймер craft-wms-backup.timer (ставит deploy/install.sh).
#
# Переменные: BACKUP_DIR (по умолчанию рядом с .env.prod → ../backups), KEEP_DAYS (14),
#   BACKUP_PASSPHRASE (шифрование),
#   OFFSITE_DEST / OFFSITE_RCLONE_REMOTE / OFFSITE_SSH_KEY (внешняя копия).
set -euo pipefail
SCRIPT_NAME=backup
# Путь к _lib.sh вычисляется в рантайме — статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env_file
# Исход ночного бэкапа — сигналом мониторингу таймеров (ADHOC-42): не пришёл к сроку или упал — письмо.
job_watch BACKUP
BACKUP_DIR="${BACKUP_DIR:-$(cd "$REPO_ROOT/.." && pwd)/backups}"
KEEP_DAYS="${KEEP_DAYS:-$(get_env KEEP_DAYS)}"
KEEP_DAYS="${KEEP_DAYS:-14}"

# Пароль шифрования читаем ДО дампа: настроен он или нет, надо знать заранее.
PASS="$(backup_passphrase)"

mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/craft_wms-$(date +%Y%m%d-%H%M%S).sql.gz"
log "Дамп $(get_env POSTGRES_DB) → $out"
dump_db "$out"
log "Готово: $(du -h "$out" | cut -f1)"

# --- Шифрование ---
# Незашифрованный .sql.gz остаётся на сервере намеренно: на нём работает еженедельная проверка
# восстановимости (craft-wms-restore-check), которой иначе пришлось бы каждый раз расшифровывать.
# Наружу уезжает только .enc — выносить незашифрованное хуже, чем не выносить вовсе.
if [[ -z "$PASS" ]]; then
  journal_err "шифрование дампов не настроено (BACKUP_PASSPHRASE пуст) — внешняя копия отправлена НЕ БУДЕТ: в дампе ФИО, логины и хеши паролей."
  warn "BACKUP_PASSPHRASE не задан — внешняя копия пропускается. Настроить: панель управления → «Настроить бэкапы»."
else
  log "Шифрую дамп…"
  encrypt_dump "$out" "$out.enc"
  log "Зашифровано: $(basename "$out.enc"), $(du -h "$out.enc" | cut -f1)"
fi

# --- Ротация (до отправки: наружу зеркалится уже проредённый набор) ---
log "Ротация: удаляю дампы старше $KEEP_DAYS дн."
find "$BACKUP_DIR" -name 'craft_wms-*.sql.gz' -type f -mtime "+$KEEP_DAYS" -print -delete || true
find "$BACKUP_DIR" -name 'craft_wms-*.sql.gz.enc' -type f -mtime "+$KEEP_DAYS" -print -delete || true

# --- Внешняя копия ---
# Только при настроенном шифровании: см. долг 3 в dev-context.md §10.
if [[ -n "$PASS" ]]; then
  offsite_push "$BACKUP_DIR"
fi

log "Бэкап завершён."
