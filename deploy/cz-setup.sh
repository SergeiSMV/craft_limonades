#!/usr/bin/env bash
# Craft WMS · настройка подписанта Честного знака «в одну команду» (CZ-02).
#
# Что делает, по шагам (повторный запуск безопасен — Enter оставляет текущее):
#   1) спрашивает пользователя сервера, у которого лежит ключ, показывает его сертификаты
#      в uMy и спрашивает отпечаток подписанта и пароль копии ключа;
#   2) пишет отпечаток и пароль в cz-signer.env рядом с .env.prod (root, 600), а в .env.prod —
#      CZ_SIGNER_USER и сокет для бэкенда;
#   3) ставит юнит, группу сокета и бинарь подписанта, перезапускает службу и проверяет
#      пробной подписью;
#   4) пересоздаёт backend с сокетом и ждёт, пока он получит токен True API;
#   5) по желанию читает марку — полный путь: бэкенд → подписант → True API.
#
# КриптоПро CSP, ключ и сертификат в uMy пользователя ставятся заранее, руками (CZ-01).
#
# Запуск:  sudo bash deploy/cz-setup.sh          — настройка (пункт 18 в craft.sh)
#          sudo bash deploy/cz-setup.sh --test   — только проверка (пункт 19)
set -euo pipefail
SCRIPT_NAME=cz
# Путь к _lib.sh вычисляется в рантайме — статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[[ $EUID -eq 0 ]] || die "запускать через sudo."
require_env_file
command -v docker >/dev/null 2>&1 || die "docker не установлен."

CPRO_BIN=/opt/cprocsp/bin/amd64
# Сокет подписанта: тот же путь на хосте и в контейнере бэкенда (том в compose, юнит).
CZ_SOCKET=/run/cz-signer/sign.sock

# ---------------------------------------------------------------------------------------
#  Помощники
# ---------------------------------------------------------------------------------------

# env_file_value КЛЮЧ — значение из cz-signer.env; пароль там в одинарных кавычках.
env_file_value() {
  local f; f="$(cz_signer_env)"
  [[ -f "$f" ]] || return 0
  sed -n "s/^$1=//p" "$f" | tail -1 | sed "s/^'\(.*\)'$/\1/"
}

# signer_health — пробная подпись прямо через сокет, мимо бэкенда: сначала проверяем звено
# «подписант», потом весь путь.
signer_health() {
  curl -fsS -m 45 --unix-socket "$CZ_SOCKET" -o /dev/null http://cz-signer/health 2>/dev/null
}

# cz_api ПУТЬ [ТЕЛО] — вызов admin-ручки ЧЗ бэкенда: тело ответа — в файл $CZ_OUT, код — в
# CZ_HTTP. Без подстановки $(…): она шла бы в подоболочке, и код ответа терялся бы.
#
# Вход админа — один раз за запуск (CZ_ADMIN_TOKEN): у входа лимит 10 в минуту, а проверка
# опрашивает статус каждые 3 секунды — вход на каждый опрос упирался в 429.
CZ_OUT="$(mktemp)"
trap 'rm -f "$CZ_OUT"' EXIT
CZ_HTTP=000
CZ_ADMIN_TOKEN=""
cz_api() {
  local bind
  bind="$(get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
  if [[ -z "$CZ_ADMIN_TOKEN" ]]; then
    CZ_ADMIN_TOKEN="$(admin_token)" || true
    [[ -n "$CZ_ADMIN_TOKEN" ]] || die "вход админа в backend не удался — проверьте ADMIN_USERNAME/ADMIN_PASSWORD (или подождите минуту: лимит входов)."
  fi
  if [[ -n "${2:-}" ]]; then
    CZ_HTTP="$(printf '%s' "$2" | curl -sS -m 60 -o "$CZ_OUT" -w '%{http_code}' \
      -H "Authorization: Bearer $CZ_ADMIN_TOKEN" -H 'Content-Type: application/json' --data-binary @- \
      "http://$bind/api/v1/admin/cz/$1")" || CZ_HTTP=000
  else
    CZ_HTTP="$(curl -sS -m 60 -o "$CZ_OUT" -w '%{http_code}' \
      -H "Authorization: Bearer $CZ_ADMIN_TOKEN" "http://$bind/api/v1/admin/cz/$1")" || CZ_HTTP=000
  fi
}

# cz_test — проверка по звеньям: служба → пробная подпись → токен в бэкенде → чтение марки.
#
# Токена ждём полторы минуты: бэкенд входит сразу при старте, а после неудачи повторяет вход
# с растущей паузой (1, 2, 4… до 15 минут). Настройка поэтому всегда перезапускает бэкенд.
cz_test() {
  command -v jq >/dev/null 2>&1 || die "нет jq: sudo apt-get install -y jq"
  systemctl is-active --quiet "$CZ_SIGNER_UNIT" \
    || die "служба $CZ_SIGNER_UNIT не работает — смотрите: journalctl -u $CZ_SIGNER_UNIT -n 30"
  log "Пробная подпись через сокет…"
  signer_health || die "подписант не подписывает — смотрите: journalctl -u $CZ_SIGNER_UNIT -n 30 (ключ, пароль, лицензия КриптоПро)"
  log "✅ Подписант подписывает."

  log "Жду токен True API в бэкенде…"
  local valid=false
  for _ in $(seq 1 30); do
    cz_api status
    [[ "$CZ_HTTP" == "200" ]] || die "status: HTTP $CZ_HTTP — бэкенд без ручек ЧЗ? Обновите сервер (пункт 2)."
    [[ "$(jq -r '.configured' "$CZ_OUT")" == "true" ]] \
      || die "бэкенд отвечает, что ЧЗ не настроен — CZ_SIGNER_SOCKET не подхвачен (пересоздайте backend)."
    [[ "$(jq -r '.signer_ok' "$CZ_OUT")" == "true" ]] \
      || die "бэкенд не достучался до подписанта: $(jq -r '.signer_error' "$CZ_OUT")"
    valid="$(jq -r '.token_valid' "$CZ_OUT")"
    [[ "$valid" == "true" ]] && break
    sleep 3
  done
  [[ "$valid" == "true" ]] \
    || die "токена пока нет. Бэкенд после неудачных входов ждёт до 15 минут — пункт 18 перезапустит его сразу; причина — в журнале: docker compose … logs backend | grep 'true api'"
  log "✅ Токен получен, действует до $(jq -r '.token_expires_at' "$CZ_OUT") (UTC)."

  local code
  read -rp "  КИ марки для пробного чтения (часть до GS; Enter — пропустить): " code
  [[ -n "$code" ]] || return 0
  cz_api info "$(jq -n --arg c "$code" '{codes: [$c]}')"
  [[ "$CZ_HTTP" == "200" ]] || die "чтение марки: HTTP $CZ_HTTP — $(jq -r '.error // .' "$CZ_OUT" 2>/dev/null || cat "$CZ_OUT")"
  jq -r '.items[] | "  код: \(.requested_cis)\n  \(.product_name // "—")\n  группа: \(.product_group // "—") · упаковка: \(.package_type // "—") · статус: \(.status // "—")\n  произведён: \(.produced_date // "—") · годен до: \(.expiration_date // "—")\(if .error_message then "\n  отказ ЧЗ: " + .error_message else "" end)"' "$CZ_OUT"
  log "✅ Марка прочитана через True API."
}

# ---------------------------------------------------------------------------------------
#  Только проверка
# ---------------------------------------------------------------------------------------
if [[ "${1:-}" == "--test" ]]; then
  [[ -n "$(get_env CZ_SIGNER_USER)" ]] || die "подписант не настроен — сначала: sudo bash deploy/cz-setup.sh"
  cz_test
  exit 0
fi

[[ -x "$CPRO_BIN/cryptcp" && -x "$CPRO_BIN/certmgr" ]] \
  || die "КриптоПро CSP не найден в $CPRO_BIN — поставьте его и ключ заранее (как в CZ-01)."
if ! command -v jq >/dev/null 2>&1; then
  log "Ставлю jq…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null || die "не удалось поставить jq: sudo apt-get install -y jq"
fi

# --- 1. Вопросы -------------------------------------------------------------------------
printf '\n%s\n' "Подписант Честного знака. Enter — оставить значение в скобках."

user_def="$(get_env CZ_SIGNER_USER)"; user_def="${user_def:-${SUDO_USER:-}}"
read -rp "  Пользователь сервера, у которого лежит ключ [${user_def:-пусто}]: " cz_user
cz_user="${cz_user:-$user_def}"
[[ -n "$cz_user" ]] || die "нужен пользователь сервера."
id "$cz_user" >/dev/null 2>&1 || die "пользователя $cz_user на сервере нет."
[[ -d "/var/opt/cprocsp/keys/$cz_user" ]] \
  || warn "нет каталога ключей /var/opt/cprocsp/keys/$cz_user — ключ должен лежать там (файловая копия)."

# Сертификаты в личном хранилище пользователя: certmgr видит хранилище того, кто его запустил.
certs="$(runuser -u "$cz_user" -- "$CPRO_BIN/certmgr" -list -store uMy 2>/dev/null || true)"
mapfile -t thumbs < <(grep -iE 'sha1' <<<"$certs" | grep -oiE '[0-9a-f]{40}' || true)
[[ ${#thumbs[@]} -gt 0 ]] || die "в хранилище uMy пользователя $cz_user нет сертификатов — поставьте сертификат подписанта (CZ-01)."
printf '\n  Сертификаты в uMy пользователя %s:\n' "$cz_user"
grep -iE 'subject|субъект|sha1|not valid after|истекает' <<<"$certs" | sed 's/^/    /'

thumb_def="$(env_file_value CZ_SIGNER_THUMB)"
[[ -n "$thumb_def" || ${#thumbs[@]} -ne 1 ]] || thumb_def="${thumbs[0]}"
read -rp "  SHA1-отпечаток сертификата подписанта [${thumb_def:-пусто}]: " thumb
thumb="${thumb:-$thumb_def}"
thumb="$(tr -d ' :' <<<"$thumb" | tr 'A-F' 'a-f')"
[[ "$thumb" =~ ^[0-9a-f]{40}$ ]] || die "отпечаток — 40 шестнадцатеричных знаков."
printf '%s\n' "${thumbs[@]}" | tr 'A-F' 'a-f' | grep -qx "$thumb" \
  || die "сертификата с отпечатком $thumb в uMy пользователя $cz_user нет."

# ИНН организации в ЧЗ (CZ-05): по нему приёмка отличает чужие марки. Не секрет — в .env.prod.
inn_def="$(get_env CZ_OWNER_INN)"
read -rp "  ИНН организации в Честном знаке (как в МЧД) [${inn_def:-пусто}]: " owner_inn
owner_inn="${owner_inn:-$inn_def}"
[[ -z "$owner_inn" || "$owner_inn" =~ ^([0-9]{10}|[0-9]{12})$ ]] || die "ИНН — 10 или 12 цифр."
[[ -n "$owner_inn" ]] || warn "ИНН не задан — приёмка не будет сверять владельца марки."

pin_cur="$(env_file_value CZ_SIGNER_PIN)"
if [[ -n "$pin_cur" ]]; then pin_shown="задан, Enter — оставить"; else pin_shown="пусто — без пароля"; fi
read -rsp "  Пароль копии ключа [$pin_shown]: " pin; printf '\n'
pin="${pin:-$pin_cur}"
# Пароль пишется в одинарных кавычках: так systemd берёт его как есть, без разбора $ и \.
[[ "$pin" != *"'"* ]] || die "пароль с одинарной кавычкой не поддерживается — смените пароль копии ключа."

# --- 2. Файлы настроек ------------------------------------------------------------------
env_out="$(cz_signer_env)"
( umask 077
  printf '# Подписант Честного знака (CZ-02). Пишет deploy/cz-setup.sh; секрет — не в git, не в бэкапах.\n'
  printf 'CZ_SIGNER_THUMB=%s\n' "$thumb"
  printf "CZ_SIGNER_PIN='%s'\n" "$pin"
) > "$env_out.new"
chown root:root "$env_out.new"; chmod 600 "$env_out.new"; mv -f "$env_out.new" "$env_out"
log "Отпечаток и пароль записаны в $env_out (root, 600)."

set_env CZ_SIGNER_USER "$cz_user"
set_env CZ_OWNER_INN "$owner_inn"
set_env CZ_SIGNER_SOCKET "$CZ_SOCKET"

# --- 3. Служба ---------------------------------------------------------------------------
log "Юнит, группа сокета и бинарь подписанта…"
install_systemd_units
cz_signer_deploy || die "бинарь подписанта не установлен — образ бэкенда без cz-signer? Сначала обновите сервер (пункт 2)."
# Перезапуск всегда: отпечаток или пароль могли смениться, а служба читает их на старте.
systemctl restart "$CZ_SIGNER_UNIT"
for _ in $(seq 1 10); do [[ -S "$CZ_SOCKET" ]] && break; sleep 1; done
[[ -S "$CZ_SOCKET" ]] || die "служба не открыла сокет — смотрите: journalctl -u $CZ_SIGNER_UNIT -n 30"

# --- 4. Backend с сокетом -----------------------------------------------------------------
# Всегда перезапуск, а не только `up -d`: при повторной настройке окружение бэкенда не
# меняется, контейнер не пересоздаётся, и он сидел бы в паузе после прошлых неудачных входов
# (найдено при выкатке CZ-02: первый запуск был с неверным паролем копии).
log "Перезапускаю backend с сокетом подписанта…"
compose up -d --force-recreate backend
health_check || die "backend не поднялся после пересоздания — смотрите: docker compose … logs backend"

# --- 5. Проверка ---------------------------------------------------------------------------
cz_test
printf '\n'
log "Готово. Проверить позже: sudo bash deploy/cz-setup.sh --test (пункт 19 в craft.sh)."
