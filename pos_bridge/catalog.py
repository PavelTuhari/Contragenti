# -*- coding: utf-8 -*-
"""
Источники товаров и цен для кассы.

    demo — база Demo CRM (таблица items): демонстрационный режим, он же
           остаётся отдельным и не требует ни Oracle, ни кассы;
    erp  — реальный справочник OfficePlus на Oracle: карточка товара
           TMS_UNIVERS (TIP = 'P') + товарная часть TMS_MPT
           (STRIH1_CODPRODUCER — штрих-код, MATPRET — цена);
    file — json-файл со списком товаров (обмен без доступа к базам).

Наружу все источники отдают одинаковую запись:
    id, code, barcode, name, unit, price, vat, tax_group, active
"""

import json
import os
import sqlite3

from . import config

# группа НДС фискального устройства по ставке: подставляется, пока
# устройство не опрошено (GET /api/v1/devices отдаёт настоящие code+rate)
FALLBACK_GROUPS = [("A", 20.0), ("B", 8.0), ("N", 0.0)]


class CatalogError(Exception):
    pass


def tax_group_for(vat, groups=None, default="A"):
    """Группа НДС по ставке: берём группу с самой близкой ставкой."""
    try:
        rate = float(vat)
    except (TypeError, ValueError):
        return default
    table = groups or FALLBACK_GROUPS
    best, diff = default, None
    for code, r in table:
        d = abs(float(r) - rate)
        if diff is None or d < diff:
            best, diff = code, d
    return best if diff is not None and diff <= 0.51 else default


def vat_for_group(code, groups=None):
    for c, r in (groups or FALLBACK_GROUPS):
        if str(c).upper() == str(code).upper():
            return float(r)
    return 0.0


# ── demo: база Demo CRM ──

def _find_crm_db(cfg):
    for p in config.crm_db_candidates(cfg):
        if p and os.path.exists(p):
            return p
    return ""


def from_demo(cfg, groups=None, limit=5000):
    """Номенклатура Demo CRM: товары и изделия с ценой и ставкой НДС."""
    path = _find_crm_db(cfg)
    if not path:
        raise CatalogError("не найдена база Demo CRM (укажите catalog.crm_db)")
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT id, code, name, kind, unit_, price, vat FROM items ORDER BY name LIMIT ?",
            (int(limit),)).fetchall()
    except sqlite3.Error as exc:
        raise CatalogError("база Demo CRM без таблицы items: %s" % exc)
    finally:
        conn.close()
    out = []
    for r in rows:
        out.append({
            "id": "crm-%s" % r["id"],
            "code": r["code"] or "",
            "barcode": "",                  # в демо-базе штрих-кодов нет
            "name": r["name"],
            "unit": r["unit_"] or "",
            "price": float(r["price"] or 0),
            "vat": float(r["vat"] or 0),
            "tax_group": tax_group_for(r["vat"], groups),
            "active": True,
        })
    return out, path


# ── erp: Oracle OfficePlus ──

SQL_GOODS = """
SELECT u.COD              AS COD,
       u.DENUMIREA        AS DENUMIREA,
       u.UM               AS UM,
       u.CODTVA           AS CODTVA,
       u.CODVECHI         AS CODVECHI,
       m.STRIH1_CODPRODUCER AS BARCODE,
       m.MATPRET          AS PRET
  FROM TMS_UNIVERS u
  LEFT JOIN TMS_MPT m ON m.COD = u.COD
 WHERE u.TIP = 'P'
   AND (:q IS NULL OR UPPER(u.DENUMIREA) LIKE '%' || UPPER(:q) || '%')
 ORDER BY u.DENUMIREA
"""

SQL_ORGS = """
SELECT u.COD        AS COD,
       u.DENUMIREA  AS DENUMIREA,
       u.NAMERUS    AS NAMERUS,
       o.CODFISCAL  AS CODFISCAL,
       o.ADRESS     AS ADRESS,
       o.DIRECTOR   AS DIRECTOR
  FROM TMS_UNIVERS u
  JOIN TMS_ORG o ON o.COD = u.COD
 WHERE u.TIP = 'O'
   AND (:q IS NULL OR UPPER(u.DENUMIREA) LIKE '%' || UPPER(:q) || '%'
        OR o.CODFISCAL LIKE '%' || :q || '%')
 ORDER BY u.DENUMIREA
"""


def _oracle_connect(cfg, schema="goods"):
    try:
        import oracledb
    except ImportError as exc:
        raise CatalogError("не установлен oracledb (pip install oracledb)") from exc
    o = cfg["oracle"]
    user = o["user"] if schema == "goods" else o.get("org_user") or o["user"]
    pwd = o["password"] if schema == "goods" else o.get("org_password") or o["password"]
    if not pwd:
        raise CatalogError(
            "не задан пароль Oracle (%s): переменная окружения %s или pos_bridge_config.json"
            % (user, "GOODS_PASSWORD" if schema == "goods" else "TMS_PASSWORD"))
    client_dir = (o.get("client_dir") or "").strip()
    if client_dir:
        # сервер 11.2 не работает в thin-режиме — нужен Instant Client
        try:
            oracledb.init_oracle_client(lib_dir=client_dir)
        except Exception:  # noqa: BLE001 — повторная инициализация не ошибка
            pass
    return oracledb.connect(user=user, password=pwd, dsn=o["dsn"])


def from_erp(cfg, groups=None, limit=5000, q=None):
    """Товары из справочника OfficePlus. CODTVA — уже готовая группа НДС."""
    conn = _oracle_connect(cfg, "goods")
    try:
        cur = conn.cursor()
        cur.execute(SQL_GOODS, q=q)
        out = []
        for cod, name, um, codtva, codvechi, barcode, pret in cur:
            group = (codtva or cfg["catalog"]["default_tax_group"]).strip().upper()
            out.append({
                "id": "erp-%s" % int(cod),
                "code": (codvechi or "").strip(),
                "barcode": (barcode or "").strip(),
                "name": (name or "").strip(),
                "unit": (um or "").strip(),
                "price": float(pret or 0),
                "vat": vat_for_group(group, groups),
                "tax_group": group,
                "active": True,
            })
            if len(out) >= int(limit):
                break
        cur.close()
        return out, "%s@%s" % (cfg["oracle"]["user"], cfg["oracle"]["dsn"])
    finally:
        conn.close()


def orgs_from_erp(cfg, limit=2000, q=None):
    """Организации из справочника OfficePlus — клиенты для CRM."""
    conn = _oracle_connect(cfg, "org")
    try:
        cur = conn.cursor()
        cur.execute(SQL_ORGS, q=q)
        out = []
        for cod, den, namerus, codfiscal, adress, director in cur:
            out.append({
                "id": int(cod),
                "denumire": (namerus or den or "").strip(),
                "short_name": (den or "").strip(),
                "idno": (codfiscal or "").strip(),
                "adresa": (adress or "").strip(),
                "administratori": (director or "").strip(),
            })
            if len(out) >= int(limit):
                break
        cur.close()
        return out
    finally:
        conn.close()


# ── file ──

def from_file(cfg, groups=None):
    path = (cfg["catalog"].get("file") or "").strip()
    if not path or not os.path.exists(path):
        raise CatalogError("не найден файл каталога: %r" % path)
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    rows = data["goods"] if isinstance(data, dict) else data
    out = []
    for i, r in enumerate(rows, 1):
        out.append({
            "id": str(r.get("id") or "file-%d" % i),
            "code": r.get("code") or "",
            "barcode": r.get("barcode") or "",
            "name": r["name"],
            "unit": r.get("unit") or "",
            "price": float(r.get("price") or 0),
            "vat": float(r.get("vat") or 0),
            "tax_group": r.get("tax_group") or tax_group_for(r.get("vat"), groups),
            "active": bool(r.get("active", True)),
        })
    return out, path


def load(cfg, groups=None, source=None, limit=None, q=None):
    """Забрать товары из выбранного источника. Возвращает (записи, откуда)."""
    src = (source or cfg["catalog"]["source"] or "demo").lower()
    lim = int(limit or cfg["catalog"].get("limit") or 5000)
    if src == "demo":
        return from_demo(cfg, groups, lim)
    if src == "erp":
        return from_erp(cfg, groups, lim, q)
    if src == "file":
        return from_file(cfg, groups)
    raise CatalogError("неизвестный источник каталога: %r" % src)
