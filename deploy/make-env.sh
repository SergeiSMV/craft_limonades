#!/usr/bin/env bash
# Craft WMS · генератор infra/.env.prod из шаблона infra/.env.prod.example.
# Автоматически подставляет СЛУЧАЙНЫЕ секреты (JWT_SECRET, POSTGRES_PASSWORD),
# остальные плейсхолдеры (домен, e-mail, пароль админа, тег образа) оставляет на правку.
#
# Запуск на сервере (из корня репозитория):  bash deploy/make-env.sh [--force]
#   без флага  — откажется перезаписывать существующий .env.prod (защита секретов);
#   --force    — перегенерирует (ВНИМАНИЕ: новый JWT инвалидирует выданные токены,
#                новый POSTGRES_PASSWORD разойдётся с уже созданной БД — только для чистого старта).
#
# Секреты генерируются НА МЕСТЕ и в git не попадают (.env.prod в .gitignore).
set -euo pipefail

log()  { printf '\033[1;36m[make-env]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[make-env] ВНИМАНИЕ:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[make-env] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$REPO_ROOT/infra/.env.prod.example"
TARGET="$REPO_ROOT/infra/.env.prod"

command -v openssl >/dev/null 2>&1 || die "нужен openssl для генерации секретов."
[[ -f "$EXAMPLE" ]] || die "нет шаблона $EXAMPLE."
if [[ -f "$TARGET" && $FORCE -eq 0 ]]; then
  die "$TARGET уже существует. Перегенерировать секреты — только осознанно: bash deploy/make-env.sh --force"
fi

# Секреты: JWT (base64, годится как есть) и пароль БД (только буквы/цифры —
# безопасно внутри DATABASE_URL, без экранирования спецсимволов).
JWT="$(openssl rand -base64 48)"
PGPASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)"

# Инстанцируем шаблон и заменяем ТОЛЬКО секретные строки.
# Разделитель sed — '|': его нет в алфавите base64, поэтому JWT со слэшами/плюсами не сломает подстановку.
cp "$EXAMPLE" "$TARGET"
sed -i.bak \
  -e "s|^JWT_SECRET=.*|JWT_SECRET=${JWT}|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PGPASS}|" \
  "$TARGET"
rm -f "$TARGET.bak"
chmod 600 "$TARGET"

log "Создан $TARGET (права 600). Секреты JWT_SECRET и POSTGRES_PASSWORD сгенерированы случайно."
warn "Осталось отредактировать под своё окружение:"
grep -nE 'example\.ru|CHANGE_ME|craft-wms-backend:main' "$TARGET" \
  || echo "  (плейсхолдеров по шаблону не осталось — проверьте домен/образ вручную)"
echo
log "После правки: deploy/10-nginx-vhost.sh (TLS) → deploy/20-deploy.sh --seed (первый деплой)."
