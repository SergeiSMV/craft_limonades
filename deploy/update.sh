#!/usr/bin/env bash
# Craft WMS · обновление стека (идемпотентно). Тянет свежий образ из GHCR, применяет
# миграции, перезапускает изменившиеся контейнеры. Безопасно гонять хоть каждые 5 минут:
# если нового образа нет — по сути no-op.
#
# Использование:
#   bash deploy/update.sh          # ручное обновление
#   (то же вызывает systemd-таймер craft-wms-update.timer — авто-обновление)
set -euo pipefail
SCRIPT_NAME=update
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env_file
command -v docker >/dev/null 2>&1 || die "docker не установлен."
preflight_net

# Логин в GHCR, если образ приватный (GHCR_USER/GHCR_TOKEN заданы). Публичный образ логина не требует.
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
  log "Новых обновлений нет (стек актуален)."
fi
