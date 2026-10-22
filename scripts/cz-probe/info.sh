#!/usr/bin/env bash
# CZ-01, разведка: информация о марках по токену из token.sh. Только чтение.
#
# Использование: ./info.sh '<код марки>' ['<код марки>' ...]
# Код — КИ марки без криптохвоста (`01`+GTIN+`21`+серийный, часть до GS) или код агрегата
# (`00`+SSCC у транспортной упаковки): с криптохвостом True API марку не находит.
set -euo pipefail
API="${API:-https://markirovka.crpt.ru/api/v3/true-api}"
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -s "$DIR/.token" ] || { echo "Нет токена — сначала ./token.sh"; exit 1; }
[ $# -gt 0 ] || { echo "Укажите хотя бы один код марки"; exit 1; }
body=$(python3 -c 'import json,sys; print(json.dumps([a.encode().decode("unicode_escape") for a in sys.argv[1:]]))' "$@")
code=$(curl -sS -o /tmp/cz-info.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $(cat "$DIR/.token")" -H 'Content-Type: application/json;charset=UTF-8' \
  --data "$body" "$API/cises/info")
echo "HTTP $code"
python3 -c 'import json,sys; r=open(sys.argv[1]).read()
try: print(json.dumps(json.loads(r), ensure_ascii=False, indent=2)[:6000])
except ValueError: print(r[:2000])' /tmp/cz-info.$$
rm -f /tmp/cz-info.$$
