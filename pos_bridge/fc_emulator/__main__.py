# -*- coding: utf-8 -*-
"""
Имитатор FiscalCloud — отдельная программа.

    python -m pos_bridge.fc_emulator              окно (если есть tkinter)
    python -m pos_bridge.fc_emulator serve        сервер без окна (Linux, служба)
    python -m pos_bridge.fc_emulator config       показать файл настроек, создать при отсутствии
    python -m pos_bridge.fc_emulator install-service   вывести unit для systemd
    python -m pos_bridge.fc_emulator conformance  сверка с описанием FiscalCloud
"""

import argparse
import os
import sys

from . import settings as cfg_mod
from .service import Emulator, install_signal_handlers, setup_logging, unit_text


def cmd_gui(args):
    from . import gui
    if not gui.available():
        print("tkinter недоступен — запускайте без окна: python -m pos_bridge.fc_emulator serve")
        return 2
    cfg = cfg_mod.load(args.config)
    if args.host:
        cfg["host"] = args.host
    if args.port:
        cfg["port"] = args.port
    gui.run(cfg, autostart=not args.no_start)
    return 0


def cmd_serve(args):
    cfg = cfg_mod.load(args.config)
    if args.host:
        cfg["host"] = args.host
    if args.port:
        cfg["port"] = args.port
    setup_logging(cfg.get("logPath") or "")
    emulator = Emulator(cfg)
    install_signal_handlers(emulator)
    print("Имитатор FiscalCloud: %s" % emulator.address)
    print("Описание API: %s/openapi.json" % emulator.address)
    print("Состояние: %s" % emulator.state_path)
    sys.stdout.flush()
    try:
        emulator.start(blocking=True)
    except KeyboardInterrupt:
        emulator.stop()
    return 0


def cmd_config(args):
    path = args.config or cfg_mod.config_path()
    cfg = cfg_mod.load(path)
    if not os.path.exists(path) or args.write:
        cfg_mod.save(cfg, path)
        print("Файл настроек создан: %s" % path)
    else:
        print("Файл настроек: %s" % path)
    print("  адрес      %s:%s" % (cfg["host"], cfg["port"]))
    print("  устройство %s, %s" % (cfg["device"]["organizationName"], cfg["device"]["serialNumber"]))
    print("  Api-Key    %s…" % cfg["apiKey"][:16])
    print("  состояние  %s" % cfg["statePath"])
    print("  журнал     %s" % (cfg["logPath"] or "только в консоль"))
    return 0


def cmd_install_service(args):
    # какой файл настроек пропишем службе: свой ключ или общий --config
    conf = args.service_config or args.config
    text = unit_text(python=args.python, config=conf, workdir=args.workdir, user=args.user)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print("Unit записан: %s" % args.out)
    else:
        sys.stdout.write(text)
    print("\n# установка:\n"
          "#   sudo cp fiscalcloud-emulator.service /etc/systemd/system/\n"
          "#   sudo systemctl daemon-reload && sudo systemctl enable --now fiscalcloud-emulator\n"
          "#   systemctl status fiscalcloud-emulator")
    return 0


def cmd_conformance(args):
    import threading
    import time

    import uvicorn

    from . import conformance
    from .server import build_app, configure
    cfg = cfg_mod.load(args.config)
    configure(cfg)
    port = args.port or 50799
    server = uvicorn.Server(uvicorn.Config(build_app(), host="127.0.0.1", port=port,
                                           log_level="warning", access_log=False))
    threading.Thread(target=server.run, daemon=True).start()
    for _ in range(100):
        if getattr(server, "started", False):
            break
        time.sleep(0.05)
    ok = conformance.run("http://127.0.0.1:%d" % port)
    server.should_exit = True
    print("\nСоответствие описанию FiscalCloud: %s" % ("True" if ok else "False"))
    return 0 if ok else 1


def main(argv=None):
    p = argparse.ArgumentParser(prog="pos_bridge.fc_emulator", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", help="файл настроек")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("gui", help="окно программы")
    s.add_argument("--no-start", action="store_true", help="не запускать сервер сразу")
    s.set_defaults(func=cmd_gui)

    s = sub.add_parser("serve", help="сервер без окна")
    s.set_defaults(func=cmd_serve)

    s = sub.add_parser("config", help="файл настроек")
    s.add_argument("--write", action="store_true", help="перезаписать значениями по умолчанию")
    s.set_defaults(func=cmd_config)

    s = sub.add_parser("install-service", help="unit systemd для Linux")
    s.add_argument("--out", help="куда записать (по умолчанию — на экран)")
    s.add_argument("--python", help="путь к интерпретатору")
    s.add_argument("--workdir", help="рабочий каталог")
    s.add_argument("--user", help="от какого пользователя запускать")
    s.add_argument("--service-config", help="файл настроек, который пропишем службе")
    s.set_defaults(func=cmd_install_service)

    s = sub.add_parser("conformance", help="сверка с описанием API")
    s.set_defaults(func=cmd_conformance)

    args = p.parse_args(argv)
    # без подкоманды — окно, а на сервере без tkinter сразу сервер
    if not getattr(args, "func", None):
        from . import gui
        if gui.available():
            args.no_start = False
            return cmd_gui(args)
        return cmd_serve(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
