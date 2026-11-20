#!/usr/bin/env bash
# Craft WMS · настройка мониторинга «в одну команду» (ADHOC-43, ADHOC-73).
#
# Ошибки собирает общий Bugsink сервера - отдельный стек /opt/bugsink, один на все проекты
# (ADHOC-73; раньше Bugsink жил в профиле monitoring этого стека). Ставит и подключает его
# deploy/bugsink.sh - общий для проектов скрипт; здесь - только то, что касается Craft.
#
# Что делает, по шагам (повторный запуск безопасен - что уже настроено, то не ломается):
#   1) спрашивает адреса мониторов таймеров (Cronitor / Healthchecks.io), Enter - оставить;
#   2) deploy/bugsink.sh: находит Bugsink на сервере или ставит его в /opt/bugsink (тогда
#      спрашивает домен, почту и пароль администратора), заводит команду craft и проекты
#      craft-backend (сервер) и craft-app (ТСД и портал, события идут через бэкенд, ADHOC-47),
#      пишет их DSN в SENTRY_DSN и CLIENT_SENTRY_DSN;
#   3) SENTRY_HOST - хост Bugsink из DSN: в compose он указывает на сам сервер (host-gateway);
#   4) пересоздаёт backend с новым окружением;
#   5) проверка: проверочная ошибка из backend - скрипт ждёт, пока она появится в Bugsink.
#
# Письма об ошибках настраиваются в /opt/bugsink/.env (BUGSINK_EMAIL_*), затем
# `docker compose --env-file /opt/bugsink/.env -f /opt/bugsink/docker-compose.yml up -d`.
#
# Запуск:  sudo bash deploy/monitoring-setup.sh          - настройка (пункт 16 в craft.sh)
#          sudo bash deploy/monitoring-setup.sh --test   - только проверочная ошибка (пункт 17)
set -euo pipefail
SCRIPT_NAME=monitoring
# Путь к _lib.sh вычисляется в рантайме - статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env_file
command -v docker >/dev/null 2>&1 || die "docker не установлен."

# Команда Bugsink: проекты в ней - craft-backend и craft-app (ADHOC-72).
BUGSINK_TEAM="craft"
# Сообщение проверочной ошибки backend (handler.MonitoringTestMessage) - по нему её ищем.
TEST_MESSAGE="проверка мониторинга"

# ---------------------------------------------------------------------------------------
#  Помощники
# ---------------------------------------------------------------------------------------

# ask_env КЛЮЧ ВОПРОС - спросить значение, Enter - оставить текущее.
ask_env() {
  local key="$1" question="$2" cur val
  cur="$(get_env "$key")"
  read -rp "  $question [${cur:-пусто}]: " val
  [[ -n "$val" ]] || val="$cur"
  set_env "$key" "$val"
}

# bugsink_container - имя работающего контейнера Bugsink (образ bugsink/bugsink), пусто - нет.
# Ищем по образу, а не по compose: Bugsink - чужой для этого стека, его стек - /opt/bugsink.
bugsink_container() {
  docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /^bugsink\/bugsink(:|$)/ { print $1; exit }'
}

# bugsink_shell PYTHON - выполнить код в Django-оболочке контейнера Bugsink, вывести stdout.
bugsink_shell() {
  local c; c="$(bugsink_container)"
  [[ -n "$c" ]] || die "Bugsink на сервере не запущен - пункт 16 «Настроить мониторинг»."
  docker exec -i "$c" bugsink-manage shell -c "$1" 2>/dev/null
}

# send_test_error - проверочная ошибка из backend и ожидание её в Bugsink.
send_test_error() {
  local bind token resp since found
  bind="$(get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
  token="$(admin_token)" || true
  [[ -n "$token" ]] || die "вход админа в backend не удался - проверьте ADMIN_USERNAME/ADMIN_PASSWORD."
  since="$(date -u +%Y-%m-%dT%H:%M:%S)"
  resp="$(curl -fsS -m 10 -X POST -H "Authorization: Bearer $token" \
    "http://$bind/api/v1/admin/monitoring/test")" || die "backend не принял проверку мониторинга."
  [[ "$(jq -r '.reporting' <<<"$resp")" == "true" ]] \
    || die "backend отвечает, что отправка выключена - SENTRY_DSN не подхвачен (пересоздайте backend)."
  log "Проверочная ошибка отправлена (request_id $(jq -r '.request_id' <<<"$resp")). Жду её в Bugsink…"
  for _ in $(seq 1 20); do
    found="$(bugsink_shell "
from issues.models import Issue
from datetime import datetime, timezone
since = datetime.fromisoformat('$since').replace(tzinfo=timezone.utc)
print('FOUND' if Issue.objects.filter(project__team__name='$BUGSINK_TEAM', calculated_value__startswith='$TEST_MESSAGE', last_seen__gte=since).exists() else 'NO')
" | tail -1)"
    [[ "$found" == "FOUND" ]] && { log "✅ Ошибка дошла до Bugsink."; return 0; }
    sleep 3
  done
  die "ошибка не появилась в Bugsink за минуту - логи: docker logs $(bugsink_container); docker compose … logs backend"
}

# jq - разбор ответов backend; ставим сами, как install.sh ставит nginx и certbot.
if ! command -v jq >/dev/null 2>&1; then
  log "Ставлю jq…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null || die "не удалось поставить jq: sudo apt-get install -y jq"
fi

# ---------------------------------------------------------------------------------------
#  Только проверка
# ---------------------------------------------------------------------------------------
if [[ "${1:-}" == "--test" ]]; then
  send_test_error
  log "Письмо о новой ошибке приходит один раз на ошибку: повторная проверка письма не шлёт,"
  log "пока ошибку не отметят решённой (Resolve) в интерфейсе Bugsink."
  exit 0
fi

# --- 1. Мониторы таймеров ----------------------------------------------------------------
printf '\n%s\n' "Мониторинг Craft WMS. Enter - оставить значение в скобках."
printf '\n%s\n' "- Мониторинг таймеров (Cronitor / Healthchecks.io). Пусто - сигнал не отправляется -"
ask_env JOB_PING_UPDATE "Адрес монитора update"
ask_env JOB_PING_BACKUP "Адрес монитора backup"
ask_env JOB_PING_RESTORE_CHECK "Адрес монитора restore-check"

# --- 2. Общий Bugsink: команда, проекты, DSN ---------------------------------------------
printf '\n%s\n' "- Сбор ошибок: общий Bugsink сервера -"
bash "$DEPLOY_DIR/bugsink.sh" --env-file "$ENV_FILE" "$BUGSINK_TEAM" \
  || die "Bugsink не подключён - повтор: sudo bash $DEPLOY_DIR/bugsink.sh --env-file $ENV_FILE $BUGSINK_TEAM"
[[ -n "$(get_env SENTRY_ENVIRONMENT)" ]] || set_env SENTRY_ENVIRONMENT prod

# --- 3. Хост Bugsink - адрес самого сервера ----------------------------------------------
host="$(get_env SENTRY_DSN | sed -nE 's#^[a-z]+://[^@/]*@([^:/]+).*#\1#p')"
set_env SENTRY_HOST "${host:-sentry.invalid}"

# --- 4. Backend с новым окружением -------------------------------------------------------
log "Пересоздаю backend с SENTRY_DSN, CLIENT_SENTRY_DSN и SENTRY_HOST…"
compose up -d backend
health_check || die "backend не поднялся после пересоздания - смотрите: docker compose … logs backend"

# --- 5. Проверка -------------------------------------------------------------------------
send_test_error

printf '\n'
log "Готово."
if [[ -n "$(get_env JOB_PING_UPDATE)" ]]; then
  log "Сигналы таймеров включены - снимите мониторы с паузы, если ставили."
else
  warn "адреса мониторов таймеров не заданы - сигналы не отправляются."
fi
log "Проверить позже: sudo bash deploy/monitoring-setup.sh --test"
