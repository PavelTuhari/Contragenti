# -*- coding: utf-8 -*-
"""
Демонстрационный эмулятор FiscalCloud: отвечает как сервис SoftLider на
localhost:50700, но ничего не печатает и ни с чем не связывается.

Нужен, чтобы показать всю цепочку «учёт → касса → продажи обратно в учёт»
без кассового аппарата Sunmi, фискального модуля и банковского терминала.
Проверяет подпись по тем же правилам, поэтому боевой ключ в коде кассового
приложения менять не придётся: меняется только адрес.

Реализованы разделы, которыми пользуется прослойка: продажа, возврат,
закрытие дня, промежуточные итоги, список и карточка чека, устройство.
"""

import datetime
import json
import uuid

from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from . import signing

# ключи демо-стенда: те же значения лежат в примере настроек
DEMO_API_KEY = "demo-api-key-0000000000000000000000000000"
DEMO_API_SECRET = "demo-api-secret-000000000000000000000000"
DEMO_DEVICE_ID = "0875b8a5-0668-41a3-a3fa-8eeccf66d289"
DEMO_POS_ID = "1f0d2a64-7b53-4f0e-9a3d-2f4d6f0a1c77"

# группы НДС Молдовы и виды оплат — как их отдаёт настоящее устройство
TAX_GROUPS = [
    {"rowNumber": 1, "enabled": True, "code": "A", "rate": 20.0},
    {"rowNumber": 2, "enabled": True, "code": "B", "rate": 8.0},
    {"rowNumber": 3, "enabled": True, "code": "C", "rate": 12.0},
    {"rowNumber": 4, "enabled": True, "code": "N", "rate": 0.0},
]
PAYMENT_TYPES = [
    {"rowNumber": 1, "code": 0, "name": "Numerar", "enabled": True, "openCashDrawer": True},
    {"rowNumber": 2, "code": 1, "name": "Card bancar (MAIB)", "enabled": True, "openCashDrawer": False},
]


class DemoState:
    """Смена и выданные чеки. Живёт в памяти процесса."""

    def __init__(self):
        self.receipts = []          # фискальные чеки (последний — первым не сортируем)
        self.returns = []
        self.reports = []
        self.number = 0
        self.day_opened = datetime.datetime.now()
        self.by_operation_id = {}   # повтор запроса с тем же id не печатает второй чек

    def next_number(self):
        self.number += 1
        return self.number


STATE = DemoState()


def _now():
    return datetime.datetime.now()


def _iso(dt):
    return dt.isoformat(timespec="seconds")


def _money(v):
    return round(float(v or 0) + 0.0, 2)


def _rate(code):
    for g in TAX_GROUPS:
        if g["code"] == code:
            return float(g["rate"])
    return 0.0


def build_receipt(body, kind="receipt"):
    """Собрать чек по запросу продажи — так же, как это делает устройство."""
    items = []
    subtotal = 0.0
    for i, it in enumerate(body.get("items") or [], 1):
        qty = float(it.get("quantity") or 0)
        price = float(it.get("price") or 0)
        before = qty * price
        mode = it.get("modifierMode")
        value = float(it.get("modifierValue") or 0)
        if mode == "ByPercent":
            amount = before * (1 + value / 100.0)
        elif mode == "ByAmount":
            amount = before + value
        else:
            amount = before
        group = (it.get("taxGroupCode") or "A").upper()
        rate = _rate(group)
        # НДС включён в цену (как в молдавском чеке)
        tax = amount - amount / (1 + rate / 100.0) if rate else 0.0
        subtotal += amount
        items.append({
            "rowNumber": i,
            "goodId": it.get("goodId"),
            "name": it.get("name"),
            "quantity": round(qty, 3),
            "price": _money(price),
            "amountBeforeModification": _money(before),
            "amount": _money(amount),
            "modifierMode": mode,
            "modifierValue": _money(value),
            "taxGroupCode": group,
            "taxRate": rate,
            "taxRatePresentation": "%s (%.0f%%)" % (group, rate),
            "taxAmount": _money(tax),
            "finalAmount": _money(amount),
            "finalTaxAmount": _money(tax),
            "comment": it.get("comment"),
        })

    mods = 0.0
    for m in body.get("amountModifications") or []:
        value = float(m.get("value") or 0)
        mods += subtotal * value / 100.0 if m.get("mode") == "ByPercent" else value
    total = _money(subtotal + mods)

    payments = []
    paid = 0.0
    for i, p in enumerate(body.get("payments") or [], 1):
        amount = float(p.get("amount") or 0)
        paid += amount
        code = int(p.get("typeCode") or 0)
        payments.append({
            "rowNumber": i,
            "typeCode": code,
            "amount": _money(amount),
            "change": 0.0,
            "typeName": next((t["name"] for t in PAYMENT_TYPES if t["code"] == code), str(code)),
            "useBankTerminal": bool(p.get("useBankTerminal")),
            "bankTerminal": p.get("bankTerminal"),
            "bankTerminalCurrency": "MDL" if p.get("useBankTerminal") else None,
            # RRN банковского терминала: у настоящего MAIB — номер операции
            "bankTerminalRRN": ("%012d" % (abs(hash(str(body))) % 10 ** 12)) if p.get("useBankTerminal") else None,
            "bankTerminalOperationNumber": str(STATE.number + 1) if p.get("useBankTerminal") else None,
            "bankTerminalPrintData": [],
        })
    change = _money(max(0.0, paid - total))
    if change and payments:
        payments[-1]["change"] = change

    number = STATE.next_number()
    now = _now()
    return {
        "fiscalDeviceId": DEMO_DEVICE_ID,
        "id": str(uuid.uuid4()),
        "uniqueId": str(uuid.uuid4()),
        "authorId": str(uuid.uuid5(uuid.NAMESPACE_DNS, "demo-user")),
        "authorUserName": "Demo",
        "number": number,
        "numberPresentation": "%06d" % number,
        "currentNumber": number,
        "currentNumberPresentation": "%06d" % number,
        "dateTime": _iso(now),
        "dateTimePresentation": now.strftime("%d.%m.%Y %H:%M:%S"),
        "organizationName": "DEMO SRL",
        "idnx": "1000000000000",
        "address": "mun. Chişinău, str. Demo 1",
        "pointOfSaleId": DEMO_POS_ID,
        "pointOfSaleCode": "01",
        "mevId": str(uuid.uuid4()),
        "mevDateTime": _iso(now),
        "mevDateTimePresentation": now.strftime("%d.%m.%Y %H:%M:%S"),
        "printFormMediaType": None,
        "printFormContent": None,
        "printErrorMessage": None,
        "licenseMessage": None,
        "additionalData": None,
        "zReportId": None,
        "totalAmount": total,
        "subTotalAmount": _money(subtotal),
        "totalPaid": _money(paid),
        "totalAmountModifications": _money(mods),
        "totalChange": change,
        "print": bool(body.get("print", True)),
        "sendToEmail": bool(body.get("sendToEmail")),
        "emailAddress": body.get("emailAddress"),
        "sendToPhone": bool(body.get("sendToPhone")),
        "phoneNumber": body.get("phoneNumber"),
        "additionalHeaderText": body.get("additionalHeaderText"),
        "additionalFooterText": body.get("additionalFooterText"),
        "items": items,
        "payments": payments,
        "amountModifications": [{"rowNumber": i, "mode": m.get("mode"), "value": _money(m.get("value"))}
                                for i, m in enumerate(body.get("amountModifications") or [], 1)],
    }


def ok(data):
    return {"success": True, "message": None, "fullExceptionMessage": None, "errorType": None, "data": data}


def fail(message, status=400):
    return JSONResponse(status_code=status, content={
        "success": False, "message": message, "fullExceptionMessage": message,
        "errorType": "BadRequest", "data": None})


async def _guard(request: Request):
    """Проверка ключа и подписи — те же правила, что у FiscalCloud."""
    key = request.headers.get("api-key")
    if key != DEMO_API_KEY:
        return "неизвестный Api-Key", None
    raw = (await request.body()).decode("utf-8") if request.method in ("POST", "PUT") else ""
    path_and_query = request.url.path + (("?" + request.url.query) if request.url.query else "")
    ok_sig, why = signing.check(DEMO_API_SECRET, dict(request.headers), request.method, path_and_query, raw)
    if not ok_sig:
        return why, None
    return "", json.loads(raw) if raw else {}


def build_app():
    app = FastAPI(title="FiscalCloud API (демо-эмулятор)", version="1.0",
                  description="Демонстрационный ответчик вместо кассы Sunmi с фискализацией SoftLider.")
    r = APIRouter(prefix="/api/v1")

    @r.post("/operations/sale")
    async def sale(request: Request):
        why, body = await _guard(request)
        if why:
            return fail(why, 401)
        op_id = body.get("id")
        if op_id and op_id in STATE.by_operation_id:
            return ok(STATE.by_operation_id[op_id])          # повтор не печатает второй чек
        if not body.get("items"):
            return fail("в чеке нет строк")
        receipt = build_receipt(body)
        STATE.receipts.append(receipt)
        result = {"receiptType": "FiscalReceipt", "fiscalReceipt": receipt, "alternativeReceipt": None}
        if op_id:
            STATE.by_operation_id[op_id] = result
        return ok(result)

    @r.post("/operations/return")
    async def do_return(request: Request):
        why, body = await _guard(request)
        if why:
            return fail(why, 401)
        receipt = build_receipt(body)
        STATE.returns.append(receipt)
        return ok(receipt)

    @r.post("/operations/closeday")
    async def closeday(request: Request):
        why, _ = await _guard(request)
        if why:
            return fail(why, 401)
        total = sum(r["totalAmount"] for r in STATE.receipts)
        report = {"id": str(uuid.uuid4()), "kind": "ZReport", "dateTime": _iso(_now()),
                  "receiptsCount": len(STATE.receipts), "totalAmount": _money(total)}
        STATE.reports.append(report)
        STATE.receipts = []
        STATE.number = 0
        STATE.day_opened = _now()
        return ok(report)

    @r.post("/operations/intermediatetotals")
    async def totals(request: Request):
        why, _ = await _guard(request)
        if why:
            return fail(why, 401)
        total = sum(r["totalAmount"] for r in STATE.receipts)
        return ok({"id": str(uuid.uuid4()), "kind": "XReport", "dateTime": _iso(_now()),
                   "receiptsCount": len(STATE.receipts), "totalAmount": _money(total)})

    @r.get("/receipts")
    async def receipts(request: Request, startIndex: int = 0, count: int = 100):
        why, _ = await _guard(request)
        if why:
            return fail(why, 401)
        part = STATE.receipts[startIndex:startIndex + count]
        short = [{k: rc[k] for k in ("id", "pointOfSaleId", "authorUserName", "number",
                                     "numberPresentation", "currentNumber", "currentNumberPresentation",
                                     "dateTime", "dateTimePresentation", "totalAmount")} for rc in part]
        return ok({"data": short, "totalCount": len(STATE.receipts)})

    @r.get("/receipts/full")
    async def receipts_full(request: Request, startIndex: int = 0, count: int = 100):
        why, _ = await _guard(request)
        if why:
            return fail(why, 401)
        return ok({"data": STATE.receipts[startIndex:startIndex + count], "totalCount": len(STATE.receipts)})

    @r.get("/receipts/{receipt_id}")
    async def receipt(request: Request, receipt_id: str):
        why, _ = await _guard(request)
        if why:
            return fail(why, 401)
        for rc in STATE.receipts:
            if rc["id"] == receipt_id:
                return ok(rc)
        return fail("чек не найден", 404)

    @r.get("/devices")
    async def devices(request: Request):
        why, _ = await _guard(request)
        if why:
            return fail(why, 401)
        return ok({"data": [{"id": DEMO_DEVICE_ID, "name": "Sunmi (демо)", "serialNumber": "DEMO-0001",
                             "organizationName": "DEMO SRL", "createdDateTime": _iso(STATE.day_opened),
                             "isDeregistered": False}], "totalCount": 1})

    @r.get("/devices/{device_id}")
    async def device(request: Request, device_id: str):
        why, _ = await _guard(request)
        if why:
            return fail(why, 401)
        return ok({
            "id": device_id, "name": "Sunmi (демо)", "serialNumber": "DEMO-0001",
            "registrationNumber": "DEMO-REG-0001", "model": "Sunmi V2s + SoftLider",
            "organizationName": "DEMO SRL", "idnx": "1000000000000",
            "address": "mun. Chişinău, str. Demo 1", "subdivisionCode": "01",
            "isFiscalized": True, "isDeregistered": False,
            "createdDateTime": _iso(STATE.day_opened), "lastOperationNumber": STATE.number,
            "useAlternativeReceipts": False,
            "taxGroups": TAX_GROUPS, "paymentTypes": PAYMENT_TYPES,
            "pointsOfSale": [{"id": DEMO_POS_ID, "code": "01", "name": "Casa 1"}],
            "alternativeReceiptsRanges": [], "taxGroupsHistoryEntries": [],
        })

    app.include_router(r)

    @app.get("/health")
    async def health():
        return {"status": "ok", "receipts": len(STATE.receipts), "number": STATE.number}

    return app
