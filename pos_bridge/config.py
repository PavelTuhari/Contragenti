# -*- coding: utf-8 -*-
"""Настройки прослойки: файл pos_bridge_config.json, поверх — окружение.

Секреты в коде не хранятся: ключи FiscalCloud и пароли Oracle берутся из
окружения или из файла настроек, который лежит вне репозитория.
"""

import json
import os

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.environ.get("POS_BRIDGE_CONFIG", os.path.join(ROOT_DIR, "pos_bridge_config.json"))
DATA_DIR = os.environ.get("POS_BRIDGE_DATA", os.path.join(ROOT_DIR, "pos_bridge_data"))

DEFAULTS = {
    # сама прослойка
    "host": "127.0.0.1",
    "port": 50800,
    # ключи кассового приложения к прослойке; пусто = на петлевом адресе без подписи
    "clients": {},          # {"Api-Key": {"name": "Sunmi-1", "secret": "…"}}

    # FiscalCloud (SoftLider): локальный сервис ставится на 50700,
    # облако — https://cloud.fiscalcloud.md
    "fiscalcloud": {
        "base_url": "http://localhost:50700",
        "api_key": "",
        "api_secret": "",
        "device_id": "",
        "point_of_sale_id": "",
        "timeout": 30,
    },

    # откуда берём товары и цены
    #   demo   — база Demo CRM (items) — тот же демо-режим, что и был
    #   erp    — Oracle OfficePlus: TMS_UNIVERS (TIP='P') + TMS_MPT
    #   file   — json-файл со списком товаров
    "catalog": {
        "source": "demo",
        "crm_db": "",              # путь к clients.db; пусто — ищем сам
        "file": "",
        "limit": 5000,
        "default_tax_group": "A",
        # НДС, % -> группа налога FiscalCloud (в Oracle это готовая CODTVA)
        "vat_to_tax_group": {"20": "A", "8": "B", "0": "N"},
    },

    # Oracle OfficePlus: справочник товаров (схема каталога) и организаций
    "oracle": {
        "dsn": "192.168.0.24:1521/clouddev.world",
        "user": "BONUS2019",
        "password": "",
        "client_dir": "",
        "org_user": "paralax",     # организации лежат в другой схеме
        "org_password": "",
    },

    # куда класть принятые продажи
    "export": {
        "crm_db": "",              # база Demo CRM: продажи станут заказами
        "client_name": "Розничный покупатель",
        "order_prefix": "POS-",
    },

    "poll_seconds": 60,            # как часто забирать чеки в режиме serve
}


def _deep_update(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _deep_update(dst[k], v)
        else:
            dst[k] = v


def load(path=None):
    cfg = json.loads(json.dumps(DEFAULTS))
    p = path or CONFIG_PATH
    try:
        with open(p, encoding="utf-8") as f:
            _deep_update(cfg, json.load(f))
    except FileNotFoundError:
        pass

    env_map = {
        "FISCALCLOUD_URL": ("fiscalcloud", "base_url"),
        "FISCALCLOUD_API_KEY": ("fiscalcloud", "api_key"),
        "FISCALCLOUD_API_SECRET": ("fiscalcloud", "api_secret"),
        "FISCALCLOUD_DEVICE_ID": ("fiscalcloud", "device_id"),
        "FISCALCLOUD_POS_ID": ("fiscalcloud", "point_of_sale_id"),
        "GOODS_DSN": ("oracle", "dsn"),
        "GOODS_USER": ("oracle", "user"),
        "GOODS_PASSWORD": ("oracle", "password"),
        "TMS_USER": ("oracle", "org_user"),
        "TMS_PASSWORD": ("oracle", "org_password"),
        "ORACLE_CLIENT_DIR": ("oracle", "client_dir"),
        "POS_CATALOG_SOURCE": ("catalog", "source"),
        "POS_CRM_DB": ("catalog", "crm_db"),
    }
    for env, (sec, key) in env_map.items():
        if os.environ.get(env):
            cfg[sec][key] = os.environ[env]
    if os.environ.get("POS_BRIDGE_PORT"):
        cfg["port"] = int(os.environ["POS_BRIDGE_PORT"])
    return cfg


def ensure_dirs():
    os.makedirs(DATA_DIR, exist_ok=True)


def db_path():
    ensure_dirs()
    return os.path.join(DATA_DIR, "pos_bridge.db")


def is_local_only(cfg):
    return str(cfg.get("host", "")).strip() in ("127.0.0.1", "localhost", "::1")


def crm_db_candidates(cfg):
    """Где искать базу Demo CRM, если путь не задан явно."""
    given = (cfg["catalog"].get("crm_db") or "").strip()
    if given:
        return [given]
    home = os.path.expanduser("~")
    return [
        os.path.join(home, "Library", "Application Support", "Contragenti", "DemoCRM", "clients.db"),
        os.path.join(ROOT_DIR, "crm_delphi", "clients.db"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Contragenti", "DemoCRM", "clients.db"),
    ]
