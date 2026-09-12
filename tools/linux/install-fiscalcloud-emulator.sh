#!/bin/bash
# Установка имитатора FiscalCloud службой на Linux.
#
#   sudo tools/linux/install-fiscalcloud-emulator.sh [каталог] [пользователь]
#
# Ставит код в каталог (по умолчанию /opt/pos-bridge), заводит окружение
# Python, создаёт настройки в /etc/fiscalcloud-emulator и включает службу.
# Окно (tkinter) на сервере не нужно: служба работает без него.
set -euo pipefail
DIR="${1:-/opt/pos-bridge}"
USER_NAME="${2:-posbridge}"
CONF_DIR="/etc/fiscalcloud-emulator"
SRC="$(cd "$(dirname "$0")/../.." && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "нужен root: sudo $0" >&2; exit 1; }

id -u "$USER_NAME" >/dev/null 2>&1 || useradd --system --home "$DIR" --shell /usr/sbin/nologin "$USER_NAME"
mkdir -p "$DIR" "$CONF_DIR"
cp -r "$SRC/pos_bridge" "$DIR/"
cp "$SRC/requirements-hub.txt" "$DIR/" 2>/dev/null || true

python3 -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" install -q --upgrade pip
"$DIR/.venv/bin/pip" install -q fastapi uvicorn

# настройки: слушаем все адреса, состояние и журнал рядом с настройками
FC_EMULATOR_CONFIG="$CONF_DIR/config.json" "$DIR/.venv/bin/python" -m pos_bridge.fc_emulator config --write >/dev/null
python3 - "$CONF_DIR/config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p, encoding="utf-8"))
cfg["host"] = "0.0.0.0"
cfg["statePath"] = "/var/lib/fiscalcloud-emulator/state.json"
cfg["logPath"] = "/var/log/fiscalcloud-emulator.log"
json.dump(cfg, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
mkdir -p /var/lib/fiscalcloud-emulator
touch /var/log/fiscalcloud-emulator.log
chown -R "$USER_NAME":"$USER_NAME" "$DIR" "$CONF_DIR" /var/lib/fiscalcloud-emulator /var/log/fiscalcloud-emulator.log

FC_EMULATOR_CONFIG="$CONF_DIR/config.json" "$DIR/.venv/bin/python" -m pos_bridge.fc_emulator \
  install-service --python "$DIR/.venv/bin/python" --workdir "$DIR" --user "$USER_NAME" \
  --service-config "$CONF_DIR/config.json" --out /etc/systemd/system/fiscalcloud-emulator.service >/dev/null

systemctl daemon-reload
systemctl enable --now fiscalcloud-emulator
sleep 2
systemctl --no-pager status fiscalcloud-emulator | head -12
echo
echo "Проверка:  curl -s http://127.0.0.1:50700/health"
echo "Настройки: $CONF_DIR/config.json (ключи Api-Key/Api-Secret меняйте здесь)"
