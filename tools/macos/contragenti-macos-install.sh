#!/bin/bash
# Тонкий установщик Contragenti для macOS — аналог Contragenti-<версия>-setup.exe.
#
# Скачивает Contragenti-<версия>-macos-app.zip по release.json, проверяет
# sha256, распаковывает в ~/Applications/Contragenti (без sudo) или, с
# --system, в /Applications/Contragenti, снимает карантин, ставит симлинки,
# запускает мастер настройки.
#
#   curl -fsSL https://raw.githubusercontent.com/PavelTuhari/Contragenti/main/release/contragenti-macos-install.sh | bash
#   … | bash -s -- --system --lang ru
#
# Флаги: --dir PATH  --system  --no-wizard  --no-shortcuts  --lang ro|en|ru
#        --offline-payload FILE.zip (готовый zip с диска — для тестов)
set -euo pipefail

REPO="PavelTuhari/Contragenti"
RELEASE_URL="https://raw.githubusercontent.com/$REPO/main/release.json"
DIR=""
SYSTEM=0
WIZARD=1
SHORTCUTS=1
LANG_CODE=""
PAYLOAD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --system) SYSTEM=1; shift ;;
    --no-wizard) WIZARD=0; shift ;;
    --no-shortcuts) SHORTCUTS=0; shift ;;
    --lang) LANG_CODE="$2"; shift 2 ;;
    --offline-payload) PAYLOAD="$2"; shift 2 ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "неизвестный флаг: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Этот установщик только для macOS." >&2; exit 2
fi

if [ -z "$DIR" ]; then
  if [ "$SYSTEM" = 1 ]; then DIR="/Applications/Contragenti"; else DIR="$HOME/Applications/Contragenti"; fi
fi
if [ -z "$LANG_CODE" ]; then
  case "$(defaults read -g AppleLocale 2>/dev/null || echo ro)" in
    ru*) LANG_CODE=ru ;; en*) LANG_CODE=en ;; *) LANG_CODE=ro ;;
  esac
fi

TMP="$(mktemp -d /tmp/contragenti-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

py_json() {  # значение поля из release.json (python3 есть на любом Mac с Xcode CLT; иначе — sed)
  local key="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$TMP/release.json" "$key"
  else
    sed -n "s/^ *\"$key\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$TMP/release.json" | head -1
  fi
}

if [ -n "$PAYLOAD" ]; then
  echo "• Готовый пакет: $PAYLOAD"
  cp "$PAYLOAD" "$TMP/app.zip"
  VER="$(unzip -p "$TMP/app.zip" 'Contragenti/VERSION' 2>/dev/null | tr -d '[:space:]' || echo "?")"
else
  echo "• Проверяю последнюю версию…"
  curl -fsSL "$RELEASE_URL" -o "$TMP/release.json"
  VER="$(py_json version)"
  URL="$(py_json macos_app_zip_url)"
  SHA="$(py_json macos_app_zip_sha256)"
  SIZE="$(py_json macos_app_zip_size)"
  if [ -z "$URL" ]; then
    echo "В release.json нет macos_app_zip_url — сборка для macOS ещё не опубликована." >&2; exit 3
  fi
  echo "• Загрузка Contragenti $VER ($((SIZE/1024/1024)) МБ)…"
  curl -fL --progress-bar "$URL" -o "$TMP/app.zip"
  echo "• Проверка контрольной суммы…"
  GOT="$(shasum -a 256 "$TMP/app.zip" | cut -d' ' -f1)"
  if [ -n "$SHA" ] && [ "$GOT" != "$SHA" ]; then
    echo "sha256 не совпал: $GOT ≠ $SHA — файл скачан повреждённым, попробуйте ещё раз." >&2; exit 4
  fi
fi

echo "• Распаковка в $DIR…"
pkill -f "Contragenti.app/Contents/MacOS/Contragenti" 2>/dev/null || true
pkill -f "Demo CRM.app/Contents/MacOS/Demo CRM" 2>/dev/null || true
ditto -x -k "$TMP/app.zip" "$TMP/unpack"
SRC="$TMP/unpack/Contragenti"
[ -d "$SRC" ] || SRC="$TMP/unpack"

SUDO=""
if [ "$SYSTEM" = 1 ] && ! mkdir -p "$DIR" 2>/dev/null; then SUDO="sudo"; fi
$SUDO mkdir -p "$DIR"
# бандлы и служебные файлы заменяются; базы и crm.ini пользователя (если он
# распаковал портативно) не трогаем
for item in "$SRC"/* "$SRC"/.[!.]*; do
  [ -e "$item" ] || continue
  name="$(basename "$item")"
  case "$name" in
    companies.db|crm.ini|settings.json|tms_config.json) [ -e "$DIR/$name" ] && continue ;;
  esac
  $SUDO rm -rf "$DIR/$name"
  $SUDO ditto "$item" "$DIR/$name"
done
# без подписи Apple Developer ID: снять карантин, иначе Gatekeeper блокирует запуск
$SUDO xattr -dr com.apple.quarantine "$DIR" 2>/dev/null || true

if [ "$SHORTCUTS" = 1 ] && [ "$SYSTEM" != 1 ]; then
  mkdir -p "$HOME/Applications"
  for app in "Contragenti.app" "Demo CRM.app" "Contragenti Setup.app"; do
    [ -d "$DIR/$app" ] || continue
    link="$HOME/Applications/$app"
    if [ "$DIR" != "$HOME/Applications/Contragenti" ] && [ ! -e "$link" ]; then ln -s "$DIR/$app" "$link"; fi
  done
fi

echo "• Установлено: Contragenti $VER → $DIR"
if [ "$WIZARD" = 1 ] && [ -d "$DIR/Contragenti Setup.app" ]; then
  echo "• Запуск мастера настройки…"
  open -a "$DIR/Contragenti Setup.app" --args --lang "$LANG_CODE"
fi
