# -*- coding: utf-8 -*-
"""
Отправка локальной базы контрагентов на хаб una.md.

Работает в фоне и не мешает интерфейсу: база копируется «на горячую»
средствами SQLite (backup API), пакуется gzip и уходит на хаб одним
POST-запросом. Хаб отвечает сразу — импорт идёт уже на его стороне.

Используется и из приложения (фоновый поток), и отдельно из консоли:
    python hub_client.py --url http://127.0.0.1:8800 --once
"""

import argparse
import gzip
import io
import json
import os
import socket
import sqlite3
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

DEFAULT_URL = os.environ.get("HUB_URL", "http://127.0.0.1:8800")


def snapshot_db(db_path):
    """Согласованная копия базы без остановки приложения (SQLite backup API)."""
    fd, tmp = tempfile.mkstemp(suffix=".db", prefix="contragenti_snap_")
    os.close(fd)
    src = sqlite3.connect(db_path)
    dst = sqlite3.connect(tmp)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()
    return tmp


def pack(db_path):
    """Упаковать базу в gzip и вернуть байты."""
    buf = io.BytesIO()
    with open(db_path, "rb") as src, gzip.GzipFile(fileobj=buf, mode="wb",
                                                   compresslevel=9, mtime=0) as gz:
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            gz.write(chunk)
    return buf.getvalue()


def send(url, payload, api_key=None, client_id=None, timeout=120):
    """Отправить пакет на хаб. Возвращает ответ хаба (dict)."""
    req = urllib.request.Request(
        url.rstrip("/") + "/api/v1/batches", data=payload, method="POST")
    req.add_header("Content-Type", "application/gzip")
    if api_key:
        req.add_header("X-Api-Key", api_key)
    req.add_header("X-Client-Id", client_id or socket.gethostname())
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def upload_once(db_path, url=DEFAULT_URL, api_key=None, client_id=None):
    """Один цикл: снимок → упаковка → отправка. Возвращает ответ хаба."""
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"нет базы {db_path}")
    snap = snapshot_db(db_path)
    try:
        payload = pack(snap)
    finally:
        try:
            os.unlink(snap)
        except OSError:
            pass
    return send(url, payload, api_key, client_id)


class HubUploader(threading.Thread):
    """Фоновая периодическая отправка базы на хаб.

    Ошибки связи не считаются фатальными: следующая попытка будет
    через увеличенный интервал, приложение продолжает работать.
    """

    def __init__(self, db_path, url=DEFAULT_URL, api_key=None, client_id=None,
                 interval=900, out_queue=None):
        super().__init__(daemon=True)
        self.db_path = db_path
        self.url = url
        self.api_key = api_key
        self.client_id = client_id
        self.interval = interval
        self.out = out_queue
        self.stop_flag = threading.Event()
        self.last_result = None

    def _report(self, kind, payload):
        if self.out is not None:
            self.out.put((kind, payload))

    def run(self):
        backoff = self.interval
        while not self.stop_flag.is_set():
            try:
                res = upload_once(self.db_path, self.url, self.api_key, self.client_id)
                self.last_result = res
                self._report("hub_sent", res)
                backoff = self.interval
            except Exception as exc:  # noqa: BLE001
                self._report("hub_error", str(exc))
                backoff = min(backoff * 2, 2 * 3600)
            self.stop_flag.wait(backoff)

    def stop(self):
        self.stop_flag.set()


def main():
    ap = argparse.ArgumentParser(description="Отправка базы контрагентов на хаб una.md")
    ap.add_argument("--db", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "companies.db"))
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--api-key", default=os.environ.get("HUB_API_KEY"))
    ap.add_argument("--client-id", default=None)
    ap.add_argument("--interval", type=int, default=900, help="период отправки, сек")
    ap.add_argument("--once", action="store_true", help="отправить один раз и выйти")
    args = ap.parse_args()

    if args.once:
        res = upload_once(args.db, args.url, args.api_key, args.client_id)
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return

    print(f"фоновая отправка на {args.url} каждые {args.interval} с; Ctrl+C — стоп")
    up = HubUploader(args.db, args.url, args.api_key, args.client_id, args.interval)
    up.start()
    try:
        while True:
            time.sleep(5)
    except KeyboardInterrupt:
        up.stop()
        print("остановлено")


if __name__ == "__main__":
    main()
