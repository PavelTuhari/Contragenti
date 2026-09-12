# -*- coding: utf-8 -*-
"""
Локальная база прослойки (SQLite): каталог товаров с ценами, принятые
продажи с их строками и журнал обмена.

Касса работает по этой базе и тогда, когда учёт недоступен: каталог
обновляется по расписанию, продажи копятся и выгружаются позже.
"""

import json
import sqlite3
import threading
import datetime

_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS goods (
  id TEXT PRIMARY KEY,            -- идентификатор товара в учёте (goodId для кассы)
  code TEXT,                      -- артикул
  barcode TEXT,
  name TEXT NOT NULL,
  unit TEXT,
  price REAL DEFAULT 0,
  vat REAL DEFAULT 0,
  tax_group TEXT,                 -- группа НДС FiscalCloud: A / B / C / N / 0
  source TEXT,                    -- demo | erp | file
  active INTEGER DEFAULT 1,
  updated_at TEXT
);
CREATE INDEX IF NOT EXISTS goods_barcode ON goods (barcode);
CREATE INDEX IF NOT EXISTS goods_updated ON goods (updated_at);

CREATE TABLE IF NOT EXISTS sales (
  id TEXT PRIMARY KEY,            -- id чека в FiscalCloud
  kind TEXT DEFAULT 'sale',       -- sale | return
  number INTEGER,
  number_text TEXT,
  date_time TEXT,
  device_id TEXT,
  point_of_sale_id TEXT,
  receipt_type TEXT,              -- FiscalReceipt | AlternativeReceipt
  total REAL DEFAULT 0,
  total_paid REAL DEFAULT 0,
  total_change REAL DEFAULT 0,
  mev_id TEXT,
  raw TEXT,                       -- ответ FiscalCloud как есть
  pulled_at TEXT,
  exported_at TEXT,               -- когда ушло в учёт
  export_ref TEXT                 -- № заказа в CRM
);
CREATE INDEX IF NOT EXISTS sales_export ON sales (exported_at, date_time);

CREATE TABLE IF NOT EXISTS sale_lines (
  sale_id TEXT NOT NULL,
  row_no INTEGER,
  good_id TEXT,
  name TEXT,
  quantity REAL,
  price REAL,
  amount REAL,
  tax_group TEXT,
  tax_amount REAL,
  PRIMARY KEY (sale_id, row_no)
);

CREATE TABLE IF NOT EXISTS log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT, level TEXT, message TEXT
);
"""


def now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def connect(path):
    conn = sqlite3.connect(path, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init(path):
    with _lock, connect(path) as conn:
        conn.executescript(SCHEMA)


def log(path, level, message):
    with _lock, connect(path) as conn:
        conn.execute("INSERT INTO log (ts, level, message) VALUES (?,?,?)",
                     (now(), level, str(message)[:2000]))


# ── каталог ──

def upsert_goods(path, rows, source):
    """Положить товары в каталог. Возвращает (новых, изменённых)."""
    added = changed = 0
    ts = now()
    with _lock, connect(path) as conn:
        for r in rows:
            gid = str(r["id"])
            old = conn.execute("SELECT price, name, active, updated_at FROM goods WHERE id = ?",
                               (gid,)).fetchone()
            if old is None:
                conn.execute(
                    "INSERT INTO goods (id, code, barcode, name, unit, price, vat, tax_group,"
                    " source, active, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (gid, r.get("code"), r.get("barcode"), r["name"], r.get("unit"),
                     float(r.get("price") or 0), float(r.get("vat") or 0), r.get("tax_group"),
                     source, 1 if r.get("active", True) else 0, ts))
                added += 1
            else:
                same = (abs(float(old["price"]) - float(r.get("price") or 0)) < 0.0001
                        and old["name"] == r["name"] and old["active"] == (1 if r.get("active", True) else 0))
                conn.execute(
                    "UPDATE goods SET code=?, barcode=?, name=?, unit=?, price=?, vat=?,"
                    " tax_group=?, source=?, active=?, updated_at=? WHERE id=?",
                    (r.get("code"), r.get("barcode"), r["name"], r.get("unit"),
                     float(r.get("price") or 0), float(r.get("vat") or 0), r.get("tax_group"),
                     source, 1 if r.get("active", True) else 0,
                     old["updated_at"] if same else ts, gid))
                if not same:
                    changed += 1
    return added, changed


def goods(path, q="", since="", limit=1000, only_active=True):
    sql = "SELECT * FROM goods WHERE 1=1"
    args = []
    if only_active:
        sql += " AND active = 1"
    if q:
        sql += " AND (name LIKE ? OR code LIKE ? OR barcode LIKE ?)"
        args += ["%%%s%%" % q] * 3
    if since:
        sql += " AND updated_at >= ?"
        args.append(since)
    sql += " ORDER BY name LIMIT ?"
    args.append(int(limit))
    with connect(path) as conn:
        return [dict(r) for r in conn.execute(sql, args).fetchall()]


def good_by_barcode(path, barcode):
    with connect(path) as conn:
        r = conn.execute("SELECT * FROM goods WHERE barcode = ? AND active = 1", (barcode,)).fetchone()
        return dict(r) if r else None


def good_by_id(path, gid):
    with connect(path) as conn:
        r = conn.execute("SELECT * FROM goods WHERE id = ?", (str(gid),)).fetchone()
        return dict(r) if r else None


def goods_count(path):
    with connect(path) as conn:
        return int(conn.execute("SELECT COUNT(*) FROM goods WHERE active = 1").fetchone()[0])


# ── продажи ──

def save_sale(path, sale, lines, kind="sale"):
    """Записать чек. Повторный чек с тем же id не дублируется."""
    with _lock, connect(path) as conn:
        exists = conn.execute("SELECT 1 FROM sales WHERE id = ?", (sale["id"],)).fetchone()
        if exists:
            return False
        conn.execute(
            "INSERT INTO sales (id, kind, number, number_text, date_time, device_id,"
            " point_of_sale_id, receipt_type, total, total_paid, total_change, mev_id,"
            " raw, pulled_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (sale["id"], kind, sale.get("number"), sale.get("number_text"),
             sale.get("date_time"), sale.get("device_id"), sale.get("point_of_sale_id"),
             sale.get("receipt_type"), float(sale.get("total") or 0),
             float(sale.get("total_paid") or 0), float(sale.get("total_change") or 0),
             sale.get("mev_id"), json.dumps(sale.get("raw") or {}, ensure_ascii=False), now()))
        for i, l in enumerate(lines, 1):
            conn.execute(
                "INSERT OR REPLACE INTO sale_lines (sale_id, row_no, good_id, name, quantity,"
                " price, amount, tax_group, tax_amount) VALUES (?,?,?,?,?,?,?,?,?)",
                (sale["id"], l.get("row_no") or i, l.get("good_id"), l.get("name"),
                 float(l.get("quantity") or 0), float(l.get("price") or 0),
                 float(l.get("amount") or 0), l.get("tax_group"), float(l.get("tax_amount") or 0)))
    return True


def sales(path, date_from="", date_to="", only_new=False, limit=500):
    sql = "SELECT * FROM sales WHERE 1=1"
    args = []
    if date_from:
        sql += " AND date_time >= ?"
        args.append(date_from)
    if date_to:
        sql += " AND date_time <= ?"
        args.append(date_to)
    if only_new:
        sql += " AND exported_at IS NULL"
    sql += " ORDER BY date_time DESC, number DESC LIMIT ?"
    args.append(int(limit))
    with connect(path) as conn:
        out = []
        for r in conn.execute(sql, args).fetchall():
            row = dict(r)
            row.pop("raw", None)
            row["lines"] = [dict(x) for x in conn.execute(
                "SELECT * FROM sale_lines WHERE sale_id = ? ORDER BY row_no", (r["id"],)).fetchall()]
            out.append(row)
        return out


def mark_exported(path, sale_id, ref):
    with _lock, connect(path) as conn:
        conn.execute("UPDATE sales SET exported_at = ?, export_ref = ? WHERE id = ?", (now(), ref, sale_id))


def stats(path):
    with connect(path) as conn:
        def one(sql):
            return conn.execute(sql).fetchone()[0]
        return {
            "goods": int(one("SELECT COUNT(*) FROM goods WHERE active = 1")),
            "sales": int(one("SELECT COUNT(*) FROM sales")),
            "sales_total": float(one("SELECT COALESCE(SUM(total),0) FROM sales WHERE kind='sale'")),
            "not_exported": int(one("SELECT COUNT(*) FROM sales WHERE exported_at IS NULL")),
            "last_sale": one("SELECT COALESCE(MAX(date_time),'') FROM sales"),
        }
