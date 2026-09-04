# -*- coding: utf-8 -*-
"""
Фоновая догрузка юридических адресов организаций una.md.

Постоянно, по одной компании за раз, точечным запросом карточки на
date.gov.md (тот же путь, что и кнопка «Данные по IDNO») дозаполняет
у организаций пустые поля: юридический адрес, форму, дату регистрации,
руководителя. Раз в 10 секунд пишет строку состояния в лог.

Запросы к порталу идут через реальный Chrome и защищены невидимой
reCAPTCHA. Если портал переходит на ручную проверку, демон не «долбится»
в него: увеличивает паузу и продолжает попытки реже, а в логе это видно.
Решить проверку может человек в открытом окне Chrome.

Запуск:
    python tools/address_daemon.py                 # бесконечно
    python tools/address_daemon.py --limit 50      # не более 50 карточек
    python tools/address_daemon.py --interval 45   # пауза между карточками
    python tools/address_daemon.py --once          # одна карточка и выход
"""

import argparse
import datetime
import logging
import os
import queue
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import company_search as cs  # noqa: E402
import tms_export  # noqa: E402

HEARTBEAT = 10          # период строки состояния в логе, сек
DETAIL_TIMEOUT = 240    # ожидание карточки от портала, сек

# Портал отвечает таймаутом и когда просит капчу, и когда компании просто нет
# в реестре (старые записи ERP с неактуальным IDNO). Различаем по серийности:
# одиночный сбой — это «не найдено», идём дальше обычным темпом; несколько
# подряд — портал закрылся, снижаем нагрузку.
CONSEC_FAIL_LIMIT = 8
MAX_BACKOFF = 5 * 60

# Портал отвечает нестабильно: одна и та же компания может не ответить сейчас
# и спокойно отдать карточку через несколько минут. Поэтому запись не
# выбрасывается после первой неудачи — к ней возвращаемся, пока не исчерпаны
# попытки, и лишь потом откладываем до следующего сеанса.
MAX_ATTEMPTS = 3


def setup_log(path):
    log = logging.getLogger("addr")
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s  %(message)s", "%Y-%m-%d %H:%M:%S")
    fh = logging.FileHandler(path, encoding="utf-8")
    fh.setFormatter(fmt)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    log.addHandler(fh)
    log.addHandler(sh)
    return log


class Heartbeat(threading.Thread):
    """Раз в 10 секунд пишет в лог, чем занят демон и сколько сделано."""

    def __init__(self, log, state):
        super().__init__(daemon=True)
        self.log = log
        self.state = state
        self.stop_flag = threading.Event()

    def run(self):
        while not self.stop_flag.wait(HEARTBEAT):
            s = self.state
            self.log.info(
                "· %s | обработано %d, обновлено %d, без адреса %d, "
                "не найдено %d | осталось %s",
                s.get("phase", "…"), s.get("done", 0), s.get("updated", 0),
                s.get("noaddr", 0), s.get("errors", 0), s.get("pending", "?"))


def pending_list(conn, limit, skip=()):
    """Организации без юридического адреса, у которых есть IDNO.

    skip — коды, по которым исчерпаны попытки в этом сеансе.

    Порядок обхода — от новых записей к старым. Организации, пришедшие с
    самого портала, там заведомо есть, и адрес по ним берётся сразу; старые
    записи ERP нередко относятся к ликвидированным фирмам, которых в реестре
    уже нет. Сначала делаем полезную работу, а безнадёжное оставляем на конец.
    """
    cur = conn.cursor()
    cur.execute("""
        SELECT o.cod, o.codfiscal, u.denumirea
          FROM tms_org o JOIN tms_univers u ON u.cod = o.cod
         WHERE o.adress IS NULL
           AND o.codfiscal IS NOT NULL
           AND LENGTH(TRIM(o.codfiscal)) = 13
         ORDER BY o.cod DESC""")
    rows = [r for r in cur.fetchall() if r[0] not in skip]
    return rows[:limit] if limit else rows


def pending_count(conn):
    cur = conn.cursor()
    cur.execute("""SELECT COUNT(*) FROM tms_org o
                    WHERE o.adress IS NULL AND o.codfiscal IS NOT NULL
                      AND LENGTH(TRIM(o.codfiscal)) = 13""")
    return cur.fetchone()[0]


def fetch_details(idno):
    """Точечный запрос карточки компании. Возвращает dict или None."""
    q = queue.Queue()
    worker = cs.BrowserWorker("details", idno, q, cs.TR["ru"], headless=False)
    worker.start()
    deadline = time.time() + DETAIL_TIMEOUT
    while time.time() < deadline:
        try:
            kind, payload = q.get(timeout=2)
        except queue.Empty:
            if not worker.is_alive():
                return None
            continue
        if kind == "details_done":
            return payload
        if kind == "error":
            return {"__error__": str(payload)}
    return {"__error__": "timeout"}


def apply_details(conn, cod, data):
    """Записать в TMS_ORG поля, которые ещё пустые. Возвращает список полей."""
    basic = data.get("basic", {}) or {}
    fields = {
        "ADRESS": basic.get("Adresa juridică"),
        "DIRECTOR": basic.get("Conducători"),
        "DATE1": basic.get("Data înregistrării"),
    }
    adresa = tms_export.to_db_charset((fields["ADRESS"] or "").strip())[:150]
    director = tms_export.to_db_charset(
        (fields["DIRECTOR"] or "").split("[")[0].strip())[:25]
    if not adresa:
        return []

    cur = conn.cursor()
    cur.execute("""UPDATE tms_org
                      SET adress = :a,
                          director = NVL(director, :d)
                    WHERE cod = :c AND adress IS NULL""",
                a=adresa, d=director or None, c=cod)
    changed = cur.rowcount
    conn.commit()
    return ["ADRESS"] if changed else []


def main():
    ap = argparse.ArgumentParser(description="Фоновая догрузка адресов из date.gov.md")
    ap.add_argument("--interval", type=int, default=30,
                    help="пауза между карточками, сек (по умолчанию 30)")
    ap.add_argument("--limit", type=int, default=0, help="максимум карточек за сеанс")
    ap.add_argument("--once", action="store_true", help="обработать одну и выйти")
    ap.add_argument("--log", default=os.path.join(cs._app_dir(), "address_daemon.log"))
    args = ap.parse_args()

    log = setup_log(args.log)
    cfg = dict(tms_export.DEFAULT_CONFIG)
    cfg["password"] = os.environ.get("TMS_PASSWORD") or os.environ.get("ORA_PWD", "")
    if not cfg["password"]:
        sys.exit("Не задан пароль: TMS_PASSWORD или ORA_PWD")

    exp = tms_export.TmsExporter(cfg).connect()
    conn = exp.conn

    state = {"phase": "старт", "done": 0, "updated": 0, "noaddr": 0,
             "errors": 0, "pending": pending_count(conn)}
    hb = Heartbeat(log, state)
    hb.start()

    log.info("демон запущен: без адреса %s организаций, пауза %s с",
             state["pending"], args.interval)

    backoff = args.interval
    processed = 0
    consec_fail = 0
    attempts = {}          # cod → сколько раз портал не ответил
    exhausted = set()      # cod → попытки исчерпаны, откладываем до след. сеанса
    try:
        while True:
            todo = pending_list(conn, args.limit - processed if args.limit else 0,
                                exhausted)
            if not todo:
                state["phase"] = "нечего догружать"
                log.info("нет организаций без адреса — ждём %s с", args.interval * 4)
                time.sleep(args.interval * 4)
                state["pending"] = pending_count(conn)
                continue

            for cod, idno, name in todo:
                state["phase"] = f"карточка {idno}"
                data = fetch_details(idno)
                state["done"] += 1
                processed += 1

                if data is None or "__error__" in (data or {}):
                    err = (data or {}).get("__error__", "нет ответа")
                    consec_fail += 1
                    state["errors"] += 1
                    attempts[cod] = attempts.get(cod, 0) + 1
                    tries = attempts[cod]
                    if tries >= MAX_ATTEMPTS:
                        exhausted.add(cod)

                    if consec_fail < CONSEC_FAIL_LIMIT:
                        # портал отвечает нестабильно: не хороним запись,
                        # а вернёмся к ней на следующем проходе
                        log.info("COD %s (%s) — портал не ответил (попытка %d из %d)%s",
                                 cod, idno, tries, MAX_ATTEMPTS,
                                 ", отложено" if tries >= MAX_ATTEMPTS else "")
                        if args.once:
                            return
                        time.sleep(args.interval)
                        continue

                    # сбои подряд — портал закрылся, снижаем нагрузку
                    backoff = min(max(backoff * 2, args.interval * 2), MAX_BACKOFF)
                    log.warning("COD %s (%s): %s — %d сбоя подряд, пауза %s с",
                                cod, idno, err[:60], consec_fail, backoff)
                    state["phase"] = "пауза: портал не отвечает"
                    time.sleep(backoff)
                    if args.once:
                        return
                    continue

                consec_fail = 0
                attempts.pop(cod, None)
                backoff = args.interval          # успех — возвращаем обычный темп
                try:
                    changed = apply_details(conn, cod, data)
                except Exception as exc:  # noqa: BLE001
                    conn.rollback()
                    state["errors"] += 1
                    log.error("COD %s: запись не удалась: %s", cod, str(exc).splitlines()[0])
                    continue

                if changed:
                    state["updated"] += 1
                    log.info("COD %s  %s  ← адрес записан", cod, name[:44])
                else:
                    state["noaddr"] += 1
                    log.info("COD %s  %s  — портал не дал адреса", cod, name[:44])

                state["pending"] = pending_count(conn)
                if args.once or (args.limit and processed >= args.limit):
                    log.info("достигнут предел сеанса")
                    return
                time.sleep(args.interval)
    except KeyboardInterrupt:
        log.info("остановлено пользователем")
    finally:
        hb.stop_flag.set()
        log.info("итог: обработано %d, обновлено %d, без адреса %d, ошибок %d",
                 state["done"], state["updated"], state["noaddr"], state["errors"])
        exp.close()


if __name__ == "__main__":
    main()
