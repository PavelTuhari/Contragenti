# -*- coding: utf-8 -*-
"""
Интеграция Contragenti → ERP una.md (Oracle TMS).

Найденная на date.gov.md организация отправляется в справочник una.md
тремя автономными блоками, каждый — отдельной транзакцией («по одной
на каждый блок организации»):

    1. TMS_UNIVERS        — справочная запись; COD генерируется триггером
    2. TMS_ORG            — реквизиты (CODFISCAL/IDNO, адрес, руководитель…)
    3. TMS_ORG_ACCOUNTS   — банковские счета (по одному на счёт); банк
                            определяется по IBAN через справочник банков

Все блоки связаны общим COD (PK TMS_UNIVERS, на который ссылаются FK
TMS_ORG.COD и TMS_ORG_ACCOUNTS.COD_ORG).

Модуль не зависит от Tkinter и не хранит пароль в коде: параметры
подключения берутся из окружения / переданного конфига.
"""

import os
import threading

import legal_forms

try:
    import oracledb
except Exception:  # noqa: BLE001
    oracledb = None


# ── конфигурация подключения ─────────────────────────────────────────

# Каталоги, где ищем 64-битный Oracle Instant Client для thick-режима
# (сервер 11.2 не поддерживается thin-режимом python-oracledb).
_CLIENT_CANDIDATES = [
    os.environ.get("ORACLE_CLIENT_DIR"),
    r"C:\oracle\instantclient_19_28",
    r"C:\oracle\instantclient_19_25",
    r"C:\oracle\instantclient",
    r"C:\instantclient",
]

DEFAULT_CONFIG = {
    "dsn": os.environ.get("TMS_DSN", "192.168.0.24:1521/clouddev.world"),
    "user": os.environ.get("TMS_USER", "paralax"),
    "password": os.environ.get("TMS_PASSWORD", ""),
    "client_dir": os.environ.get("ORACLE_CLIENT_DIR", ""),
}

_thick_inited = False
_thick_lock = threading.Lock()


class TmsError(Exception):
    """Ошибка интеграции с una.md, пригодная для показа пользователю."""


def _ensure_thick(client_dir=""):
    """Однократно инициализировать thick-режим (нужен для Oracle 11.2)."""
    global _thick_inited
    if oracledb is None:
        raise TmsError("Модуль oracledb не установлен (pip install oracledb).")
    with _thick_lock:
        if _thick_inited:
            return
        candidates = [client_dir] + _CLIENT_CANDIDATES if client_dir else _CLIENT_CANDIDATES
        last = None
        for d in candidates:
            if not d:
                continue
            if not os.path.isdir(d):
                continue
            try:
                oracledb.init_oracle_client(lib_dir=d)
                _thick_inited = True
                return
            except Exception as exc:  # noqa: BLE001
                # уже инициализирован другим вызовом — это ок
                if "already been initialized" in str(exc).lower():
                    _thick_inited = True
                    return
                last = exc
        raise TmsError(
            "Не найден 64-битный Oracle Instant Client. Укажите каталог в "
            "переменной ORACLE_CLIENT_DIR." + (f" ({last})" if last else ""))


# ── вспомогательные преобразования ──────────────────────────────────

# База una.md имеет кодировку CL8MSWIN1251 (кириллица + latin1): румынских
# диакритик в ней нет. Неявное преобразование средствами Oracle-клиента даёт
# либо транслитерацию, либо «?» — в зависимости от NLS_LANG рабочей станции.
# Поэтому приводим латиницу к ASCII сами, детерминированно; кириллица (её
# CL8MSWIN1251 поддерживает) остаётся нетронутой.
_TRANSLIT = {
    "ă": "a", "â": "a", "î": "i", "ș": "s", "ş": "s", "ț": "t", "ţ": "t",
    "Ă": "A", "Â": "A", "Î": "I", "Ș": "S", "Ş": "S", "Ț": "T", "Ţ": "T",
    "á": "a", "à": "a", "ä": "a", "é": "e", "è": "e", "ë": "e", "í": "i",
    "ó": "o", "ö": "o", "ú": "u", "ü": "u", "ç": "c", "ñ": "n", "ß": "ss",
    "Á": "A", "À": "A", "Ä": "A", "É": "E", "È": "E", "Ë": "E", "Í": "I",
    "Ó": "O", "Ö": "O", "Ú": "U", "Ü": "U", "Ç": "C", "Ñ": "N",
    "„": '"', "”": '"', "“": '"', "«": '"', "»": '"', "–": "-", "—": "-",
    "’": "'", "‘": "'", " ": " ",
}


def to_db_charset(text):
    """Привести строку к символам, представимым в CL8MSWIN1251.

    Румынская/западноевропейская диакритика транслитерируется в ASCII,
    кириллица сохраняется как есть.
    """
    if not text:
        return text
    out = []
    for ch in text:
        if ch in _TRANSLIT:
            out.append(_TRANSLIT[ch])
            continue
        try:
            ch.encode("cp1251")
            out.append(ch)
        except UnicodeEncodeError:
            # незнакомый непредставимый символ отбрасываем, а не пишем «?»
            pass
    return "".join(out)


def _clean(text):
    return to_db_charset((text or "").strip())


def _strip_role(admin):
    """'TUHARI PAVEL [Administrator]' → 'TUHARI PAVEL'."""
    s = _clean(admin)
    i = s.find("[")
    return s[:i].strip() if i >= 0 else s


def _cut(text, n):
    s = _clean(text)
    return s[:n] if s else None


def iban_bank_prefix(iban):
    """Из молдавского IBAN вернуть буквенный код банка (ведущие буквы BBAN).

    MD-IBAN: MD + 2 контрольные + буквенный код банка + счёт. Национальный
    стандарт использует 2-буквенный код (например 'AG', 'MO', 'VI'), но в
    справочнике банк хранит полный BIC; берём всю ведущую буквенную часть
    после контрольных разрядов (2–4 символа), например 'AG', 'MOBB', 'TRPB'.
    Возвращает None, если это не похоже на молдавский IBAN.
    """
    s = "".join((iban or "").split()).upper()
    if len(s) < 6 or not s.startswith("MD") or not s[2:4].isdigit():
        return None
    bank = ""
    for ch in s[4:8]:          # код банка занимает не более 4 символов
        if ch.isalpha():
            bank += ch
        else:
            break
    return bank or None


# ── маппинг записи date.gov.md → поля TMS ───────────────────────────

def map_company(rec):
    """Из записи companies.db (dict) собрать поля для блоков TMS.

    Возвращает dict с ключами 'univers', 'org', 'org26' и списком 'accounts'.
    Поля обрезаются под длину столбцов Oracle.
    """
    original = _cut(rec.get("denumire"), 80)
    if not original:
        raise TmsError("У записи нет названия (DENUMIREA) — нечего отправлять.")

    # Организационно-правовая форма выносится из названия в отдельные признаки.
    parsed = legal_forms.parse_name(rec.get("denumire") or "")
    idno = _cut(rec.get("idno"), 13)

    univers = {
        # в справочник кладём сокращённое название, оригинал — в NAMERUS
        "DENUMIREA": _cut(parsed["short"], 80) or original,
        "NAMERUS": original,
        "TIP": "O",          # организация
        # GR1='E' — соглашение системы: при нём CODVECHI трактуется как
        # фискальный код и БД сама следит за его уникальностью
        "GR1": "E",
        "CODVECHI": idno,
        "CODTVA": "A",       # плательщик НДС по умолчанию (как default столбца)
    }
    org = {
        "CODFISCAL": _cut(rec.get("idno"), 30),
        "ADRESS": _cut(rec.get("adresa"), 150),
        "DIRECTOR": _cut(_strip_role(rec.get("administratori")), 25),
    }
    org26 = {
        "TIP_ENTITATE": parsed["tip"],
        "FORMA_JURIDICA": parsed["forma"],
        "DENUMIRE": _cut(parsed["nume"], 80),
        "SURSA": "date.gov.md",
    }

    accounts = []
    # date.gov.md не отдаёт счета; блок наполняется, только если IBAN
    # присутствует в записи (ручной ввод или иной источник).
    iban = _clean(rec.get("iban"))
    if iban:
        accounts.append({"iban": iban, "valuta": _clean(rec.get("valuta")) or "MDL"})
    for extra in rec.get("ibans", []) or []:
        v = _clean(extra.get("iban") if isinstance(extra, dict) else extra)
        if v and v != iban:
            accounts.append({"iban": v,
                             "valuta": (extra.get("valuta") if isinstance(extra, dict) else "") or "MDL"})

    return {"univers": univers, "org": org, "org26": org26, "accounts": accounts}


# ── экспортёр ────────────────────────────────────────────────────────

class TmsExporter:
    """Отправка организаций в una.md. Потокобезопасно при своём connect()."""

    def __init__(self, config=None):
        self.cfg = dict(DEFAULT_CONFIG)
        if config:
            self.cfg.update({k: v for k, v in config.items() if v})
        self.conn = None
        # TMS_ORG26 — наше расширение, в схемах-арендаторах его может не быть;
        # определяем один раз при подключении и молча пропускаем, если нет
        self.has_org26 = False

    # -- соединение --

    def connect(self):
        if not self.cfg.get("password"):
            raise TmsError("Не задан пароль подключения к una.md (TMS_PASSWORD).")
        _ensure_thick(self.cfg.get("client_dir", ""))
        try:
            self.conn = oracledb.connect(
                user=self.cfg["user"], password=self.cfg["password"], dsn=self.cfg["dsn"])
        except Exception as exc:  # noqa: BLE001
            raise TmsError(f"Не удалось подключиться к una.md: {str(exc).splitlines()[0]}")
        self.has_org26 = self._detect_org26()
        self.univers_seq = self._detect_sequence()
        return self

    def _detect_org26(self):
        try:
            cur = self.conn.cursor()
            cur.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = 'TMS_ORG26'")
            return cur.fetchone()[0] > 0
        except Exception:  # noqa: BLE001
            return False

    def _detect_sequence(self):
        """Последовательность кодов справочника.

        Код берём из неё сами, а не полагаемся на RETURNING: в некоторых
        схемах собственные триггеры подставляют :NEW.cod в динамический SQL
        и на пустом коде ломаются (ORA-00936). С явным кодом работают все.
        """
        try:
            cur = self.conn.cursor()
            cur.execute("SELECT sequence_name FROM user_sequences "
                        "WHERE sequence_name = 'ID_TMS_UNIVERS'")
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
        """Проверка соединения — вернуть версию сервера."""
        cur = self.conn.cursor()
        cur.execute("SELECT banner FROM v$version WHERE ROWNUM=1")
        return cur.fetchone()[0]

    # -- поиск существующей организации по CODFISCAL --

    def find_by_codfiscal(self, codfiscal):
        """Найти организацию по фискальному коду.

        Ищем сначала в справочнике по CODVECHI, и только потом в реквизитах
        по CODFISCAL. Порядок важен: блоки фиксируются раздельно, поэтому
        существует окно, когда справочная запись уже есть, а реквизиты ещё
        не записаны — поиск только по TMS_ORG в этот момент организацию не
        увидит и примет чужую запись за сбой.
        """
        if not codfiscal:
            return None
        cur = self.conn.cursor()
        cur.execute(
            "SELECT COD, DENUMIREA FROM TMS_UNIVERS "
            "WHERE CODVECHI = :cf AND TIP = 'O' AND ROWNUM = 1", cf=str(codfiscal))
        row = cur.fetchone()
        if row:
            return {"cod": row[0], "denumire": row[1]}
        cur.execute(
            "SELECT o.COD, u.DENUMIREA FROM TMS_ORG o JOIN TMS_UNIVERS u ON u.COD=o.COD "
            "WHERE o.CODFISCAL = :cf AND ROWNUM = 1", cf=str(codfiscal))
        row = cur.fetchone()
        return {"cod": row[0], "denumire": row[1]} if row else None

    # -- матчинг банка по IBAN --

    def find_bank_cod(self, iban):
        """COD банка в TMS_UNIVERS по буквенному префиксу молдавского IBAN.

        Матчинг по CODVECHI (SWIFT/BIC): точное совпадение головного BIC
        (например 'MOBBMD22') или начало с 4-буквенного кода банка.
        """
        prefix = iban_bank_prefix(iban)
        if not prefix:
            return None
        cur = self.conn.cursor()
        # приоритет: головной офис (BIC ровно из 8 символов), затем любой филиал
        cur.execute(
            "SELECT COD FROM TMS_UNIVERS "
            "WHERE GR1 = 'BANK' AND UPPER(CODVECHI) LIKE :p || '%' "
            "ORDER BY LENGTH(CODVECHI), COD", p=prefix)
        row = cur.fetchone()
        return row[0] if row else None

    # -- вставка блоков (каждый — автономная транзакция) --

    def _insert_univers(self, cur, univers):
        fields = dict(
            DENUMIREA=univers["DENUMIREA"], NAMERUS=univers.get("NAMERUS"),
            TIP=univers["TIP"], GR1=univers.get("GR1"),
            CODVECHI=univers.get("CODVECHI"), CODTVA=univers["CODTVA"])

        if self.univers_seq:
            cur.execute(f"SELECT {self.univers_seq}.NEXTVAL FROM dual")
            cod = int(cur.fetchone()[0])
            cur.execute(
                "INSERT INTO TMS_UNIVERS (COD, DENUMIREA, NAMERUS, TIP, GR1, "
                "CODVECHI, CODTVA) VALUES (:COD, :DENUMIREA, :NAMERUS, :TIP, "
                ":GR1, :CODVECHI, :CODTVA)", COD=cod, **fields)
            return cod

        # последовательности нет — полагаемся на штатный триггер
        cod_var = cur.var(oracledb.NUMBER)
        cur.execute(
            "INSERT INTO TMS_UNIVERS (DENUMIREA, NAMERUS, TIP, GR1, CODVECHI, CODTVA) "
            "VALUES (:DENUMIREA, :NAMERUS, :TIP, :GR1, :CODVECHI, :CODTVA) "
            "RETURNING COD INTO :cod", cod=cod_var, **fields)
        val = cod_var.getvalue()
        return int(val[0] if isinstance(val, list) else val)

    def _insert_org26(self, cur, cod, org26):
        cur.execute(
            "INSERT INTO TMS_ORG26 (COD, TIP_ENTITATE, FORMA_JURIDICA, DENUMIRE, SURSA) "
            "VALUES (:COD, :TIP_ENTITATE, :FORMA_JURIDICA, :DENUMIRE, :SURSA)",
            COD=cod, TIP_ENTITATE=org26.get("TIP_ENTITATE"),
            FORMA_JURIDICA=org26.get("FORMA_JURIDICA"),
            DENUMIRE=org26.get("DENUMIRE"), SURSA=org26.get("SURSA"))

    def _insert_org(self, cur, cod, org):
        """Записать блок реквизитов.

        В части схем собственный триггер заводит строку TMS_ORG сразу вслед
        за справочной записью, поэтому слепая вставка ловит нарушение
        первичного ключа. Пишем как upsert: есть строка — дополняем её.
        """
        cur.execute("SELECT COUNT(*) FROM TMS_ORG WHERE COD = :c", c=cod)
        if cur.fetchone()[0]:
            cur.execute(
                "UPDATE TMS_ORG SET CODFISCAL = NVL(:CODFISCAL, CODFISCAL), "
                "ADRESS = NVL(:ADRESS, ADRESS), DIRECTOR = NVL(:DIRECTOR, DIRECTOR) "
                "WHERE COD = :COD",
                COD=cod, CODFISCAL=org.get("CODFISCAL"),
                ADRESS=org.get("ADRESS"), DIRECTOR=org.get("DIRECTOR"))
        else:
            cur.execute(
                "INSERT INTO TMS_ORG (COD, CODFISCAL, ADRESS, DIRECTOR) "
                "VALUES (:COD, :CODFISCAL, :ADRESS, :DIRECTOR)",
                COD=cod, CODFISCAL=org.get("CODFISCAL"),
                ADRESS=org.get("ADRESS"), DIRECTOR=org.get("DIRECTOR"))

    def _insert_account(self, cur, cod_org, cod_bank, iban, valuta):
        cur.execute(
            "INSERT INTO TMS_ORG_ACCOUNTS (COD_ORG, COD_BANK, ACCOUNT1, ACCOUNT2, VALUTA) "
            "VALUES (:COD_ORG, :COD_BANK, :ACCOUNT1, :ACCOUNT2, :VALUTA)",
            COD_ORG=cod_org, COD_BANK=cod_bank, ACCOUNT1=iban,
            ACCOUNT2=" ", VALUTA=(valuta or None))

    def export_one(self, rec, dry_run=False):
        """Отправить одну организацию. Вернуть отчёт по блокам.

        dry_run=True выполняет все вставки и делает rollback — для проверки
        корректности без записи в боевую базу.

        Каждый блок фиксируется отдельным commit (или откатывается целиком
        при dry_run). Если организация с таким CODFISCAL уже есть —
        помечается как duplicate и не дублируется.
        """
        data = map_company(rec)
        report = {"denumire": data["univers"]["DENUMIREA"],
                  "cod": None, "univers": None, "org": None, "org26": None,
                  "accounts": [], "status": None}

        existing = self.find_by_codfiscal(data["org"].get("CODFISCAL"))
        if existing:
            report["status"] = "duplicate"
            report["cod"] = existing["cod"]
            report["univers"] = "exists"
            report["org"] = "exists"
            return report

        cur = self.conn.cursor()
        try:
            # блок 1 — TMS_UNIVERS
            cod = self._insert_univers(cur, data["univers"])
            report["cod"] = cod
            if not dry_run:
                self.conn.commit()
            report["univers"] = "ok"

            # блок 2 — TMS_ORG
            self._insert_org(cur, cod, data["org"])
            if not dry_run:
                self.conn.commit()
            report["org"] = "ok"

            # блок 2б — TMS_ORG26: нормализованные тип и форма.
            # В схемах-арендаторах таблицы может не быть — тогда пропускаем:
            # признаки остаются видны в сокращённом названии.
            if self.has_org26:
                self._insert_org26(cur, cod, data["org26"])
                if not dry_run:
                    self.conn.commit()
                report["org26"] = "ok"
            else:
                report["org26"] = "skipped"

            # блок 3 — TMS_ORG_ACCOUNTS (по одному счёту)
            for acc in data["accounts"]:
                cod_bank = self.find_bank_cod(acc["iban"])
                if not cod_bank:
                    report["accounts"].append({"iban": acc["iban"], "status": "no_bank"})
                    continue
                self._insert_account(cur, cod, cod_bank, acc["iban"], acc.get("valuta"))
                if not dry_run:
                    self.conn.commit()
                report["accounts"].append(
                    {"iban": acc["iban"], "status": "ok", "cod_bank": cod_bank})

            if dry_run:
                self.conn.rollback()
                report["status"] = "dry_run"
            else:
                report["status"] = "ok"
        except Exception as exc:  # noqa: BLE001
            self.conn.rollback()
            # Гонка при одновременной работе нескольких клиентов: между нашей
            # проверкой и вставкой ту же организацию успел завести кто-то ещё.
            # База это отбила (уникальность CODVECHI при GR1='E'), и по смыслу
            # это дубликат, а не сбой — перепроверяем и сообщаем честно.
            existing = None
            try:
                existing = self.find_by_codfiscal(data["org"].get("CODFISCAL"))
            except Exception:  # noqa: BLE001
                pass
            if existing:
                report["status"] = "duplicate"
                report["cod"] = existing["cod"]
                report["univers"] = report["org"] = "exists"
                report["race"] = True      # завели параллельно, пока мы писали
            else:
                report["status"] = "error"
                report["error"] = str(exc).splitlines()[0]
        return report
