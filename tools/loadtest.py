# -*- coding: utf-8 -*-
"""
Комплексное тестирование: несколько клиентов, каждый на своей паре схем.

Поднимает по потоку на клиента; каждый прогоняет словарь корневых названий
через весь боевой конвейер: разбор наименования → дедупликация → запись
блоков TMS_UNIVERS / TMS_ORG / TMS_ORG26 в свою схему и в сводную.

По умолчанию все транзакции откатываются (--dry-run): конвейер проверяется
целиком, но общая база не засоряется. Реальная запись включается явно
через --commit и только для указанного числа записей.

    python tools/loadtest.py                      # 1000 названий, откат
    python tools/loadtest.py --count 50 --commit  # 50 записей по-настоящему
"""

import argparse
import collections
import itertools
import os
import random
import statistics
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import legal_forms  # noqa: E402
import tms_multi  # noqa: E402

DSN = os.environ.get("TMS_DSN", "192.168.0.24:1521/clouddev.world")
CLIENT_DIR = os.environ.get("ORACLE_CLIENT_DIR", "C:/oracle/instantclient_19_28")


def _pwd(var, schema):
    """Пароль только из окружения — в репозитории паролей нет."""
    value = os.environ.get(var)
    if not value:
        sys.exit(f"Не задана переменная окружения {var} (пароль схемы {schema}).")
    return value


HUB = ("paralax", _pwd("HUB_SCHEMA_PWD", "paralax"))

# три клиента, каждый работает со своей схемой и общей сводной
CLIENTS = [
    ("Клиент-1", "ARTIMA", _pwd("ARTIMA_PWD", "ARTIMA")),
    ("Клиент-2", "DIRLOC2016", _pwd("DIRLOC_PWD", "DIRLOC2016")),
    ("Клиент-3", "DTP2016", _pwd("DTP_PWD", "DTP2016")),
]

# формы, которыми обрастают корни: та же смесь написаний, что на портале
FORMS = [
    "Societatea cu Raspundere Limitata {r}",
    "SOCIETATEA CU RASPUNDERE LIMITATA {r}",
    "Societatea Comerciala {r} S.R.L.",
    "Societatea pe Actiuni {r}",
    "Intreprinderea cu Capital Strain {r} S.R.L.",
    "Intreprinderea Mixta {r} S.R.L.",
    "Intreprinderea Individuala {r}",
    "Cooperativa de Intreprinzator {r}",
    "Gospodaria Taraneasca {r}",
    "Organizatia de Microfinantare {r} S.R.L.",
    "Firma {r} S.R.L.",
    "Reprezentanta din Moldova a companiei {r} S.R.L.",
]


def load_roots(path):
    with open(path, encoding="utf-8") as f:
        return [r.strip() for r in f if r.strip()]


def make_records(roots, seed, prefix):
    """Синтетические карточки: реальные корни + разные правовые формы.

    IDNO делаем заведомо несуществующим и уникальным для клиента, чтобы
    прогоны разных клиентов не мешали друг другу.
    """
    rnd = random.Random(seed)
    recs = []
    for i, root in enumerate(roots):
        tpl = FORMS[i % len(FORMS)]
        recs.append({
            "idno": f"{prefix}{i:08d}"[:13],
            "denumire": tpl.format(r=root),
            "adresa": f"mun. Chişinău, str. {root.title()}, {rnd.randint(1, 200)}",
            "administratori": f"{root.title()} ION [Administrator]",
        })
    return recs


class ClientRun(threading.Thread):
    """Один клиент: своя схема + сводная."""

    def __init__(self, label, user, password, records, dry_run, log_lock):
        super().__init__(daemon=True)
        self.label = label
        self.user = user
        self.password = password
        self.records = records
        self.dry_run = dry_run
        self.log_lock = log_lock
        self.stats = collections.defaultdict(
            lambda: {"ok": 0, "dup": 0, "err": 0, "errors": collections.Counter()})
        self.durations = []
        self.connect_error = None
        self.schemas = []

    def say(self, msg):
        with self.log_lock:
            print(f"  [{self.label}] {msg}", flush=True)

    def run(self):
        targets = [
            {"name": self.user, "user": self.user, "password": self.password,
             "dsn": DSN, "client_dir": CLIENT_DIR},
            {"name": HUB[0], "user": HUB[0], "password": HUB[1],
             "dsn": DSN, "client_dir": CLIENT_DIR},
        ]
        mx = tms_multi.MultiExporter(targets).connect()
        self.schemas = list(mx.exporters)
        if not mx.ready:
            self.connect_error = "; ".join(f"{k}: {v}" for k, v in mx.errors.items())
            self.say(f"подключение не удалось: {self.connect_error}")
            return
        if mx.errors:
            self.say(f"часть схем недоступна: {mx.errors}")
        self.say(f"схемы: {', '.join(self.schemas)}; записей: {len(self.records)}")

        try:
            for n, rec in enumerate(self.records, 1):
                t0 = time.perf_counter()
                rep = mx.export_one(rec, dry_run=self.dry_run)
                self.durations.append(time.perf_counter() - t0)
                for name, res in rep["targets"].items():
                    st = self.stats[name]
                    status = res.get("status")
                    if status in ("ok", "dry_run"):
                        st["ok"] += 1
                    elif status == "duplicate":
                        st["dup"] += 1
                    else:
                        st["err"] += 1
                        st["errors"][str(res.get("error", status))[:60]] += 1
                if n % 100 == 0:
                    self.say(f"{n}/{len(self.records)}")
        finally:
            mx.close()
        self.say("готово")


def check_normalization(records):
    """Разбор наименований — отдельная проверка, до всякой базы."""
    bad_form, overlong, empty = [], [], []
    forms = collections.Counter()
    tips = collections.Counter()
    for rec in records:
        p = legal_forms.parse_name(rec["denumire"])
        forms[p["forma"] or "—"] += 1
        tips[p["tip"] or "—"] += 1
        if not p["forma"] and not p["tip"]:
            bad_form.append(rec["denumire"])
        if len(p["short"]) > 80:
            overlong.append(p["short"])
        if not p["nume"]:
            empty.append(rec["denumire"])
    return {"forms": forms, "tips": tips, "bad_form": bad_form,
            "overlong": overlong, "empty": empty}


def main():
    ap = argparse.ArgumentParser(description="Комплексный тест: три клиента, три базы")
    ap.add_argument("--roots", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "roots.txt"))
    ap.add_argument("--count", type=int, default=0, help="ограничить число названий")
    ap.add_argument("--commit", action="store_true",
                    help="писать по-настоящему (по умолчанию — откат)")
    ap.add_argument("--shared", action="store_true",
                    help="все клиенты пишут ОДИН И ТОТ ЖЕ набор контрагентов — "
                         "проверка дедупликации при одновременной записи")
    args = ap.parse_args()

    roots = load_roots(args.roots)
    if args.count:
        roots = roots[:args.count]
    dry_run = not args.commit

    print(f"словарь корней: {len(roots)}")
    print(f"клиентов: {len(CLIENTS)}   режим: "
          f"{'ОТКАТ (база не меняется)' if dry_run else 'РЕАЛЬНАЯ ЗАПИСЬ'}"
          f"{'   НАБОР ОБЩИЙ (проверка дублей)' if args.shared else ''}\n")

    # 1) разбор наименований — без базы
    sample = make_records(roots, 1, "9100")
    norm = check_normalization(sample)
    print("── разбор наименований ──")
    print("  формы :", dict(norm["forms"].most_common()))
    print("  типы  :", dict(norm["tips"].most_common()))
    print(f"  не распознано: {len(norm['bad_form'])}   "
          f"длиннее 80: {len(norm['overlong'])}   пустое имя: {len(norm['empty'])}")
    for s in norm["bad_form"][:5]:
        print("    ?", s)

    # 2) три клиента параллельно
    print("\n── запись в схемы ──")
    lock = threading.Lock()
    runs = []
    for i, (label, user, pwd) in enumerate(CLIENTS):
        # общий набор — одинаковые IDNO у всех клиентов: так проверяется
        # поведение дедупликации при одновременной записи в сводную схему
        recs = make_records(roots, i, "915" if args.shared else f"91{i}")
        runs.append(ClientRun(label, user, pwd, recs, dry_run, lock))
    t0 = time.perf_counter()
    for r in runs:
        r.start()
    for r in runs:
        r.join()
    elapsed = time.perf_counter() - t0

    # 3) отчёт
    print(f"\n── итог за {elapsed:.1f} с ──")
    total_ops = 0
    for r in runs:
        if r.connect_error:
            print(f"  {r.label:<10} НЕ ПОДКЛЮЧИЛСЯ: {r.connect_error[:60]}")
            continue
        med = statistics.median(r.durations) if r.durations else 0
        p95 = (statistics.quantiles(r.durations, n=20)[18]
               if len(r.durations) >= 20 else med)
        print(f"  {r.label:<10} записей {len(r.records):<5} "
              f"медиана {med*1000:6.0f} мс   p95 {p95*1000:6.0f} мс")
        for schema, st in r.stats.items():
            total_ops += st["ok"] + st["dup"] + st["err"]
            line = (f"     {schema:<12} успешно {st['ok']:<5} дублей {st['dup']:<5} "
                    f"ошибок {st['err']}")
            print(line)
            for msg, cnt in st["errors"].most_common(3):
                print(f"        × {cnt:<4} {msg}")
    if elapsed > 0:
        print(f"\n  операций записи всего: {total_ops}  "
              f"({total_ops/elapsed:.1f} в секунду)")


if __name__ == "__main__":
    main()
