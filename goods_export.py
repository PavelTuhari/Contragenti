# -*- coding: utf-8 -*-
"""
Пополнение единой базы товаров по штрих-коду (ERP на Oracle TMS).

Штрих-код — первоисточник: он глобально уникален в справочнике
(TMS_CARD_BARCODES.BARCODE), и база сама не даёт завести дубль. Партнёр
сканирует код; если товара ещё нет — заводит карточку, если есть — получает
существующую. Так общий каталог наполняется коллективно.

Карточка товара — два связанных блока по общему COD, штрих-код в карточке:

    1. TMS_UNIVERS (TIP='P')  — карточка: название, единица, ставка НДС
    2. TMS_MPT                — товарная часть; STRIH1_CODPRODUCER = основной
                                штрих-код (дополнительные — в TMS_MPT_BARCODE)

Дедупликация — по представлению VMS_MPT_BARCODE, которое объединяет основной
штрих-код из карточки и дополнительные из TMS_MPT_BARCODE. (Таблица
TMS_CARD_BARCODES здесь ни при чём — это штрих-коды карт лояльности клиентов,
не товаров.)

Модуль не зависит от Tkinter; параметры подключения берутся из окружения
или переданного конфига, пароль в коде не хранится.
"""

import os
import threading

try:
    import oracledb
except Exception:  # noqa: BLE001
    oracledb = None


_CLIENT_CANDIDATES = [
    os.environ.get("ORACLE_CLIENT_DIR"),
    r"C:\oracle\instantclient_19_28",
    r"C:\oracle\instantclient_19_25",
    r"C:\oracle\instantclient",
    r"C:\instantclient",
]

DEFAULT_CONFIG = {
    "dsn": os.environ.get("GOODS_DSN", "192.168.0.24:1521/clouddev.world"),
    "user": os.environ.get("GOODS_USER", "BONUS2019"),
    "password": os.environ.get("GOODS_PASSWORD", ""),
    "client_dir": os.environ.get("ORACLE_CLIENT_DIR", ""),
}

_thick_inited = False
_thick_lock = threading.Lock()

# ставки НДС и единицы — как в справочнике
DEFAULT_UM = "buc"        # штука
DEFAULT_GR1 = "TVR"       # товар (розница)
DEFAULT_CODTVA = "A"      # ставка НДС по умолчанию

VALID_CODTVA = {"A", "B", "N", "C", "0"}


class GoodsError(Exception):
    """Ошибка, пригодная для показа пользователю."""


def _ensure_thick(client_dir=""):
    global _thick_inited
    if oracledb is None:
        raise GoodsError("Модуль oracledb не установлен (pip install oracledb).")
    with _thick_lock:
        if _thick_inited:
            return
        for d in ([client_dir] + _CLIENT_CANDIDATES if client_dir else _CLIENT_CANDIDATES):
            if not d or not os.path.isdir(d):
                continue
            try:
                oracledb.init_oracle_client(lib_dir=d)
                _thick_inited = True
                return
            except Exception as exc:  # noqa: BLE001
                if "already been initialized" in str(exc).lower():
                    _thick_inited = True
                    return
        raise GoodsError("Не найден 64-битный Oracle Instant Client "
                         "(укажите ORACLE_CLIENT_DIR).")


# ── нормализация ──

def normalize_barcode(code):
    """Оставить только цифры; отбросить незначащие пробелы."""
    return "".join(ch for ch in (code or "") if ch.isdigit())


def valid_barcode(code):
    """Штрих-код EAN/UPC: 8, 12, 13 или 14 цифр (весовые — короче, допускаем ≥6)."""
    c = normalize_barcode(code)
    return len(c) >= 6 and len(c) <= 18


def _cut(text, n):
    s = (text or "").strip()
    return s[:n] if s else None


def map_product(rec):
    """Из карточки, введённой оператором, собрать поля блоков.

    rec: barcode, denumire, um, codtva, pret (цена, опционально).
    """
    barcode = normalize_barcode(rec.get("barcode"))
    if not valid_barcode(barcode):
        raise GoodsError(f"Некорректный штрих-код: {rec.get('barcode')!r}")
    denumire = _cut(rec.get("denumire"), 200)
    if not denumire:
        raise GoodsError("Не указано название товара.")

    codtva = (rec.get("codtva") or DEFAULT_CODTVA).strip().upper()
    if codtva not in VALID_CODTVA:
        codtva = DEFAULT_CODTVA

    univers = {
        "DENUMIREA": denumire,
        "TIP": "P",
        "UM": _cut(rec.get("um"), 15) or DEFAULT_UM,
        "GR1": DEFAULT_GR1,
        "CODTVA": codtva,
    }
    try:
        pret = float(rec.get("pret")) if rec.get("pret") not in (None, "") else None
    except (TypeError, ValueError):
        pret = None
    return {"barcode": barcode, "univers": univers, "pret": pret}


# ── экспортёр ──

class GoodsExporter:
    """Пополнение каталога товаров. Своё подключение на поток."""

    def __init__(self, config=None):
        self.cfg = dict(DEFAULT_CONFIG)
        if config:
            self.cfg.update({k: v for k, v in config.items() if v})
        self.conn = None
        self.univers_seq = None

    def connect(self):
        if not self.cfg.get("password"):
            raise GoodsError("Не задан пароль подключения к базе товаров.")
        _ensure_thick(self.cfg.get("client_dir", ""))
        try:
            self.conn = oracledb.connect(
                user=self.cfg["user"], password=self.cfg["password"], dsn=self.cfg["dsn"])
        except Exception as exc:  # noqa: BLE001
            raise GoodsError(f"Не удалось подключиться: {str(exc).splitlines()[0]}")
        self.univers_seq = self._seq("ID_TMS_UNIVERS")
        self._allow_writes()
        return self

    def _allow_writes(self):
        """Снять блокировку записи товаров для текущей сессии, если она есть.

        Схема может защищать справочник триггером TMS_UNIVERS_TRLOCK: запись
        типа разрешена, только если он перечислен в XUNIVUNLOCK. Эта таблица
        временная, уровня сессии — исключение живёт лишь в своём соединении,
        поэтому добавляем его здесь же, где будем писать. Товары — TIP='P'.
        """
        try:
            cur = self.conn.cursor()
            cur.execute("SELECT COUNT(*) FROM user_tables WHERE table_name='XUNIVUNLOCK'")
            if not cur.fetchone()[0]:
                return
            cur.execute("SELECT COUNT(*) FROM xunivunlock WHERE TRIM(tip)='P'")
            if cur.fetchone()[0] == 0:
                cur.execute("INSERT INTO xunivunlock (tip) VALUES ('P')")
                # временную таблицу коммитить не обязательно, но и не вредно
                self.conn.commit()
        except Exception:  # noqa: BLE001
            # нет таблицы / нет прав — просто пробуем писать как есть
            pass

    def _seq(self, name):
        try:
            cur = self.conn.cursor()
            cur.execute("SELECT sequence_name FROM user_sequences WHERE sequence_name = :n",
                        n=name)
            row = cur.fetchone()
            return row[0] if row else None
        except Exception:  # noqa: BLE001
            return None

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:  # noqa: BLE001
                pass
            self.conn = None

    def __enter__(self):
        return self.connect()

    def __exit__(self, *a):
        self.close()

    def ping(self):
        cur = self.conn.cursor()
        cur.execute("SELECT banner FROM v$version WHERE ROWNUM=1")
        return cur.fetchone()[0]

    # -- поиск по штрих-коду: сердце дедупликации --

    def find_by_barcode(self, barcode):
        """Товар по штрих-коду через VMS_MPT_BARCODE.

        Представление объединяет основной штрих-код товара
        (TMS_MPT.STRIH1_CODPRODUCER, secondary=0) и дополнительные
        (TMS_MPT_BARCODE, secondary=1) — так виден весь пул штрих-кодов
        товаров, независимо от того, где именно код записан.
        """
        bc = normalize_barcode(barcode)
        if not bc:
            return None
        cur = self.conn.cursor()
        cur.execute(
            "SELECT v.cod, u.denumirea, v.secondary FROM vms_mpt_barcode v "
            "LEFT JOIN tms_univers u ON u.cod = v.cod "
            "WHERE v.barcode = :b AND ROWNUM = 1", b=bc)
        row = cur.fetchone()
        if not row:
            return None
        return {"cod": row[0], "denumire": row[1],
                "store": "main" if row[2] == 0 else "extra"}

    # -- вставка блоков --

    def _insert_univers(self, cur, univers):
        if self.univers_seq:
            cur.execute(f"SELECT {self.univers_seq}.NEXTVAL FROM dual")
            cod = int(cur.fetchone()[0])
            cur.execute(
                "INSERT INTO tms_univers (cod, denumirea, tip, um, gr1, codtva) "
                "VALUES (:cod, :d, :t, :um, :g, :tva)",
                cod=cod, d=univers["DENUMIREA"], t=univers["TIP"],
                um=univers["UM"], g=univers["GR1"], tva=univers["CODTVA"])
            return cod
        cod_var = cur.var(oracledb.NUMBER)
        cur.execute(
            "INSERT INTO tms_univers (denumirea, tip, um, gr1, codtva) "
            "VALUES (:d, :t, :um, :g, :tva) RETURNING cod INTO :cod",
            d=univers["DENUMIREA"], t=univers["TIP"], um=univers["UM"],
            g=univers["GR1"], tva=univers["CODTVA"], cod=cod_var)
        val = cod_var.getvalue()
        return int(val[0] if isinstance(val, list) else val)

    def _insert_mpt(self, cur, cod, barcode, pret):
        # товарная часть: COD, основной штрих-код и (если задана) цена
        cur.execute(
            "INSERT INTO tms_mpt (cod, strih1_codproducer, matpret) "
            "VALUES (:c, :b, :p)", c=cod, b=barcode, p=pret)

    def export_one(self, rec, dry_run=False):
        """Завести товар по штрих-коду (или вернуть существующий).

        Карточка и товарная часть пишутся ЕДИНОЙ транзакцией: товар без
        штрих-кода не имеет смысла, поэтому либо оба блока, либо ничего —
        никаких висячих карточек при сбое. Возвращает отчёт.
        """
        data = map_product(rec)
        report = {"barcode": data["barcode"], "denumire": data["univers"]["DENUMIREA"],
                  "cod": None, "univers": None, "mpt": None, "status": None}

        existing = self.find_by_barcode(data["barcode"])
        if existing and existing["cod"]:
            report["status"] = "duplicate"
            report["cod"] = existing["cod"]
            report["existing_name"] = existing["denumire"]
            return report

        cur = self.conn.cursor()
        try:
            cod = self._insert_univers(cur, data["univers"])
            report["cod"] = cod
            report["univers"] = "ok"
            self._insert_mpt(cur, cod, data["barcode"], data["pret"])
            report["mpt"] = "ok"
            if dry_run:
                self.conn.rollback()
                report["status"] = "dry_run"
            else:
                self.conn.commit()          # оба блока разом
                report["status"] = "ok"
        except Exception as exc:  # noqa: BLE001
            self.conn.rollback()
            # гонка: штрих-код успели завести параллельно — база отбила по
            # уникальности; перепроверяем и честно помечаем дубликатом
            again = None
            try:
                again = self.find_by_barcode(data["barcode"])
            except Exception:  # noqa: BLE001
                pass
            if again and again["cod"]:
                report["status"] = "duplicate"
                report["cod"] = again["cod"]
                report["race"] = True
            else:
                report["status"] = "error"
                report["error"] = str(exc).splitlines()[0]
        return report
