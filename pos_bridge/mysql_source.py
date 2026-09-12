# -*- coding: utf-8 -*-
"""
Товары и организации из MySQL / MariaDB — необязательная замена Oracle.

Зачем: доступ к боевому Oracle есть не везде и не всегда, а каталог кассе
нужен всегда. Источник включается одной строкой настроек
(`catalog.source = "mysql"`), Oracle при этом никуда не девается.

Схема задаётся профилем:

    officeplus — те же таблицы, что в Oracle-версии OfficePlus:
                 TMS_UNIVERS (TIP='P') + TMS_MPT, TMS_UNIVERS (TIP='O') + TMS_ORG;
    custom     — свой SQL в настройках (`goods_sql`, `clients_sql`).

Запрос обязан вернуть колонки с известными именами:
    товары       id, code, barcode, name, unit, price, vat, tax_group
    организации  id, denumire, idno, adresa, administratori
Недостающие можно не отдавать — подставится пустое значение.

Пароль берётся из связки ключей (см. secret.py), в настройках его нет.
"""

from . import secret

PROFILES = {
    "officeplus": {
        "goods_sql": """
            SELECT u.COD                AS id,
                   u.CODVECHI           AS code,
                   m.STRIH1_CODPRODUCER AS barcode,
                   u.DENUMIREA          AS name,
                   u.UM                 AS unit,
                   m.MATPRET            AS price,
                   u.CODTVA             AS tax_group
              FROM TMS_UNIVERS u
              LEFT JOIN TMS_MPT m ON m.COD = u.COD
             WHERE u.TIP = 'P'
               AND (%(q)s IS NULL OR u.DENUMIREA LIKE CONCAT('%%', %(q)s, '%%'))
             ORDER BY u.DENUMIREA
             LIMIT %(limit)s
        """,
        "clients_sql": """
            SELECT u.COD       AS id,
                   COALESCE(u.NAMERUS, u.DENUMIREA) AS denumire,
                   o.CODFISCAL AS idno,
                   o.ADRESS    AS adresa,
                   o.DIRECTOR  AS administratori
              FROM TMS_UNIVERS u
              JOIN TMS_ORG o ON o.COD = u.COD
             WHERE u.TIP = 'O'
               AND (%(q)s IS NULL OR u.DENUMIREA LIKE CONCAT('%%', %(q)s, '%%'))
             ORDER BY u.DENUMIREA
             LIMIT %(limit)s
        """,
    },
}


class MySqlError(Exception):
    pass


def connect(cfg):
    try:
        import pymysql
    except ImportError as exc:
        raise MySqlError("не установлен pymysql (pip install pymysql)") from exc
    m = cfg["mysql"]
    password = secret.password_for(m, "MYSQL_PASSWORD")
    kwargs = dict(host=m.get("host") or "127.0.0.1", port=int(m.get("port") or 3306),
                  user=m.get("user") or "root", password=password,
                  database=m.get("database") or "", charset=m.get("charset") or "utf8mb4",
                  connect_timeout=int(m.get("timeout") or 10), autocommit=True)
    if m.get("unix_socket"):
        kwargs["unix_socket"] = m["unix_socket"]
        kwargs.pop("host", None)
        kwargs.pop("port", None)
    try:
        return pymysql.connect(cursorclass=__import__("pymysql.cursors", fromlist=["DictCursor"]).DictCursor,
                               **kwargs)
    except Exception as exc:  # noqa: BLE001
        raise MySqlError("MySQL (%s@%s/%s): %s" % (kwargs.get("user"), m.get("host") or m.get("unix_socket"),
                                                   m.get("database"), exc))


def _sql(cfg, kind):
    m = cfg["mysql"]
    own = (m.get("%s_sql" % kind) or "").strip()
    if own:
        return own
    profile = (m.get("profile") or "officeplus").lower()
    if profile not in PROFILES:
        raise MySqlError("неизвестный профиль MySQL: %r (есть %s, либо свой SQL)"
                         % (profile, ", ".join(PROFILES)))
    return PROFILES[profile]["%s_sql" % kind]


def _num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def goods(cfg, groups=None, limit=5000, q=None):
    """Товары с ценами. tax_group берётся из данных, иначе — по ставке."""
    from . import catalog
    conn = connect(cfg)
    try:
        with conn.cursor() as cur:
            cur.execute(_sql(cfg, "goods"), {"q": q, "limit": int(limit)})
            rows = cur.fetchall()
        out = []
        for r in rows:
            vat = _num(r.get("vat"), None) if r.get("vat") is not None else None
            group = (r.get("tax_group") or "").strip().upper()
            if not group:
                group = catalog.tax_group_for(vat if vat is not None else 20, groups,
                                              cfg["catalog"]["default_tax_group"])
            if vat is None:
                vat = catalog.vat_for_group(group, groups)
            out.append({
                "id": "my-%s" % r.get("id"),
                "code": str(r.get("code") or "").strip(),
                "barcode": str(r.get("barcode") or "").strip(),
                "name": (r.get("name") or "").strip(),
                "unit": (r.get("unit") or "").strip(),
                "price": _num(r.get("price")),
                "vat": vat,
                "tax_group": group,
                "active": True,
            })
        m = cfg["mysql"]
        where = "%s@%s/%s" % (m.get("user"), m.get("host") or m.get("unix_socket") or "socket", m.get("database"))
        return [r for r in out if r["name"]], where
    finally:
        conn.close()


def clients(cfg, limit=2000, q=None):
    conn = connect(cfg)
    try:
        with conn.cursor() as cur:
            cur.execute(_sql(cfg, "clients"), {"q": q, "limit": int(limit)})
            rows = cur.fetchall()
        return [{
            "id": r.get("id"),
            "denumire": (r.get("denumire") or "").strip(),
            "short_name": (r.get("denumire") or "").strip(),
            "idno": str(r.get("idno") or "").strip(),
            "adresa": (r.get("adresa") or "").strip(),
            "administratori": (r.get("administratori") or "").strip(),
        } for r in rows if (r.get("denumire") or "").strip()]
    finally:
        conn.close()


def ping(cfg):
    conn = connect(cfg)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT VERSION() AS v, DATABASE() AS db, CURRENT_USER() AS who")
            return cur.fetchone()
    finally:
        conn.close()


# ── подготовка стенда OfficePlus на MySQL ──

DDL = [
    """CREATE TABLE IF NOT EXISTS TMS_UNIVERS (
         COD INT PRIMARY KEY AUTO_INCREMENT,
         DENUMIREA VARCHAR(200) NOT NULL,
         NAMERUS VARCHAR(200),
         TIP CHAR(1) NOT NULL,
         GR1 VARCHAR(10),
         UM VARCHAR(15),
         CODVECHI VARCHAR(30),
         CODTVA CHAR(1) DEFAULT 'A',
         INDEX (TIP), INDEX (CODVECHI)
       ) DEFAULT CHARSET=utf8mb4""",
    """CREATE TABLE IF NOT EXISTS TMS_MPT (
         COD INT PRIMARY KEY,
         STRIH1_CODPRODUCER VARCHAR(30),
         MATPRET DECIMAL(15,2) DEFAULT 0,
         INDEX (STRIH1_CODPRODUCER)
       ) DEFAULT CHARSET=utf8mb4""",
    """CREATE TABLE IF NOT EXISTS TMS_ORG (
         COD INT PRIMARY KEY,
         CODFISCAL VARCHAR(30),
         ADRESS VARCHAR(150),
         DIRECTOR VARCHAR(50),
         INDEX (CODFISCAL)
       ) DEFAULT CHARSET=utf8mb4""",
]


def setup(cfg, goods_rows=None, client_rows=None):
    """Создать в MySQL таблицы OfficePlus и, если дали, наполнить их.

    Нужна, чтобы поднять стенд там, где до боевого Oracle не дотянуться:
    структура та же (TMS_UNIVERS / TMS_MPT / TMS_ORG), поэтому профиль
    `officeplus` работает и здесь, и на настоящей базе.
    """
    conn = connect(cfg)
    stat = {"goods": 0, "clients": 0}
    try:
        with conn.cursor() as cur:
            for sql in DDL:
                cur.execute(sql)
            for g in goods_rows or []:
                cur.execute("SELECT COD FROM TMS_UNIVERS WHERE TIP='P' AND DENUMIREA=%s", (g["name"][:200],))
                row = cur.fetchone()
                if row:
                    cod = row["COD"]
                    cur.execute("UPDATE TMS_UNIVERS SET UM=%s, CODTVA=%s, CODVECHI=%s WHERE COD=%s",
                                (g.get("unit") or "buc", g.get("tax_group") or "A",
                                 str(g.get("code") or "")[:30], cod))
                else:
                    cur.execute(
                        "INSERT INTO TMS_UNIVERS (DENUMIREA, TIP, GR1, UM, CODVECHI, CODTVA)"
                        " VALUES (%s,'P','TVR',%s,%s,%s)",
                        (g["name"][:200], g.get("unit") or "buc",
                         str(g.get("code") or "")[:30], g.get("tax_group") or "A"))
                    cod = cur.lastrowid
                    stat["goods"] += 1
                cur.execute(
                    "INSERT INTO TMS_MPT (COD, STRIH1_CODPRODUCER, MATPRET) VALUES (%s,%s,%s)"
                    " ON DUPLICATE KEY UPDATE STRIH1_CODPRODUCER=VALUES(STRIH1_CODPRODUCER),"
                    " MATPRET=VALUES(MATPRET)",
                    (cod, str(g.get("barcode") or "")[:30] or None, float(g.get("price") or 0)))
            for c in client_rows or []:
                cur.execute("SELECT COD FROM TMS_UNIVERS WHERE TIP='O' AND DENUMIREA=%s",
                            (c["denumire"][:200],))
                row = cur.fetchone()
                if row:
                    cod = row["COD"]
                else:
                    cur.execute(
                        "INSERT INTO TMS_UNIVERS (DENUMIREA, NAMERUS, TIP, GR1, CODVECHI, CODTVA)"
                        " VALUES (%s,%s,'O','E',%s,'A')",
                        (c["denumire"][:200], c["denumire"][:200], str(c.get("idno") or "")[:30] or None))
                    cod = cur.lastrowid
                    stat["clients"] += 1
                cur.execute(
                    "INSERT INTO TMS_ORG (COD, CODFISCAL, ADRESS, DIRECTOR) VALUES (%s,%s,%s,%s)"
                    " ON DUPLICATE KEY UPDATE CODFISCAL=VALUES(CODFISCAL), ADRESS=VALUES(ADRESS),"
                    " DIRECTOR=VALUES(DIRECTOR)",
                    (cod, str(c.get("idno") or "")[:30] or None, (c.get("adresa") or "")[:150],
                     (c.get("administratori") or "")[:50]))
        conn.commit()
    finally:
        conn.close()
    return stat
