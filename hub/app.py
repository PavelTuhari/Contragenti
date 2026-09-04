# -*- coding: utf-8 -*-
"""
Хаб сбора баз контрагентов для ERP una.md.

Локальные Contragenti в фоне присылают сюда свои companies.db в упакованном
виде; хаб принимает пакет, кладёт его в inbox и асинхронно вливает в общий
справочник una.md, постепенно собирая единую базу организаций.

Запуск:
    python -m hub.app                    # 127.0.0.1:8800
    python -m hub.app --host 0.0.0.0     # при выносе на хостинг
"""

import argparse
import asyncio
import contextlib
import datetime
import hashlib
import os
import uuid

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse

from . import config, importer, storage

CFG = config.load()
QUEUE = None


@contextlib.asynccontextmanager
async def lifespan(app):
    storage.init()
    config.ensure_dirs()
    global QUEUE
    QUEUE = importer.ImportQueue(CFG["oracle"], CFG.get("import_workers", 1))
    await QUEUE.start()
    housekeeper = asyncio.create_task(_housekeeping())
    yield
    housekeeper.cancel()
    await QUEUE.stop()


async def _housekeeping():
    """Раз в сутки убирает старые архивы из inbox."""
    while True:
        try:
            removed = await asyncio.get_running_loop().run_in_executor(
                None, importer.purge_inbox, CFG.get("keep_inbox_days", 14))
            if removed:
                print(f"[хаб] удалено старых архивов: {removed}")
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            print(f"[хаб] уборка не удалась: {exc}")
        await asyncio.sleep(24 * 3600)


app = FastAPI(title="una.md · хаб справочника контрагентов",
              version="1.0", lifespan=lifespan)


def is_local_only():
    """Хаб слушает только петлевой адрес?"""
    return str(CFG.get("host", "")).strip() in ("127.0.0.1", "localhost", "::1")


def check_key(api_key):
    """Проверить ключ клиента.

    Без ключей работаем только на петлевом адресе. Если хаб открыт наружу,
    приём без ключа запрещён: иначе писать в общий справочник сможет кто
    угодно, кто знает адрес.
    """
    clients = CFG.get("clients") or {}
    if not clients:
        if is_local_only():
            return "local"
        raise HTTPException(
            status_code=503,
            detail="хаб слушает внешний адрес, но список clients пуст — "
                   "задайте API-ключи в hub_config.json")
    if not api_key or api_key not in clients:
        raise HTTPException(status_code=401, detail="неизвестный или отсутствующий API-ключ")
    return clients[api_key]


# ─────────────────────────── API ───────────────────────────

@app.get("/api/v1/health")
async def health():
    return {"status": "ok", "time": datetime.datetime.now().isoformat(timespec="seconds"),
            "queue": QUEUE.depth() if QUEUE else 0}


@app.post("/api/v1/batches")
async def upload_batch(request: Request,
                       x_api_key: str = Header(default=None),
                       x_client_id: str = Header(default=None)):
    """Приём упакованной базы. Тело запроса — gzip(sqlite), без обёрток.

    Отвечает сразу после сохранения: импорт идёт в фоне, клиент не ждёт.
    """
    client = check_key(x_api_key)
    if x_client_id:
        client = f"{client}/{x_client_id}"

    body = await request.body()
    limit = CFG.get("max_upload_mb", 64) * 1024 * 1024
    if not body:
        raise HTTPException(status_code=400, detail="пустое тело запроса")
    if len(body) > limit:
        raise HTTPException(status_code=413,
                            detail=f"пакет больше {CFG['max_upload_mb']} МБ")
    if body[:2] != b"\x1f\x8b":
        raise HTTPException(status_code=400, detail="ожидается gzip-архив базы")

    batch_id = uuid.uuid4().hex[:16]
    digest = hashlib.sha256(body).hexdigest()

    # клиент шлёт базу по расписанию; если она не менялась, архив тот же —
    # незачем гонять импорт повторно
    same = storage.find_by_digest(digest, client)
    if same:
        return JSONResponse(status_code=200, content={
            "batch_id": same["id"], "status": "duplicate",
            "message": "такой пакет уже обработан, импорт не повторяется",
            "sha256": digest,
            "status_url": f"/api/v1/batches/{same['id']}"})

    path = os.path.join(config.INBOX_DIR, f"{batch_id}.db.gz")
    with open(path, "wb") as f:
        f.write(body)

    storage.add_batch(batch_id, client, path, len(body), digest)
    storage.log_event(batch_id, "info", f"пакет принят от {client}, {len(body)} байт")
    await QUEUE.submit(storage.get_batch(batch_id))

    return JSONResponse(status_code=202, content={
        "batch_id": batch_id, "status": "accepted",
        "size_bytes": len(body), "sha256": digest,
        "status_url": f"/api/v1/batches/{batch_id}"})


@app.get("/api/v1/batches/{batch_id}")
async def batch_status(batch_id: str, x_api_key: str = Header(default=None)):
    check_key(x_api_key)
    batch = storage.get_batch(batch_id)
    if not batch:
        raise HTTPException(status_code=404, detail="пакет не найден")
    batch.pop("filename", None)          # внутренний путь наружу не отдаём
    batch["events"] = storage.batch_events(batch_id, 20)
    return batch


@app.get("/api/v1/batches")
async def batch_list(limit: int = 50, status: str = None,
                     x_api_key: str = Header(default=None)):
    check_key(x_api_key)
    rows = storage.list_batches(limit=limit, status=status)
    for r in rows:
        r.pop("filename", None)
    return {"batches": rows}


@app.get("/api/v1/stats")
async def stats(x_api_key: str = Header(default=None)):
    check_key(x_api_key)
    out = storage.stats()
    out["queue_depth"] = QUEUE.depth() if QUEUE else 0
    return out


# ─────────────────────────── дашборд ───────────────────────────

PAGE = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>una.md · хаб справочника контрагентов</title>
<style>
:root{--ink:#12222f;--mute:#69808f;--paper:#f6f7f5;--card:#fff;--rule:#d7dde0;
      --accent:#0b6e5f;--accent-soft:#e3efec;--warn:#a63a2b;--warn-soft:#f6e7e4}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);
     font-family:"Segoe UI",system-ui,sans-serif;font-size:15px;line-height:1.55}
.wrap{max-width:1080px;margin:0 auto;padding:0 22px 64px}
header{padding:26px 0 18px;border-bottom:2px solid var(--ink);margin-bottom:26px}
.brand{font-size:22px;font-weight:700;color:var(--accent)}
h1{font-size:26px;margin:8px 0 4px}
.sub{color:var(--mute);font-size:14px;margin:0}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
       gap:1px;background:var(--rule);border:1px solid var(--rule);border-radius:3px;
       overflow:hidden;margin:0 0 26px}
.tile{background:var(--card);padding:14px 16px}
.tile .k{font-size:11px;letter-spacing:.09em;text-transform:uppercase;
         color:var(--mute);font-weight:700;margin:0 0 6px}
.tile .v{font-size:26px;font-weight:700;margin:0;font-variant-numeric:tabular-nums}
.tile .v.ok{color:var(--accent)}
h2{font-size:17px;margin:24px 0 10px}
table{border-collapse:collapse;width:100%;font-size:13.5px;background:var(--card)}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--rule)}
th{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--mute)}
td.num{text-align:right;font-variant-numeric:tabular-nums}
.pill{display:inline-block;padding:2px 8px;border-radius:2px;font-size:11px;font-weight:700}
.s-done{background:var(--accent-soft);color:var(--accent)}
.s-error{background:var(--warn-soft);color:var(--warn)}
.s-importing,.s-accepted{background:#eef2f4;color:var(--mute)}
code{font-family:Consolas,monospace;font-size:12.5px}
.hint{color:var(--mute);font-size:13px;margin-top:18px}
.wrapscroll{overflow-x:auto;border:1px solid var(--rule);border-radius:3px}
</style></head><body><div class="wrap">
<header>
  <div class="brand">una.md</div>
  <h1>Хаб справочника контрагентов</h1>
  <p class="sub">Локальные Contragenti присылают свои базы в фоне; хаб постепенно
  собирает из них единый справочник организаций.</p>
</header>
<div class="tiles" id="tiles"></div>
<h2>Последние пакеты</h2>
<div class="wrapscroll"><table id="batches">
<thead><tr><th>Пакет</th><th>Клиент</th><th>Принят</th><th>Статус</th>
<th class="num">Записей</th><th class="num">Новых</th><th class="num">Дублей</th>
<th class="num">Ошибок</th></tr></thead><tbody></tbody></table></div>
<p class="hint">Приём: <code>POST /api/v1/batches</code> — тело gzip(sqlite),
заголовки <code>X-Api-Key</code>, <code>X-Client-Id</code>.
Статус: <code>GET /api/v1/batches/{id}</code>. Сводка: <code>GET /api/v1/stats</code>.</p>
</div>
<script>
async function tick(){
  const s = await (await fetch('/api/v1/stats')).json();
  document.getElementById('tiles').innerHTML = [
    ['Пакетов', s.batches, ''],
    ['В очереди', s.queue_depth, ''],
    ['Записей получено', s.rows_total, ''],
    ['Новых организаций', s.rows_new, 'ok'],
    ['Дублей', s.rows_dup, ''],
    ['Ошибок', s.rows_error, '']
  ].map(([k,v,c]) => `<div class="tile"><p class="k">${k}</p><p class="v ${c}">${v}</p></div>`).join('');

  const b = (await (await fetch('/api/v1/batches?limit=25')).json()).batches;
  document.querySelector('#batches tbody').innerHTML = b.map(r => `
    <tr><td><code>${r.id}</code></td><td>${r.client||''}</td>
    <td>${(r.received_at||'').replace('T',' ')}</td>
    <td><span class="pill s-${r.status}">${r.status}</span></td>
    <td class="num">${r.rows_total||0}</td><td class="num">${r.rows_new||0}</td>
    <td class="num">${r.rows_dup||0}</td><td class="num">${r.rows_error||0}</td></tr>`).join('')
    || '<tr><td colspan="8" style="color:#69808f">пакетов пока нет</td></tr>';
}
tick(); setInterval(tick, 3000);
</script></body></html>"""


@app.get("/", response_class=HTMLResponse)
async def dashboard():
    return PAGE


def main():
    import uvicorn
    ap = argparse.ArgumentParser(description="Хаб справочника контрагентов una.md")
    ap.add_argument("--host", default=CFG["host"])
    ap.add_argument("--port", type=int, default=CFG["port"])
    args = ap.parse_args()
    # фактический адрес прослушивания важнее записанного в файле: от него
    # зависит, разрешён ли приём без API-ключа
    CFG["host"] = args.host
    if not is_local_only() and not CFG.get("clients"):
        print("ВНИМАНИЕ: хаб открыт наружу без API-ключей — приём будет отклоняться.\n"
              "Задайте clients в hub_config.json (см. tools/hub_keygen.py).")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
