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
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
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
