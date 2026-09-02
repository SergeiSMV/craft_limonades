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
    kv "копия:" "${C_BAD}не настроена${C_OFF} — дампы только на диске сервера, см. пункт 8"
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

# act_setup_backup — пошаговая настройка шифрования и внешней копии.
# Без неё меню только констатировало «внешняя копия не настроена», а дальше администратор
# оставался наедине с nano: сгенерировать фразу, не забыть унести её с сервера, выбрать
# транспорт, проверить, что копия реально доехала. Это и есть шаги, которые чаще всего
# откладывают, — поэтому они собраны здесь и заканчиваются проверкой.
act_setup_backup() {
  if ! have_env; then
    printf '  %s нет — сначала установка (пункт 1).\n' "$ENV_FILE"; return
  fi
  if [[ ! -w "$ENV_FILE" ]]; then
    printf '  %sНет прав на запись в %s. Перезапустите: sudo bash deploy/craft.sh%s\n' \
      "$C_BAD" "$ENV_FILE" "$C_OFF"; return
  fi

  printf '%s— Шаг 1 из 3: шифрование дампов —%s\n' "$C_HEAD" "$C_OFF"
  local pass; pass="$(get_env BACKUP_PASSPHRASE)"
  if [[ -n "$pass" ]]; then
    printf '  Парольная фраза уже задана. Менять её нельзя без последствий:\n'
    printf '  %sуже снятые дампы зашифрованы старой фразой и станут нечитаемыми.%s\n' "$C_WARN" "$C_OFF"
    if ask_yes "Всё равно сгенерировать новую?"; then
      pass=""
    else
      printf '  оставляю прежнюю\n'
    fi
  fi
  if [[ -z "$pass" ]]; then
    pass="$(openssl rand -base64 32)"
    set_env BACKUP_PASSPHRASE "$pass" || { printf '  %sне удалось записать в %s%s\n' "$C_BAD" "$ENV_FILE" "$C_OFF"; return; }
    printf '\n  %sФраза записана в .env.prod. ВОТ ОНА — другого раза не будет:%s\n\n' "$C_WARN" "$C_OFF"
    printf '      %s%s%s\n\n' "$C_OK" "$pass" "$C_OFF"
    printf '  %sСохраните её ВНЕ сервера — в менеджер паролей.%s\n' "$C_WARN" "$C_OFF"
    printf '  .env.prod живёт только здесь: погибнет диск — внешняя копия останется\n'
    printf '  нечитаемой, то есть внешней копии фактически нет.\n\n'
    local ack
    read -rp "$(printf 'Наберите СОХРАНИЛ, чтобы продолжить: ')" ack
    if [[ "$ack" != "СОХРАНИЛ" ]]; then
      printf '  %sНе подтверждено. Фраза в .env.prod уже записана — сохраните её сейчас же.%s\n' "$C_BAD" "$C_OFF"
      return
    fi
  fi

  printf '\n%s— Шаг 2 из 3: куда уезжает копия —%s\n' "$C_HEAD" "$C_OFF"
  printf '  %sВ дампе персональные данные сотрудников — вынос за пределы склада%s\n' "$C_DIM" "$C_OFF"
  printf '  %sсогласуйте с заказчиком.%s\n\n' "$C_DIM" "$C_OFF"
  printf '   1) внешний диск или каталог на этом сервере\n'
  printf '   2) второй хост в локальной сети (rsync по SSH)\n'
  printf '   3) облако, в том числе Яндекс.Диск (rclone)\n'
  printf '   0) пропустить\n\n'
  local k dest
  read -rp "$(printf 'Вариант: ')" k
  case "$k" in
    1) read -rp "Путь (например /mnt/craft-backup): " dest
       [[ -z "$dest" ]] && { printf '  пусто — пропускаю\n'; return; }
       if [[ ! -d "$dest" ]]; then
         ask_yes "Каталога нет. Создать $dest?" && mkdir -p "$dest" || { printf '  пропускаю\n'; return; }
       fi
       mountpoint -q "$dest" 2>/dev/null || printf '  %sЭто не точка монтирования. Каталог на системном диске от отказа диска не спасает.%s\n' "$C_WARN" "$C_OFF"
       set_env OFFSITE_DEST "$dest" ;;
    2) read -rp "Назначение (user@host:/path): " dest
       [[ -z "$dest" ]] && { printf '  пусто — пропускаю\n'; return; }
       local key; read -rp "Путь к SSH-ключу (Enter — ключ по умолчанию): " key
       local -a ssh_id=(); [[ -n "$key" ]] && ssh_id=(-i "$key")
       printf '  Проверяю доступ…\n'
       if ssh -o BatchMode=yes -o ConnectTimeout=5 ${ssh_id[@]+"${ssh_id[@]}"} "${dest%%:*}" true 2>/dev/null; then
         printf '  %sSSH отвечает.%s\n' "$C_OK" "$C_OFF"
       else
         printf '  %sSSH не отвечает без пароля — заведите ключ, иначе ночной таймер не пройдёт.%s\n' "$C_WARN" "$C_OFF"
       fi
       set_env OFFSITE_DEST "$dest"; [[ -n "$key" ]] && set_env OFFSITE_SSH_KEY "$key" ;;
    3) if ! command -v rclone >/dev/null 2>&1; then
         printf '  %srclone не установлен.%s Поставьте и заведите remote:\n' "$C_BAD" "$C_OFF"
         printf '    curl https://rclone.org/install.sh | sudo bash\n    rclone config\n'
         return
       fi
       printf '  Доступные remote: %s\n' "$(rclone listremotes 2>/dev/null | tr '\n' ' ')"
       read -rp "Назначение (например yandex:craft-wms-backups): " dest
       [[ -z "$dest" ]] && { printf '  пусто — пропускаю\n'; return; }
       rclone lsd "${dest%%:*}:" >/dev/null 2>&1 \
         && printf '  %sremote отвечает.%s\n' "$C_OK" "$C_OFF" \
         || printf '  %sremote не отвечает — проверьте rclone config.%s\n' "$C_WARN" "$C_OFF"
       set_env OFFSITE_RCLONE_REMOTE "$dest" ;;
    *) printf '  пропускаю\n'; return ;;
  esac

  printf '\n%s— Шаг 3 из 3: контрольный прогон —%s\n' "$C_HEAD" "$C_OFF"
  ask_yes "Снять бэкап сейчас и проверить, что копия доехала?" || return
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
  item 4 "Статус: контейнеры и таймеры"
  item 5 "Логи backend"
  item 6 "Проверить /health и /ready"

  section "Бэкапы"
  item 7  "Список бэкапов и внешней копии"
  item 8  "Настроить шифрование и внешнюю копию" "пошагово"
  item 9  "Сделать бэкап сейчас"
  item 10 "Проверить восстановимость дампа" "во временной базе, прод не трогает"
  item 11 "Восстановить из дампа" "⚠ замещает базу"

  section "Конфигурация"
  item 12 "Показать .env.prod" "секреты скрыты"
  item 13 "Редактировать .env.prod"

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
      4)  act_status;         pause ;;
      5)  act_logs;           pause ;;
      6)  bind="$(have_env && get_env BACKEND_BIND)"; bind="${bind:-127.0.0.1:8080}"
          printf '  /health → %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$bind/health" 2>/dev/null || echo "нет ответа")"
          printf '  /ready  → %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$bind/ready"  2>/dev/null || echo "нет ответа")"
          pause ;;
      7)  act_backup_list;    pause ;;
      8)  act_setup_backup;   pause ;;
      9)  run "$DEPLOY_DIR/pg-backup.sh"; pause ;;
      10) run "$DEPLOY_DIR/pg-restore.sh" --check; pause ;;
      11) act_restore;        pause ;;
      12) act_show_config;    pause ;;
      13) act_edit_config ;;
      0|q|Q) printf 'Пока.\n'; exit 0 ;;
      "") ;;
      *)  printf '  %sНет такого пункта: %s%s\n' "$C_BAD" "$choice" "$C_OFF"; pause ;;
    esac
  done
}

main "$@"
