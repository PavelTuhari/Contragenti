# -*- coding: utf-8 -*-
"""
Проверка дедупликации при одновременной работе нескольких клиентов.

Три клиента параллельно пишут ОДИН И ТОТ ЖЕ набор контрагентов в общую
сводную схему. Проверяется главное свойство: сколько бы клиентов ни писали
одну организацию, в справочнике она должна появиться ровно один раз.

Запись здесь настоящая — при откате клиенты не видят строк друг друга и
дедупликация не проверяется в принципе. Поэтому работаем только со схемами,
где разрешено удаление, и в конце убираем за собой.

    python tools/dedup_test.py --count 1000
    python tools/dedup_test.py --count 1000 --keep    # не убирать (для разбора)
"""

import argparse
import collections
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import oracledb  # noqa: E402
import tms_multi  # noqa: E402

DSN = os.environ.get("TMS_DSN", "192.168.0.24:1521/clouddev.world")
CD = os.environ.get("ORACLE_CLIENT_DIR", "C:/oracle/instantclient_19_28")



def _pwd(var, schema):
    """Пароль только из окружения — в репозитории паролей нет."""
    value = os.environ.get(var)
    if not value:
        sys.exit(f"Не задана переменная окружения {var} (пароль схемы {schema}).")
    return value


# только схемы, где удаление разрешено — иначе за собой не убрать
TARGETS = [
    {"name": "DIRLOC2016", "user": "DIRLOC2016",
     "password": _pwd("DIRLOC_PWD", "DIRLOC2016"),
     "dsn": DSN, "client_dir": CD},
    {"name": "paralax", "user": "paralax",
     "password": _pwd("HUB_SCHEMA_PWD", "paralax"),
     "dsn": DSN, "client_dir": CD},
]
PREFIX = "9399"          # коды ровно 13 знаков, проверено на отсутствие пересечений
CLIENTS = 3


def make_records(roots, count):
    recs = []
    for i in range(count):
        root = roots[i % len(roots)]
        recs.append({
            "idno": f"{PREFIX}{i:09d}",
            "denumire": f"Societatea cu Raspundere Limitata {root} DEDUP",
            "adresa": f"mun. Chişinău, str. {root.title()}, {i % 200 + 1}",
            "administratori": f"{root.title()} ION [Administrator]",
        })
    return recs


def run_client(label, records, out, lock):
    mx = tms_multi.MultiExporter(TARGETS).connect()
    stat = collections.defaultdict(collections.Counter)
    races = collections.Counter()
    errors = collections.defaultdict(collections.Counter)
    for rec in records:
        rep = mx.export_one(rec)                 # РЕАЛЬНАЯ запись
        for name, res in rep["targets"].items():
            status = res.get("status", "?")
            stat[name][status] += 1
            if res.get("race"):
                races[name] += 1
            if status == "error":
                errors[name][str(res.get("error", "?"))[:70]] += 1
    mx.close()
    with lock:
        out[label] = {"stat": {k: dict(v) for k, v in stat.items()},
                      "races": dict(races),
                      "errors": {k: dict(v) for k, v in errors.items()}}


def audit(records):
    """Сколько строк реально появилось и нет ли повторов."""
    idnos = {r["idno"] for r in records}
    report = {}
    for tgt in TARGETS:
        conn = oracledb.connect(user=tgt["user"], password=tgt["password"], dsn=DSN)
        cur = conn.cursor()
        try:
            cur.execute("""SELECT COUNT(*) FROM tms_univers
                            WHERE codvechi LIKE :p || '%' AND LENGTH(codvechi) = 13""",
                        p=PREFIX)
            total = cur.fetchone()[0]
            cur.execute("""SELECT codvechi, COUNT(*) c FROM tms_univers
                            WHERE codvechi LIKE :p || '%' AND LENGTH(codvechi) = 13
                            GROUP BY codvechi HAVING COUNT(*) > 1""", p=PREFIX)
            dupes = cur.fetchall()
            cur.execute("""SELECT COUNT(*) FROM tms_org o JOIN tms_univers u
                             ON u.cod = o.cod
                            WHERE u.codvechi LIKE :p || '%'
                              AND LENGTH(u.codvechi) = 13""", p=PREFIX)
            with_org = cur.fetchone()[0]
            report[tgt["name"]] = {"rows": total, "expected": len(idnos),
                                   "dupes": dupes, "with_org": with_org}
        finally:
            conn.close()
    return report


def cleanup():
    out = {}
    for tgt in TARGETS:
        conn = oracledb.connect(user=tgt["user"], password=tgt["password"], dsn=DSN)
        cur = conn.cursor()
        try:
            sub = ("SELECT cod FROM tms_univers WHERE codvechi LIKE :p || '%' "
                   "AND LENGTH(codvechi) = 13")
            for stmt in (f"DELETE FROM tms_org26 WHERE cod IN ({sub})",
                         f"DELETE FROM tms_org_accounts WHERE cod_org IN ({sub})",
                         f"DELETE FROM tms_org WHERE cod IN ({sub})"):
                try:
                    cur.execute(stmt, p=PREFIX)
                except Exception:
                    pass
            try:
                cur.execute("DELETE FROM tms_univers_uniqk WHERE codvechi LIKE :p || '%' "
                            "AND LENGTH(codvechi) = 13", p=PREFIX)
            except Exception:
                pass
            cur.execute("DELETE FROM tms_univers WHERE codvechi LIKE :p || '%' "
                        "AND LENGTH(codvechi) = 13", p=PREFIX)
            conn.commit()
            cur.execute("SELECT COUNT(*) FROM tms_univers WHERE codvechi LIKE :p || '%' "
                        "AND LENGTH(codvechi) = 13", p=PREFIX)
            out[tgt["name"]] = cur.fetchone()[0]
        except Exception as exc:
            conn.rollback()
            out[tgt["name"]] = f"ошибка: {str(exc).splitlines()[0][:50]}"
        finally:
            conn.close()
    return out


def main():
    ap = argparse.ArgumentParser(description="Дедупликация при конкурентной записи")
    ap.add_argument("--count", type=int, default=1000)
    ap.add_argument("--keep", action="store_true", help="не убирать записи после теста")
    ap.add_argument("--roots", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "roots.txt"))
    args = ap.parse_args()

    with open(args.roots, encoding="utf-8") as f:
        roots = [r.strip() for r in f if r.strip()]
    records = make_records(roots, args.count)

    print(f"контрагентов в наборе: {len(records)}")
    print(f"клиентов: {CLIENTS} (пишут ОДИН И ТОТ ЖЕ набор одновременно)")
    print(f"схемы: {', '.join(t['name'] for t in TARGETS)}")
    print("режим: РЕАЛЬНАЯ ЗАПИСЬ\n")

    out, lock = {}, threading.Lock()
    threads = [threading.Thread(target=run_client,
                                args=(f"Клиент-{i+1}", records, out, lock))
               for i in range(CLIENTS)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - t0

    print(f"── что вернули клиенты (за {elapsed:.1f} с) ──")
    totals = collections.defaultdict(collections.Counter)
    for label in sorted(out):
        print(f"  {label}")
        for schema, counts in out[label]["stat"].items():
            races = out[label]["races"].get(schema, 0)
            print(f"     {schema:<12} {dict(counts)}"
                  f"{f'   из них гонок: {races}' if races else ''}")
            for msg, cnt in (out[label].get("errors", {}).get(schema, {})).items():
                print(f"        × {cnt:<4} {msg}")
            totals[schema].update(counts)

    print("\n── что получилось в базе ──")
    ok = True
    for schema, r in audit(records).items():
        good = (r["rows"] == r["expected"] and not r["dupes"])
        ok = ok and good
        print(f"  {schema:<12} строк {r['rows']} из {r['expected']} ожидаемых, "
              f"с блоком реквизитов {r['with_org']} — "
              f"{'дублей нет' if not r['dupes'] else f'ДУБЛИ: {r[chr(34)+chr(34)]}'}")
        created = totals[schema].get("ok", 0)
        dup = totals[schema].get("duplicate", 0)
        err = totals[schema].get("error", 0)
        print(f"               клиенты: создано {created}, дублей {dup}, ошибок {err}"
              f"   (сумма {created + dup + err} = {CLIENTS} × {len(records)})")

    print(f"\nИТОГ: {'дедупликация работает' if ok else 'ЕСТЬ РАСХОЖДЕНИЯ'}")

    if args.keep:
        print("\nзаписи оставлены (--keep)")
    else:
        print("\n── уборка ──")
        for schema, left in cleanup().items():
            print(f"  {schema:<12} осталось {left}")


if __name__ == "__main__":
    main()
