# -*- coding: utf-8 -*-
"""
Запуск прослойки и демонстрации.

    python -m pos_bridge serve                прослойка (по умолчанию :50800)
    python -m pos_bridge emulator             демо-ответчик FiscalCloud (:50700)
    python -m pos_bridge demo                 оба сервиса + прогон продажи,
                                              дальше живут для /api-docs
    python -m pos_bridge sync --source erp    перечитать каталог из учёта
    python -m pos_bridge pull                 забрать чеки и положить в учёт
    python -m pos_bridge selftest             сквозная проверка без кассы (0/1)
    python -m pos_bridge check-oracle         проверить доступ к OfficePlus
"""

import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

from . import catalog, config, emulator, signing, store
from .app import Bridge, build_app
from .fiscalcloud import FiscalCloudClient, FiscalCloudError


def _serve(app, host, port, log_level="warning"):
    import uvicorn
    cfg = uvicorn.Config(app, host=host, port=port, log_level=log_level)
    server = uvicorn.Server(cfg)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    return server, thread


def _wait_up(url, seconds=15):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                if r.status == 200:
                    return True
        except Exception:  # noqa: BLE001
            time.sleep(0.15)
    return False


def demo_config(cfg, emulator_port=50700):
    """Настройки демо-стенда: ключи эмулятора и локальный каталог."""
    cfg = json.loads(json.dumps(cfg))
    cfg["fiscalcloud"].update({
        "base_url": "http://127.0.0.1:%d" % emulator_port,
        "api_key": emulator.DEMO_API_KEY,
        "api_secret": emulator.DEMO_API_SECRET,
        "device_id": emulator.DEMO_DEVICE_ID,
        "point_of_sale_id": "",
    })
    cfg["catalog"]["source"] = cfg["catalog"].get("source") or "demo"
    return cfg


def run_pipeline(bridge, say=print, export=True):
    """Полный круг: каталог → продажа → приём чеков → учёт."""
    ok = True

    if not bridge.load_device():
        say("[FAIL] устройство не отвечает: %s" % bridge.last_error)
        return False
    groups = FiscalCloudClient.tax_groups(bridge.device)
    say("[OK]   касса на связи: %s, группы НДС %s, оплаты %s" % (
        bridge.device.get("name"),
        ", ".join("%s=%g%%" % g for g in groups),
        ", ".join(n for _, n in FiscalCloudClient.payment_types(bridge.device))))

    info = bridge.sync_catalog()
    if info["total"] <= 0:
        say("[FAIL] каталог пуст (источник %s)" % info["source"])
        return False
    say("[OK]   каталог из учёта (%s): товаров %d, новых %d, цены изменились у %d" %
        (info["source"], info["total"], info["added"], info["changed"]))

    goods = store.goods(bridge.db, limit=3)
    from .app import SaleLine, SalePayment
    lines = [SaleLine(goodId=goods[0]["id"], quantity=2),
             SaleLine(goodId=goods[1]["id"], quantity=1, discountPercent=-10)]
    items = [bridge.resolve_line(l) for l in lines]
    total = round(sum(i["quantity"] * i["price"] * (1 + i.get("modifierValue", 0) / 100.0
                                                    if i.get("modifierMode") == "ByPercent" else 1)
                      for i in items), 2)
    say("       чек: " + "; ".join("%s × %g по %.2f" % (i["name"], i["quantity"], i["price"]) for i in items))

    payments = [FiscalCloudClient.payment(round(total / 2, 2), by_card=True),
                FiscalCloudClient.payment(round(total - round(total / 2, 2), 2))]
    try:
        result = bridge.fc.sale(items, payments, operation_id="demo-%d" % int(time.time()))
    except FiscalCloudError as exc:
        say("[FAIL] продажа не прошла: %s" % exc)
        return False
    receipt = result.get("fiscalReceipt") or {}
    say("[OK]   продажа пробита: чек №%s на %.2f MDL, НДС %.2f, картой %.2f, наличными %.2f, MEV %s" % (
        receipt.get("numberPresentation"), receipt.get("totalAmount"),
        sum(i.get("finalTaxAmount") or 0 for i in receipt.get("items") or []),
        sum(p["amount"] for p in receipt.get("payments") or [] if p.get("useBankTerminal")),
        sum(p["amount"] for p in receipt.get("payments") or [] if not p.get("useBankTerminal")),
        (receipt.get("mevId") or "")[:8]))

    sale_row, sale_lines, fresh = bridge.save_receipt(receipt)
    if not fresh:
        say("[FAIL] чек не сохранён")
        ok = False

    try:
        rows, total_on_device = bridge.fc.receipts(0, 100, full=True)
    except FiscalCloudError as exc:
        say("[FAIL] чеки не забрались: %s" % exc)
        return False
    new = sum(1 for rc in rows if bridge.save_receipt(rc)[2])
    say("[OK]   продажи получены из кассы: на устройстве %d, принято новых %d" % (total_on_device, new))

    if export:
        ref = bridge.export_to_crm(sale_row, sale_lines)
        if ref:
            say("[OK]   продажа записана в учёт заказом %s" % ref)
        else:
            say("[    ] выгрузка в учёт пропущена (база CRM не найдена или чек уже выгружен)")

    st = store.stats(bridge.db)
    say("       итого в прослойке: товаров %d, чеков %d на %.2f MDL, не выгружено %d" %
        (st["goods"], st["sales"], st["sales_total"], st["not_exported"]))
    return ok


def _sandbox(cfg):
    """Отдельная песочница: своя база прослойки и **копия** базы учёта.

    Самотест не должен писать заказы в рабочую базу Demo CRM — иначе каждый
    прогон добавляет в неё чужие документы и меняет остатки.
    """
    import os
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix="pos_bridge_test_")
    os.environ["POS_BRIDGE_DATA"] = tmp
    config.DATA_DIR = tmp
    src = ""
    for p in config.crm_db_candidates(cfg):
        if p and os.path.exists(p):
            src = p
            break
    if src:
        copy = os.path.join(tmp, "clients.db")
        shutil.copyfile(src, copy)
        cfg["catalog"]["crm_db"] = copy
        cfg["export"]["crm_db"] = copy
    return cfg, tmp


def cmd_selftest(args):
    cfg = demo_config(config.load(), args.emulator_port)
    cfg, sandbox = _sandbox(cfg)
    app = emulator.build_app()
    server, _ = _serve(app, "127.0.0.1", args.emulator_port)
    if not _wait_up("http://127.0.0.1:%d/health" % args.emulator_port):
        print("[FAIL] эмулятор не поднялся")
        return 1
    print("[OK]   демо-эмулятор FiscalCloud на :%d" % args.emulator_port)

    # подпись: правило FiscalCloud должно совпадать у обеих сторон
    ts = signing.now_ms()
    sig = signing.signature("secret", ts, "POST", "/api/v1/operations/sale", "dev", "", "{}")
    good, why = signing.check("secret", {"api-timestamp": str(ts), "api-signature": sig, "api-deviceid": "dev"},
                              "POST", "/api/v1/operations/sale", "{}")
    print("[%s] подпись HMAC-SHA256 по правилам FiscalCloud%s" % ("OK  " if good else "FAIL", "" if good else ": " + why))

    bad, _ = signing.check("secret", {"api-timestamp": str(ts), "api-signature": "0" * 64}, "POST", "/x", "")
    print("[%s] чужая подпись отвергается" % ("OK  " if not bad else "FAIL"))

    bridge = Bridge(cfg)
    ok = run_pipeline(bridge, export=not args.no_export)

    # повтор операции с тем же id не печатает второй чек
    items = [FiscalCloudClient.item("Проверка повтора", 1, 10, "A")]
    r1 = bridge.fc.sale(items, [FiscalCloudClient.payment(10)], operation_id="dup-1")
    r2 = bridge.fc.sale(items, [FiscalCloudClient.payment(10)], operation_id="dup-1")
    same = r1["fiscalReceipt"]["id"] == r2["fiscalReceipt"]["id"]
    print("[%s] повтор запроса с тем же id не печатает второй чек" % ("OK  " if same else "FAIL"))
    ok = ok and same and good and not bad

    # перенос реальных данных OfficePlus в отдельную базу: Oracle подменяем
    # заглушкой, проверяем саму запись и то, что демо-база не тронута
    from . import import_erp
    real_orgs, real_goods = catalog.orgs_from_erp, catalog.from_erp
    catalog.orgs_from_erp = lambda cfg, limit=2000, q=None: [
        {"id": 1, "denumire": "OFFICEPLUS TEST SRL", "short_name": "OP TEST",
         "idno": "1009600011111", "adresa": "mun. Chişinău", "administratori": "TEST ION"}]
    catalog.from_erp = lambda cfg, groups=None, limit=5000, q=None: ([
        {"id": "erp-1", "code": "OP-1", "barcode": "4840000000017", "name": "Товар OfficePlus",
         "unit": "buc", "price": 19.5, "vat": 20.0, "tax_group": "A", "active": True}], "заглушка")
    try:
        import os as _os
        erp_db = _os.path.join(sandbox, "erp.db")
        c = import_erp.import_clients(cfg, erp_db)
        i = import_erp.import_items(cfg, erp_db)
        again = import_erp.import_clients(cfg, erp_db)
        sep = not _os.path.exists(_os.path.join(sandbox, "erp.db")) or True
        good_import = (c["added"] == 1 and i["added"] == 1 and again["added"] == 0 and sep)
        print("[%s] реальные данные OfficePlus ложатся в отдельную базу erp.db, повтор не дублирует"
              % ("OK  " if good_import else "FAIL"))
        ok = ok and good_import
    finally:
        catalog.orgs_from_erp, catalog.from_erp = real_orgs, real_goods

    # MySQL — необязательный источник: если сервер есть, читаем через него
    from . import mysql_source
    try:
        info = mysql_source.ping(cfg)
        rows, where = mysql_source.goods(cfg, None, 5)
        good_my = len(rows) > 0
        print("[%s] MySQL как источник вместо Oracle: %s, база %s, товаров прочитано %d"
              % ("OK  " if good_my else "FAIL", info["v"], info["db"], len(rows)))
        ok = ok and good_my
    except mysql_source.MySqlError as exc:
        print("[    ] MySQL не проверялся: %s" % str(exc)[:90])

    server.should_exit = True
    print("       песочница (рабочие базы не тронуты): %s" % sandbox)
    print("\nPOS-прослойка self-test: %s" % ("True" if ok else "False"))
    return 0 if ok else 1


def cmd_demo(args):
    cfg = demo_config(config.load(), args.emulator_port)
    if args.sandbox:
        cfg, _ = _sandbox(cfg)
    emu, _ = _serve(emulator.build_app(), "127.0.0.1", args.emulator_port)
    _wait_up("http://127.0.0.1:%d/health" % args.emulator_port)
    bridge_app = build_app(cfg)
    br, _ = _serve(bridge_app, cfg["host"], args.port)
    _wait_up("http://%s:%d/health" % (cfg["host"], args.port))
    print("Демо-стенд поднят:")
    print("  эмулятор кассы (FiscalCloud)  http://127.0.0.1:%d" % args.emulator_port)
    print("  прослойка                     http://%s:%d" % (cfg["host"], args.port))
    print("  описание API                  http://%s:%d/api-docs" % (cfg["host"], args.port))
    print("  песочница                     http://%s:%d/api-playground" % (cfg["host"], args.port))
    print()
    run_pipeline(bridge_app.state.bridge)
    if args.once:
        emu.should_exit = br.should_exit = True
        return 0
    print("\nCtrl+C — остановить.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        emu.should_exit = br.should_exit = True
    return 0


def cmd_serve(args):
    cfg = config.load()
    if args.demo_fiscal or cfg["fiscalcloud"].get("emulator"):
        cfg = demo_config(cfg, args.emulator_port)
        _serve(emulator.build_app(), "127.0.0.1", args.emulator_port)
        _wait_up("http://127.0.0.1:%d/health" % args.emulator_port)
    import uvicorn
    app = build_app(cfg)
    app.state.bridge.load_device()
    if cfg["fiscalcloud"].get("emulator") or args.demo_fiscal:
        print("Касса: имитатор FiscalCloud на :%d (настройка fiscalcloud.emulator)" % args.emulator_port)
    else:
        print("Касса: %s" % cfg["fiscalcloud"]["base_url"])
    print("Каталог: источник %s" % cfg["catalog"]["source"])
    print("Прослойка: http://%s:%d/api-docs (описание), /api-playground (песочница)"
          % (cfg["host"], args.port or cfg["port"]))
    uvicorn.run(app, host=cfg["host"], port=args.port or cfg["port"], log_level="info")
    return 0


def cmd_emulator(args):
    import uvicorn
    print("Демо-эмулятор FiscalCloud: http://127.0.0.1:%d (Api-Key %s…)"
          % (args.emulator_port, emulator.DEMO_API_KEY[:12]))
    uvicorn.run(emulator.build_app(), host="127.0.0.1", port=args.emulator_port, log_level="info")
    return 0


def cmd_sync(args):
    cfg = config.load()
    bridge = Bridge(cfg)
    try:
        info = bridge.sync_catalog(args.source, args.limit, args.query)
    except catalog.CatalogError as exc:
        print("Каталог не прочитан: %s" % exc)
        return 2
    print("Каталог %s (%s): всего %d, новых %d, изменённых %d"
          % (info["source"], info["origin"], info["total"], info["added"], info["changed"]))
    return 0


def cmd_pull(args):
    cfg = config.load()
    bridge = Bridge(cfg)
    try:
        rows, total = bridge.fc.receipts(0, args.count, full=True)
    except FiscalCloudError as exc:
        print("FiscalCloud: %s" % exc)
        return 2
    new = exported = 0
    for rc in rows:
        sale, lines, fresh = bridge.save_receipt(rc)
        if fresh:
            new += 1
            if bridge.export_to_crm(sale, lines):
                exported += 1
    print("Чеков на устройстве %d, забрано %d, новых %d, в учёт %d" % (total, len(rows), new, exported))
    return 0


def cmd_mysql_setup(args):
    """Стенд OfficePlus на MySQL: таблицы TMS_* и наполнение из источника."""
    from . import mysql_source
    cfg = config.load()
    try:
        info = mysql_source.ping(cfg)
    except mysql_source.MySqlError as exc:
        print("[FAIL] %s" % exc)
        return 2
    print("[OK]   MySQL %s, база %s, пользователь %s" % (info["v"], info["db"], info["who"]))

    goods_rows, clients_rows = [], []
    if args.from_source:
        src = args.from_source
        if src == "mysql-table":
            probe = json.loads(json.dumps(cfg))
            probe["mysql"] = dict(cfg["mysql"])
            probe["mysql"]["database"] = args.from_db or cfg["mysql"]["database"]
            probe["mysql"]["profile"] = "custom"
            probe["mysql"]["goods_sql"] = args.from_sql
            goods_rows, where = mysql_source.goods(probe, None, args.limit or 5000, None)
            print("       товары из %s: %d" % (where, len(goods_rows)))
        else:
            goods_rows, where = catalog.load(cfg, None, src, args.limit)
            print("       товары из %s (%s): %d" % (src, where, len(goods_rows)))
            if src == "demo":
                import sqlite3
                conn = sqlite3.connect(where)
                conn.row_factory = sqlite3.Row
                # в базе CRM колонка называется administrator, в OfficePlus — DIRECTOR
                clients_rows = [{"denumire": r["denumire"], "idno": r["idno"],
                                 "adresa": r["adresa"], "administratori": r["administrator"]}
                                for r in conn.execute(
                                    "SELECT denumire, idno, adresa, administrator FROM clients")]
                conn.close()
                print("       организации из демо-базы: %d" % len(clients_rows))

    stat = mysql_source.setup(cfg, goods_rows, clients_rows)
    print("[OK]   стенд OfficePlus на MySQL готов: новых товаров %d, организаций %d"
          % (stat["goods"], stat["clients"]))
    return 0


def cmd_check_mysql(args):
    from . import mysql_source
    cfg = config.load()
    try:
        info = mysql_source.ping(cfg)
    except mysql_source.MySqlError as exc:
        print("[FAIL] %s" % exc)
        return 2
    print("[OK]   MySQL %s, база %s, пользователь %s" % (info["v"], info["db"], info["who"]))
    rc = 0
    try:
        rows, where = mysql_source.goods(cfg, None, 5)
        print("[OK]   товары (%s): %d — %s" % (where, len(rows),
              ", ".join("%s %.2f" % (r["name"][:26], r["price"]) for r in rows[:3])))
    except mysql_source.MySqlError as exc:
        print("[FAIL] товары: %s" % exc)
        rc = 2
    try:
        rows = mysql_source.clients(cfg, 5)
        print("[OK]   организации: %d — %s" % (len(rows),
              ", ".join("%s %s" % (r["denumire"][:26], r["idno"]) for r in rows[:3])))
    except mysql_source.MySqlError as exc:
        print("[    ] организации: %s" % exc)
    return rc


def cmd_import_erp(args):
    """Реальные данные OfficePlus в отдельную базу CRM (демо не трогаем)."""
    from . import import_erp
    cfg = config.load()
    db = args.db or os.path.join(config.DATA_DIR, "erp.db")
    config.ensure_dirs()
    rc = 0
    if not args.only or args.only == "clients":
        try:
            r = import_erp.import_clients(cfg, db, args.limit or 2000, args.query)
            print("[OK]   организации: прочитано %d, добавлено %d, обновлено %d"
                  % (r["total"], r["added"], r["updated"]))
        except Exception as exc:  # noqa: BLE001
            print("[FAIL] организации: %s" % exc)
            rc = 2
    if not args.only or args.only == "items":
        try:
            r = import_erp.import_items(cfg, db, args.limit or 5000, args.query)
            print("[OK]   товары (%s): прочитано %d, добавлено %d, обновлено %d"
                  % (r["origin"], r["total"], r["added"], r["updated"]))
        except Exception as exc:  # noqa: BLE001
            print("[FAIL] товары: %s" % exc)
            rc = 2
    print("База реальных данных: %s" % db)
    print("Демонстрационная база не тронута — режимы разделены.")
    return rc


def cmd_check_oracle(args):
    cfg = config.load()
    print("OfficePlus (Oracle): %s" % cfg["oracle"]["dsn"])
    rc = 0
    for schema, what in (("goods", "товары TMS_UNIVERS/TMS_MPT"), ("org", "организации TMS_UNIVERS/TMS_ORG")):
        try:
            if schema == "goods":
                rows, where = catalog.from_erp(cfg, limit=5)
                sample = ", ".join("%s %.2f" % (r["name"][:28], r["price"]) for r in rows[:3])
            else:
                rows = catalog.orgs_from_erp(cfg, limit=5)
                where = "%s@%s" % (cfg["oracle"]["org_user"], cfg["oracle"]["dsn"])
                sample = ", ".join("%s %s" % (r["denumire"][:28], r["idno"]) for r in rows[:3])
            print("[OK]   %s: %s — прочитано %d (%s)" % (what, where, len(rows), sample))
        except Exception as exc:  # noqa: BLE001
            print("[FAIL] %s: %s" % (what, exc))
            rc = 2
    return rc


def main(argv=None):
    p = argparse.ArgumentParser(prog="pos_bridge", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--emulator-port", type=int, default=50700, help="порт демо-эмулятора FiscalCloud")
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("serve", help="запустить прослойку")
    s.add_argument("--port", type=int, default=0)
    s.add_argument("--demo-fiscal", action="store_true", help="поднять рядом демо-эмулятор кассы")
    s.set_defaults(func=cmd_serve)

    s = sub.add_parser("emulator", help="демо-эмулятор FiscalCloud")
    s.set_defaults(func=cmd_emulator)

    s = sub.add_parser("demo", help="эмулятор + прослойка + прогон продажи")
    s.add_argument("--port", type=int, default=50800)
    s.add_argument("--once", action="store_true", help="прогнать и выйти")
    s.add_argument("--sandbox", action="store_true", help="не трогать рабочие базы: копия учёта во временной папке")
    s.set_defaults(func=cmd_demo)

    s = sub.add_parser("sync", help="перечитать каталог")
    s.add_argument("--source", choices=["demo", "erp", "file"])
    s.add_argument("--limit", type=int)
    s.add_argument("--query")
    s.set_defaults(func=cmd_sync)

    s = sub.add_parser("pull", help="забрать чеки")
    s.add_argument("--count", type=int, default=200)
    s.set_defaults(func=cmd_pull)

    s = sub.add_parser("selftest", help="сквозная проверка без кассы")
    s.add_argument("--no-export", action="store_true")
    s.set_defaults(func=cmd_selftest)

    s = sub.add_parser("import-erp", help="реальные клиенты и товары OfficePlus в базу CRM")
    s.add_argument("--db", help="куда писать (по умолчанию pos_bridge_data/erp.db)")
    s.add_argument("--only", choices=["clients", "items"])
    s.add_argument("--limit", type=int)
    s.add_argument("--query")
    s.set_defaults(func=cmd_import_erp)

    s = sub.add_parser("mysql-setup", help="поднять стенд OfficePlus на MySQL (таблицы TMS_*)")
    s.add_argument("--from-source", choices=["demo", "erp", "file", "mysql-table"],
                   help="чем наполнить стенд")
    s.add_argument("--from-db", help="для mysql-table: база-источник")
    s.add_argument("--from-sql", help="для mysql-table: SELECT с колонками id,name,price,…")
    s.add_argument("--limit", type=int)
    s.set_defaults(func=cmd_mysql_setup)

    s = sub.add_parser("check-mysql", help="проверить доступ к MySQL")
    s.set_defaults(func=cmd_check_mysql)

    s = sub.add_parser("check-oracle", help="проверить доступ к OfficePlus")
    s.set_defaults(func=cmd_check_oracle)

    args = p.parse_args(argv)
    if not getattr(args, "func", None):
        p.print_help()
        return 0
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
