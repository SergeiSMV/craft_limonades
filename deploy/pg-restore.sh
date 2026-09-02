#!/usr/bin/env bash
# Craft WMS · восстановление PostgreSQL из дампа deploy/pg-backup.sh.
#
# Два режима:
#   bash deploy/pg-restore.sh --check [файл]   — проверка дампа: разворачивает его во ВРЕМЕННУЮ
#       базу, сверяет состав, удаляет её. Прод-база и backend НЕ трогаются. Безопасно, гоняется
#       по расписанию (craft-wms-restore-check.timer).
#   bash deploy/pg-restore.sh [файл]           — боевое восстановление: ЗАМЕЩАЕТ прод-базу
#       содержимым дампа. Разрушающая операция, спрашивает подтверждение (обойти: --yes).
#
# Без аргумента-файла берётся самый свежий дамп из BACKUP_DIR.
#
# Переменные: BACKUP_DIR (по умолчанию рядом с .env.prod → ../backups).
set -euo pipefail
SCRIPT_NAME=restore
# Путь к _lib.sh вычисляется в рантайме — статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# --- Разбор аргументов ---
MODE=restore
ASSUME_YES=false
DUMP=""
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "неизвестный ключ: $arg (см. --help)." ;;
    *)  DUMP="$arg" ;;
  esac
done

require_env_file
BACKUP_DIR="${BACKUP_DIR:-$(cd "$REPO_ROOT/.." && pwd)/backups}"

PG_USER="$(get_env POSTGRES_USER)"; PG_DB="$(get_env POSTGRES_DB)"
[[ -n "$PG_USER" && -n "$PG_DB" ]] || die "POSTGRES_USER/POSTGRES_DB не заданы в $ENV_FILE."

cid="$(compose ps -q db)"
[[ -n "$cid" ]] || die "контейнер БД не запущен (сначала deploy/install.sh)."

# psql_admin ... — psql в контейнере БД от служебной базы postgres (не от восстанавливаемой:
# её нельзя дропнуть, будучи к ней подключённым).
psql_admin() { docker exec -i "$cid" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 "$@"; }
# psql_db DB ... — psql внутри конкретной базы.
psql_db() { local db="$1"; shift; docker exec -i "$cid" psql -U "$PG_USER" -d "$db" -v ON_ERROR_STOP=1 "$@"; }

# --- Уборка за собой ---
# Один обработчик на оба хвоста (расшифрованный временный файл и временная база проверки):
# trap на EXIT ставится один раз, второй `trap … EXIT` молча заменил бы первый.
TMP_PLAIN=""
CHECK_DB=""
cleanup() {
  # Расшифрованный дамп — это открытые ФИО и хеши паролей: убираем при любом исходе.
  [[ -n "$TMP_PLAIN" && -f "$TMP_PLAIN" ]] && rm -f "$TMP_PLAIN"
  [[ -n "$CHECK_DB" ]] && psql_admin -c "DROP DATABASE IF EXISTS \"$CHECK_DB\"" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# --- Выбор дампа ---
# Приоритет у зашифрованных: при настроенном шифровании .enc — основной формат, а .sql.gz
# живёт на сервере лишь до ближайшей ротации, ради проверки восстановимости.
if [[ -z "$DUMP" ]]; then
  DUMP="$(ls -1t "$BACKUP_DIR"/craft_wms-*.sql.gz.enc "$BACKUP_DIR"/craft_wms-*.sql.gz 2>/dev/null | head -1 || true)"
  [[ -n "$DUMP" ]] || die "в $BACKUP_DIR нет дампов craft_wms-*.sql.gz[.enc] — сначала deploy/pg-backup.sh."
  log "Дамп не указан — беру самый свежий: $(basename "$DUMP")"
fi
[[ -f "$DUMP" ]] || die "файл не найден: $DUMP"

# --- Расшифровка ---
# Временный файл — с правами 600 в приватном каталоге: в дампе персональные данные, а
# BACKUP_DIR может быть доступен на чтение другим.
if [[ "$DUMP" == *.enc ]]; then
  log "Файл зашифрован — расшифровываю во временный…"
  TMP_PLAIN="$(mktemp -t craft-wms-restore.XXXXXX)"
  chmod 600 "$TMP_PLAIN"
  decrypt_dump "$DUMP" "$TMP_PLAIN"
  log "Расшифровано: $(du -h "$TMP_PLAIN" | cut -f1)"
  DUMP="$TMP_PLAIN"
fi

# Целостность архива проверяем ДО того, как что-то ронять: битый gzip лучше поймать сейчас.
log "Проверяю целостность архива…"
gzip -t "$DUMP" || die "архив повреждён: $DUMP"
log "Архив цел: $(du -h "$DUMP" | cut -f1), $(date -r "$DUMP" '+%Y-%m-%d %H:%M')"

# restore_into DB — развернуть дамп в существующую пустую базу.
restore_into() {
  local db="$1"
  gunzip -c "$DUMP" | docker exec -i "$cid" psql -U "$PG_USER" -d "$db" -v ON_ERROR_STOP=1 --quiet >/dev/null
}

# verify DB — минимальная проверка, что развернулось осмысленное содержимое, а не пустышка.
# Проверяем: таблицы миграций на месте и все доменные таблицы созданы. Затем печатаем строки.
verify() {
  local db="$1" missing
  local expected=(users audit_log warehouses cells goods barcodes batches stock
                  nomenclature_groups suppliers stock_entry_sessions stock_entry_lines
                  schema_migrations)

  local list; list="$(printf "'%s'," "${expected[@]}")"; list="${list%,}"
  missing="$(psql_db "$db" -tAc "
    SELECT string_agg(t, ', ')
    FROM unnest(ARRAY[$list]) AS t
    WHERE to_regclass('public.' || t) IS NULL")"
  [[ -z "$missing" ]] || die "в дампе нет таблиц: $missing — восстановление неполное."

  local version dirty
  version="$(psql_db "$db" -tAc 'SELECT version FROM schema_migrations LIMIT 1' | tr -d ' ')"
  dirty="$(psql_db "$db" -tAc 'SELECT dirty FROM schema_migrations LIMIT 1' | tr -d ' ')"
  [[ "$dirty" != "t" ]] || die "schema_migrations.dirty = true — дамп снят с БД в незавершённой миграции."
  log "Схема: версия миграций $version, dirty=false, все ${#expected[@]} таблиц на месте."

  log "Содержимое:"
  psql_db "$db" -c "
    SELECT 'users' AS \"таблица\", count(*) AS \"строк\" FROM users
    UNION ALL SELECT 'goods', count(*) FROM goods
    UNION ALL SELECT 'cells', count(*) FROM cells
    UNION ALL SELECT 'barcodes', count(*) FROM barcodes
    UNION ALL SELECT 'batches', count(*) FROM batches
    UNION ALL SELECT 'stock', count(*) FROM stock
    UNION ALL SELECT 'stock_entry_sessions', count(*) FROM stock_entry_sessions"

  # Пустая таблица users означала бы дамп без сида админа — войти в систему будет нельзя.
  local users
  users="$(psql_db "$db" -tAc 'SELECT count(*) FROM users' | tr -d ' ')"
  [[ "$users" -gt 0 ]] || die "в дампе нет ни одного пользователя — восстановление бессмысленно."
}

# --- Режим проверки: временная база, прод не трогаем ---
if [[ "$MODE" == check ]]; then
  # Присваивание CHECK_DB включает уборку временной базы в общем cleanup (trap выше):
  # иначе она осталась бы занимать место после падения.
  CHECK_DB="${PG_DB}_restore_check"
  log "Проверка дампа во временной базе $CHECK_DB (прод-база не затрагивается)."
  # На случай, если прошлый прогон упал и не убрал за собой.
  psql_admin -c "DROP DATABASE IF EXISTS \"$CHECK_DB\"" >/dev/null
  psql_admin -c "CREATE DATABASE \"$CHECK_DB\"" >/dev/null

  log "Разворачиваю дамп…"
  restore_into "$CHECK_DB"
  verify "$CHECK_DB"
  log "✅ Дамп восстанавливается корректно. Временная база удалена."
  exit 0
fi

# --- Боевое восстановление: замещаем прод-базу ---
warn "БОЕВОЕ ВОССТАНОВЛЕНИЕ: содержимое базы «$PG_DB» будет ЗАМЕЩЕНО дампом."
warn "Текущие данные будут потеряны безвозвратно. Дамп: $(basename "$DUMP")"
if [[ "$ASSUME_YES" != true ]]; then
  read -rp "Введите имя базы «$PG_DB» для подтверждения: " answer
  [[ "$answer" == "$PG_DB" ]] || die "не подтверждено — выхожу, ничего не изменено."
fi

# Страховка: снимаем дамп ТЕКУЩЕГО состояния перед тем, как его затереть.
mkdir -p "$BACKUP_DIR"
pre="$BACKUP_DIR/pre-restore-$(date +%Y%m%d-%H%M%S).sql.gz"
log "Страховочный дамп текущей базы → $(basename "$pre")"
docker exec "$cid" pg_dump -U "$PG_USER" -d "$PG_DB" | gzip -c > "$pre"
[[ -s "$pre" ]] || die "страховочный дамп пустой — прерываю, прод не тронут."

# Backend держит пул соединений: пока он жив, базу не дропнуть.
log "Останавливаю backend на время восстановления…"
compose stop backend >/dev/null
# Даже после остановки backend соединения могут отвисать — рвём принудительно.
psql_admin -c "
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = '$PG_DB' AND pid <> pg_backend_pid()" >/dev/null

log "Пересоздаю базу $PG_DB…"
psql_admin -c "DROP DATABASE IF EXISTS \"$PG_DB\"" >/dev/null
psql_admin -c "CREATE DATABASE \"$PG_DB\" OWNER \"$PG_USER\"" >/dev/null

log "Разворачиваю дамп…"
restore_into "$PG_DB"
verify "$PG_DB"

log "Поднимаю backend…"
compose start backend >/dev/null
log "✅ Восстановление завершено. Страховочный дамп прежнего состояния: $pre"
log "Проверьте: curl -fsS http://127.0.0.1:8080/ready (или https://<домен>/ready)."
