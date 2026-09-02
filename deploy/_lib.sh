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
  [[ -f "$ENV_FILE" ]] || die "нет файла $ENV_FILE — создайте его (шаблон: infra/.env.prod.example). См. docs/deploy/prod-deploy.md."
}

# get_env KEY — значение переменной из .env.prod.
# Срезает inline-комментарий (пробел + #) и хвостовые пробелы; значения с '#' без пробела не портит.
get_env() {
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
  v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')"
  printf '%s' "$v"
}

# set_env КЛЮЧ ЗНАЧЕНИЕ — идемпотентная запись переменной в .env.prod.
# Значение подставляется как есть, без sed: парольные фразы из `openssl rand -base64`
# содержат `/` и `+`, и в sed-выражении они ломали бы разделитель.
# Содержимое перезаписывается через `cat >`, а не подменой файла, — так сохраняются
# права и владелец: в .env.prod лежат секреты, и файл обычно 600 у root.
set_env() {
  local key="$1" val="$2" tmp line found=0
  tmp="$(mktemp)" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$val" >> "$tmp"; found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$ENV_FILE"
  [[ $found -eq 0 ]] && printf '%s=%s\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
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

# =====================================================================
#  Шифрование дампов и внешняя копия (ADHOC-01)
# =====================================================================

# Шифрование — парольной фразой из .env.prod (BACKUP_PASSPHRASE), инструмент openssl.
#
# Почему не age и не gpg. Оба тянут за собой файл-ключ, который надо где-то хранить и не
# потерять; в проекте, который ведёт один человек, потерянный ключ убивает бэкапы так же
# надёжно, как их отсутствие. Пароль — одна строка: её кладут в менеджер паролей рядом с
# остальными секретами проекта. Плюс `age -p` вообще неприменим: он читает фразу только с
# терминала и в systemd-таймере падает с «standard input is not a terminal».
#
# ⚠ Пароль обязан существовать ВНЕ сервера. .env.prod живёт только на сервере, и если он
# погибнет вместе с диском, внешняя копия останется нечитаемой — то есть внешней копии нет.
#
# openssl предустановлен, ключ выводится PBKDF2 (600000 итераций), пароль передаётся через
# окружение (-pass env:), а не аргументом: в -pass pass:… он был бы виден в списке процессов.
BACKUP_CIPHER_ARGS=(-aes-256-cbc -pbkdf2 -iter 600000)

# backup_passphrase — пароль из .env.prod или пусто, если шифрование не настроено.
backup_passphrase() { get_env BACKUP_PASSPHRASE; }

# encrypt_dump ИСХОДНИК ЦЕЛЬ — шифрует файл паролем из .env.prod.
# Шифруем именно ФАЙЛ, а не звено конвейера pg_dump|gzip|openssl: в конвейере отказ середины
# маскируется, а нам нужен ещё и незашифрованный дамп — на нём работает еженедельная
# проверка восстановимости.
encrypt_dump() {
  local src="$1" dst="$2"
  CRAFT_BACKUP_PASS="$(backup_passphrase)"; export CRAFT_BACKUP_PASS
  [[ -n "$CRAFT_BACKUP_PASS" ]] || die "encrypt_dump вызвана без BACKUP_PASSPHRASE."
  openssl enc "${BACKUP_CIPHER_ARGS[@]}" -salt -pass env:CRAFT_BACKUP_PASS \
    -in "$src" -out "$dst" || die "шифрование не прошло: $src"
  unset CRAFT_BACKUP_PASS
  [[ -s "$dst" ]] || die "шифрование дало пустой файл: $dst"
}

# decrypt_dump ИСХОДНИК ЦЕЛЬ — расшифровывает .enc обратно в .sql.gz.
# Неверный пароль openssl отдаёт кодом 1 (не сходится PKCS-паддинг); вторым рубежом идёт
# gzip -t в вызывающем коде — на случай, когда паддинг случайно сошёлся, а данные мусор.
decrypt_dump() {
  local src="$1" dst="$2"
  CRAFT_BACKUP_PASS="$(backup_passphrase)"; export CRAFT_BACKUP_PASS
  [[ -n "$CRAFT_BACKUP_PASS" ]] || die "файл $src зашифрован, а BACKUP_PASSPHRASE в $ENV_FILE не задан."
  openssl enc -d "${BACKUP_CIPHER_ARGS[@]}" -pass env:CRAFT_BACKUP_PASS \
    -in "$src" -out "$dst" 2>/dev/null || die "не удалось расшифровать $src — не тот BACKUP_PASSPHRASE?"
  unset CRAFT_BACKUP_PASS
  [[ -s "$dst" ]] || die "расшифровка дала пустой файл: $dst"
}

# ── Яндекс.Диск через WebDAV ────────────────────────────────────────────────
# Доступ выдаётся паролем приложения, а не OAuth-токеном. Причина практическая: OAuth
# требует браузера, которого на сервере нет, — пришлось бы получать токен на другой машине
# и переносить строкой. Пароль приложения заводится в веб-интерфейсе Яндекса с любого
# устройства и вводится здесь как обычный пароль.
#
# Подключение задаётся ПЕРЕМЕННЫМИ ОКРУЖЕНИЯ, а не файлом rclone.conf. Так единственным
# местом для секретов остаётся .env.prod (рядом с паролем БД и фразой шифрования), и не
# возникает вопроса, в чьём домашнем каталоге лежит конфиг: бэкап по расписанию запускает
# systemd от root, а меню человек может открыть и от себя.
YA_WEBDAV_URL="https://webdav.yandex.ru"

# yandex_configured — заданы ли логин и пароль приложения.
yandex_configured() {
  [[ -n "$(get_env YANDEX_LOGIN)" && -n "$(get_env YANDEX_WEBDAV_PASSWORD)" ]]
}

# yandex_folder — папка на Диске, куда складываются дампы.
yandex_folder() { local f; f="$(get_env YANDEX_FOLDER)"; printf '%s' "${f:-craft-wms-backups}"; }

# ya_rclone АРГ… — rclone с подключением «ya:» к Яндекс.Диску.
# Пароль передаётся через окружение в obscure-виде (этого требует rclone). Окружение
# процесса читается только root'ом, тогда как аргументы командной строки видны всем
# в `ps` — поэтому именно окружение, а не флаг.
ya_rclone() {
  local pass
  pass="$(rclone obscure "$(get_env YANDEX_WEBDAV_PASSWORD)" 2>/dev/null)"
  env RCLONE_CONFIG_YA_TYPE=webdav \
      RCLONE_CONFIG_YA_URL="$YA_WEBDAV_URL" \
      RCLONE_CONFIG_YA_VENDOR=other \
      RCLONE_CONFIG_YA_USER="$(get_env YANDEX_LOGIN)" \
      RCLONE_CONFIG_YA_PASS="$pass" \
      rclone "$@"
}

# yandex_check — быстрая проверка, что логин и пароль пускают на Диск.
# Дёшево и без побочных эффектов, поэтому годится для чек-листа.
yandex_check() { ya_rclone about ya: >/dev/null 2>&1; }

# yandex_roundtrip — настоящая проверка: залить файл, увидеть его в списке, удалить.
# `about` отвечает лишь «пускают ли», а сломаться может именно заливка: квота, ограничения
# WebDAV, права на папку. Раз бэкап нужен для восстановления, проверять надо то, от чего
# оно зависит, — что файл реально доезжает и читается обратно.
yandex_roundtrip() {
  local folder tmp name rc=0
  folder="$(yandex_folder)"
  tmp="$(mktemp -d)" || return 1
  name="craft-wms-selftest-$(date +%Y%m%d-%H%M%S).txt"
  printf 'craft-wms self test\n' > "$tmp/$name"

  ya_rclone copy "$tmp/$name" "ya:$folder" >/dev/null 2>&1 || rc=1
  if [[ $rc -eq 0 ]]; then
    ya_rclone lsf "ya:$folder" 2>/dev/null | grep -qx "$name" || rc=2
  fi
  # Убираем за собой в любом случае: тестовый файл в папке бэкапов только мешает.
  ya_rclone delete "ya:$folder/$name" >/dev/null 2>&1
  rm -rf "$tmp"
  return $rc
}

# offsite_push КАТАЛОГ — отправляет зашифрованные дампы во внешнюю копию.
# Настраивается двумя независимыми переменными, можно задать обе (копия в двух местах):
#   OFFSITE_DEST          — назначение rsync: локальный путь (внешний диск /mnt/…) ИЛИ
#                           user@host:/path. rsync эти формы не различает — код один.
#   OFFSITE_RCLONE_REMOTE — remote:path для rclone (yandex:, S3, WebDAV). Яндекс.Диск
#                           доступен только так: протокола Яндекс.Диска rsync не знает.
# Обе пустые — шаг пропускается с предупреждением в journal: молчаливое «внешней копии нет»
# ровно то состояние, ради ухода от которого задача и делалась.
offsite_push() {
  local dir="$1" dest remote pattern='craft_wms-*.sql.gz.enc' pushed=0
  dest="$(get_env OFFSITE_DEST)"
  remote="$(get_env OFFSITE_RCLONE_REMOTE)"

  # Яндекс.Диск — отдельной веткой: подключение собирается из логина и пароля приложения,
  # файла конфигурации rclone для него не нужно.
  if yandex_configured; then
    command -v rclone >/dev/null 2>&1 || die "нет rclone, а Яндекс.Диск настроен (см. docs/deploy/prod-deploy.md)."
    local folder; folder="$(yandex_folder)"
    log "Внешняя копия (Яндекс.Диск) → $folder"
    ya_rclone copy --include "$pattern" "$dir" "ya:$folder" \
      || die "загрузка на Яндекс.Диск не прошла (проверьте YANDEX_LOGIN и пароль приложения)."
    local keep; keep="$(get_env KEEP_DAYS)"; keep="${keep:-14}"
    ya_rclone delete --min-age "${keep}d" --include "$pattern" "ya:$folder" \
      || warn "ротация на Яндекс.Диске не прошла — старые дампы могли остаться."
    pushed=1
  fi

  if [[ -z "$dest" && -z "$remote" ]] && ! yandex_configured; then
    journal_err "внешняя копия не настроена (Яндекс.Диск / OFFSITE_DEST / OFFSITE_RCLONE_REMOTE пусты) — дампы лежат только на диске сервера."
    warn "Внешняя копия не настроена — пропускаю."
    return 0
  fi

  if [[ -n "$dest" ]]; then
    command -v rsync >/dev/null 2>&1 || die "нет rsync (apt-get install -y rsync), а OFFSITE_DEST задан."
    # Локальное назначение должно быть смонтировано: если внешний диск отвалился, каталог
    # точки монтирования существует и пуст — rsync отработает «успешно» в никуда.
    if [[ "$dest" != *:* ]]; then
      [[ -d "$dest" ]] || die "OFFSITE_DEST=$dest — каталога нет (внешний диск не смонтирован?)."
      mountpoint -q "$dest" 2>/dev/null || warn "$dest не является точкой монтирования — убедитесь, что это действительно внешний носитель, а не каталог на системном диске."
    fi
    local -a ssh_opt=()
    local key; key="$(get_env OFFSITE_SSH_KEY)"
    [[ -n "$key" ]] && ssh_opt=(-e "ssh -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new")

    log "Внешняя копия (rsync) → $dest"
    # --include/--exclude + --delete: на приёмнике удаляются только НАШИ файлы, которых уже
    # нет локально (локальная ротация KEEP_DAYS зеркалится наружу). Чужое в каталоге
    # назначения под --exclude и от удаления защищено — --delete-excluded мы не передаём.
    #
    # ${ssh_opt[@]+"${ssh_opt[@]}"} вместо "${ssh_opt[@]}": в bash 3.2 (macOS, где гоняются
    # локальные проверки) раскрытие ПУСТОГО массива под `set -u` падает с «unbound variable».
    # На сервере bash 5.x это работает и так, но скрипт должен проверяться и локально.
    rsync -a --delete ${ssh_opt[@]+"${ssh_opt[@]}"} \
      --include="$pattern" --exclude='*' \
      "$dir"/ "$dest"/ || die "rsync во внешнюю копию не прошёл ($dest)."
    pushed=1
  fi

  if [[ -n "$remote" ]]; then
    command -v rclone >/dev/null 2>&1 || die "нет rclone (см. docs/deploy/prod-deploy.md), а OFFSITE_RCLONE_REMOTE задан."
    log "Внешняя копия (rclone) → $remote"
    rclone copy --include "$pattern" "$dir" "$remote" || die "rclone во внешнюю копию не прошёл ($remote)."
    # Ротация на стороне remote: rclone copy сам ничего не удаляет, иначе старые дампы
    # копились бы в облаке вечно.
    local keep; keep="$(get_env KEEP_DAYS)"; keep="${keep:-14}"
    rclone delete --min-age "${keep}d" --include "$pattern" "$remote" || \
      warn "ротация в $remote не прошла — старые дампы могли остаться."
    pushed=1
  fi

  [[ $pushed -eq 1 ]] && log "Внешняя копия обновлена."
  return 0
}
