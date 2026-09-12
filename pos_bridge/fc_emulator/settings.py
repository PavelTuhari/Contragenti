# -*- coding: utf-8 -*-
"""
Настройки имитатора: отдельная программа со своим файлом настроек,
не зависящим от прослойки.

Файл ищется по `FC_EMULATOR_CONFIG`, иначе рядом с рабочим каталогом
программы: на Linux это `/etc/fiscalcloud-emulator/config.json` при запуске
службой, у пользователя — `~/.config/fiscalcloud-emulator/config.json`.
"""

import json
import os
import sys

APP_NAME = "fiscalcloud-emulator"

DEFAULTS = {
    "host": "127.0.0.1",
    "port": 50700,
    # ключи, которые ждёт имитатор от кассового приложения
    "apiKey": "demo-api-key-0000000000000000000000000000",
    "apiSecret": "demo-api-secret-000000000000000000000000",
    # реквизиты «устройства»
    "device": {
        "id": "0875b8a5-0668-41a3-a3fa-8eeccf66d289",
        "pointOfSaleId": "1f0d2a64-7b53-4f0e-9a3d-2f4d6f0a1c77",
        "name": "Sunmi V2s (имитатор)",
        "serialNumber": "DEMO-0001",
        "registrationNumber": "DEMO-REG-0001",
        "model": "Sunmi V2s + SoftLider FiscalCloud",
        "organizationName": "DEMO SRL",
        "idnx": "1000000000000",
        "address": "mun. Chişinău, str. Demo 1",
        "subdivisionCode": "01",
    },
    "taxGroups": [
        {"code": "A", "rate": 20.0}, {"code": "B", "rate": 8.0},
        {"code": "C", "rate": 12.0}, {"code": "N", "rate": 0.0},
    ],
    "paymentTypes": [
        {"code": 0, "name": "Numerar", "openCashDrawer": True},
        {"code": 1, "name": "Card bancar (MAIB)", "openCashDrawer": False},
    ],
    "useAlternativeReceipts": False,
    # доступность сервера налоговой: на False продажа в режиме
    # FiscalThenAlternativeReceipt уходит в «Bon de plata»
    "taxAuthorityOnline": True,
    "statePath": "",      # пусто — рядом с файлом настроек, state.json
    "logPath": "",        # пусто — только в консоль
    "saveEverySeconds": 20,
}


def config_dir():
    given = os.environ.get("FC_EMULATOR_DIR")
    if given:
        return given
    if os.name == "nt":
        return os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "FiscalCloudEmulator")
    if sys.platform == "darwin":
        return os.path.join(os.path.expanduser("~"), "Library", "Application Support", APP_NAME)
    # Linux: службе — /etc, пользователю — ~/.config
    system = os.path.join("/etc", APP_NAME)
    if os.path.isdir(system) and os.access(system, os.R_OK):
        return system
    return os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), APP_NAME)


def config_path():
    return os.environ.get("FC_EMULATOR_CONFIG") or os.path.join(config_dir(), "config.json")


def _deep_update(dst, src):
    for k, v in (src or {}).items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _deep_update(dst[k], v)
        else:
            dst[k] = v


def load(path=None):
    cfg = json.loads(json.dumps(DEFAULTS))
    p = path or config_path()
    try:
        with open(p, encoding="utf-8") as f:
            _deep_update(cfg, json.load(f))
    except FileNotFoundError:
        pass
    except ValueError as exc:
        raise ValueError("файл настроек повреждён (%s): %s" % (p, exc))
    for env, key in (("FC_EMULATOR_HOST", "host"), ("FC_EMULATOR_API_KEY", "apiKey"),
                     ("FC_EMULATOR_API_SECRET", "apiSecret"), ("FC_EMULATOR_STATE", "statePath"),
                     ("FC_EMULATOR_LOG", "logPath")):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    if os.environ.get("FC_EMULATOR_PORT"):
        cfg["port"] = int(os.environ["FC_EMULATOR_PORT"])
    if not cfg.get("statePath"):
        cfg["statePath"] = os.path.join(os.path.dirname(p) or config_dir(), "state.json")
    return cfg


def save(cfg, path=None):
    p = path or config_path()
    os.makedirs(os.path.dirname(os.path.abspath(p)) or ".", exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, p)
    return p
