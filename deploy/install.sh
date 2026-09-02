#!/usr/bin/env bash
# Craft WMS · установка «в одну команду». Разворачивает прод с нуля по /opt/craft-wms/.env.prod:
#   1) проверяет/ставит ПО (docker, nginx, certbot, ufw, gettext);
#   2) настраивает хостовый nginx под ваш домен + выпускает TLS (Let's Encrypt);
#   3) поднимает стек из GHCR, накатывает миграции, заводит админа;
#   4) ставит systemd-таймеры: авто-обновление (AUTO_UPDATE=true), бэкап БД и проверку
#      восстановимости (AUTO_BACKUP≠false).
# Идемпотентно: повторный запуск не ломает — доводит до нужного состояния.
#
# Запуск (на сервере):  sudo bash app/deploy/install.sh
set -euo pipefail
SCRIPT_NAME=install
# Путь к _lib.sh вычисляется в рантайме — статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[[ $EUID -eq 0 ]] || die "запускать через sudo."
command -v apt-get >/dev/null 2>&1 || die "ожидается Debian/Ubuntu (apt)."
require_env_file

# --- Читаем и валидируем ключевые параметры ---
DOMAIN="$(get_env DEPLOY_DOMAIN)"; EMAIL="$(get_env CERTBOT_EMAIL)"; BIND="$(get_env BACKEND_BIND)"
for pair in "DEPLOY_DOMAIN=$DOMAIN" "CERTBOT_EMAIL=$EMAIL" "BACKEND_BIND=$BIND"; do
  val="${pair#*=}"
  [[ -n "$val" ]]                 || die "${pair%%=*} не задан в $ENV_FILE."
  [[ "$val" != *CHANGE_ME* && "$val" != *example* ]] || die "${pair%%=*} содержит шаблонное значение — впишите своё в $ENV_FILE."
done
log "Домен: $DOMAIN · backend: $BIND · env: $ENV_FILE"

preflight_net

# --- 1. ПО ---
APT_UPDATED=0
ensure_pkg() { # ensure_pkg <бинарь> <apt-пакет>
  command -v "$1" >/dev/null 2>&1 && { log "$1: есть."; return; }
  [[ $APT_UPDATED -eq 0 ]] && { log "apt-get update…"; apt-get update -qq; APT_UPDATED=1; }
  log "Ставлю $2…"; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2"
}
if ! command -v docker >/dev/null 2>&1; then
  log "Ставлю Docker (get.docker.com)…"; curl -4 -fsSL https://get.docker.com | sh
else log "docker: есть."; fi
docker compose version >/dev/null 2>&1 || ensure_pkg docker-compose-plugin docker-compose-plugin
ensure_pkg nginx nginx
ensure_pkg certbot certbot
certbot plugins 2>/dev/null | grep -q nginx || ensure_pkg __certbot_nginx__ python3-certbot-nginx || true
command -v envsubst >/dev/null 2>&1 || ensure_pkg envsubst gettext-base

# ПО для внешней копии дампов — ставим только под то, что реально настроено.
# Для шифрования ничего ставить не нужно: openssl есть в любой базовой системе.
if [[ -n "$(get_env OFFSITE_DEST)" ]]; then
  ensure_pkg rsync rsync
fi
# rclone намеренно НЕ ставим из apt: в репозиториях Debian/Ubuntu он застревает на старых
# версиях, а бэкенд yandex у них ломался. Ставится вручную по docs/deploy/prod-deploy.md (rclone.org),
# там же заводится remote — шаг всё равно интерактивный (OAuth).
if [[ -n "$(get_env OFFSITE_RCLONE_REMOTE)" ]] && ! command -v rclone >/dev/null 2>&1; then
  warn "OFFSITE_RCLONE_REMOTE задан, но rclone не установлен — внешняя копия в облако не поедет. См. docs/deploy/prod-deploy.md."
fi

# --- 2. Доступ к приватному образу (если задан GHCR_TOKEN) ---
GHCR_USER="$(get_env GHCR_USER)"; GHCR_TOKEN="$(get_env GHCR_TOKEN)"
if [[ -n "$GHCR_USER" && -n "$GHCR_TOKEN" ]]; then
  log "Логин в GHCR ($GHCR_USER)…"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null \
    || die "логин в GHCR не прошёл (проверьте GHCR_USER/GHCR_TOKEN)."
else
  log "GHCR_TOKEN не задан — считаем образ публичным (рекомендуется)."
fi

# --- 3. Хостовый nginx: vhost + TLS ---
TEMPLATE="$REPO_ROOT/infra/nginx/craft-wms.conf.template"
[[ -f "$TEMPLATE" ]] || die "нет шаблона $TEMPLATE."
if command -v getent >/dev/null 2>&1 && ! getent hosts "$DOMAIN" >/dev/null; then
  warn "$DOMAIN пока не резолвится в IP — certbot не выпустит серт. Проверьте DNS/проброс порта 80."
fi
log "Генерирую vhost /etc/nginx/sites-available/$DOMAIN"
export DEPLOY_DOMAIN="$DOMAIN" BACKEND_BIND="$BIND"
envsubst '${DEPLOY_DOMAIN} ${BACKEND_BIND}' < "$TEMPLATE" > "/etc/nginx/sites-available/$DOMAIN"
ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
log "nginx -t…"; nginx -t
systemctl reload nginx
log "certbot --nginx для $DOMAIN…"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect --keep-until-expiring

# --- 4. Стек: pull → up → миграции → админ ---
log "Тяну образ и поднимаю стек…"
compose pull --quiet
compose up -d
cid="$(compose ps -q backend)"; [[ -n "$cid" ]] || die "контейнер backend не создан."
log "Жду healthcheck backend…"
for i in $(seq 1 30); do
  st="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)"
  [[ "$st" == "healthy" ]] && { log "backend healthy."; break; }
  [[ "$st" == "unhealthy" || $i -eq 30 ]] && die "backend не поднялся — логи: docker logs $cid"
  sleep 2
done
log "Миграции…"; compose run --rm --entrypoint /usr/local/bin/migrate backend up
log "Стартовый админ…"; compose run --rm --entrypoint /usr/local/bin/seed backend

# --- 5. systemd-таймеры: авто-обновление, бэкап, проверка восстановимости ---
# Установка вынесена в install_systemd_units() (deploy/_lib.sh): её же вызывает update.sh,
# поэтому правки юнитов доезжают на сервер сами, без повторного install.sh.
log "Ставлю systemd-таймеры по .env.prod…"
install_systemd_units
if [[ "$(get_env AUTO_UPDATE)" == "true" ]]; then
  log "Авто-обновление включено (каждые $(get_env UPDATE_INTERVAL || echo 5min))."
else
  log "AUTO_UPDATE=false — авто-обновление не включено (обновлять вручную: deploy/update.sh)."
fi
if [[ "$(get_env AUTO_BACKUP)" != "false" ]]; then
  log "Бэкап БД и проверка восстановимости включены."
else
  warn "AUTO_BACKUP=false — бэкап по расписанию НЕ включён. Единственная копия данных — сама БД."
fi
log "Проверка таймеров: systemctl list-timers 'craft-wms-*'"

echo
log "ГОТОВО. Проверьте: https://$DOMAIN/health (200) и https://$DOMAIN/ready (200)."
log "Файрвол (по желанию, сервер многосайтовый — на ваше усмотрение): sudo ufw allow 22,80,443/tcp && sudo ufw enable"
