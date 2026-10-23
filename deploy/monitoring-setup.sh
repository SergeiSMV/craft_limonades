#!/usr/bin/env bash
# Craft WMS · настройка мониторинга «в одну команду» (ADHOC-43).
#
# Что делает, по шагам (повторный запуск безопасен — что уже настроено, то не ломается):
#   1) спрашивает то, что знаете только вы: почту админа, SMTP-ящик для алертов, адреса
#      мониторов таймеров (Cronitor / Healthchecks.io). Enter — оставить как есть;
#   2) сам генерирует секреты Bugsink: ключ приложения, пароль базы, пароль админа;
#   3) поддомен Bugsink: vhost хостового nginx + сертификат Let's Encrypt;
#   4) поднимает Bugsink и его базу, заводит команду и проект, включает письма о новых ошибках;
#   5) берёт DSN проекта, переводит на внутренний адрес сети compose и пишет в SENTRY_DSN;
#   6) пересоздаёт backend с новым окружением;
#   7) проверка: тестовое письмо (если задан SMTP) и проверочная ошибка из backend —
#      скрипт ждёт, пока она появится в Bugsink.
#
# Запуск:  sudo bash deploy/monitoring-setup.sh          — настройка (пункт 16 в craft.sh)
#          sudo bash deploy/monitoring-setup.sh --test   — только проверочная ошибка (пункт 17)
set -euo pipefail
SCRIPT_NAME=monitoring
# Путь к _lib.sh вычисляется в рантайме — статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env_file
command -v docker >/dev/null 2>&1 || die "docker не установлен."

# Проект и команда Bugsink, куда пишет backend.
BUGSINK_TEAM="craft"
BUGSINK_PROJECT="backend"
# Сообщение проверочной ошибки backend (handler.MonitoringTestMessage) — по нему её ищем.
TEST_MESSAGE="проверка мониторинга"

# ---------------------------------------------------------------------------------------
#  Помощники
# ---------------------------------------------------------------------------------------

# ask_env КЛЮЧ ВОПРОС [ПО_УМОЛЧАНИЮ] [secret] — спросить значение, Enter — оставить текущее
# (или значение по умолчанию, если текущего нет). secret — ввод не показывается на экране.
ask_env() {
  local key="$1" question="$2" def="${3:-}" secret="${4:-}" cur shown val
  cur="$(get_env "$key")"; [[ -n "$cur" ]] || cur="$def"
  if [[ -n "$secret" && -n "$cur" ]]; then shown="задан, Enter — оставить"; else shown="${cur:-пусто}"; fi
  if [[ -n "$secret" ]]; then
    read -rsp "  $question [$shown]: " val; printf '\n'
  else
    read -rp "  $question [$shown]: " val
  fi
  [[ -n "$val" ]] || val="$cur"
  set_env "$key" "$val"
}

# gen_secret КЛЮЧ ДЛИНА — сгенерировать секрет, если его ещё нет. Уже заданный не трогаем:
# пароль базы Bugsink записан в её том при первом запуске, новый с ним бы не совпал.
gen_secret() {
  local key="$1" len="$2"
  [[ -n "$(get_env "$key")" ]] && return 0
  set_env "$key" "$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$len")"
  log "Сгенерирован $key."
}

# bugsink_shell PYTHON — выполнить код в Django-оболочке контейнера Bugsink, вывести stdout.
bugsink_shell() { compose exec -T bugsink bugsink-manage shell -c "$1" 2>/dev/null; }

# wait_bugsink — дождаться готовности Bugsink (первый запуск применяет миграции его базы).
wait_bugsink() {
  local bind attempts=60
  bind="$(get_env BUGSINK_BIND)"; bind="${bind:-127.0.0.1:8001}"
  while (( attempts-- > 0 )); do
    curl -fsS -m 5 -o /dev/null "http://$bind/health/ready" 2>/dev/null && return 0
    sleep 3
  done
  die "Bugsink не поднялся за 3 минуты — логи: docker compose … logs bugsink"
}

# admin_token — access-токен админа портала (ADMIN_USERNAME/ADMIN_PASSWORD) для вызова
# проверочной ошибки. Пароль идёт в теле запроса через stdin — в списке процессов его нет.
admin_token() {
  local bind user pass body
  bind="$(get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
  user="$(get_env ADMIN_USERNAME)"; pass="$(get_env ADMIN_PASSWORD)"
  [[ -n "$user" && -n "$pass" ]] || die "ADMIN_USERNAME/ADMIN_PASSWORD не заданы — проверочную ошибку не вызвать."
  body="$(jq -n --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')"
  printf '%s' "$body" | curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @- \
    "http://$bind/api/v1/auth/login/password" | jq -r '.access // empty'
}

# send_test_error — проверочная ошибка из backend и ожидание её в Bugsink.
send_test_error() {
  local bind token resp since found
  bind="$(get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
  token="$(admin_token)" || true
  [[ -n "$token" ]] || die "вход админа в backend не удался — проверьте ADMIN_USERNAME/ADMIN_PASSWORD."
  since="$(date -u +%Y-%m-%dT%H:%M:%S)"
  resp="$(curl -fsS -m 10 -X POST -H "Authorization: Bearer $token" \
    "http://$bind/api/v1/admin/monitoring/test")" || die "backend не принял проверку мониторинга."
  [[ "$(jq -r '.reporting' <<<"$resp")" == "true" ]] \
    || die "backend отвечает, что отправка выключена — SENTRY_DSN не подхвачен (пересоздайте backend)."
  log "Проверочная ошибка отправлена (request_id $(jq -r '.request_id' <<<"$resp")). Жду её в Bugsink…"
  for _ in $(seq 1 20); do
    found="$(bugsink_shell "
from issues.models import Issue
from datetime import datetime, timezone
since = datetime.fromisoformat('$since').replace(tzinfo=timezone.utc)
print('FOUND' if Issue.objects.filter(calculated_value__startswith='$TEST_MESSAGE', last_seen__gte=since).exists() else 'NO')
" | tail -1)"
    [[ "$found" == "FOUND" ]] && { log "✅ Ошибка дошла до Bugsink."; return 0; }
    sleep 3
  done
  die "ошибка не появилась в Bugsink за минуту — логи: docker compose … logs bugsink backend"
}

# ---------------------------------------------------------------------------------------
#  Только проверка
# ---------------------------------------------------------------------------------------
if [[ "${1:-}" == "--test" ]]; then
  command -v jq >/dev/null 2>&1 || die "нет jq: sudo apt-get install -y jq"
  send_test_error
  log "Письмо о новой ошибке приходит один раз на ошибку: повторная проверка письма не шлёт,"
  log "пока ошибку не отметят решённой (Resolve) в интерфейсе Bugsink."
  exit 0
fi

# jq — разбор ответов backend; ставим сами, как install.sh ставит nginx и certbot.
if ! command -v jq >/dev/null 2>&1; then
  log "Ставлю jq…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null || die "не удалось поставить jq: sudo apt-get install -y jq"
fi
command -v openssl >/dev/null 2>&1 || die "нет openssl."
START_ADMIN_SET="$(get_env BUGSINK_ADMIN)"

# --- 1. Вопросы -------------------------------------------------------------------------
printf '\n%s\n' "Мониторинг Craft WMS. Enter — оставить значение в скобках."
printf '\n%s\n' "— Bugsink (сбор ошибок) —"
domain_def="errors.$(get_env DEPLOY_DOMAIN)"
ask_env BUGSINK_DOMAIN "Поддомен интерфейса Bugsink" "$domain_def"
admin_email_def="${START_ADMIN_SET%%:*}"; [[ -n "$admin_email_def" ]] || admin_email_def="$(get_env CERTBOT_EMAIL)"
read -rp "  Почта админа Bugsink (вход и алерты) [${admin_email_def:-пусто}]: " admin_email
admin_email="${admin_email:-$admin_email_def}"
[[ "$admin_email" == *@* ]] || die "нужна почта админа Bugsink."

printf '\n%s\n' "— Почта для алертов (SMTP). Пусто — Bugsink без писем, ошибки только в интерфейсе —"
ask_env BUGSINK_EMAIL_HOST "SMTP-сервер (например smtp.yandex.ru)"
if [[ -n "$(get_env BUGSINK_EMAIL_HOST)" ]]; then
  ask_env BUGSINK_EMAIL_PORT "Порт (465 — SSL, 587 — STARTTLS)" "465"
  ask_env BUGSINK_EMAIL_USER "Логин ящика (обычно полный адрес)"
  ask_env BUGSINK_EMAIL_PASSWORD "Пароль приложения ящика" "" secret
  ask_env BUGSINK_EMAIL_FROM "Адрес отправителя" "$(get_env BUGSINK_EMAIL_USER)"
  # Шифрование — по порту: 465 — сразу SSL, остальное — STARTTLS. Оба сразу Django не примет.
  if [[ "$(get_env BUGSINK_EMAIL_PORT)" == "465" ]]; then
    set_env BUGSINK_EMAIL_USE_SSL True; set_env BUGSINK_EMAIL_USE_TLS False
  else
    set_env BUGSINK_EMAIL_USE_SSL False; set_env BUGSINK_EMAIL_USE_TLS True
  fi
fi

printf '\n%s\n' "— Мониторинг таймеров (Cronitor / Healthchecks.io). Пусто — сигнал не отправляется —"
ask_env JOB_PING_UPDATE "Адрес монитора update"
ask_env JOB_PING_BACKUP "Адрес монитора backup"
ask_env JOB_PING_RESTORE_CHECK "Адрес монитора restore-check"

# --- 2. Секреты -------------------------------------------------------------------------
gen_secret BUGSINK_SECRET_KEY 60
gen_secret BUGSINK_DB_PASSWORD 32
ADMIN_PASS_NEW=""
if [[ -z "$START_ADMIN_SET" ]]; then
  ADMIN_PASS_NEW="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)"
  set_env BUGSINK_ADMIN "$admin_email:$ADMIN_PASS_NEW"
fi
[[ -n "$(get_env BUGSINK_IMAGE)" ]] || set_env BUGSINK_IMAGE "bugsink/bugsink:2"
[[ -n "$(get_env BUGSINK_BIND)" ]] || set_env BUGSINK_BIND "127.0.0.1:8001"

# --- 3. Поддомен ------------------------------------------------------------------------
if command -v nginx >/dev/null 2>&1; then
  setup_bugsink_vhost
else
  warn "хостового nginx нет — поддомен не настраиваю (интерфейс — только на $(get_env BUGSINK_BIND))."
fi

# --- 4. Bugsink: контейнеры, команда, проект --------------------------------------------
log "Поднимаю Bugsink (первый раз — скачивание образа и миграции его базы)…"
compose up -d bugsink-db bugsink
wait_bugsink

log "Команда «$BUGSINK_TEAM», проект «$BUGSINK_PROJECT», письма о новых ошибках…"
dsn="$(bugsink_shell "
from django.contrib.auth import get_user_model
from teams.models import Team, TeamMembership
from projects.models import Project, ProjectMembership
User = get_user_model()
u = User.objects.filter(is_superuser=True).order_by('id').first()
t, _ = Team.objects.get_or_create(name='$BUGSINK_TEAM')
TeamMembership.objects.update_or_create(team=t, user=u, defaults=dict(role=1, accepted=True, send_email_alerts=True))
p = Project.objects.filter(team=t, name='$BUGSINK_PROJECT').first() or Project.objects.create(team=t, name='$BUGSINK_PROJECT')
p.alert_on_new_issue = True; p.alert_on_regression = True; p.alert_on_unmute = True; p.save()
ProjectMembership.objects.update_or_create(project=p, user=u, defaults=dict(role=1, accepted=True, send_email_alerts=True))
print('DSN=' + p.dsn)
" | sed -n 's/^DSN=//p' | tail -1)"
[[ "$dsn" =~ ^https?://([0-9a-f]+)@[^/]+/([0-9]+)$ ]] || die "не удалось получить DSN проекта Bugsink (получено: «$dsn»)."
# Внутренний адрес сети compose: события от backend наружу не выходят и не зависят от nginx.
set_env SENTRY_DSN "http://${BASH_REMATCH[1]}@bugsink:8000/${BASH_REMATCH[2]}"
[[ -n "$(get_env SENTRY_ENVIRONMENT)" ]] || set_env SENTRY_ENVIRONMENT prod
log "SENTRY_DSN записан (внутренний адрес bugsink:8000)."

# --- 5. Backend с новым окружением -----------------------------------------------------
log "Пересоздаю backend с SENTRY_DSN…"
compose up -d backend
health_check || die "backend не поднялся после пересоздания — смотрите: docker compose … logs backend"

# --- 6. Проверка ----------------------------------------------------------------------
if [[ -n "$(get_env BUGSINK_EMAIL_HOST)" ]]; then
  log "Тестовое письмо на $admin_email…"
  if compose exec -T bugsink bugsink-manage sendtestemail "$admin_email" >/dev/null 2>&1; then
    log "Письмо отправлено — проверьте ящик (и «Спам»)."
  else
    warn "тестовое письмо не ушло — проверьте SMTP: сервер, порт, логин и пароль приложения."
  fi
fi
send_test_error

# --- Итог -------------------------------------------------------------------------------
printf '\n'
log "Готово."
log "Интерфейс ошибок: https://$(get_env BUGSINK_DOMAIN)  ·  вход: $admin_email"
if [[ -n "$ADMIN_PASS_NEW" ]]; then
  printf '\n  Пароль админа Bugsink (показывается один раз, лежит и в .env.prod как BUGSINK_ADMIN):\n'
  printf '    %s\n\n' "$ADMIN_PASS_NEW"
  printf '  Сохраните его в менеджер паролей.\n'
fi
[[ -n "$(get_env JOB_PING_UPDATE)" ]] \
  && log "Сигналы таймеров включены — снимите мониторы с паузы, если ставили." \
  || warn "адреса мониторов таймеров не заданы — сигналы не отправляются."
log "Проверить позже: sudo bash deploy/monitoring-setup.sh --test"
