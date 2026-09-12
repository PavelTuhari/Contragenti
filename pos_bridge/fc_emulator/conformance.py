# -*- coding: utf-8 -*-
"""
Проверка соответствия имитатора описанию FiscalCloud.

Обходит **каждую** объявленную точку, вызывает её с осмысленными данными и
сверяет ответ со схемой из описания: все ли объявленные поля на месте и того
ли они типа. Так «совместим» перестаёт быть словом и становится прогоном,
который либо проходит целиком, либо называет расхождение.

    python -m pos_bridge fc-conformance
"""

import json
import urllib.error
import urllib.request

from .. import signing
from .server import DEMO_API_KEY, DEMO_API_SECRET
from .spec import SPEC
from .state import DEMO_DEVICE_ID, DEMO_POS_ID


class Caller:
    def __init__(self, base_url, device_id=DEMO_DEVICE_ID, pos_id=""):
        self.base_url = base_url.rstrip("/")
        self.device_id = device_id
        self.pos_id = pos_id

    def __call__(self, method, path_and_query, body=None, device=True):
        raw = json.dumps(body, ensure_ascii=False) if body is not None else None
        headers = signing.headers_for(DEMO_API_KEY, DEMO_API_SECRET, method, path_and_query,
                                      device_id=self.device_id if device else "",
                                      point_of_sale_id=self.pos_id if device else "",
                                      body=raw or "")
        req = urllib.request.Request(self.base_url + path_and_query, method=method.upper(),
                                     data=raw.encode("utf-8") if raw is not None else None,
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            text = exc.read().decode("utf-8", "replace")
            try:
                return exc.code, json.loads(text or "{}")
            except ValueError:
                return exc.code, {"raw": text}


SALE_BODY = {
    "receiptMode": "FiscalReceiptOnly",
    "printOnServer": False,
    "printFormMediaType": "Json",
    "print": True,
    "sendToEmail": True,
    "emailAddress": "test@mail.com",
    "sendToPhone": True,
    "phoneNumber": "079000001",
    "items": [
        {"name": "Piine Praga (Franzeluta)", "quantity": 2.0, "price": 8.10,
         "modifierMode": "ByPercent", "modifierValue": -15.0, "taxGroupCode": "B"},
        {"name": "Gura Cainarului 1.5l", "quantity": 1.0, "price": 12.00,
         "modifierMode": "ByAmount", "modifierValue": -1.0, "taxGroupCode": "A"},
    ],
    "payments": [{"typeCode": 1, "amount": 15.0, "useBankTerminal": True},
                 {"typeCode": 0, "amount": 10.0, "useBankTerminal": False}],
    "amountModifications": [{"mode": "ByPercent", "value": -25.0}],
}

RECEIPT_BODY = {k: v for k, v in SALE_BODY.items() if k not in ("receiptMode",)}


def plan(state):
    """Последовательность вызовов: сначала создаём документы, потом читаем их."""
    dup = {"printOnServer": False, "printFormMediaType": "Html"}
    return [
        ("POST", "/api/v1/operations/sale", dict(SALE_BODY, id="conf-sale-1"), "sale"),
        ("POST", "/api/v1/operations/return",
         {"printOnServer": False, "printFormMediaType": "Json",
          "items": [{"name": "Piine Praga (Franzeluta)", "quantity": 1.0, "price": 8.10, "taxGroupCode": "B"}],
          "payments": [{"typeCode": 0, "amount": 8.10}]}, None),
        ("POST", "/api/v1/receipts", dict(RECEIPT_BODY, id="conf-receipt-1"), "receipt"),
        ("POST", "/api/v1/returnreceipts",
         {"items": [{"name": "Gura Cainarului 1.5l", "quantity": 1.0, "price": 12.0, "taxGroupCode": "A"}],
          "payments": [{"typeCode": 0, "amount": 12.0}], "originalReceiptId": state.get("receipt")}, "return"),
        ("POST", "/api/v1/alternativereceipts",
         {"items": [{"name": "Serviciu", "quantity": 1.0, "price": 50.0, "taxGroupCode": "A"}],
          "payments": [{"typeCode": 0, "amount": 50.0}]}, "alternative"),
        ("POST", "/api/v1/nonfiscalreceipts",
         {"print": True, "text": "Multumim pentru vizita!\nwww.example.md"}, None),
        ("POST", "/api/v1/cashoperations", {"amount": 100.0, "printOnServer": False}, "cashop"),
        ("POST", "/api/v1/reports", {"type": "XReport", "printOnServer": False}, "report"),

        ("GET", "/api/v1/receipts?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/receipts/full?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/receipts/{receipt}", None, None),
        ("POST", "/api/v1/receipts/{receipt}/duplicate", dup, None),
        ("GET", "/api/v1/returnreceipts?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/returnreceipts/full?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/returnreceipts/{return}", None, None),
        ("GET", "/api/v1/alternativereceipts?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/alternativereceipts/full?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/alternativereceipts/{alternative}", None, None),
        ("POST", "/api/v1/alternativereceipts/{alternative}/duplicate", dup, None),
        ("GET", "/api/v1/reports?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/reports/full?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/reports/{report}", None, None),
        ("POST", "/api/v1/reports/{report}/duplicate", dup, None),
        ("GET", "/api/v1/cashoperations?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/cashoperations/full?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/cashoperations/{cashop}", None, None),
        ("POST", "/api/v1/cashoperations/{cashop}/duplicate", dup, None),

        ("POST", "/api/v1/periodicreports",
         {"reportSettings": {"detailed": True, "filterType": "ByDate",
                             "startDate": "2026-01-01T00:00:00", "endDate": "2026-12-31T23:59:59"},
          "printOnServer": False, "printFormMediaType": "Pdf"}, None),
        ("POST", "/api/v1/periodicreports/print",
         {"reportSettings": {"detailed": False, "filterType": "ByZReportNumber",
                             "firstZReportNumber": "1", "lastZReportNumber": "99"}}, None),
        ("GET", "/api/v1/devices?startIndex=0&count=10", None, None),
        ("GET", "/api/v1/devices/assureno24h", None, None),
        ("GET", "/api/v1/devices/" + DEMO_DEVICE_ID, None, None),
        ("POST", "/api/v1/misc/opencashdrawer", {}, None),
        # закрытие дня — последним: оно обнуляет смену
        ("POST", "/api/v1/operations/intermediatetotals", {"printOnServer": False}, None),
        ("POST", "/api/v1/operations/closeday", {"printOnServer": False}, None),
    ]


def spec_operation(path, method):
    """Описание операции по пути с подставленным идентификатором."""
    for spath, smethod, op in SPEC.operations():
        if smethod != method.lower():
            continue
        if spath == path:
            return spath, op
        # /api/v1/receipts/{receiptId} против /api/v1/receipts/<uuid>
        sparts, pparts = spath.strip("/").split("/"), path.strip("/").split("/")
        if len(sparts) != len(pparts):
            continue
        if all(s.startswith("{") or s == p for s, p in zip(sparts, pparts)):
            return spath, op
    return None, None


def run(base_url, say=print):
    caller = Caller(base_url)
    state = {}
    checked, failed = 0, 0
    covered = set()

    def remember(key, payload):
        if not key or not isinstance(payload, dict):
            return
        if key == "sale":
            r = payload.get("fiscalReceipt") or payload.get("alternativeReceipt") or {}
            state["receipt"] = r.get("id")
        else:
            state[key] = payload.get("id")

    for method, template, body, key in plan(state):
        path = template
        for name, value in state.items():
            path = path.replace("{%s}" % name, str(value or ""))
        if "{" in path.split("?")[0]:
            say("[FAIL] %-6s %s — нет идентификатора для подстановки" % (method, template))
            failed += 1
            continue
        clean_path = path.split("?")[0]
        spath, op = spec_operation(clean_path, method)
        if op is None:
            say("[FAIL] %-6s %s — такой точки нет в описании" % (method, clean_path))
            failed += 1
            continue
        with_device = any(p.get("name") == "Api-DeviceId" for p in SPEC.params(op))
        status, data = caller(method, path, body, device=with_device or True)
        schema = SPEC.response_schema(op, "200")
        errs = []
        if status != 200:
            errs.append("HTTP %s: %s" % (status, (data or {}).get("message")))
        elif schema:
            errs = SPEC.check(data, schema, schema)
        checked += 1
        covered.add((spath, method.lower()))
        if errs:
            failed += 1
            say("[FAIL] %-6s %-48s %s" % (method, spath, "; ".join(errs[:3])))
        else:
            note = ""
            payload = (data or {}).get("data")
            if isinstance(payload, dict):
                if payload.get("numberPresentation"):
                    note = "№%s" % payload["numberPresentation"]
                elif payload.get("totalCount") is not None:
                    note = "записей %s" % payload["totalCount"]
                elif payload.get("printFormMediaType"):
                    note = "форма %s" % payload["printFormMediaType"]
            say("[OK]   %-6s %-48s %-22s %s" % (method, spath, schema, note))
        remember(key, (data or {}).get("data"))

    # ── отказы: форма ответа при отказе тоже часть контракта ──
    def negative(title, headers_fix, expect_status=(401, 400)):
        nonlocal checked, failed
        import json as _json
        raw = _json.dumps({"items": []})
        path = "/api/v1/operations/sale"
        headers = signing.headers_for(DEMO_API_KEY, DEMO_API_SECRET, "POST", path,
                                      device_id=DEMO_DEVICE_ID, body=raw)
        headers.update(headers_fix)
        req = urllib.request.Request(base_url + path, method="POST", data=raw.encode("utf-8"),
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                status, data = resp.status, json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as exc:
            status, data = exc.code, json.loads(exc.read().decode("utf-8", "replace") or "{}")
        checked += 1
        errs = SPEC.check(data, "ApiResponse", "ApiResponse")
        if status not in expect_status or data.get("success") is not False:
            errs.append("ожидался отказ, пришло HTTP %s success=%s" % (status, data.get("success")))
        if errs:
            failed += 1
            say("[FAIL] отказ: %-40s %s" % (title, "; ".join(errs[:2])))
        else:
            say("[OK]   отказ: %-40s HTTP %s, %s" % (title, status, data.get("errorType")))

    negative("чужой Api-Key", {"Api-Key": "no-such-key"})
    negative("подделанная подпись", {"Api-Signature": "0" * 64})
    negative("часы ушли на час", {"Api-Timestamp": str(signing.now_ms() - 3600 * 1000)})
    negative("нет Api-DeviceId", {"Api-DeviceId": ""}, expect_status=(400, 401))

    # ── режим «Bon de plata»: продажа должна вернуть альтернативный чек ──
    checked += 1
    status, data = caller("POST", "/api/v1/operations/sale",
                          dict(SALE_BODY, id="conf-alt-1", receiptMode="AlternativeReceiptOnly"))
    payload = (data or {}).get("data") or {}
    errs = SPEC.check(data, "SaleResponseApiResponse", "SaleResponseApiResponse")
    if payload.get("receiptType") != "AlternativeReceipt" or not payload.get("alternativeReceipt"):
        errs.append("ожидался AlternativeReceipt, пришло %s" % payload.get("receiptType"))
    if errs:
        failed += 1
        say("[FAIL] режим AlternativeReceiptOnly: %s" % "; ".join(errs[:2]))
    else:
        say("[OK]   режим AlternativeReceiptOnly: серия и номер %s"
            % payload["alternativeReceipt"].get("seriesAndNumber"))

    # ── описание API отдаётся тем же файлом, что у сервиса ──
    checked += 1
    with urllib.request.urlopen(base_url + "/openapi.json", timeout=15) as resp:
        served = json.loads(resp.read().decode())
    same = (sorted(served.get("paths", {})) == sorted(SPEC.doc["paths"])
            and sorted(served["components"]["schemas"]) == sorted(SPEC.schemas))
    if same:
        say("[OK]   /openapi.json — то же описание: путей %d, схем %d"
            % (len(served["paths"]), len(served["components"]["schemas"])))
    else:
        failed += 1
        say("[FAIL] /openapi.json отличается от описания сервиса")

    declared = {(p, m) for p, m, _ in SPEC.operations()}
    not_covered = sorted("%s %s" % (m.upper(), p) for p, m in declared - covered)
    say("")
    say("Точек в описании: %d, покрыто: %d, всего проверок: %d, расхождений: %d"
        % (len(declared), len(covered), checked, failed))
    if not_covered:
        say("Не покрыто проверкой: %s" % ", ".join(not_covered))
    return failed == 0 and not not_covered
