#!/usr/bin/env bash
# Craft WMS · деплой/обновление прод-стека. Идемпотентно — гоняется при каждом релизе.
#
# Порядок: preflight → pull образа из GHCR → up -d → дождаться healthy → миграции → (опц.) seed.
#
# Запуск на сервере (из корня репозитория):
#   bash deploy/20-deploy.sh            # обновление: pull + up + migrate
#   bash deploy/20-deploy.sh --seed     # + завести стартового админа (обычно только ПЕРВЫЙ раз)
#
# Требует заполненный infra/.env.prod и доступ к приватному образу GHCR
# (разово: docker login ghcr.io -u <github-user>  — токен с scope read:packages).
# Если docker требует прав — запускайте через sudo (или добавьте пользователя в группу docker).
set -euo pipefail

RUN_SEED=0
[[ "${1:-}" == "--seed" ]] && RUN_SEED=1

log()  { printf '\033[1;36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy] ВНИМАНИЕ:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[deploy] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/infra/.env.prod"
COMPOSE_FILE="$REPO_ROOT/infra/docker-compose.prod.yml"

[[ -f "$ENV_FILE" ]]     || die "нет $ENV_FILE — скопируйте из infra/.env.prod.example и заполните."
[[ -f "$COMPOSE_FILE" ]] || die "нет $COMPOSE_FILE."
command -v docker >/dev/null 2>&1 || die "docker не установлен (запустите deploy/00-bootstrap.sh)."
docker compose version >/dev/null 2>&1 || die "нет docker compose v2."

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
BACKEND_IMAGE="$(grep -E '^BACKEND_IMAGE=' "$ENV_FILE" | tail -1 | cut -d= -f2-)"

# --- Preflight: исходящая связь ---
log "Проверка связи с ghcr.io…"
code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 15 https://ghcr.io/v2/ 2>/dev/null || echo 000)"
[[ "$code" != "000" ]] || die "нет выхода на ghcr.io (проверьте сеть/прокси). Деплой прерван."

# --- Pull образа ---
log "Тяну образ: $BACKEND_IMAGE"
if ! "${COMPOSE[@]}" pull; then
  warn "Не удалось скачать образ. Если он приватный — авторизуйтесь в GHCR:"
  warn "  docker login ghcr.io -u <github-user>   (пароль = PAT со scope read:packages)"
  die  "pull не прошёл."
fi

# --- Запуск ---
log "Поднимаю стек (up -d)…"
"${COMPOSE[@]}" up -d

# --- Ждём, пока backend станет healthy ---
cid="$("${COMPOSE[@]}" ps -q backend)"
[[ -n "$cid" ]] || die "контейнер backend не создан."
log "Жду healthcheck backend…"
for i in $(seq 1 30); do
  status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)"
  [[ "$status" == "healthy" ]] && { log "backend healthy."; break; }
  [[ "$status" == "unhealthy" ]] && die "backend unhealthy — смотрите логи: ${COMPOSE[*]} logs backend"
  sleep 2
  [[ $i -eq 30 ]] && die "backend не стал healthy за ~60с — смотрите логи: ${COMPOSE[*]} logs backend"
done

# --- Миграции (разовый контейнер из того же образа; .sql встроены в бинарь migrate) ---
log "Накатываю миграции…"
"${COMPOSE[@]}" run --rm --entrypoint /usr/local/bin/migrate backend up

# --- Сид админа (только по флагу; сам по себе идемпотентен — создаёт, если нет) ---
if [[ $RUN_SEED -eq 1 ]]; then
  log "Завожу стартового админа (seed)…"
  "${COMPOSE[@]}" run --rm --entrypoint /usr/local/bin/seed backend
else
  log "seed пропущен (запустите с --seed при первом деплое, если админ ещё не заведён)."
fi

log "Деплой завершён. Проверьте: https://<домен>/ready (должно вернуть 200 при живой БД)."
"${COMPOSE[@]}" ps
