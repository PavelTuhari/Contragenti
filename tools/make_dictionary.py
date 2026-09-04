# -*- coding: utf-8 -*-
"""
Словарь корневых названий для нагрузочного теста.

Корни берём из реальных наименований справочника: так тест бьёт по тем же
формам, сокращениям и диакритике, что встречаются в работе, а не по
выдуманным строкам.

    python tools/make_dictionary.py --count 1000 --out tools/roots.txt
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import legal_forms  # noqa: E402
import tms_export  # noqa: E402

STOP = {"SRL", "SA", "COM", "GRUP", "COMPANY", "PRIM", "PLUS", "TEST"}


def collect(cfg, limit):
    exp = tms_export.TmsExporter(cfg).connect()
    cur = exp.conn.cursor()
    cur.execute("SELECT denumirea FROM tms_univers WHERE tip = 'O' AND denumirea IS NOT NULL")
    roots, seen = [], set()
    for (name,) in cur.fetchall():
        nume = legal_forms.parse_name(name)["nume"]
        # корень — первое содержательное слово названия
        for token in re.split(r"[\s,./\\\"'«»()-]+", nume):
            token = token.strip().upper()
            if len(token) < 4 or not token.isalpha() or token in STOP:
                continue
            if token in seen:
                continue
            seen.add(token)
            roots.append(token)
            break
        if len(roots) >= limit:
            break
    exp.close()
    return roots


def main():
    ap = argparse.ArgumentParser(description="Словарь корней для нагрузочного теста")
    ap.add_argument("--count", type=int, default=1000)
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "roots.txt"))
    ap.add_argument("--user", default=os.environ.get("TMS_USER", "paralax"))
    args = ap.parse_args()

    cfg = dict(tms_export.DEFAULT_CONFIG)
    cfg["user"] = args.user
    cfg["password"] = os.environ.get("TMS_PASSWORD") or os.environ.get("ORA_PWD", "")
    if not cfg["password"]:
        sys.exit("нужен TMS_PASSWORD или ORA_PWD")

    roots = collect(cfg, args.count)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(roots))
    print(f"корней собрано: {len(roots)} → {args.out}")
    print("примеры:", ", ".join(roots[:12]))


if __name__ == "__main__":
    main()
