# -*- coding: utf-8 -*-
"""Снимок окна имитатора кассы: поднять, наполнить, сфотографировать, закрыть."""

import json
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, ".")

from pos_bridge import signing                      # noqa: E402
from pos_bridge.fc_emulator import gui, settings    # noqa: E402
from pos_bridge.fc_emulator.server import API       # noqa: E402


def main():
    dst = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 50719
    cfg = settings.load()
    cfg["port"] = port
    window = gui.EmulatorWindow(cfg)
    window.on_start()

    def call(path, body):
        raw = json.dumps(body, ensure_ascii=False)
        headers = signing.headers_for(API["key"], API["secret"], "POST", path,
                                      device_id=cfg["device"]["id"], body=raw)
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), method="POST",
                                     data=raw.encode("utf-8"), headers=headers)
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode())

    call("/api/v1/operations/sale", {
        "items": [{"name": "Panou cu logo (acril, LED)", "quantity": 2, "price": 186.50, "taxGroupCode": "A"},
                  {"name": "Montaj si punere in functiune", "quantity": 1, "price": 350, "taxGroupCode": "A"}],
        "payments": [{"typeCode": 1, "amount": 500, "useBankTerminal": True},
                     {"typeCode": 0, "amount": 223}]})
    window.refresh()
    kids = window.docs.get_children()
    if kids:
        window.docs.selection_set(kids[0])
        window.on_pick_doc()
    root = window.root
    root.lift()
    root.attributes("-topmost", True)
    root.update()
    time.sleep(1.2)
    root.update()
    x, y = root.winfo_rootx(), root.winfo_rooty()
    w, h = root.winfo_width(), root.winfo_height()
    subprocess.run(["screencapture", "-x", "-R", "%d,%d,%d,%d" % (x - 6, y - 30, w + 12, h + 36), dst])
    root.attributes("-topmost", False)
    window.on_close()


if __name__ == "__main__":
    main()
