# -*- coding: utf-8 -*-
"""Настройки хаба сбора баз контрагентов."""

import json
import os

HUB_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(HUB_DIR)

# каталоги данных: принятые архивы и реестр заданий
DATA_DIR = os.environ.get("HUB_DATA_DIR", os.path.join(ROOT_DIR, "hub_data"))
INBOX_DIR = os.path.join(DATA_DIR, "inbox")
REGISTRY_DB = os.path.join(DATA_DIR, "hub.db")

CONFIG_PATH = os.environ.get("HUB_CONFIG", os.path.join(ROOT_DIR, "hub_config.json"))

DEFAULTS = {
    "host": "127.0.0.1",
    "port": 8800,
    # ключи клиентов: {"api-key": "имя клиента"}; пустой словарь = приём без ключа
    # (допустимо только на локальном стенде, на хостинге ключи обязательны)
    "clients": {},
    "max_upload_mb": 64,
    "import_workers": 1,        # параллельных импортов в Oracle
    "keep_inbox_days": 14,      # сколько хранить архивы обработанных пакетов
    # подключение к una.md; пароль лучше держать в переменной окружения
    "oracle": {
        "dsn": "192.168.0.24:1521/clouddev.world",
        "user": "paralax",
        "password": "",
        "client_dir": "",
    },
}


def load():
    cfg = json.loads(json.dumps(DEFAULTS))     # глубокая копия
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            disk = json.load(f)
        for key, val in disk.items():
            if isinstance(val, dict) and isinstance(cfg.get(key), dict):
                cfg[key].update(val)
            else:
                cfg[key] = val
    except FileNotFoundError:
        pass

    # окружение имеет приоритет над файлом
    env_map = {
        "TMS_DSN": ("oracle", "dsn"),
        "TMS_USER": ("oracle", "user"),
        "TMS_PASSWORD": ("oracle", "password"),
        "ORA_PWD": ("oracle", "password"),
        "ORACLE_CLIENT_DIR": ("oracle", "client_dir"),
    }
    for env, (sec, key) in env_map.items():
        if os.environ.get(env):
            cfg[sec][key] = os.environ[env]
    if os.environ.get("HUB_PORT"):
        cfg["port"] = int(os.environ["HUB_PORT"])
    return cfg


def ensure_dirs():
    os.makedirs(INBOX_DIR, exist_ok=True)
