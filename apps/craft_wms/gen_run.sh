#!/bin/zsh

GREEN='\033[0;32m'
BLUE='\033[0;34m'
BRIGHT_RED='\033[1;31m'

DEFAULT='\033[0m'

echo
echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${DEFAULT}"
echo "${BLUE}━━━━━━━━ 🧹 Clean build runner... 🧹 ━━━━━━━━━${DEFAULT}"
echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${DEFAULT}"

dart run build_runner clean

# slang пишет в lib/core/gen/ напрямую; clean их не трогает — без удаления повторный build падает
rm -f lib/core/gen/strings*.g.dart

echo "${BRIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${DEFAULT}"
echo "${BRIGHT_RED}━━━━━━━━━━ 🚀 Run build runner... 🚀 ━━━━━━━━━${DEFAULT}"
echo "${BRIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${DEFAULT}"

dart run build_runner build

echo "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${DEFAULT}"
echo "${GREEN}━━━━━━━━━━━━━━━━ 🎉 Done! 🎉 ━━━━━━━━━━━━━━━━━${DEFAULT}"
echo "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${DEFAULT}"
echo
