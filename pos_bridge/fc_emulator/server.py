# -*- coding: utf-8 -*-
"""
Имитатор FiscalCloud: все точки описания API, полные формы ответов.

Правила доступа те же, что у сервиса: `Api-Key`, `Api-DeviceId` (там, где
он объявлен обязательным), `Api-Timestamp` в пределах ±10 минут и
`Api-Signature` — HMAC-SHA256 по склейке
`DeviceId + PointOfSaleId + Timestamp + МЕТОД + путь с параметрами + тело`.

Ответ всегда завёрнут в ApiResponse и собирается поверх «пустышки» из
описания, поэтому в нём присутствует каждое объявленное поле.
"""

import uuid

from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from .. import signing
from . import printforms as pf
from .spec import SPEC
from .state import (CASH_TYPE_CODE, DEMO_DEVICE_ID, DEMO_POS_ID, PAYMENT_TYPES, STATE, TAX_GROUPS,
                    human, iso, m2, now, payment_name, rate_of)

# ключи демо-стенда; настройками программы заменяются на свои
DEMO_API_KEY = "demo-api-key-0000000000000000000000000000"
DEMO_API_SECRET = "demo-api-secret-000000000000000000000000"
API = {"key": DEMO_API_KEY, "secret": DEMO_API_SECRET}


def configure(cfg):
    """Применить настройки программы к имитатору."""
    from .state import configure as configure_state
    if cfg.get("apiKey"):
        API["key"] = cfg["apiKey"]
    if cfg.get("apiSecret"):
        API["secret"] = cfg["apiSecret"]
    configure_state(cfg)

# соответствие вида документа схемам описания
KINDS = {
    "receipt": {"dto": "ReceiptDto", "item": "ReceiptItemDto", "payment": "ReceiptPaymentDto",
                "modification": "ReceiptAmountModificationDto", "short": "ReceiptShortInfo",
                "paged_short": "ReceiptShortInfoPagedResponse", "paged_full": "ReceiptDtoPagedResponse",
                "title": "BON FISCAL"},
    "return": {"dto": "ReturnReceiptDto", "item": "ReturnReceiptItemDto", "payment": "ReturnReceiptPaymentDto",
               "modification": "ReceiptAmountModificationDto", "short": "ReturnReceiptShortInfo",
               "paged_short": "ReturnReceiptShortInfoPagedResponse", "paged_full": "ReturnReceiptDtoPagedResponse",
               "title": "BON DE RESTITUIRE"},
    "alternative": {"dto": "AlternativeReceiptDto", "item": "AlternativeReceiptItemDto",
                    "payment": "AlternativeReceiptPaymentDto",
                    "modification": "AlternativeReceiptAmountModificationDto",
                    "short": "AlternativeReceiptShortInfo",
                    "paged_short": "AlternativeReceiptShortInfoPagedResponse",
                    "paged_full": "AlternativeReceiptDtoPagedResponse", "title": "BON DE PLATA"},
    "cashoperation": {"dto": "CashOperationDto", "short": "CashOperationShortInfo",
                      "paged_short": "CashOperationShortInfoPagedResponse",
                      "paged_full": "CashOperationDtoPagedResponse", "title": "OPERATIUNE DE CASA"},
    "report": {"dto": "ReportDto", "short": "ReportShortInfo",
               "paged_short": "ReportShortInfoPagedResponse", "paged_full": "ReportDtoPagedResponse",
               "title": "RAPORT"},
    "nonfiscal": {"dto": "NonfiscalReceiptDto", "title": "BON NEFISCAL"},
}


# ── конверт ответа ──

def ok(data=None):
    env = SPEC.blank("ApiResponse")
    env.update({"success": True, "message": None, "fullExceptionMessage": None, "errorType": None})
    env["data"] = data
    return env


def fail(message, status=400, error_type="BadRequest"):
    env = SPEC.blank("ApiResponse")
    env.update({"success": False, "message": message, "fullExceptionMessage": message,
                "errorType": error_type, "data": None})
    return JSONResponse(status_code=status, content=env)


def paged(schema, items, total):
    out = SPEC.blank(schema)
    out.update({"data": items, "totalCount": int(total)})
    return out


# ── доступ ──

async def guard(request: Request, need_device=True):
    """(ошибка, тело). Ошибка — готовый ответ, тело — разобранный JSON."""
    if request.headers.get("api-key") != API["key"]:
        return fail("Invalid API key", 401, "Unauthorized"), None
    device = request.headers.get("api-deviceid") or ""
    if need_device and not device:
        return fail("Api-DeviceId header is required", 400, "BadRequest"), None
    raw = (await request.body()).decode("utf-8") if request.method in ("POST", "PUT") else ""
    path_and_query = request.url.path + (("?" + request.url.query) if request.url.query else "")
    good, why = signing.check(API["secret"], dict(request.headers), request.method, path_and_query, raw)
    if not good:
        return fail("Invalid signature: %s" % why, 401, "Unauthorized"), None
    if raw:
        try:
            import json
            return None, json.loads(raw)
        except ValueError:
            return fail("Request body is not valid JSON", 400, "BadRequest"), None
    return None, {}


def pos_of(request):
    from .state import DEVICE_INFO
    return request.headers.get("api-pointofsaleid") or DEVICE_INFO["pointOfSaleId"]


# ── сборка документов ──

def build_lines(kind, body):
    """Строки документа с НДС, включённым в цену, — как считает устройство."""
    meta = KINDS[kind]
    items, subtotal = [], 0.0
    for i, src in enumerate(body.get("items") or [], 1):
        qty = float(src.get("quantity") or 0)
        price = float(src.get("price") or 0)
        before = qty * price
        mode = src.get("modifierMode")
        value = float(src.get("modifierValue") or 0)
        if mode == "ByPercent":
            amount = before * (1 + value / 100.0)
        elif mode == "ByAmount":
            amount = before + value
        else:
            amount = before
        group = (src.get("taxGroupCode") or "A").upper()
        rate = rate_of(group)
        tax = amount - amount / (1 + rate / 100.0) if rate else 0.0
        row = SPEC.blank(meta["item"])
        row.update({
            "rowNumber": i, "goodId": src.get("goodId"), "name": src.get("name"),
            "quantity": round(qty, 3), "price": m2(price),
            "amountBeforeModification": m2(before), "amount": m2(amount),
            "modifierMode": mode, "modifierValue": m2(value),
            "taxGroupCode": group, "taxRate": rate, "taxRatePresentation": "%s (%g%%)" % (group, rate),
            "taxAmount": m2(tax), "finalAmount": m2(amount), "finalTaxAmount": m2(tax),
            "comment": src.get("comment"),
        })
        items.append(row)
        subtotal += amount

    mods, mod_total = [], 0.0
    for i, src in enumerate(body.get("amountModifications") or [], 1):
        value = float(src.get("value") or 0)
        delta = subtotal * value / 100.0 if src.get("mode") == "ByPercent" else value
        mod_total += delta
        row = SPEC.blank(meta["modification"])
        row.update({"rowNumber": i, "mode": src.get("mode"), "value": m2(value)})
        mods.append(row)

    total = m2(subtotal + mod_total)
    # скидка на чек делится по строкам: иначе не сойдутся итоги по НДС
    if mod_total and subtotal:
        k = total / subtotal
        for row in items:
            row["finalAmount"] = m2(row["amount"] * k)
            rate = row["taxRate"]
            row["finalTaxAmount"] = m2(row["finalAmount"] - row["finalAmount"] / (1 + rate / 100.0)) if rate else 0.0

    payments, paid = [], 0.0
    for i, src in enumerate(body.get("payments") or [], 1):
        amount = float(src.get("amount") or 0)
        paid += amount
        code = int(src.get("typeCode") or 0)
        row = SPEC.blank(meta["payment"])
        row.update({
            "rowNumber": i, "typeCode": code, "amount": m2(amount), "change": 0.0,
            "typeName": payment_name(code), "useBankTerminal": bool(src.get("useBankTerminal")),
            "bankTerminal": src.get("bankTerminal"),
            "bankTerminalCurrency": "MDL" if src.get("useBankTerminal") else None,
            "bankTerminalRRN": ("%012d" % (uuid.uuid4().int % 10 ** 12)) if src.get("useBankTerminal") else None,
            "bankTerminalOperationNumber": str(STATE.numbers.get("receipt", 0) + 1) if src.get("useBankTerminal") else None,
            "bankTerminalPrintData": [],
        })
        payments.append(row)
    change = m2(max(0.0, paid - total))
    if change and payments:
        payments[-1]["change"] = change
    return items, payments, mods, m2(subtotal), total, m2(paid), change, m2(mod_total)


def fill_document(kind, body, request, schema=None):
    meta = KINDS[kind]
    doc = STATE.head(schema or meta["dto"], kind, pos_of(request))
    items, payments, mods, subtotal, total, paid, change, mod_total = build_lines(kind, body)
    doc.update({
        "zReportId": None,
        "totalAmount": total, "subTotalAmount": subtotal, "totalPaid": paid,
        "totalAmountModifications": mod_total, "totalChange": change,
        "print": bool(body.get("print", True)),
        "sendToEmail": bool(body.get("sendToEmail")), "emailAddress": body.get("emailAddress"),
        "sendToPhone": bool(body.get("sendToPhone")), "phoneNumber": body.get("phoneNumber"),
        "additionalHeaderText": body.get("additionalHeaderText"),
        "additionalFooterText": body.get("additionalFooterText"),
        "items": items, "payments": payments, "amountModifications": mods,
    })
    if kind == "return":
        doc["originalReceiptId"] = body.get("originalReceiptId")
        doc["printOnServer"] = bool(body.get("printOnServer", True))
        doc["pdfPrintFormSettings"] = body.get("pdfPrintFormSettings")
        doc["imagePrintFormSettings"] = body.get("imagePrintFormSettings")
    if kind == "alternative":
        series_number = body.get("seriesAndNumber") or body.get("alternativeReceiptSeriesAndNumber")
        if not series_number:
            series_number = "%s%06d" % (STATE.alt_series, STATE.alt_next)
            STATE.alt_next += 1
        doc["series"] = series_number[:2]
        doc["seriesAndNumber"] = series_number
    return doc


def attach_print(doc, body, rows, title="Bon"):
    """Печатная форма в ответе, если её попросили вернуть вызывающему."""
    if body.get("printOnServer", True):
        return doc
    media, content = pf.render(rows, body.get("printFormMediaType") or "Json",
                               body.get("pdfPrintFormSettings"), body.get("imagePrintFormSettings"), title)
    doc["printFormMediaType"] = media
    doc["printFormContent"] = content
    return doc


def short_of(kind, doc):
    s = SPEC.blank(KINDS[kind]["short"])
    for key in list(s):
        if key in doc:
            s[key] = doc[key]
    return s


def make_report(report_type, point_of_sale_id=None, body=None):
    """X- или Z-отчёт по накопленным итогам смены.

    Вызывается и из API, и из окна программы, поэтому принимает не запрос,
    а идентификатор рабочего места.
    """
    body = body or {}
    from .state import DEVICE_INFO
    doc = STATE.head("ReportDto", "report", point_of_sale_id or DEVICE_INFO["pointOfSaleId"])
    sh = STATE.shift
    tax_items = []
    total_tax = 0.0
    for i, (code, (amount, tax)) in enumerate(sorted(sh.tax_totals.items()), 1):
        row = SPEC.blank("ReportTaxItemDto")
        rate = rate_of(code)
        row.update({"rowNumber": i, "taxGroupCode": code, "taxRate": rate,
                    "taxRatePresentation": "%g %%" % rate, "amount": m2(amount), "taxAmount": m2(tax)})
        tax_items.append(row)
        total_tax += tax
    payments = []
    for i, (code, amount) in enumerate(sorted(sh.payment_totals.items()), 1):
        row = SPEC.blank("ReportPaymentDto")
        row.update({"rowNumber": i, "typeCode": code, "typeName": payment_name(code), "amount": m2(amount)})
        payments.append(row)
    doc.update({
        "type": report_type,
        "untaxedAmount": m2(sum(a for c, (a, t) in sh.tax_totals.items() if rate_of(c) == 0)),
        "totalAmount": m2(sh.total), "totalTaxAmount": m2(total_tax),
        "totalNettoAmount": m2(sh.total - total_tax),
        "cashInAmount": m2(sh.cash_in), "cashOutAmount": m2(sh.cash_out), "finalBalance": sh.balance,
        "grandTotalAmount": m2(STATE.grand_total + sh.total),
        "grandTotalTaxAmount": m2(STATE.grand_tax + total_tax),
        "grandTotalNettoAmount": m2(STATE.grand_total + sh.total - STATE.grand_tax - total_tax),
        "annualTotalAmount": m2(STATE.annual_total + sh.total),
        "annualTotalTaxAmount": m2(STATE.annual_tax + total_tax),
        "annualTotalNettoAmount": m2(STATE.annual_total + sh.total - STATE.annual_tax - total_tax),
        "receiptCount": sh.receipt_count, "lastReceiptNumber": sh.last_receipt_number,
        "payments": payments, "taxItems": tax_items,
    })
    attach_print(doc, body, pf.report_rows(doc, STATE.device()), "Raport")
    STATE.store("report", doc)
    if report_type == "ZReport":
        # смена закрывается: документы привязываются к отчёту, итоги уходят в накопительные
        for kind in ("receipt", "return", "alternative", "cashoperation"):
            for d in STATE.documents[kind]:
                if d.get("zReportId") is None:
                    d["zReportId"] = doc["id"]
        STATE.grand_total += sh.total
        STATE.grand_tax += total_tax
        STATE.annual_total += sh.total
        STATE.annual_tax += total_tax
        from .state import Shift
        STATE.shift = Shift()
    return doc


def duplicate(kind, doc_id, body, title):
    doc = STATE.find(kind, doc_id)
    if doc is None:
        return None
    rows = pf.report_rows(doc, STATE.device()) if kind == "report" else pf.receipt_rows(doc, STATE.device(), title)
    media, content = pf.render(rows, body.get("printFormMediaType") or "Json",
                               body.get("pdfPrintFormSettings"), body.get("imagePrintFormSettings"), title)
    out = SPEC.blank("DuplicateResponse")
    out.update({"printFormMediaType": media, "printFormContent": content})
    return out


def build_app():
    app = FastAPI(title=SPEC.doc["info"]["title"], version=SPEC.doc["info"].get("version", "1.0"),
                  docs_url=None, redoc_url=None, openapi_url=None)

    # отдаём то же описание, что и сервис: клиентские генераторы увидят его без отличий
    @app.get("/openapi.json", include_in_schema=False)
    async def openapi():
        return JSONResponse(SPEC.doc)

    @app.get("/health", include_in_schema=False)
    async def health():
        return {"status": "ok", "receipts": len(STATE.documents["receipt"]),
                "shiftOpenedAt": iso(STATE.shift.opened_at)}

    @app.middleware("http")
    async def journal(request: Request, call_next):
        response = await call_next(request)
        if request.url.path.startswith("/api/"):
            STATE.log(request.method, request.url.path, response.status_code)
            if request.method == "POST" and response.status_code == 200:
                STATE.changed()
        return response

    r = APIRouter(prefix="/api/v1")

    # ── высокоуровневые операции ──

    @r.post("/operations/sale")
    async def sale(request: Request):
        err, body = await guard(request)
        if err:
            return err
        if not body.get("items"):
            return fail("Receipt has no items", 422, "ValidationError")
        op_id = body.get("id")
        if op_id and ("sale", op_id) in STATE.by_operation_id:
            return ok(STATE.by_operation_id[("sale", op_id)])
        mode = body.get("receiptMode") or "FiscalReceiptOnly"
        as_alternative = mode == "AlternativeReceiptOnly" or (
            mode == "FiscalThenAlternativeReceipt" and not STATE.tax_authority_online)
        kind = "alternative" if as_alternative else "receipt"
        doc = fill_document(kind, body, request)
        attach_print(doc, body, pf.receipt_rows(doc, STATE.device(), KINDS[kind]["title"]), KINDS[kind]["title"])
        STATE.store(kind, doc)
        STATE.shift.add_document(doc, 1)
        result = SPEC.blank("SaleResponse")
        result.update({"receiptType": "AlternativeReceipt" if as_alternative else "FiscalReceipt",
                       "fiscalReceipt": None if as_alternative else doc,
                       "alternativeReceipt": doc if as_alternative else None})
        if op_id:
            STATE.by_operation_id[("sale", op_id)] = result
        return ok(result)

    @r.post("/operations/return")
    async def operation_return(request: Request):
        err, body = await guard(request)
        if err:
            return err
        op_id = body.get("id")
        if op_id and ("return", op_id) in STATE.by_operation_id:
            return ok(STATE.by_operation_id[("return", op_id)])
        # Хранится полноценный чек возврата (его отдаёт /returnreceipts),
        # а в ответе этой точки описание объявляет ReceiptDto — отдаём срез
        # ровно по его полям, чтобы обе формы оставались верными.
        doc = fill_document("return", body, request)
        attach_print(doc, body, pf.receipt_rows(doc, STATE.device(), "BON DE RESTITUIRE"), "Restituire")
        STATE.store("return", doc)
        STATE.shift.add_document(doc, -1)
        answer = {k: doc.get(k) for k in SPEC.properties("ReceiptDto")}
        if op_id:
            STATE.by_operation_id[("return", op_id)] = answer
        return ok(answer)

    @r.post("/operations/closeday")
    async def closeday(request: Request):
        err, body = await guard(request)
        if err:
            return err
        return ok(make_report("ZReport", pos_of(request), body))

    @r.post("/operations/intermediatetotals")
    async def intermediate(request: Request):
        err, body = await guard(request)
        if err:
            return err
        return ok(make_report("XReport", pos_of(request), body))

    # ── фискальные чеки ──

    @r.post("/receipts")
    async def create_receipt(request: Request):
        err, body = await guard(request)
        if err:
            return err
        if not body.get("items"):
            return fail("Receipt has no items", 422, "ValidationError")
        doc = fill_document("receipt", body, request)
        attach_print(doc, body, pf.receipt_rows(doc, STATE.device(), "BON FISCAL"), "Bon fiscal")
        STATE.store("receipt", doc)
        STATE.shift.add_document(doc, 1)
        return ok(doc)

    @r.get("/receipts")
    async def list_receipts(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("receipt", startIndex, count)
        return ok(paged("ReceiptShortInfoPagedResponse", [short_of("receipt", d) for d in items], total))

    @r.get("/receipts/full")
    async def list_receipts_full(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("receipt", startIndex, count)
        return ok(paged("ReceiptDtoPagedResponse", items, total))

    @r.get("/receipts/{receiptId}")
    async def get_receipt(request: Request, receiptId: str):
        err, _ = await guard(request)
        if err:
            return err
        doc = STATE.find("receipt", receiptId)
        return ok(doc) if doc else fail("Receipt not found", 404, "NotFound")

    @r.post("/receipts/{receiptId}/duplicate")
    async def duplicate_receipt(request: Request, receiptId: str):
        err, body = await guard(request)
        if err:
            return err
        out = duplicate("receipt", receiptId, body, "BON FISCAL (COPIE)")
        return ok(out) if out else fail("Receipt not found", 404, "NotFound")

    # ── нефискальный чек ──

    @r.post("/nonfiscalreceipts")
    async def nonfiscal(request: Request):
        err, body = await guard(request)
        if err:
            return err
        doc = STATE.head("NonfiscalReceiptDto", "nonfiscal", pos_of(request))
        doc.update({"print": bool(body.get("print", True)), "sendToEmail": bool(body.get("sendToEmail")),
                    "emailAddress": body.get("emailAddress"), "text": body.get("text") or ""})
        rows = [pf.row(pf.TEXT, line) for line in (doc["text"] or "").splitlines()] or [pf.row(pf.EMPTY)]
        attach_print(doc, body, rows, "Bon nefiscal")
        STATE.store("nonfiscal", doc)
        return ok(doc)

    # ── чеки возврата ──

    @r.post("/returnreceipts")
    async def create_return(request: Request):
        err, body = await guard(request)
        if err:
            return err
        doc = fill_document("return", body, request)
        attach_print(doc, body, pf.receipt_rows(doc, STATE.device(), "BON DE RESTITUIRE"), "Restituire")
        STATE.store("return", doc)
        STATE.shift.add_document(doc, -1)
        return ok(doc)

    @r.get("/returnreceipts")
    async def list_returns(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("return", startIndex, count)
        return ok(paged("ReturnReceiptShortInfoPagedResponse", [short_of("return", d) for d in items], total))

    @r.get("/returnreceipts/full")
    async def list_returns_full(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("return", startIndex, count)
        return ok(paged("ReturnReceiptDtoPagedResponse", items, total))

    @r.get("/returnreceipts/{receiptId}")
    async def get_return(request: Request, receiptId: str):
        err, _ = await guard(request)
        if err:
            return err
        doc = STATE.find("return", receiptId)
        return ok(doc) if doc else fail("Return receipt not found", 404, "NotFound")

    # ── альтернативные чеки (bon de plata) ──

    @r.post("/alternativereceipts")
    async def create_alternative(request: Request):
        err, body = await guard(request)
        if err:
            return err
        doc = fill_document("alternative", body, request)
        attach_print(doc, body, pf.receipt_rows(doc, STATE.device(), "BON DE PLATA"), "Bon de plata")
        STATE.store("alternative", doc)
        STATE.shift.add_document(doc, 1)
        return ok(doc)

    @r.get("/alternativereceipts")
    async def list_alternative(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("alternative", startIndex, count)
        return ok(paged("AlternativeReceiptShortInfoPagedResponse",
                        [short_of("alternative", d) for d in items], total))

    @r.get("/alternativereceipts/full")
    async def list_alternative_full(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("alternative", startIndex, count)
        return ok(paged("AlternativeReceiptDtoPagedResponse", items, total))

    @r.get("/alternativereceipts/{receiptId}")
    async def get_alternative(request: Request, receiptId: str):
        err, _ = await guard(request)
        if err:
            return err
        doc = STATE.find("alternative", receiptId)
        return ok(doc) if doc else fail("Alternative receipt not found", 404, "NotFound")

    @r.post("/alternativereceipts/{receiptId}/duplicate")
    async def duplicate_alternative(request: Request, receiptId: str):
        err, body = await guard(request)
        if err:
            return err
        out = duplicate("alternative", receiptId, body, "BON DE PLATA (COPIE)")
        return ok(out) if out else fail("Alternative receipt not found", 404, "NotFound")

    # ── отчёты ──

    @r.post("/reports")
    async def create_report(request: Request):
        err, body = await guard(request)
        if err:
            return err
        kind = body.get("type") or "XReport"
        if kind not in ("ZReport", "XReport"):
            return fail("Unknown report type: %s" % kind, 422, "ValidationError")
        return ok(make_report(kind, pos_of(request), body))

    @r.get("/reports")
    async def list_reports(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("report", startIndex, count)
        return ok(paged("ReportShortInfoPagedResponse", [short_of("report", d) for d in items], total))

    @r.get("/reports/full")
    async def list_reports_full(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("report", startIndex, count)
        return ok(paged("ReportDtoPagedResponse", items, total))

    @r.get("/reports/{reportId}")
    async def get_report(request: Request, reportId: str):
        err, _ = await guard(request)
        if err:
            return err
        doc = STATE.find("report", reportId)
        return ok(doc) if doc else fail("Report not found", 404, "NotFound")

    @r.post("/reports/{reportId}/duplicate")
    async def duplicate_report(request: Request, reportId: str):
        err, body = await guard(request)
        if err:
            return err
        out = duplicate("report", reportId, body, "RAPORT (COPIE)")
        return ok(out) if out else fail("Report not found", 404, "NotFound")

    # ── операции с наличными ──

    @r.post("/cashoperations")
    async def create_cashop(request: Request):
        err, body = await guard(request)
        if err:
            return err
        amount = float(body.get("amount") or 0)
        if amount == 0:
            return fail("Amount must not be zero", 422, "ValidationError")
        doc = STATE.head("CashOperationDto", "cashoperation", pos_of(request))
        if amount > 0:
            STATE.shift.cash_in += amount
        else:
            STATE.shift.cash_out += -amount
        doc.update({"zReportId": None, "amount": m2(amount), "finalBalanceInformatory": STATE.shift.balance})
        rows = [pf.row(pf.TEXT, "OPERATIUNE DE CASA", align="Center", bold=True),
                pf.row(pf.TEXT, "Nr. %s  %s" % (doc["numberPresentation"], doc["dateTimePresentation"])),
                pf.row(pf.TEXT, ("Depunere: " if amount > 0 else "Extragere: ") + pf.money(abs(amount))),
                pf.row(pf.TEXT, "Sold: %s" % pf.money(doc["finalBalanceInformatory"]))]
        attach_print(doc, body, rows, "Operatiune de casa")
        STATE.store("cashoperation", doc)
        return ok(doc)

    @r.get("/cashoperations")
    async def list_cashops(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("cashoperation", startIndex, count)
        return ok(paged("CashOperationShortInfoPagedResponse",
                        [short_of("cashoperation", d) for d in items], total))

    @r.get("/cashoperations/full")
    async def list_cashops_full(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request)
        if err:
            return err
        items, total = STATE.page("cashoperation", startIndex, count)
        return ok(paged("CashOperationDtoPagedResponse", items, total))

    @r.get("/cashoperations/{cashOperationId}")
    async def get_cashop(request: Request, cashOperationId: str):
        err, _ = await guard(request)
        if err:
            return err
        doc = STATE.find("cashoperation", cashOperationId)
        return ok(doc) if doc else fail("Cash operation not found", 404, "NotFound")

    @r.post("/cashoperations/{cashOperationId}/duplicate")
    async def duplicate_cashop(request: Request, cashOperationId: str):
        err, body = await guard(request)
        if err:
            return err
        out = duplicate("cashoperation", cashOperationId, body, "OPERATIUNE DE CASA (COPIE)")
        return ok(out) if out else fail("Cash operation not found", 404, "NotFound")

    # ── периодические отчёты ──

    def periodic_rows(settings):
        s = settings or {}
        head = "RAPORT PERIODIC %s" % ("DETALIAT" if s.get("detailed") else "SUMAR")
        if s.get("filterType") == "ByZReportNumber":
            period = "Z %s - %s" % (s.get("firstZReportNumber") or "", s.get("lastZReportNumber") or "")
        else:
            period = "%s - %s" % ((s.get("startDate") or "")[:10], (s.get("endDate") or "")[:10])
        rows = [pf.row(pf.TEXT, STATE.device()["organizationName"], align="Center", bold=True),
                pf.row(pf.TEXT, head, align="Center", bold=True),
                pf.row(pf.TEXT, period, align="Center"), pf.row(pf.SEPARATOR)]
        zs = [d for d in STATE.documents["report"] if d.get("type") == "ZReport"]
        for d in zs:
            rows.append(pf.row(pf.TEXT, "Z %s  %s  %s MDL" % (
                d["numberPresentation"], d["dateTimePresentation"], pf.money(d["totalAmount"]))))
        rows += [pf.row(pf.SEPARATOR),
                 pf.row(pf.TEXT, "Rapoarte Z: %d" % len(zs)),
                 pf.row(pf.TEXT, "Total: %s MDL" % pf.money(sum(d["totalAmount"] for d in zs)))]
        return rows

    @r.post("/periodicreports")
    async def periodic(request: Request):
        err, body = await guard(request)
        if err:
            return err
        rows = periodic_rows(body.get("reportSettings"))
        media, content = pf.render(rows, body.get("printFormMediaType") or "Json",
                                   body.get("pdfPrintFormSettings"), body.get("imagePrintFormSettings"),
                                   "Raport periodic")
        out = SPEC.blank("PeriodicReportResponse")
        out.update({"printFormMediaType": media, "printFormContent": content})
        return ok(out)

    @r.post("/periodicreports/print")
    async def periodic_print(request: Request):
        err, body = await guard(request)
        if err:
            return err
        periodic_rows(body.get("reportSettings"))
        return ok(None)

    # ── устройства и мелочи ──

    @r.get("/devices")
    async def devices(request: Request, startIndex: int = 0, count: int = 100):
        err, _ = await guard(request, need_device=False)
        if err:
            return err
        items = [STATE.device_short()][int(startIndex or 0):int(startIndex or 0) + int(count or 100)]
        return ok(paged("FiscalDeviceShortInfoPagedResponse", items, 1))

    @r.get("/devices/assureno24h")
    async def assure_no_24h(request: Request):
        err, _ = await guard(request)
        if err:
            return err
        age = (now() - STATE.shift.opened_at).total_seconds()
        if age >= 24 * 3600:
            make_report("ZReport", pos_of(request), {})
            env = ok(None)
            env["message"] = "Z report issued: shift was older than 24 hours"
            return env
        return ok(None)

    @r.get("/devices/{deviceId}")
    async def device(request: Request, deviceId: str):
        err, _ = await guard(request, need_device=False)
        if err:
            return err
        return ok(STATE.device(deviceId))

    @r.post("/misc/opencashdrawer")
    async def open_drawer(request: Request):
        err, _ = await guard(request, need_device=False)
        if err:
            return err
        return ok(None)

    app.include_router(r)

    # страховка от расхождения с описанием: каждая объявленная точка должна
    # иметь обработчик, иначе имитатор молча перестаёт быть совместимым
    missing = missing_operations(app, r)
    if missing:
        raise RuntimeError("в имитаторе нет точек описания: %s" % ", ".join(missing))
    return app


def _collect(routes, have):
    """Пути маршрутов, включая вложенные роутеры (их оборачивает FastAPI).

    У маршрута APIRouter путь уже записан вместе с префиксом, поэтому
    ничего не приклеиваем — иначе получится /api/v1/api/v1/…
    """
    for route in routes or []:
        inner = getattr(route, "original_router", None) or getattr(route, "router", None)
        if inner is not None and hasattr(inner, "routes"):
            _collect(inner.routes, have)
            continue
        path = getattr(route, "path", None)
        if not path:
            continue
        for m in (getattr(route, "methods", None) or set()):
            have.add((path, m.lower()))


def missing_operations(app, router=None):
    """Точки описания, для которых в приложении нет маршрута."""
    have = set()
    _collect(app.routes, have)
    if router is not None:
        _collect(router.routes, have)
    out = []
    for path, method, _op in SPEC.operations():
        # в описании параметр пути записан как {receiptId}, в маршруте — так же
        if (path, method) not in have:
            out.append("%s %s" % (method.upper(), path))
    return out
