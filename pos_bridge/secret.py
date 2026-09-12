# -*- coding: utf-8 -*-
"""
Пароли — из связки ключей macOS, а не из файлов репозитория.

В настройках у источника данных вместо пароля указывается, где его взять:

    "keychain_service": "192.168.0.24 (Cloud) access",
    "keychain_account": "root"

Читает `security find-generic-password -w`; при первом обращении macOS
спросит разрешение. Пароль нигде не печатается и в журнал не попадает.
Если связка недоступна (не macOS, запуск без сеанса пользователя) —
работает обычный порядок: явный пароль в настройках или переменная
окружения.
"""

import os
import subprocess

_cache = {}


def from_keychain(service, account=""):
    """Пароль из связки ключей или пустая строка."""
    if not service:
        return ""
    key = (service, account)
    if key in _cache:
        return _cache[key]
    cmd = ["security", "find-generic-password", "-s", service, "-w"]
    if account:
        cmd[2:2] = ["-a", account]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return ""
    value = out.stdout.strip() if out.returncode == 0 else ""
    _cache[key] = value
    return value


def password_for(section, env_name=""):
    """Пароль источника: явный → связка ключей → переменная окружения."""
    if section.get("password"):
        return section["password"]
    value = from_keychain(section.get("keychain_service", ""), section.get("keychain_account", ""))
    if value:
        return value
    return os.environ.get(env_name, "") if env_name else ""


def store(service, account, password):
    """Положить пароль в связку ключей (перезаписывает существующий)."""
    cmd = ["security", "add-generic-password", "-U", "-s", service, "-a", account, "-w", password]
    out = subprocess.run(cmd, capture_output=True, text=True)
    return out.returncode == 0, (out.stderr or "").strip()
