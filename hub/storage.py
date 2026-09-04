# -*- coding: utf-8 -*-
"""Реестр хаба: принятые пакеты, их статус и накопленная статистика.

Реестр хранится в отдельном SQLite рядом с хабом и не зависит от Oracle:
пакет должен приниматься и переживать перезапуск даже когда una.md недоступна.
"""

import json
import sqlite3
import threading
import datetime

from . import config

_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS batches (
    id            TEXT PRIMARY KEY,
    client        TEXT,
    filename      TEXT,
    size_bytes    INTEGER,
    sha256        TEXT,
    received_at   TEXT,
    status        TEXT,          -- accepted | importing | done | error
    started_at    TEXT,
    finished_at   TEXT,
    rows_total    INTEGER DEFAULT 0,
    rows_new      INTEGER DEFAULT 0,
    rows_dup      INTEGER DEFAULT 0,
    rows_error    INTEGER DEFAULT 0,
    message       TEXT
);
CREATE INDEX IF NOT EXISTS ix_batches_status ON batches(status);
CREATE INDEX IF NOT EXISTS ix_batches_received ON batches(received_at);

CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id   TEXT,
    ts         TEXT,
    level      TEXT,
    message    TEXT
);
CREATE INDEX IF NOT EXISTS ix_events_batch ON events(batch_id);
"""


def _now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def connect():
    conn = sqlite3.connect(config.REGISTRY_DB, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init():
    config.ensure_dirs()
    with _lock, connect() as conn:
        conn.executescript(SCHEMA)


def add_batch(batch_id, client, filename, size_bytes, sha256):
    with _lock, connect() as conn:
        conn.execute(
            "INSERT INTO batches (id, client, filename, size_bytes, sha256, "
            "received_at, status) VALUES (?,?,?,?,?,?,'accepted')",
            (batch_id, client, filename, size_bytes, sha256, _now()))


def set_status(batch_id, status, **fields):
    sets = ["status = ?"]
    vals = [status]
    if status == "importing":
        sets.append("started_at = ?")
        vals.append(_now())
    if status in ("done", "error"):
        sets.append("finished_at = ?")
        vals.append(_now())
    for key, val in fields.items():
        sets.append(f"{key} = ?")
        vals.append(val)
    vals.append(batch_id)
    with _lock, connect() as conn:
        conn.execute(f"UPDATE batches SET {', '.join(sets)} WHERE id = ?", vals)


def log_event(batch_id, level, message):
    with _lock, connect() as conn:
        conn.execute("INSERT INTO events (batch_id, ts, level, message) VALUES (?,?,?,?)",
                     (batch_id, _now(), level, message[:2000]))


def find_by_digest(sha256, client=None):
    """Уже обработанный пакет с тем же содержимым (тот же клиент)."""
    q = ("SELECT * FROM batches WHERE sha256 = ? AND status = 'done'")
    args = [sha256]
    if client:
        q += " AND client = ?"
        args.append(client)
    q += " ORDER BY received_at DESC LIMIT 1"
    with connect() as conn:
        row = conn.execute(q, args).fetchone()
        return dict(row) if row else None


def get_batch(batch_id):
    with connect() as conn:
        row = conn.execute("SELECT * FROM batches WHERE id = ?", (batch_id,)).fetchone()
        return dict(row) if row else None


def list_batches(limit=50, status=None):
    q = "SELECT * FROM batches"
    args = []
    if status:
        q += " WHERE status = ?"
        args.append(status)
    q += " ORDER BY received_at DESC LIMIT ?"
    args.append(limit)
    with connect() as conn:
        return [dict(r) for r in conn.execute(q, args).fetchall()]


def batch_events(batch_id, limit=100):
    with connect() as conn:
        return [dict(r) for r in conn.execute(
            "SELECT * FROM events WHERE batch_id = ? ORDER BY id DESC LIMIT ?",
            (batch_id, limit)).fetchall()]


def pending_batches():
    """Пакеты, ожидающие импорта (в т.ч. после перезапуска хаба)."""
    with connect() as conn:
        return [dict(r) for r in conn.execute(
            "SELECT * FROM batches WHERE status IN ('accepted','importing') "
            "ORDER BY received_at").fetchall()]


def stats():
    with connect() as conn:
        row = conn.execute("""
            SELECT COUNT(*) batches,
                   COALESCE(SUM(rows_total),0) rows_total,
                   COALESCE(SUM(rows_new),0)   rows_new,
                   COALESCE(SUM(rows_dup),0)   rows_dup,
                   COALESCE(SUM(rows_error),0) rows_error
              FROM batches""").fetchone()
        by_status = {r["status"]: r["n"] for r in conn.execute(
            "SELECT status, COUNT(*) n FROM batches GROUP BY status").fetchall()}
        clients = [dict(r) for r in conn.execute(
            "SELECT client, COUNT(*) batches, COALESCE(SUM(rows_new),0) rows_new, "
            "MAX(received_at) last_seen FROM batches GROUP BY client "
            "ORDER BY last_seen DESC").fetchall()]
    out = dict(row)
    out["by_status"] = by_status
    out["clients"] = clients
    return out
