#!/usr/bin/env bash
# CZ-01, разведка: токен True API подписью КЭП физлица с Рутокена.
#
# Что: auth/key → подпись строки (CAdES-BES, присоединённая) → simpleSignIn.
# Зачем: проверить, выдаёт ли ЧЗ токен физлицу с МЧД и ролью «без права подписи».
# Запуск: CZ_THUMB=<отпечаток> ./token.sh - PIN токена спросит КриптоПро.
# Только чтение: в Честном знаке ничего не меняется. Токен пишется в .token (доступ - только
# владельцу) и на экран не выводится.
set -euo pipefail
API="${API:-https://markirovka.crpt.ru/api/v3/true-api}"
# Отпечаток (SHA1) сертификата подписанта в хранилище uMy пользователя:
#   /opt/cprocsp/bin/amd64/certmgr -list -store uMy | grep SHA1
THUMB="${CZ_THUMB:?задайте CZ_THUMB - SHA1-отпечаток сертификата подписанта}"
CRYPTCP=/opt/cprocsp/bin/amd64/cryptcp
DIR="$(cd "$(dirname "$0")" && pwd)"
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "1/3 auth/key ($API)"
curl -sS -f "$API/auth/key" -o "$work/key.json"
python3 - "$work" <<'PY'
import json, sys
w = sys.argv[1]
d = json.load(open(w + "/key.json"))
open(w + "/uuid", "w").write(d["uuid"])
open(w + "/data.txt", "w").write(d["data"])
PY

echo "2/3 подпись - КриптоПро спросит PIN Рутокена"
"$CRYPTCP" -sign -uMy -thumbprint "$THUMB" -nochain -cadesbes -attached -der -askpin \
  "$work/data.txt" "$work/data.sig" >/dev/null

python3 - "$work" <<'PY'
import base64, json, sys
w = sys.argv[1]
json.dump({"uuid": open(w + "/uuid").read(),
           "data": base64.b64encode(open(w + "/data.sig", "rb").read()).decode()},
          open(w + "/body.json", "w"))
PY

echo "3/3 simpleSignIn"
code=$(curl -sS -o "$work/resp.json" -w '%{http_code}' \
  -H 'Content-Type: application/json;charset=UTF-8' --data @"$work/body.json" "$API/auth/simpleSignIn")
python3 - "$work" "$code" "$DIR" <<'PY'
import json, sys
w, code, out = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(w + "/resp.json").read()
try:
    resp = json.loads(raw)
except ValueError:
    resp = None
if code == "200" and isinstance(resp, dict) and resp.get("token"):
    open(out + "/.token", "w").write(resp["token"])
    print(f"Токен получен (HTTP 200), сохранён в {out}/.token")
else:
    print(f"Отказ: HTTP {code}")
    print(raw[:2000])
PY
