#!/usr/bin/env bash
# Craft WMS · демо-сервер «в одну команду» (ADHOC-67).
#
# Что делает (повторный запуск безопасен):
#   1) при первом запуске создаёт .env.demo рядом с .env.prod (root, 600): домен демо, свои
#      пароль базы, JWT-секрет и ключ бейджей - не боевые; адрес бэкенда демо на loopback;
#   2) поднимает демо тем же образом бэкенда, что прод (compose-проект craft-wms-demo):
#      миграции, старт, бэкенд сам заполняет пустую базу выдуманным складом;
#   3) заводит vhost хостового nginx для домена демо (портал - тот же каталог, что у прода)
#      и сертификат Let's Encrypt;
#   4) проверяет снаружи через nginx: GET /api/v1/demo → {"enabled":true}.
# Дальше демо обновляет deploy/update.sh вместе с продом.
#
# Запуск:  sudo bash deploy/demo-setup.sh [домен]   - настройка (пункт 20 в craft.sh),
#                                                     домен по умолчанию demo.<DEPLOY_DOMAIN>
#          sudo bash deploy/demo-setup.sh --reset   - вернуть демо-данные к исходным (пункт 21)
set -euo pipefail
SCRIPT_NAME=demo
# Путь к _lib.sh вычисляется в рантайме - статический анализатор его не проходит.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[[ $EUID -eq 0 ]] || die "запускать через sudo."
require_env_file
command -v docker >/dev/null 2>&1 || die "docker не установлен."

if [[ "${1:-}" == "--reset" ]]; then
  demo_reset_now
  exit 0
fi

# --- 1. Секреты демо --------------------------------------------------------------------
env_demo="$(demo_env_file)"
if [[ ! -f "$env_demo" ]]; then
  prod_domain="$(get_env DEPLOY_DOMAIN)"
  domain="${1:-demo.${prod_domain:-craft.skogi.ru}}"
  log "Создаю $env_demo (домен $domain)…"
  umask 077
  cat > "$env_demo" <<EOF
# Демо-сервер Craft WMS (ADHOC-67). Секреты свои, не боевые. Создан deploy/demo-setup.sh.
DEMO_DOMAIN=$domain
DEMO_BIND=127.0.0.1:8081
DEMO_RESET_AT=03:00
DEMO_DB_PASSWORD=$(openssl rand -hex 24)
DEMO_JWT_SECRET=$(openssl rand -hex 32)
DEMO_BADGE_KEY=$(openssl rand -hex 32)
EOF
else
  log "$env_demo уже есть - секреты не меняю."
fi
chown root:root "$env_demo"
chmod 600 "$env_demo"

# --- 2. Демо тем же образом, что прод ---------------------------------------------------
log "Проверяю образ бэкенда прода…"
compose pull --quiet backend || warn "не удалось обновить образ - беру локальный."
demo_deploy || die "демо не поднялось - смотрите: docker compose -p craft-wms-demo logs backend"

# --- 3. nginx и сертификат --------------------------------------------------------------
setup_demo_vhost

# --- 4. Проверка снаружи ----------------------------------------------------------------
domain="$(demo_get DEMO_DOMAIN)"
if curl -fsS -m 10 --resolve "$domain:443:127.0.0.1" "https://$domain/api/v1/demo" | grep -q '"enabled":true'; then
  log "Готово: https://$domain - портал демо; ТСД - кнопка «Демо-режим» на экране входа."
else
  die "https://$domain/api/v1/demo не ответил {\"enabled\":true} - проверьте nginx и журнал демо."
fi
