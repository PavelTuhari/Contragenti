# -*- coding: utf-8 -*-
"""
API прослойки для кассового приложения (Sunmi).

Принцип повторяет FiscalCloud: те же заголовки (`Api-Key`, `Api-Timestamp`,
`Api-Signature`), документация на `/api-docs`, песочница на
`/api-playground`, машинное описание на `/openapi.json`.

Что отдаёт и что принимает:
    GET  /api/v1/catalog/goods              товары и цены для кассы
    GET  /api/v1/catalog/goods/{barcode}    поиск по штрих-коду
    POST /api/v1/catalog/sync               перечитать каталог из учёта
    POST /api/v1/pos/sale                   продажа: чек и оплата картой
    POST /api/v1/pos/return                 возврат
    POST /api/v1/pos/closeday | /totals     Z-отчёт и X-отчёт
    POST /api/v1/pos/pull                   забрать чеки из FiscalCloud
    POST /api/v1/pos/export                 выгрузить продажи в учёт
    GET  /api/v1/pos/sales                  что уже принято
    GET  /api/v1/pos/status                 устройство, каталог, очередь
"""

import json
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, FastAPI, Request
from fastapi.openapi.docs import get_redoc_html, get_swagger_ui_html
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import catalog, config, export_crm, signing, store
from .fiscalcloud import FiscalCloudClient, FiscalCloudError


# ── модели запросов (из них же собирается описание в /api-docs) ──

class SaleLine(BaseModel):
    goodId: Optional[str] = Field(None, description="Идентификатор товара из каталога прослойки.")
    barcode: Optional[str] = Field(None, description="Штрих-код — вместо goodId.")
    name: Optional[str] = Field(None, description="Название, если товара нет в каталоге.")
    quantity: float = Field(1, description="Количество.")
    price: Optional[float] = Field(None, description="Цена за единицу; по умолчанию — из каталога.")
    discountPercent: float = Field(0, description="Скидка на строку, %: отрицательное значение.")
    taxGroupCode: Optional[str] = Field(None, description="Группа НДС; по умолчанию — из каталога.")
    comment: Optional[str] = None


class SalePayment(BaseModel):
    amount: float = Field(..., description="Сумма оплаты.")
    card: bool = Field(False, description="Оплата картой на банковском терминале MAIB.")
    typeCode: Optional[int] = Field(None, description="Код вида оплаты фискального устройства.")


class SaleIn(BaseModel):
    id: Optional[str] = Field(None, description="Идентификатор операции: повтор не печатает второй чек.")
    items: List[SaleLine]
    payments: List[SalePayment] = []
    discountPercent: float = Field(0, description="Скидка на весь чек, %.")
    email: Optional[str] = None
    phone: Optional[str] = None
    comment: Optional[str] = None
    exportToCrm: bool = Field(True, description="Сразу записать продажу в учёт.")


class SyncIn(BaseModel):
    source: Optional[str] = Field(None, description="demo | erp | file; по умолчанию — из настроек.")
    limit: Optional[int] = None
    query: Optional[str] = None


class PullIn(BaseModel):
    count: int = Field(100, description="Сколько чеков забрать за раз.")
    exportToCrm: bool = True


# ── вспомогательное ──

def _ok(data, **extra):
    out = {"success": True, "message": None, "data": data}
    out.update(extra)
    return out


def _fail(message, status=400):
    return JSONResponse(status_code=status, content={"success": False, "message": message, "data": None})


class Bridge:
    """Состояние прослойки: настройки, база, клиент FiscalCloud, устройство."""

    def __init__(self, cfg=None):
        self.cfg = cfg or config.load()
        self.db = config.db_path()
        store.init(self.db)
        self.fc = FiscalCloudClient(self.cfg)
        self.device = None
        self.tax_groups = None
        self.catalog_source = self.cfg["catalog"]["source"]
        self.last_error = ""

    # устройство: настоящие группы НДС и виды оплат берём у него
    def load_device(self):
        try:
            self.device = self.fc.device()
            groups = FiscalCloudClient.tax_groups(self.device)
            self.tax_groups = groups or None
            return True
        except FiscalCloudError as exc:
            self.last_error = str(exc)
            return False

    def sync_catalog(self, source=None, limit=None, query=None):
        rows, where = catalog.load(self.cfg, self.tax_groups, source, limit, query)
        src = (source or self.catalog_source)
        added, changed = store.upsert_goods(self.db, rows, src)
        store.log(self.db, "info", "каталог %s: всего %d, новых %d, изменённых %d" %
                  (src, len(rows), added, changed))
        return {"source": src, "origin": where, "total": len(rows), "added": added, "changed": changed}

    def resolve_line(self, line: SaleLine):
        good = None
        if line.goodId:
            good = store.good_by_id(self.db, line.goodId)
        if good is None and line.barcode:
            good = store.good_by_barcode(self.db, line.barcode)
        name = line.name or (good or {}).get("name")
        if not name:
            raise ValueError("строка без товара: нет ни goodId, ни barcode, ни названия")
        price = line.price if line.price is not None else float((good or {}).get("price") or 0)
        group = line.taxGroupCode or (good or {}).get("tax_group") or self.cfg["catalog"]["default_tax_group"]
        return FiscalCloudClient.item(name, line.quantity, price, group,
                                      good_id=(good or {}).get("id"),
                                      discount_percent=line.discountPercent,
                                      comment=line.comment or "")

    def save_receipt(self, receipt, kind="sale", receipt_type="FiscalReceipt"):
        sale = {
            "id": receipt.get("id"),
            "number": receipt.get("number"),
            "number_text": receipt.get("numberPresentation"),
            "date_time": receipt.get("dateTime"),
            "device_id": receipt.get("fiscalDeviceId"),
            "point_of_sale_id": receipt.get("pointOfSaleId"),
            "receipt_type": receipt_type,
            "total": receipt.get("totalAmount"),
            "total_paid": receipt.get("totalPaid"),
            "total_change": receipt.get("totalChange"),
            "mev_id": receipt.get("mevId"),
            "raw": receipt,
        }
        lines = [{
            "row_no": it.get("rowNumber"), "good_id": it.get("goodId"), "name": it.get("name"),
            "quantity": it.get("quantity"), "price": it.get("price"),
            "amount": it.get("finalAmount") if it.get("finalAmount") is not None else it.get("amount"),
            "tax_group": it.get("taxGroupCode"), "tax_amount": it.get("finalTaxAmount") or it.get("taxAmount"),
        } for it in receipt.get("items") or []]
        fresh = store.save_sale(self.db, sale, lines, kind)
        return sale, lines, fresh

    def export_to_crm(self, sale, lines):
        crm_db = (self.cfg["export"].get("crm_db") or "").strip()
        if not crm_db:
            for p in config.crm_db_candidates(self.cfg):
                import os
                if p and os.path.exists(p):
                    crm_db = p
                    break
        if not crm_db:
            return ""
        ref = export_crm.export_sale(crm_db, sale, lines,
                                     self.cfg["export"].get("client_name") or "Розничный покупатель",
                                     self.cfg["export"].get("order_prefix") or "POS-")
        if ref:
            store.mark_exported(self.db, sale["id"], ref)
        return ref


def build_app(cfg=None):
    bridge = Bridge(cfg)
    app = FastAPI(
        title="POS Bridge · учёт ↔ касса Sunmi (FiscalCloud / SoftLider)",
        version="1.0",
        description=(
            "Прослойка между учётом (Demo CRM или ERP OfficePlus на Oracle) и кассой: "
            "отдаёт кассе товары и цены, принимает от неё продажи и кладёт их обратно в учёт.\n\n"
            "**Подпись запроса** — как в FiscalCloud: заголовки `Api-Key`, `Api-Timestamp` "
            "(UTC, миллисекунды) и `Api-Signature` (HMAC-SHA256 от склейки "
            "`Api-DeviceId + Api-PointOfSaleId + Api-Timestamp + МЕТОД + путь с параметрами + тело`). "
            "На петлевом адресе без заданных ключей подпись не требуется — так удобно пробовать "
            "запросы в песочнице `/api-playground`."
        ),
        docs_url=None, redoc_url=None, openapi_url="/openapi.json")
    app.state.bridge = bridge

    # ── подпись входящих ──
    @app.middleware("http")
    async def verify(request: Request, call_next):
        path = request.url.path
        open_paths = ("/health", "/openapi.json", "/api-docs", "/api-playground", "/docs/oauth2-redirect")
        if path.startswith(open_paths) or request.method == "OPTIONS":
            return await call_next(request)
        clients = bridge.cfg.get("clients") or {}
        if not clients:
            if config.is_local_only(bridge.cfg):
                return await call_next(request)
            return _fail("прослойка открыта наружу, но ключи не заданы (clients в настройках)", 503)
        key = request.headers.get("api-key")
        client = clients.get(key)
        if not client:
            return _fail("неизвестный Api-Key", 401)
        raw = (await request.body()).decode("utf-8") if request.method in ("POST", "PUT") else ""
        pq = path + (("?" + request.url.query) if request.url.query else "")
        good, why = signing.check(client.get("secret", ""), dict(request.headers), request.method, pq, raw)
        if not good:
            return _fail(why, 401)
        return await call_next(request)

    r = APIRouter(prefix="/api/v1")

    # ── каталог ──

    @r.get("/catalog/goods", summary="Товары и цены для кассы",
           description="Список товаров с ценой и группой НДС. `since` отдаёт только изменившиеся — "
                       "касса тянет каталог по частям.")
    async def goods(q: str = "", since: str = "", limit: int = 1000):
        return _ok(store.goods(bridge.db, q, since, limit))

    @r.get("/catalog/goods/{barcode}", summary="Товар по штрих-коду")
    async def good(barcode: str):
        g = store.good_by_barcode(bridge.db, barcode) or store.good_by_id(bridge.db, barcode)
        return _ok(g) if g else _fail("товар не найден", 404)

    @r.post("/catalog/sync", summary="Перечитать каталог из учёта",
            description="Источник: `demo` — база Demo CRM, `erp` — справочник OfficePlus на Oracle "
                        "(TMS_UNIVERS TIP='P' + TMS_MPT), `file` — json-файл.")
    async def sync(body: SyncIn = SyncIn()):
        try:
            return _ok(bridge.sync_catalog(body.source, body.limit, body.query))
        except catalog.CatalogError as exc:
            return _fail(str(exc), 502)

    @r.get("/erp/clients", summary="Организации из OfficePlus (Oracle)",
           description="Справочник TMS_UNIVERS (TIP='O') + TMS_ORG: название, IDNO, адрес, руководитель. "
                       "Нужен учёту, когда он работает на реальных данных, а не в демо-режиме.")
    async def erp_clients(q: str = "", limit: int = 200):
        try:
            return _ok(catalog.orgs_from_erp(bridge.cfg, limit, q or None))
        except catalog.CatalogError as exc:
            return _fail(str(exc), 502)

    @r.get("/erp/goods", summary="Товары из OfficePlus (Oracle) напрямую",
           description="Карточка TMS_UNIVERS (TIP='P') + товарная часть TMS_MPT: штрих-код, цена, "
                       "группа НДС (CODTVA — она же TaxGroupCode фискального устройства).")
    async def erp_goods(q: str = "", limit: int = 200):
        try:
            rows, origin = catalog.from_erp(bridge.cfg, bridge.tax_groups, limit, q or None)
            return _ok(rows, origin=origin)
        except catalog.CatalogError as exc:
            return _fail(str(exc), 502)

    # ── касса ──

    @r.post("/pos/sale", summary="Продажа: фискальный чек и оплата картой")
    async def sale(body: SaleIn):
        if not body.items:
            return _fail("в чеке нет строк")
        try:
            items = [bridge.resolve_line(l) for l in body.items]
        except ValueError as exc:
            return _fail(str(exc))
        total = sum(i["quantity"] * i["price"] for i in items)
        payments = [FiscalCloudClient.payment(p.amount, p.card, p.typeCode) for p in body.payments]
        if not payments:
            payments = [FiscalCloudClient.payment(round(total, 2), by_card=False)]
        mods = [{"mode": "ByPercent", "value": body.discountPercent}] if body.discountPercent else []
        try:
            result = bridge.fc.sale(items, payments, mods, email=body.email or "",
                                    phone=body.phone or "", operation_id=body.id,
                                    comment=body.comment or "")
        except FiscalCloudError as exc:
            store.log(bridge.db, "error", "продажа не прошла: %s" % exc)
            return _fail("касса отказала: %s" % exc, 502)
        receipt = result.get("fiscalReceipt") or result.get("alternativeReceipt") or {}
        sale_row, lines, fresh = bridge.save_receipt(receipt, "sale", result.get("receiptType", "FiscalReceipt"))
        ref = bridge.export_to_crm(sale_row, lines) if (body.exportToCrm and fresh) else ""
        return _ok({"receiptType": result.get("receiptType"), "receipt": receipt,
                    "savedAsOrder": ref or None})

    @r.post("/pos/return", summary="Возврат по чеку")
    async def do_return(body: SaleIn):
        try:
            items = [bridge.resolve_line(l) for l in body.items]
        except ValueError as exc:
            return _fail(str(exc))
        payments = [FiscalCloudClient.payment(p.amount, p.card, p.typeCode) for p in body.payments]
        try:
            receipt = bridge.fc.do_return(items, payments, operation_id=body.id)
        except FiscalCloudError as exc:
            return _fail("касса отказала: %s" % exc, 502)
        bridge.save_receipt(receipt, "return", "FiscalReceipt")
        return _ok(receipt)

    @r.post("/pos/closeday", summary="Закрытие дня: Z-отчёт и сверка терминала")
    async def closeday():
        try:
            return _ok(bridge.fc.close_day())
        except FiscalCloudError as exc:
            return _fail(str(exc), 502)

    @r.post("/pos/totals", summary="Промежуточные итоги: X-отчёт")
    async def totals():
        try:
            return _ok(bridge.fc.intermediate_totals())
        except FiscalCloudError as exc:
            return _fail(str(exc), 502)

    @r.post("/pos/pull", summary="Забрать чеки из FiscalCloud",
            description="Скачивает выданные чеки (в том числе пробитые на самой кассе, минуя прослойку) "
                        "и, если попросили, сразу кладёт их в учёт.")
    async def pull(body: PullIn = PullIn()):
        try:
            rows, total = bridge.fc.receipts(0, body.count, full=True)
        except FiscalCloudError as exc:
            return _fail(str(exc), 502)
        new, exported = 0, 0
        for rc in rows:
            sale_row, lines, fresh = bridge.save_receipt(rc, "sale")
            if not fresh:
                continue
            new += 1
            if body.exportToCrm and bridge.export_to_crm(sale_row, lines):
                exported += 1
        store.log(bridge.db, "info", "приём чеков: всего %d, новых %d, в учёт %d" % (len(rows), new, exported))
        return _ok({"fetched": len(rows), "totalOnDevice": total, "new": new, "exportedToCrm": exported})

    @r.post("/pos/export", summary="Выгрузить принятые продажи в учёт")
    async def export(limit: int = 200):
        done = []
        for s in store.sales(bridge.db, only_new=True, limit=limit):
            lines = s.pop("lines", [])
            ref = bridge.export_to_crm(s, lines)
            if ref:
                done.append(ref)
        return _ok({"exported": len(done), "orders": done})

    @r.get("/pos/sales", summary="Принятые продажи")
    async def sales(date_from: str = "", date_to: str = "", onlyNew: bool = False, limit: int = 200):
        return _ok(store.sales(bridge.db, date_from, date_to, onlyNew, limit))

    @r.get("/pos/status", summary="Состояние: устройство, каталог, очередь выгрузки")
    async def status():
        st = store.stats(bridge.db)
        dev = bridge.device or {}
        return _ok({
            "catalogSource": bridge.catalog_source,
            "fiscalCloud": {"url": bridge.fc.base_url, "configured": bridge.fc.configured,
                            "deviceId": bridge.fc.device_id, "lastError": bridge.last_error},
            "device": {"name": dev.get("name"), "serialNumber": dev.get("serialNumber"),
                       "organizationName": dev.get("organizationName"),
                       "taxGroups": FiscalCloudClient.tax_groups(dev),
                       "paymentTypes": FiscalCloudClient.payment_types(dev)},
            "store": st,
        })

    app.include_router(r)

    @app.get("/health", include_in_schema=False)
    async def health():
        return {"status": "ok", "goods": store.goods_count(bridge.db)}

    # ── документация: тот же принцип, что у FiscalCloud ──
    @app.get("/api-docs", include_in_schema=False)
    async def api_docs():
        return get_redoc_html(openapi_url="/openapi.json", title="POS Bridge · описание API")

    @app.get("/api-playground", include_in_schema=False)
    async def api_playground():
        return get_swagger_ui_html(openapi_url="/openapi.json", title="POS Bridge · песочница")

    return app
