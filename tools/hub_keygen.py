# -*- coding: utf-8 -*-
"""
Выпуск API-ключей для клиентов хаба.

Ключ выдаётся каждому рабочему месту отдельно: так видно, кто прислал
пакет, и можно отозвать доступ одной машине, не трогая остальные.

    python tools/hub_keygen.py "Бухгалтерия"          # показать ключ
    python tools/hub_keygen.py "Отдел продаж" --save  # и записать в конфиг
    python tools/hub_keygen.py --list                 # кто уже заведён
    python tools/hub_keygen.py --revoke <ключ>        # отозвать
"""

import argparse
import json
import os
import secrets
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hub import config  # noqa: E402


def load_raw():
    try:
        with open(config.CONFIG_PATH, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_raw(data):
    with open(config.CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def main():
    ap = argparse.ArgumentParser(description="API-ключи клиентов хаба una.md")
    ap.add_argument("name", nargs="?", help="название клиента (рабочего места)")
    ap.add_argument("--save", action="store_true", help="записать ключ в hub_config.json")
    ap.add_argument("--list", action="store_true", help="показать заведённых клиентов")
    ap.add_argument("--revoke", metavar="KEY", help="отозвать ключ")
    args = ap.parse_args()

    raw = load_raw()
    clients = raw.get("clients") or {}

    if args.list:
        if not clients:
            print("клиентов нет — приём разрешён только с петлевого адреса")
        for key, name in clients.items():
            print(f"  {key}  {name}")
        return

    if args.revoke:
        if args.revoke not in clients:
            sys.exit("такого ключа нет")
        name = clients.pop(args.revoke)
        raw["clients"] = clients
        save_raw(raw)
        print(f"ключ отозван: {name}")
        return

    if not args.name:
        ap.error("укажите название клиента или --list/--revoke")

    key = secrets.token_urlsafe(32)
    print(f"клиент : {args.name}")
    print(f"ключ   : {key}")
    if args.save:
        clients[key] = args.name
        raw["clients"] = clients
        save_raw(raw)
        print(f"записан в {config.CONFIG_PATH}")
    else:
        print("\n(ключ не сохранён; добавьте --save или впишите в clients вручную)")
    print("\nНа рабочем месте:  HUB_API_KEY=<ключ>  или hub_key в tms_config.json")


if __name__ == "__main__":
    main()
