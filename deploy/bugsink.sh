#!/usr/bin/env bash
# Общий Bugsink на сервере - подключение проекта одной командой. Файл одинаковый во всех
# проектах, которые шлют ошибки в общий Bugsink; правится в одном и копируется в остальные.
#
# Запуск на сервере:  sudo bash deploy/bugsink.sh [--env-file ФАЙЛ] <команда> [проект ...]
#   <команда>  - команда Bugsink, обычно имя проекта: compass (буквы, цифры, «-»);
#   [проект]   - проекты команды, по умолчанию backend и app. В Bugsink они называются
#                «<команда>-<проект>»: в общем списке их видно сразу;
#   --env-file - записать DSN в env-файл бэкенда: SENTRY_DSN - проект backend,
#                CLIENT_SENTRY_DSN - проект app (права и владелец файла сохраняются).
#
# Что делает (повторный запуск безопасен - что есть, то не задваивается и не ломается):
#   1) ищет Bugsink на сервере: свой стек в $BUGSINK_DIR или любой работающий контейнер
#      образа bugsink/bugsink (например, внутри стека другого проекта);
#   2) нет ни того, ни другого - ставит заново отдельным стеком в $BUGSINK_DIR (Bugsink и его
#      Postgres), спрашивает домен, почту и пароль администратора (Enter - сгенерировать);
#      vhost хостового nginx и сертификат Let's Encrypt - если на сервере есть nginx и certbot;
#   3) заводит команду и её проекты (проекты со старыми именами без префикса переименовывает -
#      DSN у них не меняется), включает письма о новых ошибках администратору;
#   4) проверяет пароль администратора из установки: подходит - напоминает его; не подходит
#      (меняли в интерфейсе) - в терминале предлагает задать новый (действующий из Bugsink не
#      достать - там только хеш);
#   5) печатает DSN проектов, адрес, логин и пароль входа; с --env-file - пишет DSN в env-файл.
#
# Переменные (необязательные): BUGSINK_DIR (/opt/bugsink), BUGSINK_DOMAIN, BUGSINK_ADMIN_EMAIL,
# BUGSINK_ADMIN_PASSWORD,
# BUGSINK_BIND (127.0.0.1:8001), BUGSINK_IMAGE (bugsink/bugsink:2), CERTBOT_EMAIL.
set -euo pipefail

BUGSINK_DIR="${BUGSINK_DIR:-/opt/bugsink}"
ENV_FILE="$BUGSINK_DIR/.env"
COMPOSE_FILE="$BUGSINK_DIR/docker-compose.yml"
DEFAULT_DOMAIN="errors.skogi.ru"

log() { printf '[bugsink] %s\n' "$*"; }
warn() { printf '[bugsink] внимание: %s\n' "$*" >&2; }
die() { printf '[bugsink] ошибка: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '4,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0
OUT_ENV=""
if [[ "${1:-}" == "--env-file" ]]; then
  OUT_ENV="${2:-}"; shift 2 || usage 1
  [[ -f "$OUT_ENV" ]] || die "нет env-файла: $OUT_ENV"
fi
TEAM="${1:-}"; [[ -n "$TEAM" ]] || usage 1
shift
[[ "$TEAM" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "имя команды - строчные латинские буквы, цифры и «-»: $TEAM"
PROJECTS=("$@"); [[ ${#PROJECTS[@]} -gt 0 ]] || PROJECTS=(backend app)
for p in "${PROJECTS[@]}"; do
  [[ "$p" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "имя проекта - строчные латинские буквы, цифры и «-»: $p"
done

command -v docker >/dev/null 2>&1 || die "docker не установлен."
docker info >/dev/null 2>&1 || die "нет доступа к docker (запустите через sudo)."

# --- Помощники ---------------------------------------------------------------------------

# env_get КЛЮЧ - значение из $ENV_FILE (без одинарных кавычек вокруг).
env_get() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1 | sed "s/^'\(.*\)'$/\1/"; }

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

# container_env КОНТЕЙНЕР ПЕРЕМЕННАЯ - значение переменной окружения контейнера.
container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n "s/^$2=//p" | head -1
}

# find_container - имя работающего контейнера Bugsink (образ bugsink/bugsink), пусто - нет.
find_container() {
  docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /^bugsink\/bugsink(:|$)/ { print $1; exit }'
}

# wait_ready КОНТЕЙНЕР - ждать, пока Bugsink ответит на /health/ready (до 3 минут).
wait_ready() {
  local _
  for _ in $(seq 60); do
    docker exec "$1" python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/ready', timeout=5)" \
      >/dev/null 2>&1 && return 0
    sleep 3
  done
  die "Bugsink не ответил за 3 минуты - логи: docker logs $1"
}

# ask_password ВОПРОС - пароль из терминала дважды, без эха; Enter - пустая строка. В .env он
# лежит в одинарных кавычках, в учётке Bugsink - после «почта:»: без пробелов, «'» и «:».
ask_password() {
  local p1 p2
  read -rsp "  $1: " p1 </dev/tty; printf '\n' >&2
  [[ -n "$p1" ]] || return 0
  [[ ${#p1} -ge 12 ]] || die "пароль короче 12 символов."
  [[ "$p1" != *[[:space:]\':]* ]] || die "в пароле не должно быть пробелов, «'» и «:»."
  read -rsp "  Повторите пароль: " p2 </dev/tty; printf '\n' >&2
  [[ "$p1" == "$p2" ]] || die "пароли не совпали."
  printf '%s' "$p1"
}

# gen_password - случайный пароль из букв и цифр.
gen_password() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; }

# admin_shell КОНТЕЙНЕР КОД - выполнить Python в Bugsink (Django) с переменными login и password
# (ADMIN_LOGIN, ADMIN_PASSWORD). Они идут в base64 через stdin, а не аргументами команды:
# аргументы видны в списке процессов.
admin_shell() {
  local l p
  l="$(printf '%s' "${ADMIN_LOGIN:-}" | base64 | tr -d '\n')"
  p="$(printf '%s' "${ADMIN_PASSWORD:-}" | base64 | tr -d '\n')"
  printf '%s\n' \
    "import base64" \
    "from django.contrib.auth import authenticate, get_user_model" \
    "login = base64.b64decode('$l').decode()" \
    "password = base64.b64decode('$p').decode()" \
    "$2" | docker exec -i "$1" bugsink-manage shell 2>/dev/null
}

# ask ВОПРОС ПО_УМОЛЧАНИЮ - ответ из терминала, Enter - значение по умолчанию.
ask() {
  local val
  read -rp "  $1 [$2]: " val
  printf '%s' "${val:-$2}"
}

# --- 1. Поиск -----------------------------------------------------------------------------
container=""
if [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]]; then
  log "Свой стек Bugsink: $BUGSINK_DIR - запускаю, если остановлен."
  compose up -d >/dev/null
  container="$(compose ps -q bugsink | xargs -r docker inspect -f '{{.Name}}' | sed 's#^/##')"
  [[ -n "$container" ]] || die "контейнер bugsink в $BUGSINK_DIR не поднялся: docker compose -f $COMPOSE_FILE logs bugsink"
else
  container="$(find_container)"
  [[ -n "$container" ]] && log "Найден работающий Bugsink: контейнер $container - подключаюсь к нему."
fi

# --- 2. Установка заново ------------------------------------------------------------------
if [[ -z "$container" ]]; then
  [[ $EUID -eq 0 || "$BUGSINK_DIR" != /opt/* ]] || die "установка в $BUGSINK_DIR - через sudo."
  command -v openssl >/dev/null 2>&1 || die "нет openssl."
  log "Bugsink на сервере нет - ставлю отдельным стеком в $BUGSINK_DIR."
  domain="${BUGSINK_DOMAIN:-$(ask "Домен интерфейса (DNS-запись A на этот сервер)" "$DEFAULT_DOMAIN")}"
  email="${BUGSINK_ADMIN_EMAIL:-$(ask "Почта администратора (логин и письма об ошибках)" "")}"
  [[ "$email" == *@* ]] || die "нужна почта администратора."
  password="${BUGSINK_ADMIN_PASSWORD:-}"
  if [[ -z "$password" && -t 0 ]]; then
    password="$(ask_password "Пароль администратора (от 12 символов; Enter - сгенерировать)")"
  fi
  [[ -n "$password" ]] || password="$(gen_password)"
  bind="${BUGSINK_BIND:-127.0.0.1:8001}"
  if [[ "$domain" == localhost ]]; then base_url="http://localhost:${bind##*:}"; else base_url="https://$domain"; fi

  mkdir -p "$BUGSINK_DIR"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Общий Bugsink - секреты (создано deploy/bugsink.sh). Файл только для root.
BUGSINK_IMAGE=${BUGSINK_IMAGE:-bugsink/bugsink:2}
BUGSINK_BIND=$bind
BUGSINK_DOMAIN=$domain
BUGSINK_BASE_URL=$base_url
BUGSINK_SECRET_KEY=$(openssl rand -hex 32)
BUGSINK_DB_PASSWORD=$(openssl rand -hex 24)
# Вход в интерфейс «почта:пароль». Учётка создаётся один раз, при пустой базе.
BUGSINK_ADMIN='$email:$password'
BUGSINK_SITE_TITLE=Ошибки
# Письма об ошибках - SMTP-ящик (пусто - без писем). После правки: docker compose up -d.
# Порт 587 - STARTTLS (USE_TLS=True), порт 465 - SSL (USE_SSL=True, USE_TLS=False).
BUGSINK_EMAIL_HOST=
BUGSINK_EMAIL_PORT=587
BUGSINK_EMAIL_USER=
BUGSINK_EMAIL_PASSWORD=
BUGSINK_EMAIL_USE_TLS=True
BUGSINK_EMAIL_USE_SSL=False
BUGSINK_EMAIL_FROM=
EOF
  umask 022
  cat > "$COMPOSE_FILE" <<'EOF'
# Общий Bugsink (создано deploy/bugsink.sh). Секреты - в .env рядом.
name: bugsink
services:
  bugsink-db:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: bugsink
      POSTGRES_PASSWORD: ${BUGSINK_DB_PASSWORD}
      POSTGRES_DB: bugsink
    volumes:
      - db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bugsink -d bugsink"]
      interval: 5s
      timeout: 3s
      retries: 20
    mem_limit: 256m

  bugsink:
    image: ${BUGSINK_IMAGE}
    restart: unless-stopped
    environment:
      SECRET_KEY: ${BUGSINK_SECRET_KEY}
      CREATE_SUPERUSER: ${BUGSINK_ADMIN}
      DATABASE_URL: postgresql://bugsink:${BUGSINK_DB_PASSWORD}@bugsink-db:5432/bugsink
      BASE_URL: ${BUGSINK_BASE_URL}
      ALLOWED_HOSTS: ${BUGSINK_DOMAIN},localhost,127.0.0.1,bugsink
      BEHIND_HTTPS_PROXY: "True"
      USE_X_FORWARDED_HOST: "True"
      SITE_TITLE: ${BUGSINK_SITE_TITLE}
      USER_REGISTRATION: CB_ADMINS
      EMAIL_HOST: ${BUGSINK_EMAIL_HOST}
      EMAIL_PORT: ${BUGSINK_EMAIL_PORT}
      EMAIL_HOST_USER: ${BUGSINK_EMAIL_USER}
      EMAIL_HOST_PASSWORD: ${BUGSINK_EMAIL_PASSWORD}
      EMAIL_USE_TLS: ${BUGSINK_EMAIL_USE_TLS}
      EMAIL_USE_SSL: ${BUGSINK_EMAIL_USE_SSL:-False}
      DEFAULT_FROM_EMAIL: ${BUGSINK_EMAIL_FROM}
    depends_on:
      bugsink-db:
        condition: service_healthy
    ports:
      # Только loopback: снаружи интерфейс и приём событий открывает хостовый nginx с TLS.
      - "${BUGSINK_BIND}:8000"
    mem_limit: 512m

volumes:
  db_data:
EOF
  log "Поднимаю Bugsink (первый раз - скачивание образа и миграции базы)…"
  compose up -d
  container="$(compose ps -q bugsink | xargs docker inspect -f '{{.Name}}' | sed 's#^/##')"

  # vhost и сертификат: только для настоящего домена и при наличии nginx и certbot.
  if [[ "$domain" != localhost ]]; then
    if command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1; then
      vhost="/etc/nginx/sites-available/$domain"
      [[ -f "$vhost" ]] && cp -a "$vhost" "$vhost.bak-$(date +%Y%m%d-%H%M%S)"
      cat > "$vhost" <<EOF
# Общий Bugsink (создано deploy/bugsink.sh). TLS добавляет certbot --nginx.
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    client_max_body_size 20m;
    location / {
        proxy_pass http://$bind;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$host;
    }
}
EOF
      ln -sfn "$vhost" "/etc/nginx/sites-enabled/$domain"
      nginx -t && systemctl reload nginx
      certbot --nginx -d "$domain" --non-interactive --agree-tos -m "${CERTBOT_EMAIL:-$email}" \
        --redirect --keep-until-expiring
    else
      warn "нет nginx или certbot - интерфейс доступен только на $bind; vhost и сертификат - вручную."
    fi
  fi
fi

wait_ready "$container"

# --- 3. Команда и проекты -----------------------------------------------------------------
log "Команда «$TEAM», проекты: ${PROJECTS[*]/#/$TEAM-}"
dsns="$(docker exec -i -e TEAM="$TEAM" -e PROJECTS="${PROJECTS[*]}" "$container" \
  bugsink-manage shell 2>/dev/null <<'EOF'
import os
from django.contrib.auth import get_user_model
from teams.models import Team, TeamMembership
from projects.models import Project, ProjectMembership
team = os.environ['TEAM']
u = get_user_model().objects.filter(is_superuser=True).order_by('id').first()
t, _ = Team.objects.get_or_create(name=team)
if u:
    TeamMembership.objects.update_or_create(team=t, user=u, defaults=dict(role=1, accepted=True, send_email_alerts=True))
for short in os.environ['PROJECTS'].split():
    name = team + '-' + short
    p = Project.objects.filter(team=t, name=name).first()
    if p is None:
        p = Project.objects.filter(team=t, name=short).first()
        if p is not None:
            p.name = name
    p = p or Project(team=t, name=name)
    p.alert_on_new_issue = True; p.alert_on_regression = True; p.alert_on_unmute = True
    p.save()
    if u:
        ProjectMembership.objects.update_or_create(project=p, user=u, defaults=dict(role=1, accepted=True, send_email_alerts=True))
    print('DSN ' + name + ' ' + p.dsn)
EOF
)" || die "не удалось завести команду и проекты - логи: docker logs $container"
dsns="$(printf '%s\n' "$dsns" | sed -n 's/^DSN //p')"
[[ -n "$dsns" ]] || die "Bugsink не вернул DSN проектов - логи: docker logs $container"

# --- 4. Вход администратора --------------------------------------------------------------
# Действующий пароль из Bugsink не достать - там только хеш. Есть пароль первой установки
# (окружение контейнера, у своего стека - .env): проверяем, подходит ли он. Не подходит (меняли
# в интерфейсе) или неизвестен - в терминале предлагаем задать новый.
base_url="$(container_env "$container" BASE_URL)"
admin="$(container_env "$container" CREATE_SUPERUSER)"
own_stack=0; [[ -f "$ENV_FILE" ]] && own_stack=1
if [[ $own_stack -eq 1 && -n "$(env_get BUGSINK_ADMIN)" ]]; then admin="$(env_get BUGSINK_ADMIN)"; fi
ADMIN_LOGIN="${admin%%:*}"; ADMIN_PASSWORD="${admin#*:}"
[[ "$admin" == *:* ]] || ADMIN_PASSWORD=""
if [[ -z "$ADMIN_LOGIN" ]]; then
  ADMIN_LOGIN="$(admin_shell "$container" "u = get_user_model().objects.filter(is_superuser=True).order_by('id').first()
print('LOGIN ' + (u.get_username() if u else ''))" | sed -n 's/^LOGIN //p')"
fi
[[ -n "$ADMIN_LOGIN" ]] || die "в Bugsink нет администратора: docker exec -it $container bugsink-manage createsuperuser"

valid=0
if [[ -n "$ADMIN_PASSWORD" ]] && admin_shell "$container" \
  "print('AUTH ' + ('ok' if authenticate(username=login, password=password) else 'bad'))" | grep -q '^AUTH ok'; then
  valid=1
fi

if [[ $valid -eq 0 ]]; then
  warn "пароль администратора $ADMIN_LOGIN из установки не подходит (меняли в интерфейсе) или неизвестен."
  new=""
  if [[ -t 0 ]]; then new="$(ask_password "Новый пароль администратора (Enter - не менять)")"; fi
  if [[ -n "$new" ]]; then
    ADMIN_PASSWORD="$new"
    admin_shell "$container" "u = get_user_model().objects.get(username=login)
u.set_password(password); u.save(); print('SET ok')" | grep -q '^SET ok' \
      || die "не удалось сменить пароль - логи: docker logs $container"
    valid=1
    if [[ $own_stack -eq 1 ]]; then
      tmp="$(mktemp)"
      awk -v v="BUGSINK_ADMIN='$ADMIN_LOGIN:$new'" 'index($0, "BUGSINK_ADMIN=") == 1 { print v; next } { print }' \
        "$ENV_FILE" > "$tmp"
      cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
      log "Новый пароль записан в $ENV_FILE."
    else
      warn "Bugsink в чужом стеке: сохраните новый пароль в менеджер паролей (там записан прежний)."
    fi
  fi
fi

# --- 5. DSN в env-файл бэкенда (--env-file) -----------------------------------------------
# Перезапись через `cat >`, а не подменой файла: env-файл с секретами обычно root 600, и
# владелец с правами должны сохраниться. Значение не изменилось - файл не трогается.
set_out_env() {
  local key="$1" val="$2" tmp line found=0
  grep -qxF "$key=$val" "$OUT_ENV" && return 0
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then printf '%s=%s\n' "$key" "$val" >> "$tmp"; found=1
    else printf '%s\n' "$line" >> "$tmp"; fi
  done < "$OUT_ENV"
  [[ $found -eq 1 ]] || printf '%s=%s\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$OUT_ENV"; rm -f "$tmp"
}
if [[ -n "$OUT_ENV" ]]; then
  backend_dsn="$(printf '%s\n' "$dsns" | awk -v n="$TEAM-backend" '$1 == n { print $2 }')"
  app_dsn="$(printf '%s\n' "$dsns" | awk -v n="$TEAM-app" '$1 == n { print $2 }')"
  [[ -n "$backend_dsn" ]] && set_out_env SENTRY_DSN "$backend_dsn"
  [[ -n "$app_dsn" ]] && set_out_env CLIENT_SENTRY_DSN "$app_dsn"
  log "DSN записаны в $OUT_ENV (SENTRY_DSN${backend_dsn:+ ок}, CLIENT_SENTRY_DSN${app_dsn:+ ок})."
fi

# --- 6. Итог ------------------------------------------------------------------------------
printf '\n'
log "Готово. DSN проектов (в env бэкенда проекта: SENTRY_DSN - backend, CLIENT_SENTRY_DSN - app):"
printf '%s\n' "$dsns" | awk '{ printf "    %-24s %s\n", $1, $2 }'
printf '\n'
log "Интерфейс: ${base_url:-?}"
log "Логин:     $ADMIN_LOGIN"
if [[ $valid -eq 1 ]]; then
  log "Пароль:    $ADMIN_PASSWORD"
else
  log "Пароль:    неизвестен. Задать новый - запустить скрипт снова в терминале."
fi
