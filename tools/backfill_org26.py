# -*- coding: utf-8 -*-
"""
Дозаполнение уже импортированных организаций una.md.

Приводит ранее загруженные записи к текущему соглашению:
  * TMS_UNIVERS.CODVECHI = IDNO, GR1 = 'E'
      — так система сама следит за уникальностью фискального кода
  * TMS_UNIVERS.DENUMIREA = сокращённое название (форма → аббревиатура)
  * TMS_UNIVERS.NAMERUS   = исходное наименование с портала
  * TMS_ORG26             = нормализованные тип предприятия и юр. форма

Запуск:
    python tools/backfill_org26.py --dry-run     # показать, ничего не менять
    python tools/backfill_org26.py --from 10314  # применить с указанного COD
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import oracledb  # noqa: E402
import legal_forms  # noqa: E402
import tms_export  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description="Дозаполнение TMS_ORG26 и полей TMS_UNIVERS")
    ap.add_argument("--dry-run", action="store_true", help="показать изменения без записи")
    ap.add_argument("--from", dest="cod_from", type=int, default=0,
                    help="обрабатывать записи с COD больше указанного")
    ap.add_argument("--limit", type=int, default=0, help="ограничить число записей")
    args = ap.parse_args()

    cfg = dict(tms_export.DEFAULT_CONFIG)
    cfg["password"] = os.environ.get("TMS_PASSWORD") or os.environ.get("ORA_PWD", "")
    if not cfg["password"]:
        sys.exit("Не задан пароль: TMS_PASSWORD или ORA_PWD")

    exp = tms_export.TmsExporter(cfg).connect()
    conn = exp.conn
    cur = conn.cursor()

    cur.execute("""
        SELECT u.cod, u.denumirea, u.namerus, u.codvechi, u.gr1, o.codfiscal
          FROM tms_univers u JOIN tms_org o ON o.cod = u.cod
         WHERE u.cod > :c AND u.tip = 'O'
         ORDER BY u.cod""", c=args.cod_from)
    rows = cur.fetchall()
    if args.limit:
        rows = rows[:args.limit]
    print(f"кандидатов: {len(rows)}{'   (dry-run)' if args.dry_run else ''}")

    stat = {"univers": 0, "org26": 0, "skip26": 0, "err": 0}
    for cod, denumirea, namerus, codvechi, gr1, codfiscal in rows:
        # исходное наименование: в NAMERUS, если уже перенесено, иначе в DENUMIREA
        source = namerus or denumirea
        p = legal_forms.parse_name(source)
        short = p["short"][:80] or source[:80]

        need_univers = (denumirea != short or namerus != source
                        or (codfiscal and codvechi != codfiscal) or gr1 != "E")
        try:
            if need_univers:
                if not args.dry_run:
                    cur.execute("""UPDATE tms_univers
                                      SET denumirea = :d, namerus = :n,
                                          codvechi = NVL(:cv, codvechi), gr1 = 'E'
                                    WHERE cod = :c""",
                                d=short, n=source[:80], cv=codfiscal, c=cod)
                stat["univers"] += 1

            # идемпотентно: если строка уже есть — обновляем её значениями
            # текущей версии разбора, иначе создаём
            cur.execute("""SELECT tip_entitate, forma_juridica, denumire
                             FROM tms_org26 WHERE cod = :c""", c=cod)
            cur_row = cur.fetchone()
            want = (p["tip"], p["forma"], p["nume"][:80])
            if cur_row is None:
                if not args.dry_run:
                    cur.execute("""INSERT INTO tms_org26
                                     (cod, tip_entitate, forma_juridica, denumire, sursa)
                                   VALUES (:c, :t, :f, :d, 'date.gov.md')""",
                                c=cod, t=want[0], f=want[1], d=want[2])
                stat["org26"] += 1
            elif tuple(cur_row) != want:
                if not args.dry_run:
                    cur.execute("""UPDATE tms_org26
                                      SET tip_entitate = :t, forma_juridica = :f,
                                          denumire = :d
                                    WHERE cod = :c""",
                                t=want[0], f=want[1], d=want[2], c=cod)
                stat["org26"] += 1
            else:
                stat["skip26"] += 1

            if not args.dry_run:
                conn.commit()
        except Exception as exc:  # noqa: BLE001
            conn.rollback()
            stat["err"] += 1
            print(f"  ! COD {cod}: {str(exc).splitlines()[0]}")
            continue

        if stat["univers"] <= 8 or cod % 50 == 0:
            print(f"  {cod}  {(p['tip'] or '-'):<4}{(p['forma'] or '-'):<5} {short[:52]}")

    print(f"\nобновлено univers: {stat['univers']}, добавлено в TMS_ORG26: {stat['org26']}, "
          f"уже было: {stat['skip26']}, ошибок: {stat['err']}")
    exp.close()


if __name__ == "__main__":
    main()
