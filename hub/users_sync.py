# -*- coding: utf-8 -*-
"""
Обмен карточками сотрудников между Demo CRM и ERP (UNIAC/OfficePlus).

Обе стороны устроены одинаково: правку ставит в очередь **триггер**, а
разбирает очередь программа. Хаб — та самая программа посередине:

    CRM → хаб → ERP    POST /api/v1/users   (строки очереди sync_log)
    ERP → хаб → CRM    GET  /api/v1/users   (строки очереди A$CRM_SYNC)

Сторона ERP (таблица A$CRM_SYNC, пакет A$CRM$SYNC, триггеры на A$ADM,
A$ADP и TMS_MUNC) устанавливается скриптом sql/erp_users_sync.sql.
Пароли через обмен не ходят: в CRM хранится SHA-256, в UNIA — свой код
(a$util.hide_passwd), передаётся только признак «нужна смена пароля».

Oracle-драйвер синхронный, поэтому вызовы уходят в отдельный поток —
как в importer.py.
"""

import asyncio
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tms_export  # noqa: E402

FIELDS = ("login", "full_name", "position", "role", "email", "phone", "active", "erp_code")


def parse_payload(text):
    """Разбор снимка из очереди CRM: {"login":"…","full_name":"…",…}.

    Ключи фиксированы и идут в известном порядке, поэтому значение — это
    всё между своим маркером и маркером следующего ключа: запятая или
    двоеточие в имени человека разбор не ломают (так же читает и CRM).
    """
    out = {}
    if not text:
        return out
    for i, key in enumerate(FIELDS):
        mark = '"%s":"' % key
        start = text.find(mark)
        if start < 0:
            continue
        start += len(mark)
        end = -1
        if i + 1 < len(FIELDS):
            end = text.find('","%s":"' % FIELDS[i + 1], start)
        if end < 0:
            end = text.rfind('"}')
        out[key] = text[start:end] if end > start else ""
    return out


class UsersSync:
    """Синхронная работа с очередью ERP. Свой connect() на поток."""

    def __init__(self, oracle_cfg=None):
        self.cfg = dict(tms_export.DEFAULT_CONFIG)
        if oracle_cfg:
            self.cfg.update(oracle_cfg)
        self.conn = None

    def connect(self):
        tms_export._ensure_thick(self.cfg.get("client_dir", ""))
        self.conn = tms_export.oracledb.connect(
            user=self.cfg["user"], password=self.cfg["password"], dsn=self.cfg["dsn"])
        return self

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            finally:
                self.conn = None

    def __enter__(self):
        return self.connect()

    def __exit__(self, *a):
        self.close()

    # ── CRM → ERP ──

    def push(self, rows):
        """Принять строки очереди CRM. Возвращает статистику и список id."""
        stat = {"applied": 0, "created": 0, "updated": 0, "skipped": 0, "errors": [], "acks": []}
        cur = self.conn.cursor()
        try:
            for row in rows:
                fields = row.get("fields") or parse_payload(row.get("payload", ""))
                login = (fields.get("login") or "").strip()
                if not login:
                    stat["skipped"] += 1
                    continue
                try:
                    out = cur.var(str)
                    cur.execute(
                        "begin :r := A$CRM$SYNC.APPLY_USER(:login, :full_name, :position, :role,"
                        " :email, :phone, :active, :erp_code, :reg); end;",
                        r=out, login=login,
                        full_name=fields.get("full_name") or login,
                        position=fields.get("position") or None,
                        role=fields.get("role") or None,
                        email=fields.get("email") or None,
                        phone=fields.get("phone") or None,
                        active=fields.get("active") or "1",
                        erp_code=(fields.get("erp_code") or None),
                        reg=row.get("changed_at"))
                    result = out.getvalue() or ""
                    stat["applied"] += 1
                    if result.startswith("созд"):
                        stat["created"] += 1
                    elif result.startswith("обнов"):
                        stat["updated"] += 1
                    else:
                        stat["skipped"] += 1
                    if row.get("id"):
                        stat["acks"].append(row["id"])
                except Exception as exc:  # noqa: BLE001
                    stat["errors"].append("%s: %s" % (login, exc))
            self.conn.commit()
        finally:
            cur.close()
        return stat

    # ── ERP → CRM ──

    def pull(self, limit=200, mark_sent=True):
        """Забрать неотданные строки очереди ERP."""
        cur = self.conn.cursor()
        rows = []
        try:
            cur.execute(
                "SELECT ID, OP, TO_CHAR(CHANGED_AT,'YYYY-MM-DD HH24:MI:SS'), PAYLOAD, LOGIN_NAME"
                "  FROM A$CRM_SYNC WHERE SENT_AT IS NULL AND ENTITY = 'users'"
                "  ORDER BY ID FETCH FIRST :n ROWS ONLY", n=limit)
            for rec in cur.fetchall():
                payload = rec[3]
                if payload is None:
                    continue
                rows.append({"id": rec[0], "op": rec[1], "changed_at": rec[2],
                             "payload": payload, "fields": parse_payload(payload)})
            if mark_sent:
                for r in rows:
                    cur.execute("begin A$CRM$SYNC.ACK(:id, 'crm'); end;", id=r["id"])
                self.conn.commit()
        finally:
            cur.close()
        return rows

    def pending(self):
        cur = self.conn.cursor()
        try:
            cur.execute("SELECT COUNT(*) FROM A$CRM_SYNC WHERE SENT_AT IS NULL")
            return int(cur.fetchone()[0])
        finally:
            cur.close()


def _sync_call(oracle_cfg, action, rows, limit):
    with UsersSync(oracle_cfg) as us:
        if action == "push":
            return us.push(rows)
        return {"rows": us.pull(limit), "pending": us.pending()}


async def exchange(oracle_cfg, action, rows=None, limit=200):
    """Асинхронная обёртка: Oracle синхронный, событийный цикл не блокируем."""
    return await asyncio.get_running_loop().run_in_executor(
        None, _sync_call, oracle_cfg, action, rows or [], limit)


def now_str():
    return datetime.datetime.now().isoformat(timespec="seconds")
