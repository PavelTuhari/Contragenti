#!/bin/bash
# Сборка всех артефактов Contragenti для macOS (аналог setup.py build_exe +
# tools/build_exe_installer.py + tools/make_release.py на Windows):
#
#   1. Demo CRM.app        — xcodebuild (crm_macos/DemoCRM.xcodeproj);
#   2. Contragenti.app     — PyInstaller --windowed из company_search.py
#      (Python и tkinter внутри бандла, системный Python не нужен);
#   3. Contragenti Setup.app — PyInstaller из setup_wizard_macos.py;
#   4. каталог dist/macos/Contragenti/ — оба бандла + Demo CRM, companies.db
#      из data/companies_seed.zip, DemoCRM/clients.db (--seed-demo), lang.json,
#      processes.json, sdk/, инструкции, VERSION, release.json, app_icon.icns;
#   5. release/Contragenti-<v>-macos-app.zip, Contragenti-<v>-macos-democrm.zip,
#      Contragenti-<v>-macos.pkg (pkgbuild + productbuild, postinstall
#      запускает мастер), release/contragenti-macos-install.sh;
#   6. tools/make_release.py --macos — sha256 и размеры в release.json.
#
#   tools/build_macos.sh            всё
#   tools/build_macos.sh --skip-crm не пересобирать Demo CRM (взять готовый бандл)
#   tools/build_macos.sh --no-pkg   без .pkg (быстрая проверка бандлов)
#
# Требования: Xcode (xcodebuild), .venv с зависимостями requirements.txt и
# pyinstaller, python-tk (tkinter в .venv/bin/python).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VER="$(tr -d '[:space:]' < VERSION)"
PY="$ROOT/.venv/bin/python"
ARCH="$(uname -m)"
OUT="$ROOT/build/macos"
DIST="$ROOT/dist/macos"
STAGE="$DIST/Contragenti"
SKIP_CRM=0
NO_PKG=0
for a in "$@"; do
  case "$a" in
    --skip-crm) SKIP_CRM=1 ;;
    --no-pkg) NO_PKG=1 ;;
  esac
done

[ -x "$PY" ] || { echo "нет $PY — создайте .venv и поставьте requirements.txt + pyinstaller" >&2; exit 2; }
"$PY" -c "import tkinter, selenium, PyInstaller" || { echo "в .venv нужны tkinter, selenium, pyinstaller" >&2; exit 2; }

echo "== Contragenti $VER для macOS ($ARCH) =="
rm -rf "$OUT" "$STAGE"
mkdir -p "$OUT" "$STAGE" "$ROOT/release"

# ── 1. Demo CRM.app ──
CRM_APP="$ROOT/crm_macos/build/DerivedData/Build/Products/Release/Demo CRM.app"
if [ "$SKIP_CRM" = 0 ] || [ ! -d "$CRM_APP" ]; then
  echo "-- xcodebuild Demo CRM"
  (cd crm_macos && xcodebuild -project DemoCRM.xcodeproj -scheme "Demo CRM" -configuration Release \
      -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning: .*Swift|BUILD" | tail -5)
fi
[ -d "$CRM_APP" ] || { echo "нет $CRM_APP" >&2; exit 3; }

# ── 2/3. PyInstaller: Contragenti.app и Contragenti Setup.app ──
ICON="$ROOT/crm_macos/Resources/AppIcon.icns"
echo "-- PyInstaller Contragenti.app"
"$PY" -m PyInstaller --noconfirm --clean --windowed --name Contragenti --icon "$ICON" \
  --osx-bundle-identifier md.una.contragenti \
  --distpath "$OUT/py" --workpath "$OUT/work" --specpath "$OUT/spec" --paths "$ROOT" \
  --collect-all selenium --collect-all certifi \
  --hidden-import pystray._darwin --hidden-import PIL.ImageGrab --hidden-import PIL.ImageDraw \
  --hidden-import tms_export --hidden-import hub_client --hidden-import legal_forms --hidden-import openpyxl \
  --exclude-module oracledb --exclude-module fastapi --exclude-module uvicorn --exclude-module numpy \
  "$ROOT/company_search.py" > "$OUT/pyinstaller_contragenti.log" 2>&1 \
  || { tail -30 "$OUT/pyinstaller_contragenti.log"; exit 4; }

echo "-- PyInstaller Contragenti Setup.app"
"$PY" -m PyInstaller --noconfirm --clean --windowed --name "Contragenti Setup" --icon "$ICON" \
  --osx-bundle-identifier md.una.contragenti.setup \
  --distpath "$OUT/py" --workpath "$OUT/work" --specpath "$OUT/spec" --paths "$ROOT" \
  --collect-all certifi --hidden-import setup_common \
  --exclude-module selenium --exclude-module PIL --exclude-module numpy \
  "$ROOT/setup_wizard_macos.py" > "$OUT/pyinstaller_setup.log" 2>&1 \
  || { tail -30 "$OUT/pyinstaller_setup.log"; exit 4; }

# ── 4. каталог установки ──
echo "-- сборка каталога $STAGE"
ditto "$OUT/py/Contragenti.app" "$STAGE/Contragenti.app"
ditto "$OUT/py/Contragenti Setup.app" "$STAGE/Contragenti Setup.app"
ditto "$CRM_APP" "$STAGE/Demo CRM.app"
# CLI-режимы бандлов должны работать из терминала: проверяем сразу
"$STAGE/Contragenti.app/Contents/MacOS/Contragenti" --selftest > "$OUT/selftest_contragenti.log" 2>&1 \
  || { echo "Contragenti.app --selftest не прошёл:"; tail -12 "$OUT/selftest_contragenti.log"; exit 5; }
grep -c "^\[OK\]" "$OUT/selftest_contragenti.log" | sed 's/^/   Contragenti.app --selftest: OK x/'
"$STAGE/Demo CRM.app/Contents/MacOS/Demo CRM" --selftest > "$OUT/selftest_democrm.log" 2>&1 \
  || { echo "Demo CRM.app --selftest не прошёл:"; tail -5 "$OUT/selftest_democrm.log"; exit 5; }

mkdir -p "$STAGE/data" "$STAGE/DemoCRM" "$STAGE/sdk"
cp data/companies_seed.zip "$STAGE/data/"
# стартовая база компаний — ровно та, что в seed-zip (как setup.py на Windows)
rm -rf "$OUT/seed" && mkdir -p "$OUT/seed" && unzip -q -o data/companies_seed.zip -d "$OUT/seed"
SEED_DB="$(find "$OUT/seed" -name '*.db' | head -1)"
cp "$SEED_DB" "$STAGE/companies.db"
# демо-база Demo CRM — засеивается самим приложением (те же счётчики, что и на Windows)
rm -f "$STAGE/DemoCRM/clients.db"
"$STAGE/Demo CRM.app/Contents/MacOS/Demo CRM" --seed-demo "$STAGE/DemoCRM/clients.db" > "$OUT/seed_democrm.log" 2>&1
tail -1 "$OUT/seed_democrm.log" | sed 's/^/   /'
cp crm_delphi/lang.json crm_delphi/processes.json crm_delphi/sample_card.xml crm_delphi/README_ru.md "$STAGE/DemoCRM/"
ditto sdk "$STAGE/sdk"
cp README.md INTEGRATION.md API_ru.md GUIDE_ru.md INSTALL_MACOS_ru.md INSTALL_MACOS_RO.md INSTALL_WINDOWS_ru.md \
   INSTALL_MSI_ru.md INSTALL_RO.md STAFF_ERP_ru.md VERSION release.json setup_wizard_macos.py setup_common.py "$STAGE/"
mkdir -p "$STAGE/sql" && cp sql/erp_users_sync.sql "$STAGE/sql/"
cp "$ICON" "$STAGE/app_icon.icns"
# ad-hoc подпись убирает часть предупреждений Gatekeeper (Developer ID нет)
for app in "$STAGE"/*.app; do codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true; done
# расширенные атрибуты (provenance, quarantine) не должны попасть в zip и pkg
# как ._-файлы: com.apple.provenance xattr'ом не снимается — копируем каталог
# без атрибутов и ресурсных вилок и дальше работаем с чистой копией
CLEAN="$DIST/clean"
rm -rf "$CLEAN" && mkdir -p "$CLEAN"
ditto --noextattr --norsrc --noqtn "$STAGE" "$CLEAN/Contragenti"
rm -rf "$STAGE" && mv "$CLEAN/Contragenti" "$STAGE" && rmdir "$CLEAN"
du -sh "$STAGE" | sed 's/^/   размер: /'

# ── 5. архивы и pkg ──
echo "-- архивы"
cd "$DIST"
rm -f "Contragenti-$VER-macos-app.zip" "Contragenti-$VER-macos-democrm.zip"
ditto -c -k --norsrc --noextattr --keepParent Contragenti "Contragenti-$VER-macos-app.zip"
ditto -c -k --norsrc --noextattr --keepParent "Contragenti/Demo CRM.app" "Contragenti-$VER-macos-democrm.zip"
ls -la "Contragenti-$VER-macos-app.zip" "Contragenti-$VER-macos-democrm.zip" | awk '{print "   " $5, $9}'

if [ "$NO_PKG" = 0 ]; then
  echo "-- pkg"
  rm -rf "$OUT/pkg" && mkdir -p "$OUT/pkg/scripts" "$OUT/pkg/res"
  cp "$ROOT/tools/macos/postinstall" "$OUT/pkg/scripts/postinstall"
  chmod +x "$OUT/pkg/scripts/postinstall"
  cp "$ROOT/tools/macos/welcome.html" "$OUT/pkg/res/"
  sed "s/@VERSION@/$VER/g" "$ROOT/tools/macos/distribution.xml" > "$OUT/pkg/distribution.xml"
  pkgbuild --root "$STAGE" --filter '\._.*' --identifier md.una.contragenti.pkg --version "$VER" \
    --install-location /Applications/Contragenti --scripts "$OUT/pkg/scripts" \
    "$OUT/pkg/Contragenti-component.pkg" > "$OUT/pkgbuild.log" 2>&1
  productbuild --distribution "$OUT/pkg/distribution.xml" --resources "$OUT/pkg/res" \
    --package-path "$OUT/pkg" "$DIST/Contragenti-$VER-macos.pkg" > "$OUT/productbuild.log" 2>&1
  ls -la "Contragenti-$VER-macos.pkg" | awk '{print "   " $5, $9}'
fi

# ── 6. release/ и release.json ──
cd "$ROOT"
cp tools/macos/contragenti-macos-install.sh release/contragenti-macos-install.sh
chmod +x release/contragenti-macos-install.sh
"$PY" tools/make_release.py --macos
echo "== готово: release/Contragenti-$VER-macos-app.zip, -democrm.zip$([ "$NO_PKG" = 0 ] && echo ", .pkg"), contragenti-macos-install.sh =="
