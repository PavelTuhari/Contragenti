# -*- coding: utf-8 -*-
"""
Наполнение базы CRM реальными данными OfficePlus (Oracle).

Демо-режим остаётся отдельным: демонстрационная база `clients.db` не
трогается, реальные данные ложатся в свою базу (по умолчанию `erp.db` в том
же каталоге данных). Demo CRM открывает ту, которая выбрана в настройках.

Переносятся:
    организации TMS_UNIVERS (TIP='O') + TMS_ORG  ->  clients
    товары      TMS_UNIVERS (TIP='P') + TMS_MPT  ->  items

Повторный запуск не плодит дубликаты: организации сверяются по IDNO
(CODFISCAL), товары — по коду карточки.
"""

import os
import sqlite3

from . import catalog

# минимум схемы: остальное Demo CRM добавит миграциями при открытии базы
DDL = [
    """CREATE TABLE IF NOT EXISTS clients (
         id INTEGER PRIMARY KEY AUTOINCREMENT, denumire TEXT NOT NULL, idno TEXT,
         forma_juridica TEXT, adresa TEXT, administratori TEXT, data_inregistrarii TEXT,
         source TEXT, added_at TEXT DEFAULT (datetime('now','localtime')))""",
    """CREATE TABLE IF NOT EXISTS items (
         id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT, name TEXT NOT NULL, kind TEXT,
         unit_ TEXT, price REAL DEFAULT 0, vat REAL DEFAULT 20, stock REAL DEFAULT 0, notes TEXT)""",
]


def _open(path):
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    conn = sqlite3.connect(path, timeout=20)
    conn.row_factory = sqlite3.Row
    for sql in DDL:
        conn.execute(sql)
    # колонки, которых может не быть в старой базе
    have = {r["name"] for r in conn.execute("PRAGMA table_info(clients)")}
    for col in ("client_type", "phone", "email", "notes", "contact_person", "source"):
        if col not in have:
            conn.execute("ALTER TABLE clients ADD COLUMN %s TEXT" % col)
    return conn


def import_clients(cfg, db_path, limit=2000, query=None):
    rows = catalog.orgs_from_erp(cfg, limit, query)
    conn = _open(db_path)
    added = updated = 0
    try:
        for r in rows:
            idno = (r["idno"] or "").strip()
            found = None
            if idno:
                found = conn.execute("SELECT id FROM clients WHERE idno = ?", (idno,)).fetchone()
            if found is None:
                found = conn.execute("SELECT id FROM clients WHERE denumire = ?", (r["denumire"],)).fetchone()
            if found is None:
                conn.execute(
                    "INSERT INTO clients (denumire, idno, adresa, administratori, client_type, source)"
                    " VALUES (?,?,?,?,?,?)",
                    (r["denumire"], idno or None, r["adresa"], r["administratori"], "Клиент", "officeplus"))
                added += 1
            else:
                conn.execute(
                    "UPDATE clients SET denumire = ?, adresa = ?, administratori = ?, source = ? WHERE id = ?",
                    (r["denumire"], r["adresa"], r["administratori"], "officeplus", found["id"]))
                updated += 1
        conn.commit()
    finally:
        conn.close()
    return {"total": len(rows), "added": added, "updated": updated}


def import_items(cfg, db_path, limit=5000, query=None):
    rows, origin = catalog.from_erp(cfg, None, limit, query)
    conn = _open(db_path)
    added = updated = 0
    try:
        for r in rows:
            code = r["code"] or r["id"]
            found = conn.execute("SELECT id FROM items WHERE code = ?", (code,)).fetchone()
            if found is None:
                found = conn.execute("SELECT id FROM items WHERE name = ?", (r["name"],)).fetchone()
            notes = ("штрих-код %s" % r["barcode"]) if r["barcode"] else None
            if found is None:
                conn.execute(
                    "INSERT INTO items (code, name, kind, unit_, price, vat, stock, notes)"
                    " VALUES (?,?,?,?,?,?,0,?)",
                    (code, r["name"], "Товар", r["unit"] or "шт", r["price"], r["vat"], notes))
                added += 1
            else:
                conn.execute(
                    "UPDATE items SET code = ?, name = ?, unit_ = ?, price = ?, vat = ?, notes = ? WHERE id = ?",
                    (code, r["name"], r["unit"] or "шт", r["price"], r["vat"], notes, found["id"]))
                updated += 1
        conn.commit()
    finally:
        conn.close()
    return {"total": len(rows), "added": added, "updated": updated, "origin": origin}
