#!/usr/bin/env bash
# Общие функции для скриптов деплоя Craft WMS. Подключается через `source`.
# Единое место: цветной вывод, резолв путей/.env.prod, чтение переменных (со срезкой
# inline-комментариев), обёртка docker compose, preflight сети.

# --- Вывод ---
log()  { printf '\033[1;36m[%s]\033[0m %s\n' "${SCRIPT_NAME:-deploy}" "$*"; }
warn() { printf '\033[1;33m[%s] ВНИМАНИЕ:\033[0m %s\n' "${SCRIPT_NAME:-deploy}" "$*"; }
die()  { printf '\033[1;31m[%s] ОШИБКА:\033[0m %s\n' "${SCRIPT_NAME:-deploy}" "$*" >&2; exit 1; }

# --- Пути ---
# Раскладка на сервере (рекомендуемая):
#   /opt/craft-wms/.env.prod   ← секреты, кладутся руками (вне git)
#   /opt/craft-wms/app/        ← git clone репозитория (здесь лежит этот скрипт)
# .env.prod ищем на уровень выше корня репо; переопределяется переменной CRAFT_ENV_FILE.
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CRAFT_REPO_ROOT — переопределение для случая, когда скрипт запущен из временной копии
# (update.sh копирует себя перед git pull, чтобы обновление не подменило скрипт на ходу).
REPO_ROOT="${CRAFT_REPO_ROOT:-$(cd "$DEPLOY_DIR/.." && pwd)}"
COMPOSE_FILE="$REPO_ROOT/infra/docker-compose.prod.yml"
ENV_FILE="${CRAFT_ENV_FILE:-$(cd "$REPO_ROOT/.." && pwd)/.env.prod}"

require_env_file() {
  [[ -f "$ENV_FILE" ]] || die "нет файла $ENV_FILE — создайте его (шаблон: infra/.env.prod.example). См. docs/deploy.md."
}

# get_env KEY — значение переменной из .env.prod.
# Срезает inline-комментарий (пробел + #) и хвостовые пробелы; значения с '#' без пробела не портит.
get_env() {
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
  v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')"
  printf '%s' "$v"
}

# compose ... — docker compose с нашим env-файлом и prod-compose.
compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

# preflight_net — проверка прямого выхода к реестру GHCR (иначе pull/деплой не пройдут).
preflight_net() {
  local code
  code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 15 https://ghcr.io/v2/ 2>/dev/null || echo 000)"
  [[ "$code" != "000" ]] || die "нет прямого выхода на https://ghcr.io (сеть/прокси). Деплой прерван."
}

# journal_err СООБЩЕНИЕ — строка в journal с приоритетом error. systemd читает префикс <3>,
# поэтому падение ночного таймера видно в `systemctl status` красным, а не теряется в потоке.
journal_err() { printf '<3>[%s] %s\n' "${SCRIPT_NAME:-deploy}" "$*"; }

# install_systemd_units — ставит/обновляет юниты из $REPO_ROOT/deploy/systemd по .env.prod.
# Идемпотентна: перезаписывает файлы и включает таймеры, повторный вызов безопасен.
# Общая для install.sh (первая установка) и update.sh (доставка изменившихся юнитов).
install_systemd_units() {
  # CRAFT_SYSTEMD_DIR — куда класть юниты. Переопределяется только в тестах: на сервере
  # это /etc/systemd/system, и туда нужен root.
  local sysd="${CRAFT_SYSTEMD_DIR:-/etc/systemd/system}"
  local units_dir="$REPO_ROOT/deploy/systemd" changed=0
  mkdir -p "$sysd"

  # Авто-обновление.
  if [[ "$(get_env AUTO_UPDATE)" == "true" ]]; then
    local interval; interval="$(get_env UPDATE_INTERVAL)"; interval="${interval:-5min}"
    sed "s|__REPO_ROOT__|$REPO_ROOT|g" "$units_dir/craft-wms-update.service" \
      > "$sysd/craft-wms-update.service"
    sed "s|__INTERVAL__|$interval|g" "$units_dir/craft-wms-update.timer" \
      > "$sysd/craft-wms-update.timer"
    changed=1
  fi

  # Бэкап и проверка восстановимости. Флаг отдельный: обновление можно не хотеть, бэкап нужен всегда.
  if [[ "$(get_env AUTO_BACKUP)" != "false" ]]; then
    local backup_at check_at
    backup_at="$(get_env BACKUP_SCHEDULE)"; backup_at="${backup_at:-*-*-* 03:30:00}"
    check_at="$(get_env RESTORE_CHECK_SCHEDULE)"; check_at="${check_at:-Sun *-*-* 04:30:00}"
    local unit
    for unit in craft-wms-backup craft-wms-restore-check; do
      sed "s|__REPO_ROOT__|$REPO_ROOT|g" "$units_dir/$unit.service" \
        > "$sysd/$unit.service"
    done
    sed "s|__SCHEDULE__|$backup_at|g" "$units_dir/craft-wms-backup.timer" \
      > "$sysd/craft-wms-backup.timer"
    sed "s|__SCHEDULE__|$check_at|g" "$units_dir/craft-wms-restore-check.timer" \
      > "$sysd/craft-wms-restore-check.timer"
    changed=1
  fi

  [[ $changed -eq 1 ]] || return 0
  # В тестах (CRAFT_SYSTEMD_DIR задан) systemd не трогаем — только раскладываем файлы.
  [[ -n "${CRAFT_SYSTEMD_DIR:-}" ]] && return 0
  systemctl daemon-reload
  [[ "$(get_env AUTO_UPDATE)" == "true" ]] && systemctl enable --now craft-wms-update.timer >/dev/null
  [[ "$(get_env AUTO_BACKUP)" != "false" ]] && \
    systemctl enable --now craft-wms-backup.timer craft-wms-restore-check.timer >/dev/null
  return 0
}

# health_check — дождаться готовности backend на loopback. Возвращает 1, если не поднялся.
# Проверяем именно /ready (он щупает БД), а не /health: после миграций важна связность с базой.
health_check() {
  local bind url attempts=20
  bind="$(get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
  url="http://$bind/ready"
  # Счётчик не нужен — важно лишь число попыток; while с декрементом избегает пустой переменной.
  while (( attempts-- > 0 )); do
    curl -fsS --max-time 5 -o /dev/null "$url" 2>/dev/null && { log "Готовность: $url отвечает 200."; return 0; }
    sleep 3
  done
  journal_err "backend не отвечает 200 на $url после обновления — стек может быть нерабочим."
  return 1
}
