#!/usr/bin/env bash
# Craft WMS · подготовка сервера (идемпотентно).
# Проверяет наличие нужного ПО и доустанавливает недостающее: docker (+compose),
# nginx, certbot (+плагин nginx), ufw. Что уже стоит — НЕ трогает.
# Плюс preflight-проверка исходящей связи (чтобы деплой не завис на мёртвом прокси/без сети).
#
# Запуск на сервере:  sudo bash deploy/00-bootstrap.sh [--yes]
#   --yes  — ставить без интерактивного подтверждения (для автоматизации).
#
# Рассчитан на Debian/Ubuntu (apt). Прокси в скрипт НЕ зашит — нужен прямой выход в интернет.
set -euo pipefail

ASSUME_YES=0
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1

log()  { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap] ВНИМАНИЕ:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[bootstrap] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Проверки окружения ---
[[ $EUID -eq 0 ]] || die "запускать через sudo (нужны права на установку пакетов)."
command -v apt-get >/dev/null 2>&1 || die "ожидается Debian/Ubuntu (apt). Другой дистрибутив — установите ПО вручную (см. docs/deploy.md)."

# --- Preflight: есть ли прямой выход в интернет ---
# Проверяем реальную цель деплоя — реестр GHCR. http=401 = «доступен, нужен токен» → связь есть.
log "Проверка исходящей связи (ghcr.io)…"
code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 15 https://ghcr.io/v2/ 2>/dev/null || echo 000)"
if [[ "$code" == "000" ]]; then
  warn "Нет прямого выхода на https://ghcr.io."
  warn "Если на сервере включён shell-прокси (http_proxy/https_proxy) — сбросьте его или почините."
  die  "Без исходящей связи деплой невозможен (нужны GHCR и Let's Encrypt)."
fi
log "Связь есть (ghcr.io → HTTP $code)."

confirm() {
  # confirm "текст" → 0 если пользователь согласен (или --yes)
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "  → $1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

apt_install() {
  # apt_install <пакет...> — установка с обновлением индекса один раз
  if [[ "${APT_UPDATED:-0}" -eq 0 ]]; then
    log "apt-get update…"; apt-get update -qq; APT_UPDATED=1
  fi
  log "Установка: $*"; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

# --- Docker (+ compose plugin) ---
if command -v docker >/dev/null 2>&1; then
  log "docker: уже установлен ($(docker --version | awk '{print $3}' | tr -d ','))."
else
  warn "docker не найден."
  if confirm "Установить Docker Engine официальным скриптом get.docker.com?"; then
    curl -4 -fsSL https://get.docker.com | sh
  else
    die "docker обязателен. Установите вручную и перезапустите."
  fi
fi
# compose v2 — это плагин docker: проверяем подкоманду `docker compose`
if docker compose version >/dev/null 2>&1; then
  log "docker compose: доступен ($(docker compose version --short 2>/dev/null || echo '?'))."
else
  warn "плагин docker compose не найден."
  confirm "Установить docker-compose-plugin?" && apt_install docker-compose-plugin \
    || die "нужен docker compose v2 (плагин). Установите docker-compose-plugin."
fi

# --- nginx (хостовый reverse-proxy) ---
if command -v nginx >/dev/null 2>&1; then
  log "nginx: уже установлен ($(nginx -v 2>&1 | awk -F/ '{print $2}'))."
else
  warn "nginx не найден."
  confirm "Установить nginx?" && apt_install nginx || die "nginx обязателен для reverse-proxy/TLS."
fi

# --- certbot (+ плагин nginx) для Let's Encrypt ---
if command -v certbot >/dev/null 2>&1; then
  log "certbot: уже установлен ($(certbot --version 2>&1 | awk '{print $2}'))."
else
  warn "certbot не найден."
  confirm "Установить certbot + python3-certbot-nginx?" && apt_install certbot python3-certbot-nginx \
    || die "certbot обязателен для выпуска TLS-сертификата."
fi
# плагин nginx для certbot — отдельная проверка (certbot мог стоять без него)
if certbot plugins 2>/dev/null | grep -q nginx; then
  log "certbot: плагин nginx на месте."
else
  warn "плагин certbot-nginx не найден."
  confirm "Установить python3-certbot-nginx?" && apt_install python3-certbot-nginx \
    || warn "без плагина nginx придётся выпускать серт вручную (webroot)."
fi

# --- ufw (файрвол) ---
if command -v ufw >/dev/null 2>&1; then
  log "ufw: уже установлен."
else
  warn "ufw не найден."
  confirm "Установить ufw (файрвол)?" && apt_install ufw || warn "ufw пропущен — настройте файрвол сами."
fi

log "Готово. Проверьте вывод выше. Дальше: настроить .env.prod, затем deploy/10-nginx-vhost.sh и deploy/20-deploy.sh."
