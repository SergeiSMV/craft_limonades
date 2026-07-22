#!/usr/bin/env bash
# Craft WMS · настройка ХОСТОВОГО nginx под ${DEPLOY_DOMAIN} + выпуск TLS (Let's Encrypt).
# Идемпотентно: повторный запуск не ломает конфиг, certbot переиспользует существующий серт.
#
# Что делает:
#   1. генерирует vhost из infra/nginx/craft-wms.conf.template (envsubst по домену и backend);
#   2. кладёт в /etc/nginx/sites-available/<домен> и включает симлинком в sites-enabled/;
#   3. `nginx -t` (не сломать соседние сайты!) → reload;
#   4. `certbot --nginx` выпускает серт и добавляет 443-блок + редирект http→https.
#
# Запуск на сервере:  sudo bash deploy/10-nginx-vhost.sh
# Требует заполненный infra/.env.prod и уже настроенный проброс портов 80/443 на сервер.
set -euo pipefail

log()  { printf '\033[1;36m[vhost]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vhost] ВНИМАНИЕ:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[vhost] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/infra/.env.prod"
TEMPLATE="$REPO_ROOT/infra/nginx/craft-wms.conf.template"

[[ $EUID -eq 0 ]] || die "запускать через sudo (правит /etc/nginx и запускает certbot)."
[[ -f "$ENV_FILE" ]] || die "нет $ENV_FILE — скопируйте из infra/.env.prod.example и заполните."
[[ -f "$TEMPLATE" ]] || die "нет шаблона $TEMPLATE."
command -v nginx   >/dev/null 2>&1 || die "nginx не установлен (запустите deploy/00-bootstrap.sh)."
command -v certbot >/dev/null 2>&1 || die "certbot не установлен (запустите deploy/00-bootstrap.sh)."
command -v envsubst >/dev/null 2>&1 || die "нет envsubst (пакет gettext-base): apt-get install -y gettext-base."

# Читаем нужные переменные из .env.prod (без экспорта всего файла в окружение).
get_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- ; }
DEPLOY_DOMAIN="$(get_env DEPLOY_DOMAIN)"
CERTBOT_EMAIL="$(get_env CERTBOT_EMAIL)"
BACKEND_BIND="$(get_env BACKEND_BIND)"
[[ -n "$DEPLOY_DOMAIN" ]] || die "DEPLOY_DOMAIN не задан в $ENV_FILE."
[[ -n "$CERTBOT_EMAIL" ]] || die "CERTBOT_EMAIL не задан в $ENV_FILE."
[[ -n "$BACKEND_BIND"  ]] || die "BACKEND_BIND не задан в $ENV_FILE."

log "Домен: $DEPLOY_DOMAIN · backend: $BACKEND_BIND"

# Предупреждение, если домен ещё не резолвится (certbot тогда не выпустит серт).
if command -v getent >/dev/null 2>&1 && ! getent hosts "$DEPLOY_DOMAIN" >/dev/null; then
  warn "$DEPLOY_DOMAIN пока не резолвится в IP. Проверьте DNS и проброс порта 80 до выпуска серта."
fi

# 1. Генерируем vhost (подставляем ТОЛЬКО наши переменные — nginx-переменные $host не трогаем).
VHOST_AVAIL="/etc/nginx/sites-available/$DEPLOY_DOMAIN"
VHOST_ENABLED="/etc/nginx/sites-enabled/$DEPLOY_DOMAIN"
log "Генерирую $VHOST_AVAIL"
export DEPLOY_DOMAIN BACKEND_BIND
envsubst '${DEPLOY_DOMAIN} ${BACKEND_BIND}' < "$TEMPLATE" > "$VHOST_AVAIL"

# 2. Включаем симлинком (идемпотентно).
ln -sfn "$VHOST_AVAIL" "$VHOST_ENABLED"
log "Включён симлинк $VHOST_ENABLED"

# 3. Проверка всей конфигурации nginx ПЕРЕД перезагрузкой — чтобы не уронить соседние сайты.
log "nginx -t…"
nginx -t
systemctl reload nginx
log "nginx перезагружен (HTTP-vhost активен)."

# 4. Выпуск/установка TLS-сертификата. Идемпотентно: если серт уже есть — certbot переиспользует.
log "certbot --nginx для $DEPLOY_DOMAIN…"
certbot --nginx -d "$DEPLOY_DOMAIN" \
  --non-interactive --agree-tos -m "$CERTBOT_EMAIL" \
  --redirect --keep-until-expiring

log "Готово. Проверьте: https://$DEPLOY_DOMAIN/health (после деплоя backend вернёт 200)."
