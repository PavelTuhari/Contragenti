# -*- coding: utf-8 -*-
"""
Асинхронный импорт принятых пакетов в справочник una.md.

Пакет — это companies.db локального Contragenti, упакованный gzip. Импорт
идёт в фоне и по одной организации: каждая ложится тремя связанными блоками
(TMS_UNIVERS → TMS_ORG → TMS_ORG26), дубли отсекаются по фискальному коду.

Oracle-драйвер синхронный, поэтому вся работа с базой уходит в отдельный
поток — событийный цикл хаба при этом не блокируется и сайт остаётся живым.
"""

import asyncio
import gzip
import os
import shutil
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tms_export  # noqa: E402

from . import storage  # noqa: E402


def unpack(path):
    """Распаковать gzip-архив во временный .db. Вернуть путь."""
    fd, tmp = tempfile.mkstemp(suffix=".db", prefix="hub_batch_")
    os.close(fd)
    with gzip.open(path, "rb") as src, open(tmp, "wb") as dst:
        shutil.copyfileobj(src, dst)
    return tmp


def read_companies(db_path):
    """Прочитать записи организаций из присланной базы Contragenti."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        tables = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        if "companies" not in tables:
            raise ValueError("в архиве нет таблицы companies — это не база Contragenti")
        rows = [dict(r) for r in conn.execute("SELECT * FROM companies").fetchall()]
    finally:
        conn.close()
    return rows


def import_rows(batch_id, rows, oracle_cfg, progress=None):
    """Синхронная заливка в Oracle. Выполняется в отдельном потоке."""
    stat = {"total": len(rows), "new": 0, "dup": 0, "error": 0}
    exporter = tms_export.TmsExporter(oracle_cfg).connect()
    try:
        for i, rec in enumerate(rows, 1):
            idno = (rec.get("idno") or "").strip()
            if not idno:
                # без фискального кода дедупликация невозможна — пропускаем,
                # иначе такая запись будет задваиваться при каждом пакете
                stat["error"] += 1
                continue
            try:
                rep = exporter.export_one(rec)
            except Exception as exc:  # noqa: BLE001
                stat["error"] += 1
                storage.log_event(batch_id, "error", f"{idno}: {exc}")
                continue
            if rep["status"] == "ok":
                stat["new"] += 1
            elif rep["status"] == "duplicate":
                stat["dup"] += 1
            else:
                stat["error"] += 1
                storage.log_event(batch_id, "error",
                                  f"{idno}: {rep.get('error', rep['status'])}")
            if progress and i % 10 == 0:
                progress(i, stat)
    finally:
        exporter.close()
    return stat


async def process_batch(batch, oracle_cfg):
    """Полный цикл обработки одного пакета."""
    batch_id = batch["id"]
    path = batch["filename"]
    storage.set_status(batch_id, "importing")
    storage.log_event(batch_id, "info", "начата обработка")

    tmp_db = None
    try:
        loop = asyncio.get_running_loop()
        tmp_db = await loop.run_in_executor(None, unpack, path)
        rows = await loop.run_in_executor(None, read_companies, tmp_db)
        storage.log_event(batch_id, "info", f"в архиве записей: {len(rows)}")
        storage.set_status(batch_id, "importing", rows_total=len(rows))

        def on_progress(done, stat):
            storage.set_status(batch_id, "importing", rows_new=stat["new"],
                               rows_dup=stat["dup"], rows_error=stat["error"])

        stat = await loop.run_in_executor(
            None, import_rows, batch_id, rows, oracle_cfg, on_progress)

        storage.set_status(batch_id, "done", rows_total=stat["total"],
                           rows_new=stat["new"], rows_dup=stat["dup"],
                           rows_error=stat["error"],
                           message=f"новых {stat['new']}, дублей {stat['dup']}, "
                                   f"ошибок {stat['error']}")
        storage.log_event(batch_id, "info", "импорт завершён")
    except Exception as exc:  # noqa: BLE001
        storage.set_status(batch_id, "error", message=str(exc)[:500])
        storage.log_event(batch_id, "error", str(exc))
    finally:
        if tmp_db and os.path.exists(tmp_db):
            try:
                os.unlink(tmp_db)
            except OSError:
                pass


def purge_inbox(keep_days):
    """Удалить архивы обработанных пакетов старше keep_days.

    Сам пакет после импорта уже не нужен: результат зафиксирован в реестре
    и в справочнике. Без уборки inbox растёт бесконечно.
    """
    if not keep_days:
        return 0
    import time as _time
    from . import config as _config

    edge = _time.time() - keep_days * 86400
    removed = 0
    done_ids = {b["id"] for b in storage.list_batches(limit=100000)
                if b["status"] in ("done", "error")}
    for name in os.listdir(_config.INBOX_DIR):
        path = os.path.join(_config.INBOX_DIR, name)
        if not os.path.isfile(path):
            continue
        if name.split(".")[0] not in done_ids:
            continue                      # ещё не импортирован — не трогаем
        try:
            if os.path.getmtime(path) < edge:
                os.unlink(path)
                removed += 1
        except OSError:
            pass
    return removed


class ImportQueue:
    """Очередь импорта: принимает пакеты и разбирает их в фоне."""

    def __init__(self, oracle_cfg, workers=1):
        self.oracle_cfg = oracle_cfg
        self.workers = max(1, workers)
        self.queue = asyncio.Queue()
        self.tasks = []

    async def start(self):
        for _ in range(self.workers):
            self.tasks.append(asyncio.create_task(self._worker()))
        # пакеты, не доехавшие до конца при прошлом запуске
        for batch in storage.pending_batches():
            await self.queue.put(batch)

    async def stop(self):
        for task in self.tasks:
            task.cancel()
        self.tasks.clear()

    async def submit(self, batch):
        await self.queue.put(batch)

    def depth(self):
        return self.queue.qsize()

    async def _worker(self):
        while True:
            batch = await self.queue.get()
            try:
                await process_batch(batch, self.oracle_cfg)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                storage.log_event(batch.get("id", "?"), "error", f"worker: {exc}")
            finally:
                self.queue.task_done()
