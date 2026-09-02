#!/usr/bin/env bash
# Craft WMS · панель управления сервером. Единственный файл, который нужно запускать
# на сервере: и на новом (установка с нуля), и на работающем (обновление, бэкапы, логи).
# Остальные скрипты деплоя — install/update/pg-backup/pg-restore — вызываются отсюда.
#
# Запуск:  sudo bash deploy/craft.sh
#
# Почему обёртка. Раньше администратору приходилось помнить пять скриптов и их ключи
# (`pg-restore.sh --check` против боевого режима, `SELF_UPDATE=false`, куда смотрит BACKUP_DIR).
# Ошибка в выборе скрипта на проде стоит дорого — `pg-restore.sh` без `--check` замещает базу.
# Меню закрывает выбор списком и показывает состояние до того, как что-то запускать.
set -uo pipefail   # без -e: меню обязано переживать неудачу отдельного пункта и вернуться в список
SCRIPT_NAME=craft
# Путь к _lib.sh вычисляется в рантайме — статический анализатор его не проходит,
# и без подсказки ниже SCRIPT_NAME считается неиспользуемым (SC2034).
# Строка с директивой должна содержать только её: текст после пути ломает разбор.
# shellcheck source=deploy/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# --- Палитра ---
C_HEAD=$'\033[1;35m'; C_ITEM=$'\033[0;36m'; C_NUM=$'\033[1;32m'
C_OK=$'\033[1;32m';   C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'
C_DIM=$'\033[2m';     C_OFF=$'\033[0m'

BACKUP_DIR="${BACKUP_DIR:-$(cd "$REPO_ROOT/.." 2>/dev/null && pwd)/backups}"
TIMERS=(craft-wms-update craft-wms-backup craft-wms-restore-check)

# ───────────────────────── Вспомогательное ─────────────────────────

# rule СИМВОЛ — горизонтальная линия во всю ширину заголовка.
rule() { printf '%s%s%s\n' "$C_HEAD" "$(printf '=%.0s' {1..64})" "$C_OFF"; }

# strlen СТРОКА — длина в СИМВОЛАХ, не в байтах.
# `${#s}` меряет в единицах текущей локали: под UTF-8 это символы, а под C — байты,
# и тогда кириллические подписи разъезжаются вдвое. Локаль на сервере непредсказуема,
# поэтому считаем детерминированно: фиксируем LC_ALL=C (то есть байты) и выкидываем
# продолжающие байты UTF-8 (0x80–0xBF) — остаётся ровно один байт на символ.
strlen() {
  local LC_ALL=C s="$1"
  s="${s//[$'\x80'-$'\xbf']/}"
  printf '%s' "${#s}"
}

# section ЗАГОЛОВОК — подпись раздела меню с добивкой «=» до общей ширины.
section() {
  local t="$1" pad
  pad=$(( 59 - $(strlen "$t") ))
  (( pad < 0 )) && pad=0
  printf '\n%s=== %s %s%s\n' "$C_HEAD" "$t" "$(printf '=%.0s' $(seq 1 $pad))" "$C_OFF"
}

# kv ПОДПИСЬ ЗНАЧЕНИЕ — строка сводки с выравниванием по СИМВОЛАМ.
# `printf %-10s` добивает по байтам, поэтому кириллические подписи разной длины
# («домен:» и «/ready:») разъезжались бы; ширину считаем через strlen.
kv() {
  local label="$1" pad
  pad=$(( 9 - $(strlen "$label") ))
  (( pad < 0 )) && pad=0
  printf '  %s%*s %b\n' "$label" "$pad" "" "$2"
}

# item НОМЕР ТЕКСТ [ПОМЕТКА] — строка пункта меню.
item() { printf ' %s%2s)%s %s%s%s%s\n' "$C_NUM" "$1" "$C_OFF" "$C_ITEM" "$2" "${3:+  $C_DIM$3$C_OFF}" "$C_OFF"; }

pause() { printf '\n%sEnter — назад в меню%s' "$C_DIM" "$C_OFF"; read -r _; }

# ask_yes ВОПРОС — подтверждение разрушающего действия. Пустой ответ = «нет».
ask_yes() {
  local a
  read -rp "$(printf '%s%s [y/N]: %s' "$C_WARN" "$1" "$C_OFF")" a
  [[ "$a" == [yY] ]]
}

# run СКРИПТ [АРГ…] — запуск скрипта деплоя как есть, без повышения прав.
# Бэкап и восстановление root НЕ требуют: им нужен доступ к docker, а он может быть
# у пользователя по членству в группе `docker`. Гнать их через sudo без нужды — лишнее
# приглашение вводить пароль там, где он не требуется.
run() { bash "$@"; }

# need_root СКРИПТ [АРГ…] — запуск скрипта деплоя с правами root.
# Нужен только установке и обновлению: они ставят пакеты через apt и пишут юниты
# в /etc/systemd/system. Вместо невнятного отказа внутри скрипта поднимаем права здесь.
need_root() {
  if [[ $EUID -eq 0 ]]; then
    bash "$@"
  elif command -v sudo >/dev/null 2>&1; then
    printf '%sТребуются права root — запускаю через sudo.%s\n' "$C_DIM" "$C_OFF"
    sudo bash "$@"
  else
    printf '%sНужен root, а sudo нет. Перезапустите: sudo bash deploy/craft.sh%s\n' "$C_BAD" "$C_OFF"
    return 1
  fi
}

# have_env — .env.prod на месте и заполнен (не шаблон).
have_env() { [[ -f "$ENV_FILE" ]]; }

# docker_ok — docker установлен и отвечает.
docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# ───────────────────────── Состояние ─────────────────────────

# state_line — шапка со сводкой: что установлено, чем живёт сервер прямо сейчас.
# Показывается перед меню, чтобы не выбирать пункт вслепую.
state_line() {
  local domain="—" image="—" stack="${C_BAD}не запущен${C_OFF}" ready="${C_BAD}нет${C_OFF}"

  if have_env; then
    domain="$(get_env DEPLOY_DOMAIN)"; domain="${domain:-—}"
    image="$(get_env BACKEND_IMAGE)";  image="${image##*/}"; image="${image:-—}"
  else
    printf '%s  .env.prod не найден (%s)%s\n' "$C_WARN" "$ENV_FILE" "$C_OFF"
    printf '%s  Новый сервер: начните с пункта 1 — установка.%s\n' "$C_DIM" "$C_OFF"
    return 0
  fi

  if docker_ok; then
    local up
    up="$(compose ps --status running --format '{{.Service}}' 2>/dev/null | tr '\n' ' ')"
    [[ -n "${up// /}" ]] && stack="${C_OK}${up% }${C_OFF}"
  else
    stack="${C_WARN}docker недоступен${C_OFF}"
  fi

  local bind; bind="$(get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
  curl -fsS --max-time 3 -o /dev/null "http://$bind/ready" 2>/dev/null && ready="${C_OK}200${C_OFF}"

  kv "домен:"  "$domain"
  kv "образ:"  "$image"
  kv "стек:"   "$stack"
  kv "/ready:" "$ready"

  # Куда уезжает копия и шифруется ли она. Раньше это было видно только внутри пункта 7,
  # то есть проблему «дампы лежат на одном диске с базой» надо было пойти и поискать.
  local enc off
  [[ -n "$(get_env BACKUP_PASSPHRASE)" ]] && enc="${C_OK}шифр.${C_OFF}" || enc="${C_BAD}БЕЗ шифрования${C_OFF}"
  off="$(get_env OFFSITE_DEST)"; [[ -z "$off" ]] && off="$(get_env OFFSITE_RCLONE_REMOTE)"
  if [[ -n "$off" ]]; then
    kv "копия:" "$off  ($enc)"
  else
    kv "копия:" "${C_BAD}не настроена${C_OFF} — дампы только на диске сервера, см. пункт «Настроить бэкапы»"
  fi

  # Последний дамп — самый частый вопрос «а бэкап-то есть?».
  local last
  last="$(ls -1t "$BACKUP_DIR"/craft_wms-*.sql.gz* 2>/dev/null | head -1)"
  if [[ -n "$last" ]]; then
    kv "бэкап:" "$(date -r "$last" '+%Y-%m-%d %H:%M')  $(basename "$last")"
  else
    kv "бэкап:" "${C_WARN}нет${C_OFF}"
  fi
}

# ───────────────────────── Действия ─────────────────────────

act_status() {
  printf '%s— Контейнеры —%s\n' "$C_HEAD" "$C_OFF"
  if docker_ok; then compose ps 2>&1 | sed 's/^/  /'; else printf '  docker недоступен\n'; fi

  printf '\n%s— Таймеры —%s\n' "$C_HEAD" "$C_OFF"
  if command -v systemctl >/dev/null 2>&1; then
    local t st
    for t in "${TIMERS[@]}"; do
      st="$(systemctl is-active "$t.timer" 2>/dev/null || echo "нет")"
      printf '  %-28s %s\n' "$t.timer" "$st"
    done
    printf '\n'
    systemctl list-timers 'craft-wms-*' --no-pager 2>/dev/null | sed 's/^/  /'
  else
    printf '  systemd недоступен (не Linux-сервер?)\n'
  fi
}

act_logs() {
  if ! docker_ok; then printf '  docker недоступен\n'; return; fi
  printf '%s— Последние 60 строк backend —%s\n' "$C_HEAD" "$C_OFF"
  compose logs --tail 60 backend 2>&1 | sed 's/^/  /'
}

act_update_history() {
  printf '%s— Прогоны авто-обновления —%s\n' "$C_HEAD" "$C_OFF"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u craft-wms-update --no-pager -n 40 2>/dev/null | sed 's/^/  /'
  else
    printf '  journalctl недоступен\n'
  fi
  printf '\n%s— Последние коммиты в клоне —%s\n' "$C_HEAD" "$C_OFF"
  git -C "$REPO_ROOT" -c safe.directory="$REPO_ROOT" log --oneline -8 2>/dev/null | sed 's/^/  /' \
    || printf '  git-история недоступна\n'
}

act_backup_list() {
  printf '%s— Локальные дампы (%s) —%s\n' "$C_HEAD" "$BACKUP_DIR" "$C_OFF"
  if [[ -d "$BACKUP_DIR" ]]; then
    ls -lht "$BACKUP_DIR" 2>/dev/null | head -12 | sed 's/^/  /'
  else
    printf '  каталога нет — бэкап ещё не делался\n'
  fi

  local dest remote
  dest="$(have_env && get_env OFFSITE_DEST)"
  remote="$(have_env && get_env OFFSITE_RCLONE_REMOTE)"

  if [[ -z "$dest$remote" ]]; then
    printf '\n  %sВнешняя копия не настроена — дампы только на диске сервера.%s\n' "$C_WARN" "$C_OFF"
    return
  fi
  if [[ -n "$dest" ]]; then
    printf '\n%s— Внешняя копия (rsync): %s —%s\n' "$C_HEAD" "$dest" "$C_OFF"
    if [[ "$dest" == *:* ]]; then
      printf '  удалённый хост — проверка вручную: rsync --list-only %s/\n' "$dest"
    elif [[ -d "$dest" ]]; then
      ls -lht "$dest" 2>/dev/null | head -8 | sed 's/^/  /'
    else
      printf '  %sкаталог недоступен (внешний диск не смонтирован?)%s\n' "$C_BAD" "$C_OFF"
    fi
  fi
  if [[ -n "$remote" ]]; then
    printf '\n%s— Внешняя копия (rclone): %s —%s\n' "$C_HEAD" "$remote" "$C_OFF"
    if command -v rclone >/dev/null 2>&1; then
      rclone lsl "$remote" 2>&1 | tail -8 | sed 's/^/  /'
    else
      printf '  rclone не установлен\n'
    fi
  fi
}

# yandex_remote_name — имя rclone-remote, которое заводит мастер. Фиксированное:
# пользователю не нужно его выдумывать, а скриптам — угадывать.
YA_REMOTE=craft-yandex
YA_FOLDER=craft-wms-backups

# setup_yandex — проводка по настройке Яндекс.Диска целиком, от установки rclone
# до проверки, что папка создалась. Рассчитано на человека, который про rclone не слышал.
#
# Почему именно так. У Яндекс.Диска нет ни SSH, ни rsync — только API, и работать с ним
# умеет rclone. Доступ выдаётся по OAuth, а OAuth требует браузера, которого на сервере нет.
# Поэтому единственный рабочий путь: получить токен на своей машине, где браузер есть,
# и перенести его сюда строкой. `rclone config` в интерактивном режиме здесь же спросил бы
# два десятка вопросов — вместо этого создаём remote одной командой из готового токена.
setup_yandex() {
  # 1. rclone
  if ! command -v rclone >/dev/null 2>&1; then
    printf '  rclone не установлен — он нужен для работы с Яндекс.Диском.\n'
    ask_yes "Установить rclone сейчас?" || { printf '  без rclone Яндекс.Диск не настроить\n'; return 1; }
    printf '  Ставлю (скрипт с rclone.org)…\n'
    if [[ $EUID -eq 0 ]]; then curl -fsSL https://rclone.org/install.sh | bash
    else curl -fsSL https://rclone.org/install.sh | sudo bash; fi
    command -v rclone >/dev/null 2>&1 || { printf '  %sустановить не удалось%s\n' "$C_BAD" "$C_OFF"; return 1; }
  fi
  printf '  %srclone: %s%s\n' "$C_OK" "$(rclone version 2>/dev/null | head -1)" "$C_OFF"

  # 2. Чей это конфиг. Ночной бэкап запускает systemd от root, поэтому remote обязан быть
  # в конфиге root. Настроенный из-под обычного пользователя remote таймер не увидит.
  if [[ $EUID -ne 0 ]]; then
    printf '\n  %sВы не root.%s Бэкап по расписанию запускается от root, и remote нужен\n' "$C_WARN" "$C_OFF"
    printf '  именно в его конфиге. Перезапустите: sudo bash deploy/craft.sh\n'
    ask_yes "Всё равно продолжить (настройка будет только для текущего пользователя)?" || return 1
  fi

  # 3. Готовый remote уже может быть.
  if rclone listremotes 2>/dev/null | grep -qx "$YA_REMOTE:"; then
    printf '\n  Remote «%s» уже настроен. Проверяю доступ…\n' "$YA_REMOTE"
    if rclone lsd "$YA_REMOTE:" >/dev/null 2>&1; then
      printf '  %sЯндекс.Диск отвечает — заново настраивать не нужно.%s\n' "$C_OK" "$C_OFF"
      ask_yes "Всё-таки перенастроить (нужен новый токен)?" || { ya_finish; return $?; }
    else
      printf '  %sНе отвечает — токен просрочен или отозван, нужен новый.%s\n' "$C_WARN" "$C_OFF"
    fi
  fi

  # 4. Токен. Единственный шаг, который нельзя сделать на сервере.
  printf '\n%s  ── Токен доступа к Яндекс.Диску ──%s\n' "$C_HEAD" "$C_OFF"
  printf '  На сервере нет браузера, а Яндекс выдаёт доступ только через него.\n'
  printf '  Поэтому токен получаем на ВАШЕМ компьютере и переносим сюда.\n\n'
  printf '  %s1.%s На своём компьютере установите rclone: %shttps://rclone.org/downloads/%s\n' "$C_NUM" "$C_OFF" "$C_DIM" "$C_OFF"
  printf '       macOS:  brew install rclone\n'
  printf '       Windows: скачайте архив по ссылке выше и распакуйте\n\n'
  printf '  %s2.%s Там же в терминале выполните:\n\n' "$C_NUM" "$C_OFF"
  printf '         %srclone authorize "yandex"%s\n\n' "$C_OK" "$C_OFF"
  printf '  %s3.%s Откроется браузер — войдите в Яндекс и нажмите «Разрешить».\n\n' "$C_NUM" "$C_OFF"
  printf '  %s4.%s В терминале появится строка вида\n' "$C_NUM" "$C_OFF"
  printf '         %s{"access_token":"y0_AgAA…","token_type":"bearer","refresh_token":"…"}%s\n' "$C_DIM" "$C_OFF"
  printf '       Скопируйте её %sцеликом, вместе с фигурными скобками%s.\n\n' "$C_WARN" "$C_OFF"

  local token
  read -rp "$(printf 'Вставьте токен сюда (Enter без текста — отмена): ')" token
  [[ -z "$token" ]] && { printf '  отменено\n'; return 1; }
  if [[ "$token" != *access_token* ]]; then
    printf '  %sЭто не похоже на токен — в нём должно быть "access_token".%s\n' "$C_BAD" "$C_OFF"
    printf '  Скопируйте строку целиком, начиная с «{».\n'
    return 1
  fi

  # 5. Создаём remote одной командой — интерактивный `rclone config` тут не нужен.
  printf '\n  Создаю подключение «%s»…\n' "$YA_REMOTE"
  rclone config delete "$YA_REMOTE" >/dev/null 2>&1
  # --non-interactive обязателен: без него rclone, даже получив готовый токен, пытается
  # поднять локальный веб-сервер под OAuth-редирект и ждать браузера. На сервере браузера
  # нет, и команда просто повисла бы. Код возврата тут неинформативен (rclone печатает
  # JSON-состояние диалога), поэтому успех проверяем следующим шагом — реальным обращением.
  rclone config create "$YA_REMOTE" yandex token "$token" --non-interactive >/dev/null 2>&1
  printf '  Конфигурация rclone: %s\n' "$(rclone config file 2>/dev/null | tail -1)"

  # 6. Проверяем, что доступ реальный, а не только записан в конфиг.
  printf '  Проверяю доступ к диску…\n'
  if ! rclone lsd "$YA_REMOTE:" >/dev/null 2>&1; then
    printf '  %sЯндекс.Диск не отвечает.%s Токен просрочен или скопирован не полностью.\n' "$C_BAD" "$C_OFF"
    printf '  Повторите шаг с `rclone authorize "yandex"` и вставьте строку целиком.\n'
    # Нерабочее подключение убираем: иначе оно осталось бы в конфиге и при следующем заходе
    # мастер счёл бы Яндекс.Диск уже настроенным.
    rclone config delete "$YA_REMOTE" >/dev/null 2>&1
    return 1
  fi
  printf '  %sДоступ есть.%s\n' "$C_OK" "$C_OFF"
  ya_finish
}

# ya_finish — папка на диске и запись назначения в .env.prod.
ya_finish() {
  rclone mkdir "$YA_REMOTE:$YA_FOLDER" >/dev/null 2>&1
  if rclone lsd "$YA_REMOTE:" 2>/dev/null | grep -q "$YA_FOLDER"; then
    printf '  %sПапка «%s» на диске готова.%s\n' "$C_OK" "$YA_FOLDER" "$C_OFF"
  else
    printf '  %sПапку создать не удалось — проверьте место на диске.%s\n' "$C_WARN" "$C_OFF"
  fi
  set_env OFFSITE_RCLONE_REMOTE "$YA_REMOTE:$YA_FOLDER"
  printf '  Назначение записано: %s:%s\n' "$YA_REMOTE" "$YA_FOLDER"
}

# ok / no / warn ТЕКСТ [ЧТО ДЕЛАТЬ] — строка чек-листа.
# Для каждого «не готово» сразу пишем, каким пунктом меню это чинится: человек, который
# видит систему впервые, не должен догадываться сам.
ck_ok()   { printf '  %s✅%s %s\n' "$C_OK" "$C_OFF" "$1"; }
ck_warn() { printf '  %s⚠%s  %s%s\n' "$C_WARN" "$C_OFF" "$1" "${2:+  → $2}"; }
ck_bad()  { printf '  %s❌%s %s%s\n' "$C_BAD" "$C_OFF" "$1" "${2:+  → $2}"; }

# act_check — «что уже готово, а что ещё нужно сделать».
# Проверяет всю цепочку от настроек до внешней копии и по каждому пункту говорит,
# каким действием он закрывается. Это ответ на вопрос «я всё настроил или нет?».
act_check() {
  printf '%s— Готовность прод-сервера —%s\n\n' "$C_HEAD" "$C_OFF"

  # 1. Настройки
  if ! have_env; then
    ck_bad "файла настроек нет ($ENV_FILE)" "пункт «Установить / переустановить»"
    return
  fi
  ck_ok "файл настроек на месте"
  local tpl
  tpl="$(grep -cE '(CHANGE_ME|example\.ru)' "$ENV_FILE" 2>/dev/null || echo 0)"
  (( tpl > 0 )) && ck_bad "в настройках осталось $tpl шаблонных значений" "пункт «Редактировать настройки»" \
                || ck_ok "шаблонных значений не осталось"

  # 2. Домен и сеть
  local domain; domain="$(get_env DEPLOY_DOMAIN)"
  if command -v getent >/dev/null 2>&1 && getent hosts "$domain" >/dev/null 2>&1; then
    ck_ok "домен $domain резолвится"
  else
    ck_warn "домен $domain не резолвится" "проверьте A-запись и проброс портов 80/443"
  fi

  # 3. Docker и стек
  if docker_ok; then
    ck_ok "docker работает"
    local up; up="$(compose ps --status running --format '{{.Service}}' 2>/dev/null | tr '\n' ' ')"
    [[ "$up" == *db* ]]      && ck_ok "контейнер БД запущен"      || ck_bad "контейнер БД не запущен" "пункты «Установить» или «Обновить сейчас»"
    [[ "$up" == *backend* ]] && ck_ok "контейнер backend запущен" || ck_bad "backend не запущен" "«Обновить сейчас», затем «Логи backend»"
  else
    ck_bad "docker недоступен" "пункт «Установить / переустановить»"
    return
  fi

  # 4. Схема и админ — без них приложение не пустит внутрь.
  local cid; cid="$(compose ps -q db 2>/dev/null)"
  if [[ -n "$cid" ]]; then
    local user db ver dirty users
    user="$(get_env POSTGRES_USER)"; db="$(get_env POSTGRES_DB)"
    ver="$(docker exec -i "$cid" psql -U "$user" -d "$db" -tAc 'SELECT version FROM schema_migrations LIMIT 1' 2>/dev/null | tr -d ' ')"
    dirty="$(docker exec -i "$cid" psql -U "$user" -d "$db" -tAc 'SELECT dirty FROM schema_migrations LIMIT 1' 2>/dev/null | tr -d ' ')"
    users="$(docker exec -i "$cid" psql -U "$user" -d "$db" -tAc 'SELECT count(*) FROM users' 2>/dev/null | tr -d ' ')"
    if [[ -z "$ver" ]]; then ck_bad "миграции не применены" "пункт «Обновить сейчас»"
    elif [[ "$dirty" == "t" ]]; then ck_bad "миграции в состоянии dirty" "разбирайтесь до всего остального"
    else ck_ok "схема БД: версия $ver"; fi
    [[ "${users:-0}" -gt 0 ]] && ck_ok "пользователи заведены ($users)" || ck_bad "нет ни одного пользователя" "пункт «Установить» заводит админа"
  fi

  # 5. Пробы
  local bind; bind="$(get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
  curl -fsS --max-time 5 -o /dev/null "http://$bind/ready" 2>/dev/null \
    && ck_ok "/ready отвечает 200" || ck_bad "/ready не отвечает" "пункт «Логи backend»"
  if [[ -n "$domain" ]]; then
    curl -fsS --max-time 8 -o /dev/null "https://$domain/health" 2>/dev/null \
      && ck_ok "HTTPS снаружи работает" \
      || ck_warn "снаружи по HTTPS не отвечает" "сертификат, DNS или проброс портов"
  fi

  # 6. Таймеры
  if command -v systemctl >/dev/null 2>&1; then
    local t
    for t in "${TIMERS[@]}"; do
      [[ "$(systemctl is-enabled "$t.timer" 2>/dev/null)" == "enabled" ]] \
        && ck_ok "таймер $t включён" || ck_warn "таймер $t не включён" "пункты «Установить» или «Обновить сейчас»"
    done
  else
    ck_warn "systemd недоступен — расписание не проверить"
  fi

  # 7. Бэкапы — то, ради чего всё и затевалось.
  [[ -n "$(get_env BACKUP_PASSPHRASE)" ]] \
    && ck_ok "шифрование дампов настроено" \
    || ck_bad "дампы не шифруются" "пункт «Настроить бэкапы»"
  local off; off="$(get_env OFFSITE_RCLONE_REMOTE)"; [[ -z "$off" ]] && off="$(get_env OFFSITE_DEST)"
  if [[ -n "$off" ]]; then
    ck_ok "внешняя копия настроена: $off"
  else
    ck_bad "внешней копии нет — дампы на одном диске с базой" "пункт «Настроить бэкапы»"
  fi

  local last; last="$(ls -1t "$BACKUP_DIR"/craft_wms-*.sql.gz* 2>/dev/null | head -1)"
  if [[ -z "$last" ]]; then
    ck_bad "бэкапов ещё не было" "пункт «Сделать бэкап сейчас»"
  else
    local age
    age=$(( ( $(date +%s) - $(date -r "$last" +%s) ) / 86400 ))
    (( age <= 1 )) && ck_ok "последний бэкап: $(date -r "$last" '+%Y-%m-%d %H:%M')" \
                   || ck_warn "последний бэкап $age дн. назад" "проверьте таймер: «Статус: контейнеры и таймеры»"
  fi

  printf '\n  %sОтдельно, автоматом не проверяется:%s парольная фраза должна быть\n' "$C_WARN" "$C_OFF"
  printf '  сохранена ВНЕ сервера. Иначе внешняя копия нечитаема и смысла в ней нет.\n'
}

# act_setup_backup — пошаговая настройка бэкапа: шифрование, место хранения, контрольный прогон.
# Без неё меню только констатировало «внешняя копия не настроена», а дальше администратор
# оставался наедине с nano: сгенерировать фразу, не забыть унести её с сервера, выбрать
# место, проверить, что копия реально доехала. Это и есть шаги, которые чаще всего
# откладывают, — поэтому они собраны здесь и заканчиваются проверкой.
act_setup_backup() {
  if ! have_env; then
    printf '  %s нет — сначала пункт «Установить / переустановить».\n' "$ENV_FILE"; return
  fi
  if [[ ! -w "$ENV_FILE" ]]; then
    printf '  %sНет прав на запись в %s. Перезапустите: sudo bash deploy/craft.sh%s\n' \
      "$C_BAD" "$ENV_FILE" "$C_OFF"; return
  fi

  # ── Шаг 1: шифрование ──
  printf '%s— Шаг 1 из 3: шифрование дампов —%s\n' "$C_HEAD" "$C_OFF"
  printf '  %sВ дампе ФИО сотрудников, логины и хеши паролей. За пределы сервера%s\n' "$C_DIM" "$C_OFF"
  printf '  %sтакой файл должен уезжать только зашифрованным.%s\n\n' "$C_DIM" "$C_OFF"
  local pass; pass="$(get_env BACKUP_PASSPHRASE)"
  if [[ -n "$pass" ]]; then
    printf '  Парольная фраза уже задана.\n'
    printf '  %sСмена сделает уже снятые дампы нечитаемыми — они зашифрованы старой.%s\n' "$C_WARN" "$C_OFF"
    if ask_yes "Всё равно сгенерировать новую?"; then pass=""; else printf '  оставляю прежнюю\n'; fi
  fi
  if [[ -z "$pass" ]]; then
    pass="$(openssl rand -base64 32)"
    set_env BACKUP_PASSPHRASE "$pass" || { printf '  %sне удалось записать в %s%s\n' "$C_BAD" "$ENV_FILE" "$C_OFF"; return; }
    printf '\n  %sФраза записана. ВОТ ОНА — показываю один раз:%s\n\n' "$C_WARN" "$C_OFF"
    printf '      %s%s%s\n\n' "$C_OK" "$pass" "$C_OFF"
    printf '  %sСохраните её ВНЕ сервера — в менеджер паролей.%s\n' "$C_WARN" "$C_OFF"
    printf '  Файл настроек живёт только здесь: погибнет диск — копия останется\n'
    printf '  нечитаемой, то есть внешней копии фактически нет.\n\n'
    local ack
    read -rp "$(printf 'Наберите СОХРАНИЛ, чтобы продолжить: ')" ack
    if [[ "$ack" != "СОХРАНИЛ" ]]; then
      printf '  %sНе подтверждено. Фраза уже записана в настройки — сохраните её сейчас же.%s\n' "$C_BAD" "$C_OFF"
      return
    fi
  fi

  # ── Шаг 2: где хранить ──
  printf '\n%s— Шаг 2 из 3: где хранить копии —%s\n' "$C_HEAD" "$C_OFF"
  printf '  Можно выбрать оба варианта.\n\n'
  printf '   %s1)%s На сервере — дамп всегда пишется сюда, это рабочая копия\n' "$C_NUM" "$C_OFF"
  printf '   %s2)%s На Яндекс.Диске — копия за пределами сервера\n' "$C_NUM" "$C_OFF"
  printf '   %s0)%s Ничего не менять\n\n' "$C_NUM" "$C_OFF"
  printf '  %sВ дампе персональные данные сотрудников — вынос за пределы склада%s\n' "$C_DIM" "$C_OFF"
  printf '  %sсогласуйте с заказчиком.%s\n\n' "$C_DIM" "$C_OFF"
  local pick
  read -rp "$(printf 'Номера через пробел (например: 1 2): ')" pick
  [[ "$pick" == *0* || -z "$pick" ]] && { printf '  ничего не меняю\n'; return; }

  if [[ "$pick" == *2* ]]; then
    setup_yandex || { printf '\n  %sЯндекс.Диск не настроен — копия останется только на сервере.%s\n' "$C_WARN" "$C_OFF"; }
  fi
  if [[ "$pick" != *2* && "$pick" == *1* ]]; then
    set_env OFFSITE_RCLONE_REMOTE ""
    printf '\n  %s⚠ Копии только на сервере.%s Дампы лежат на том же диске, что и база:\n' "$C_BAD" "$C_OFF"
    printf '  отказ диска, кража или шифровальщик уносят и базу, и все копии разом.\n'
    printf '  Вернуться к этому можно в любой момент — этот же пункт меню.\n'
  fi

  # ── Шаг 3: контрольный прогон ──
  printf '\n%s— Шаг 3 из 3: контрольный прогон —%s\n' "$C_HEAD" "$C_OFF"
  ask_yes "Снять бэкап сейчас и проверить, что всё работает?" || return
  run "$DEPLOY_DIR/pg-backup.sh" || { printf '  %sбэкап не прошёл — разберитесь по выводу выше%s\n' "$C_BAD" "$C_OFF"; return; }
  printf '\n'
  act_backup_list
}

act_show_config() {
  if ! have_env; then printf '  %s нет\n' "$ENV_FILE"; return; fi
  printf '%s— %s (значения секретов скрыты) —%s\n' "$C_HEAD" "$ENV_FILE" "$C_OFF"
  # Маскируем всё, что похоже на секрет: показать конфиг на общем экране — обычное дело,
  # а пароль БД и BACKUP_PASSPHRASE при этом светить незачем.
  sed -E 's/^([A-Z_]*(PASSWORD|SECRET|TOKEN|PASSPHRASE)[A-Z_]*)=.+$/\1=********/' "$ENV_FILE" \
    | sed 's/^/  /'
}

act_edit_config() {
  if ! have_env; then
    printf '  %s нет. Создайте из шаблона: cp infra/.env.prod.example %s\n' "$ENV_FILE" "$ENV_FILE"
    return
  fi
  "${EDITOR:-nano}" "$ENV_FILE"
}

act_restore() {
  printf '%s⚠ БОЕВОЕ ВОССТАНОВЛЕНИЕ замещает базу содержимым дампа.%s\n' "$C_BAD" "$C_OFF"
  printf '%sПеред этим прогоните пункт «проверить восстановимость».%s\n\n' "$C_DIM" "$C_OFF"
  act_backup_list
  printf '\n'
  local f
  read -rp "$(printf 'Файл дампа (Enter — самый свежий, пусто и Ctrl-C — отмена): ')" f
  ask_yes "Точно замещать базу?" || { printf '  отменено\n'; return; }
  if [[ -n "$f" ]]; then run "$DEPLOY_DIR/pg-restore.sh" "$f"
  else run "$DEPLOY_DIR/pg-restore.sh"; fi
}

# ───────────────────────── Меню ─────────────────────────

show_menu() {
  clear 2>/dev/null
  rule
  printf '%s        ⚙  Craft WMS · панель управления сервером%s\n' "$C_HEAD" "$C_OFF"
  rule
  state_line

  section "Установка и обновление"
  item 1 "Установить / переустановить" "install.sh, нужен root"
  item 2 "Обновить сейчас"             "update.sh"
  item 3 "История обновлений"          "journal + коммиты"

  section "Состояние"
  item 4 "Что готово, а что ещё нужно" "чек-лист по всему серверу"
  item 5 "Статус: контейнеры и таймеры"
  item 6 "Логи backend"
  item 7 "Проверить /health и /ready"

  section "Бэкапы"
  item 8  "Настроить бэкапы" "шифрование и где хранить, пошагово"
  item 9  "Список бэкапов и внешней копии"
  item 10 "Сделать бэкап сейчас"
  item 11 "Проверить восстановимость дампа" "во временной базе, прод не трогает"
  item 12 "Восстановить из дампа" "⚠ замещает базу"

  section "Конфигурация"
  item 13 "Показать настройки" "секреты скрыты"
  item 14 "Редактировать настройки"

  printf '\n'
  item 0 "Выйти"
  rule
}

main() {
  local choice bind
  while true; do
    show_menu
    printf '\n%s👉 Введи номер: %s' "$C_WARN" "$C_OFF"
    read -r choice || exit 0
    printf '\n'
    case "$choice" in
      1)  need_root "$DEPLOY_DIR/install.sh"; pause ;;
      2)  need_root "$DEPLOY_DIR/update.sh";  pause ;;
      3)  act_update_history; pause ;;
      4)  act_check;          pause ;;
      5)  act_status;         pause ;;
      6)  act_logs;           pause ;;
      7)  bind="$(have_env && get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
          printf '  /health → %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$bind/health" 2>/dev/null || echo "нет ответа")"
          printf '  /ready  → %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$bind/ready"  2>/dev/null || echo "нет ответа")"
          pause ;;
      8)  act_setup_backup;   pause ;;
      9)  act_backup_list;    pause ;;
      10) run "$DEPLOY_DIR/pg-backup.sh"; pause ;;
      11) run "$DEPLOY_DIR/pg-restore.sh" --check; pause ;;
      12) act_restore;        pause ;;
      13) act_show_config;    pause ;;
      14) act_edit_config ;;
      0|q|Q) printf 'Пока.\n'; exit 0 ;;
      "") ;;
      *)  printf '  %sНет такого пункта: %s%s\n' "$C_BAD" "$choice" "$C_OFF"; pause ;;
    esac
  done
}

main "$@"
