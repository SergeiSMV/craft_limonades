#!/usr/bin/env bash
# Craft WMS · обновление сервера «в одну команду» (идемпотентно):
#   1) подтягивает свежий код деплоя (git pull) — скрипты и systemd-юниты;
#   2) переустанавливает юниты, если они изменились;
#   3) тянет свежий образ backend из GHCR, применяет миграции, перезапускает изменившееся;
#   4) проверяет /ready и громко ругается в journal, если стек не поднялся.
#
# Безопасно гонять хоть каждые 5 минут: нет изменений — по сути no-op.
#
# Использование:
#   sudo bash deploy/update.sh          # обновить сервер целиком
#   (то же вызывает systemd-таймер craft-wms-update.timer — авто-обновление)
#
# SELF_UPDATE=false в .env.prod отключает шаги 1–2: код деплоя обновляется только вручную.
set -euo pipefail
SCRIPT_NAME=update
# Путь к _lib.sh вычисляется в рантайме — статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env_file
command -v docker >/dev/null 2>&1 || die "docker не установлен."

# --- 0. Перезапуск из временной копии ---------------------------------------------------
# git pull ниже перепишет ЭТОТ файл. bash дочитывает скрипт с диска по мере выполнения,
# поэтому подмена на ходу приводит к исполнению обрывка новой версии вперемешку со старой.
# Уходим в копию: обновление доедет целиком, а новая версия вступит в силу со следующего
# запуска — сломанный update.sh не сможет оборваться на середине собственного обновления.
if [[ "${CRAFT_SELF_COPY:-}" != "1" && "$(get_env SELF_UPDATE)" != "false" ]]; then
  copy_dir="$(mktemp -d)"
  cp "$DEPLOY_DIR"/*.sh "$copy_dir/"
  trap 'rm -rf "$copy_dir"' EXIT
  log "Работаю из копии $copy_dir (git pull не подменит скрипт на ходу)."
  CRAFT_SELF_COPY=1 CRAFT_REPO_ROOT="$REPO_ROOT" bash "$copy_dir/update.sh" "$@"
  exit $?
fi

preflight_net

# --- 1. Код деплоя ----------------------------------------------------------------------
if [[ "$(get_env SELF_UPDATE)" != "false" ]]; then
  before_rev="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  log "Обновляю код деплоя (git pull)…"
  # safe.directory: таймер работает от root, а клон принадлежит пользователю сервера —
  # без этого git отказывается работать с «чужим» репозиторием.
  # --ff-only: если в клоне локальные правки и слияние неочевидно, лучше не тронуть
  # боевой сервер, чем молча смержить.
  if git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" pull --ff-only --quiet; then
    after_rev="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    if [[ "$before_rev" != "$after_rev" ]]; then
      log "Код деплоя обновлён: $before_rev → $after_rev."
      log "Правки в самом update.sh вступят в силу со следующего запуска."
    else
      log "Код деплоя актуален ($after_rev)."
    fi
  else
    journal_err "git pull не прошёл (локальные правки в $REPO_ROOT?) — продолжаю со старым кодом деплоя."
  fi

  # --- 2. systemd-юниты ---
  # Идемпотентно перезаписываем из репозитория: иначе правки юнитов лежали бы в git
  # и никогда не доезжали до сервера.
  log "Применяю systemd-юниты…"
  install_systemd_units
else
  log "SELF_UPDATE=false — код деплоя и юниты не трогаю."
fi

# --- 3. Образ backend -------------------------------------------------------------------
# Логин в GHCR, если образ приватный (GHCR_USER/GHCR_TOKEN заданы). Публичный логина не требует.
GHCR_USER="$(get_env GHCR_USER)"; GHCR_TOKEN="$(get_env GHCR_TOKEN)"
if [[ -n "$GHCR_USER" && -n "$GHCR_TOKEN" ]]; then
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null 2>&1 \
    || warn "не удалось залогиниться в GHCR (проверьте GHCR_USER/GHCR_TOKEN)."
fi

# Запоминаем текущий образ backend, чтобы понять, было ли обновление.
before="$(compose images -q backend 2>/dev/null || true)"

log "Проверяю обновления образа…"
compose pull --quiet

log "Применяю (up -d — пересоздаст контейнер только при новом образе)…"
compose up -d

after="$(compose images -q backend 2>/dev/null || true)"

# Миграции применяем всегда (идемпотентно: нет новых — 'no change'). Это дёшево и надёжно.
log "Миграции…"
compose run --rm --entrypoint /usr/local/bin/migrate backend up

if [[ "$before" != "$after" ]]; then
  log "Обновление применено: образ backend изменился."
else
  log "Новых обновлений образа нет."
fi

# --- 4. Проверка готовности -------------------------------------------------------------
# Без неё ночное падение обнаружилось бы утром по жалобе кладовщика.
health_check || die "обновление применено, но стек не отвечает — смотрите: docker compose logs backend"
log "Обновление завершено."
