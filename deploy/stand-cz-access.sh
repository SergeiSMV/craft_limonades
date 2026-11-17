#!/usr/bin/env bash
# Craft WMS · доступ тестового стенда к подписанту Честного знака (ADHOC-54).
#
# Что: заводит на боевом сервере пользователя cz-tunnel, которому SSH разрешает только
#   локальный проброс: сокет подписанта /run/cz-signer/sign.sock и выход стенда в True API
#   (SOCKS) с адреса сервера. Ни оболочки, ни обратных туннелей, ни агента; из сокетов ему
#   доступен лишь сокет подписанта (группа cz-signer, без docker и sudo).
#
#   Сузить TCP нельзя: sshd открывает проброс unix-сокетов только при AllowTcpForwarding
#   local, а PermitOpen закрывает вместе с TCP и сокеты. Ключ cz-tunnel лежит на машине
#   разработчика, у которой и так есть полный SSH-доступ к серверу.
# Зачем: стенд разработчика (deploy/test_stand) получает токен True API той же подписью, что
#   и прод, - КриптоПро и ключ остаются только на сервере, копий КЭП нет.
#
# Запускает stand.sh cz-setup с машины разработчика (копирует сюда и вызывает через sudo);
# руками: sudo bash stand-cz-access.sh '<публичный ключ стенда>'. Повторный запуск безопасен.
# sudo bash stand-cz-access.sh --revoke - убрать доступ.
set -euo pipefail

TUNNEL_USER=cz-tunnel
SIGNER_GROUP=cz-signer
DROPIN=/etc/ssh/sshd_config.d/craft-stand-cz.conf

die() { printf '[stand-cz] ОШИБКА: %s\n' "$*" >&2; exit 1; }
log() { printf '[stand-cz] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "запускать через sudo."

# reload_sshd - проверить конфигурацию и перечитать её. Открытые сессии не рвутся.
reload_sshd() {
  sshd -t || die "sshd -t не принял конфигурацию - sshd не перезагружен."
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

if [[ "${1:-}" == "--revoke" ]]; then
  rm -f "$DROPIN"
  reload_sshd
  if id "$TUNNEL_USER" >/dev/null 2>&1; then
    userdel -r "$TUNNEL_USER" 2>/dev/null || userdel "$TUNNEL_USER"
  fi
  log "Доступ стенда к подписанту убран."
  exit 0
fi

pubkey="${1:-}"
[[ "$pubkey" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "нужен публичный ключ ssh-ed25519 одной строкой."
getent group "$SIGNER_GROUP" >/dev/null || die "группы $SIGNER_GROUP нет - подписант на сервере не настроен (craft.sh, пункт 18)."
grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config \
  || die "sshd_config не подключает sshd_config.d - правило для $TUNNEL_USER не применится."
if grep -qiE '^\s*Allow(Users|Groups)\s' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
  log "ВНИМАНИЕ: в sshd задан AllowUsers/AllowGroups - добавьте туда $TUNNEL_USER, иначе вход не пустят."
fi

if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$TUNNEL_USER"
  log "Заведён пользователь $TUNNEL_USER."
fi
# Только группа сокета: в docker и sudo он не входит.
usermod -G "$SIGNER_GROUP" "$TUNNEL_USER"

home="$(getent passwd "$TUNNEL_USER" | cut -d: -f6)"
install -d -m 700 -o "$TUNNEL_USER" -g "$TUNNEL_USER" "$home/.ssh"
# restrict гасит всё, port-forwarding возвращает только проброс; что именно можно
# пробрасывать, сужает правило sshd ниже. Ключ один - прежний заменяется.
printf 'restrict,port-forwarding %s\n' "$pubkey" > "$home/.ssh/authorized_keys"
chown "$TUNNEL_USER:$TUNNEL_USER" "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"

cat > "$DROPIN" <<EOF
# ADHOC-54: стенд разработчика пробрасывает к себе сокет подписанта ЧЗ и выходит через сервер в True API.
# Пишет deploy/stand-cz-access.sh; убрать: sudo bash deploy/stand-cz-access.sh --revoke
Match User $TUNNEL_USER
    AllowTcpForwarding local
    AllowStreamLocalForwarding local
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    GatewayPorts no
    PasswordAuthentication no
    ForceCommand /usr/sbin/nologin
EOF
chmod 644 "$DROPIN"
reload_sshd
log "✅ $TUNNEL_USER: только локальный проброс (сокет подписанта, выход в True API); ключ стенда принят."
