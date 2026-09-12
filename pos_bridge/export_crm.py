# -*- coding: utf-8 -*-
"""
Выгрузка принятых продаж в учёт: чек кассы становится заказом Demo CRM
(таблицы orders / order_lines той же базы clients.db).

Это обратная половина обмена: товары и цены ушли на кассу, продажи
вернулись в учёт. Заказ создаётся проведённым (posted = 1) — остатки
списывать второй раз не нужно, это уже сделала касса.
"""

import sqlite3

ORDER_STATUS = "Оплачен"
ORDER_KIND = "Продажа"


def _conn(path):
    conn = sqlite3.connect(path, timeout=15)
    conn.row_factory = sqlite3.Row
    return conn


def _client_id(conn, name):
    """Покупатель розничного чека — один служебный клиент."""
    row = conn.execute("SELECT id FROM clients WHERE denumire = ?", (name,)).fetchone()
    if row:
        return row["id"]
    cur = conn.execute(
        "INSERT INTO clients (denumire, client_type, source) VALUES (?, 'Клиент', 'pos')", (name,))
    return cur.lastrowid


def _item_id(conn, line):
    """Позиция номенклатуры по идентификатору из каталога, иначе по названию."""
    good = (line.get("good_id") or "")
    if good.startswith("crm-"):
        try:
            iid = int(good.split("-", 1)[1])
        except ValueError:
            iid = 0
        if iid and conn.execute("SELECT 1 FROM items WHERE id = ?", (iid,)).fetchone():
            return iid
    name = line.get("name") or "Товар с кассы"
    row = conn.execute("SELECT id FROM items WHERE name = ?", (name,)).fetchone()
    if row:
        return row["id"]
    cur = conn.execute(
        "INSERT INTO items (code, name, kind, unit_, price, vat, stock) VALUES (?,?,?,?,?,?,0)",
        (good[:20] or None, name, "Товар", "шт", float(line.get("price") or 0), 20))
    return cur.lastrowid


def export_sale(crm_db, sale, lines, client_name="Розничный покупатель", prefix="POS-"):
    """Создать заказ по чеку. Возвращает номер заказа или '' при повторе."""
    conn = _conn(crm_db)
    try:
        number = prefix + (sale.get("number_text") or str(sale.get("number") or ""))
        if conn.execute("SELECT 1 FROM orders WHERE number = ?", (number,)).fetchone():
            return ""                      # такой чек уже выгружен
        client_id = _client_id(conn, client_name)
        date = (sale.get("date_time") or "")[:10]
        cur = conn.execute(
            "INSERT INTO orders (number, order_date, client_id, kind, status, total, advance,"
            " paid, due_date, ship_date, notes, posted) VALUES (?,?,?,?,?,?,0,?,?,?,?,1)",
            (number, date, client_id, ORDER_KIND, ORDER_STATUS,
             float(sale.get("total") or 0), float(sale.get("total_paid") or 0),
             date, date, "Чек кассы %s от %s" % (sale.get("number_text") or "", date)))
        order_id = cur.lastrowid
        for l in lines:
            item_id = _item_id(conn, l)
            qty = float(l.get("quantity") or 0)
            price = float(l.get("price") or 0)
            conn.execute(
                "INSERT INTO order_lines (order_id, item_id, qty, price, sum) VALUES (?,?,?,?,?)",
                (order_id, item_id, qty, price, float(l.get("amount") or qty * price)))
            # касса уже отпустила товар — остаток уменьшаем здесь один раз
            conn.execute("UPDATE items SET stock = COALESCE(stock,0) - ? WHERE id = ?", (qty, item_id))
        conn.commit()
        return number
    finally:
        conn.close()
