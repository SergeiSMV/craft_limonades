#!/usr/bin/env bash
# Craft WMS · тестовый стенд на машине разработчика (ADHOC-27).
#
# Что: копия боевого контура — Postgres со снимком боевой базы, бэкенд ТЕКУЩЕЙ ветки, nginx
#   с порталом — в отдельном compose-проекте `craft-stand`, рядом с обычным dev-стеком.
# Зачем: новые миграции и код проверяются на настоящих данных до мержа, а не на проде.
# Как: снимок прода снимается по SSH (pg_dump внутри боевого контейнера, только чтение) и
#   хранится файлом в snapshots/; база стенда разворачивается из файла, поверх накатываются
#   миграции ветки — так же, как на проде при обновлении.
#
# Стенд в боевую базу не пишет никогда: к ней нет подключения, есть только файл снимка.
#
# Запуск:  bash deploy/test_stand/stand.sh <команда>   (список — `help`)
#
# Совместим с bash 3.2 (системный bash macOS): без mapfile, ассоциативных массивов и ${x,,}.
set -euo pipefail

STAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$STAND_DIR/../.." && pwd)"
COMPOSE_FILE="$STAND_DIR/docker-compose.stand.yml"
ENV_FILE="$STAND_DIR/stand.env"
SNAP_DIR="$STAND_DIR/snapshots"
APP_DIR="$REPO_ROOT/apps/craft_wms"
DB_VOLUME="craft-stand_db_data"
DB_USER="wms"
DB_NAME="craft_wms"

# --- Вывод ---
log()  { printf '\033[1;36m[stand]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[stand] ВНИМАНИЕ:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[stand] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

# load_env — читает stand.env; при первом запуске создаёт его из шаблона со своим JWT-секретом.
# Переменные экспортируются: compose берёт их из окружения, без --env-file.
load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$STAND_DIR/stand.env.example" "$ENV_FILE"
    log "Создан $ENV_FILE из шаблона."
  fi
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
  if [[ -z "${STAND_JWT_SECRET:-}" ]]; then
    STAND_JWT_SECRET="$(openssl rand -hex 32)"
    # Значение без спецсимволов (hex) — правка sed безопасна.
    sed -i.bak "s/^STAND_JWT_SECRET=.*/STAND_JWT_SECRET=$STAND_JWT_SECRET/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    export STAND_JWT_SECRET
    log "Сгенерирован JWT-секрет стенда."
  fi
  : "${STAND_HTTP_PORT:=8090}" "${STAND_DB_PORT:=5433}" "${STAND_KEEP_SNAPSHOTS:=5}"
  : "${STAND_PROD_PROJECT:=craft-wms}"
}

# compose ... — docker compose стенда.
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

# require_docker — Docker доступен; нет — поднять Colima сам. На этой машине Docker живёт в
# Colima, и её штатно гасят после работы (`colima stop`) — стенд не должен падать из-за этого.
require_docker() {
  docker info >/dev/null 2>&1 && return 0
  command -v colima >/dev/null 2>&1 || die "Docker недоступен, а colima не установлена."
  log "Docker недоступен — запускаю Colima…"
  colima start || die "Colima не запустилась (colima status)."
  docker info >/dev/null 2>&1 || die "Colima запущена, но Docker не отвечает."
}

# latest_snapshot — путь к самому свежему снимку или пусто. Имена несут время, сортировка
# по имени совпадает с хронологией.
latest_snapshot() {
  # shellcheck disable=SC2012
  ls -1 "$SNAP_DIR"/prod-*.dump 2>/dev/null | sort | tail -1
}

# Метка базы стенда: комментарий к базе с именем снимка. Ставится ПОСЛЕДНИМ шагом удачного
# восстановления, поэтому «том есть» ещё не значит «база есть»: прерванное восстановление
# оставляет том без метки, и следующий up разворачивает снимок заново, а не накатывает
# миграции на пустую базу.
STAND_MARK="stand-snapshot:"

# wait_db — дождаться базы, принимающей TCP-подключения. Healthcheck контейнера проверяет
# сокет, а при первом старте тома образ postgres поднимает временный сервер инициализации
# только на сокете и затем гасит его — подключение в это окно обрывается.
wait_db() {
  compose up -d --wait db
  local tries=0
  while (( tries < 30 )); do
    if compose exec -T db pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  die "база стенда не поднялась за 30 секунд (stand.sh logs db)."
}

# loaded_snapshot — имя снимка, из которого развёрнута база, или пусто (тома нет, метки нет).
loaded_snapshot() {
  docker volume inspect "$DB_VOLUME" >/dev/null 2>&1 || return 0
  wait_db
  local mark
  mark="$(compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -Atc \
    "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = current_database()")"
  [[ "$mark" == "$STAND_MARK"* ]] && printf '%s' "${mark#"$STAND_MARK"}"
  return 0
}

# lan_ip — адрес этой машины в локальной сети: его ТСД использует для связи со стендом.
lan_ip() {
  ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

# ───────────────────────── Команды ─────────────────────────

# pull — снять свежий снимок боевой базы в snapshots/. Стенд не трогает.
#
# pg_dump идёт внутри боевого контейнера БД: имя базы и пользователя берутся из его же
# окружения, поэтому .env.prod читать не нужно (он у root). Формат custom (-Fc): сжатый,
# восстанавливается pg_restore без владельцев и прав прода. Пишем во временный файл и
# переименовываем только после проверки — оборванный обмен не подменит последний снимок.
cmd_pull() {
  [[ -n "${STAND_PROD_SSH:-}" ]] || die "STAND_PROD_SSH не задан в $ENV_FILE."
  mkdir -p "$SNAP_DIR"
  # В снимке ФИО, логины и хеши паролей: файл доступен только владельцу.
  umask 077
  local out tmp
  out="$SNAP_DIR/prod-$(date +%Y%m%d-%H%M%S).dump"
  tmp="$out.part"
  log "Снимаю снимок с $STAND_PROD_SSH (проект $STAND_PROD_PROJECT)…"
  # Скрипт уходит на сервер через stdin, дамп возвращается через stdout.
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$STAND_PROD_SSH" bash -s -- "$STAND_PROD_PROJECT" > "$tmp" <<'REMOTE'
set -euo pipefail
cid="$(docker ps -q --filter "label=com.docker.compose.project=$1" --filter label=com.docker.compose.service=db)"
[ -n "$cid" ] || { echo "контейнер БД проекта $1 не найден" >&2; exit 1; }
docker exec "$cid" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc'
REMOTE
  then
    rm -f "$tmp"
    die "снимок не снят (сервер доступен только из LAN; SSH-ключ должен быть принят без пароля)."
  fi
  # Файл custom-формата начинается с сигнатуры PGDMP — иначе это не дамп, а сообщение об ошибке.
  if [[ "$(head -c 5 "$tmp")" != "PGDMP" ]]; then
    rm -f "$tmp"
    die "получен не дамп PostgreSQL."
  fi
  mv "$tmp" "$out"
  log "Снимок: $(basename "$out"), $(du -h "$out" | cut -f1)"

  # Ротация: держим последние STAND_KEEP_SNAPSHOTS.
  local n=0 f
  # shellcheck disable=SC2012
  for f in $(ls -1 "$SNAP_DIR"/prod-*.dump | sort -r); do
    n=$((n + 1))
    if (( n > STAND_KEEP_SNAPSHOTS )); then
      rm -f "$f"
      log "Удалён старый снимок $(basename "$f")"
    fi
  done
}

# restore_snapshot ФАЙЛ — пересоздать базу стенда из снимка. Прежняя база стенда удаляется.
restore_snapshot() {
  local snap="$1"
  [[ -f "$snap" ]] || die "нет снимка $snap"
  log "Пересоздаю базу стенда из $(basename "$snap")…"
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  wait_db
  # --no-owner/--no-privileges: владельцы и права прода стенду не нужны, база принадлежит wms.
  # --exit-on-error: недовосстановленная база хуже отсутствующей — тест на ней врёт.
  compose exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-privileges --exit-on-error < "$snap"
  compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -qc \
    "COMMENT ON DATABASE $DB_NAME IS '$STAND_MARK$(basename "$snap")'"
  log "Снимок развёрнут."
}

# migrate — собрать бэкенд ветки и накатить её миграции на базу стенда. Тот же бинарь
# migrate из образа, что на проде в update.sh.
cmd_migrate() {
  log "Собираю бэкенд текущей ветки ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD))…"
  compose build backend
  wait_db
  log "Накатываю миграции ветки…"
  compose run --rm --no-deps --entrypoint /usr/local/bin/migrate backend up
}

# start_services — поднять бэкенд и nginx и показать адреса.
start_services() {
  if [[ ! -f "$APP_DIR/build/web/index.html" ]]; then
    warn "бандл портала не собран — на корне будет 404. Собрать: stand.sh portal"
  fi
  compose up -d --wait backend nginx
  cmd_status
}

# up — поднять стенд. Нет базы — развернуть последний снимок; есть — работать с тем, что в ней.
cmd_up() {
  local loaded
  loaded="$(loaded_snapshot)"
  if [[ -z "$loaded" ]]; then
    if docker volume inspect "$DB_VOLUME" >/dev/null 2>&1; then
      warn "база стенда без метки снимка (прерванное восстановление?) — разворачиваю заново."
    fi
    local snap
    snap="$(latest_snapshot)"
    [[ -n "$snap" ]] || die "снимков нет. Сначала: stand.sh pull"
    restore_snapshot "$snap"
  else
    log "База стенда из снимка $loaded — работаю с ней (свежий снимок: stand.sh refresh)."
  fi
  cmd_migrate
  start_services
}

# reset [ФАЙЛ] — вернуть базу к снимку (по умолчанию последнему) без похода на сервер.
cmd_reset() {
  local snap="${1:-}"
  [[ -n "$snap" ]] || snap="$(latest_snapshot)"
  [[ -n "$snap" ]] || die "снимков нет. Сначала: stand.sh pull"
  # Имя без пути — ищем в snapshots/.
  [[ "$snap" == */* ]] || snap="$SNAP_DIR/$snap"
  restore_snapshot "$snap"
  cmd_migrate
  start_services
}

# refresh — свежий снимок с прода и стенд на нём.
cmd_refresh() {
  cmd_pull
  cmd_reset
}

# portal — собрать бандл портала против API стенда. Адрес относительный, как на проде:
# портал и API на одном origin, без CORS.
cmd_portal() {
  log "Собираю портал…"
  (cd "$APP_DIR" && flutter build web --release -t lib/main_portal.dart --dart-define=BASE_URL=/api/v1/)
  log "Портал собран: http://localhost:$STAND_HTTP_PORT (nginx отдаёт бандл без перезапуска)."
}

# apk — релизная сборка ТСД против стенда (адрес этой машины в LAN). Не ставит её на устройство:
# переключение терминала между продом и стендом — только с пустой очередью (см. инструкцию).
cmd_apk() {
  local ip
  ip="$(lan_ip)"
  [[ -n "$ip" ]] || die "не удалось определить адрес этой машины в LAN."
  log "Собираю APK против стенда: http://$ip:$STAND_HTTP_PORT/api/v1/"
  (cd "$APP_DIR" && flutter build apk --release -t lib/main.dart \
    --dart-define=BASE_URL="http://$ip:$STAND_HTTP_PORT/api/v1/")
  log "APK: $APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
  warn "перед установкой на ТСД очередь операций на нём должна быть пуста (экран «Несинхронизированное»)."
}

# down — остановить стенд, база сохраняется.
cmd_down() {
  compose down
  log "Стенд остановлен, база сохранена (stand.sh up — продолжить)."
}

# destroy [--keep-snapshots] [--yes] — удалить всё, что создал стенд: контейнеры, базу, образ
# бэкенда и снимки. В снимках боевые данные (ФИО, хеши паролей) — без нужды они не лежат;
# новый снимается за секунды. --keep-snapshots оставляет их, например чтобы воспроизвести
# падение миграции на тех же данных. Настройки stand.env остаются — в них нет данных прода.
cmd_destroy() {
  local keep=0 yes=0 arg
  for arg in "$@"; do
    case "$arg" in
      --keep-snapshots) keep=1 ;;
      --yes|-y)         yes=1 ;;
      *)                die "неизвестный ключ destroy: $arg" ;;
    esac
  done
  if (( ! yes )); then
    if (( keep )); then
      printf 'Удалить стенд, его базу и образ бэкенда (снимки останутся)? [y/N] '
    else
      printf 'Удалить стенд, его базу, образ бэкенда и ВСЕ снимки? [y/N] '
    fi
    local answer
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { log "Отменено."; return; }
  fi

  compose down -v --remove-orphans --rmi local
  log "Контейнеры, база и образ бэкенда стенда удалены."
  if (( keep )); then
    log "Снимки сохранены в $SNAP_DIR."
  else
    rm -f "$SNAP_DIR"/prod-*.dump "$SNAP_DIR"/prod-*.dump.part
    log "Снимки удалены."
  fi
}

cmd_status() {
  compose ps
  local ip
  ip="$(lan_ip)"
  printf '\n'
  log "Портал и API:  http://localhost:$STAND_HTTP_PORT   (API — /api/v1/)"
  if [[ -n "$ip" ]]; then
    log "Для ТСД:       http://$ip:$STAND_HTTP_PORT/api/v1/"
  fi
  log "База:          psql postgres://$DB_USER:stand@127.0.0.1:$STAND_DB_PORT/$DB_NAME"
  local loaded snap
  loaded="$(loaded_snapshot)"
  log "База стенда:   ${loaded:-не развёрнута}"
  snap="$(latest_snapshot)"
  if [[ -n "$snap" ]]; then
    log "Свежий снимок: $(basename "$snap")"
  else
    log "Свежий снимок: нет (stand.sh pull)"
  fi
}

cmd_snapshots() {
  # shellcheck disable=SC2012
  ls -lh "$SNAP_DIR"/prod-*.dump 2>/dev/null || log "снимков нет."
}

cmd_logs() { compose logs -f "$@"; }

cmd_psql() { compose exec db psql -U "$DB_USER" -d "$DB_NAME" "$@"; }

cmd_help() {
  cat <<'EOF'
Тестовый стенд Craft WMS — копия боевой базы + бэкенд и портал текущей ветки.

Запуск из корня проекта:  bash deploy/test_stand/stand.sh <команда>

  pull           снять свежий снимок боевой базы (только чтение, стенд не трогает)
  up             поднять стенд: нет базы — из последнего снимка; есть — с ней
  reset [файл]   вернуть базу к снимку (по умолчанию последнему) + миграции ветки
  refresh        pull + reset: свежий снимок и стенд на нём
  migrate        пересобрать бэкенд ветки и накатить её миграции
  portal         собрать портал (открывается на http://localhost:8090)
  apk            собрать APK для ТСД против стенда
  status         контейнеры, адреса, свежий снимок
  snapshots      список снимков
  logs [сервис]  логи (backend, db, nginx)
  psql           консоль базы стенда
  down           остановить, база сохраняется
  destroy [--keep-snapshots] [--yes]
                 удалить всё: стенд, базу, образ бэкенда и снимки (с подтверждением)

Порты — в deploy/test_stand/stand.env (по умолчанию портал 8090, база 5433).
EOF
}

main() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    help|-h|--help) cmd_help; return ;;
  esac
  load_env
  case "$cmd" in
    pull)      cmd_pull ;;
    up)        require_docker; cmd_up ;;
    reset)     require_docker; cmd_reset "$@" ;;
    refresh)   require_docker; cmd_refresh ;;
    migrate)   require_docker; cmd_migrate ;;
    portal)    cmd_portal ;;
    apk)       cmd_apk ;;
    status)    require_docker; cmd_status ;;
    snapshots) cmd_snapshots ;;
    logs)      require_docker; cmd_logs "$@" ;;
    psql)      require_docker; cmd_psql "$@" ;;
    down)      require_docker; cmd_down ;;
    destroy)   require_docker; cmd_destroy "$@" ;;
    *)         cmd_help; die "неизвестная команда: $cmd" ;;
  esac
}

main "$@"
