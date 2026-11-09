#!/usr/bin/env bash
# build_tsd_rustore.sh — релизный APK ТСД для RuStore (ADHOC-66).
#
# Что: собирает боевое приложение «КЛ: Склад» релизом, подписанным ключом приложения, и
#      проверяет результат до загрузки в RuStore Консоль.
# Зачем: RuStore примет версию, только если подпись совпадает с первой загруженной и versionCode
#        растёт; APK с отладочной подписью (нет android/key.properties) загружать нельзя — его
#        не обновить.
# Демо: в сборку входит адрес демо-сервера (DEMO_BASE_URL), иначе кнопки «Демо-режим» нет.
# Как: flutter build apk --release только под ARM (терминалы ARM, x86_64 нужен лишь эмулятору),
#      затем apksigner — подпись не отладочная, aapt2 — пакет, версия и разрешения.
#
# Запуск из корня репозитория: bash scripts/build_tsd_rustore.sh
# Результат: apps/craft_wms/build/app/outputs/flutter-apk/app-release.apk
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/craft_wms"
APK="$APP/build/app/outputs/flutter-apk/app-release.apk"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

[[ -f "$APP/android/key.properties" ]] \
  || die "нет apps/craft_wms/android/key.properties - без ключа приложения релиз подпишется отладочным."
[[ -f "$APP/.env" ]] || die "нет apps/craft_wms/.env (BASE_URL боевого сервера)."
grep -q '"STAND"' "$APP/.env" && die ".env задаёт STAND - это сборка стенда, в RuStore её не грузим."

# Демо-сервер (ADHOC-67): кнопка «Демо-режим» на экране входа - по ней модератор RuStore
# проверяет приложение. Адрес можно переопределить строкой DEMO_BASE_URL в .env.
DEMO_DEFINE=()
grep -q '"DEMO_BASE_URL"' "$APP/.env" \
  || DEMO_DEFINE=(--dart-define=DEMO_BASE_URL="${DEMO_BASE_URL:-https://demo.craft.skogi.ru/api/v1/}")

BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
[[ -n "$BT" ]] || die "не найдены build-tools Android SDK ($SDK)."

cd "$APP"
flutter pub get >/dev/null
dart run build_runner build --delete-conflicting-outputs >/dev/null
flutter build apk --release -t lib/main.dart --dart-define-from-file=.env \
  ${DEMO_DEFINE[@]+"${DEMO_DEFINE[@]}"} --target-platform android-arm,android-arm64

echo
echo "== Подпись"
certs="$("$BT/apksigner" verify --print-certs "$APK")"
echo "$certs" | grep -E "certificate DN|SHA-256"
echo "$certs" | grep -q "CN=Android Debug" && die "APK подписан отладочным ключом."

echo
echo "== Пакет и разрешения"
"$BT/aapt2" dump badging "$APK" | grep -E "^package:|uses-permission|^application-label:"
echo
ls -lh "$APK" | awk '{print "== Файл: " $9 " (" $5 ")"}'
