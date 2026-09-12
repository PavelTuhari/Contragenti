# -*- coding: utf-8 -*-
"""
Состояние имитатора: устройство, смена, счётчики и выданные документы.

Считает всё то же, что настоящая касса: итоги по группам НДС и видам
оплат, накопительные суммы (grand total), остаток наличных в ящике,
привязку документов к Z-отчёту закрытой смены.
"""

import datetime
import uuid

from .spec import SPEC

DEMO_DEVICE_ID = "0875b8a5-0668-41a3-a3fa-8eeccf66d289"
DEMO_POS_ID = "1f0d2a64-7b53-4f0e-9a3d-2f4d6f0a1c77"

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
CASH_TYPE_CODE = 0


def now():
    return datetime.datetime.now()


def iso(dt):
    return dt.isoformat(timespec="seconds")


def human(dt):
    return dt.strftime("%d.%m.%Y %H:%M:%S")


def m2(v):
    return round(float(v or 0) + 0.0, 2)


def rate_of(code):
    for g in TAX_GROUPS:
        if g["code"] == (code or "").upper():
            return float(g["rate"])
    return 0.0


def payment_name(code):
    for p in PAYMENT_TYPES:
        if int(p["code"]) == int(code or 0):
            return p["name"]
    return str(code)


class Shift:
    """Смена: от первого документа до Z-отчёта."""

    def __init__(self):
        self.opened_at = now()
        self.current_number = {}       # номер внутри смены по видам документов
        self.receipts = []             # id фискальных чеков смены
        self.returns = []
        self.alternatives = []
        self.tax_totals = {}           # код группы -> [оборот, НДС]
        self.payment_totals = {}       # код оплаты -> сумма
        self.cash_in = 0.0
        self.cash_out = 0.0
        self.total = 0.0
        self.receipt_count = 0
        self.last_receipt_number = 0

    def next_current(self, kind):
        self.current_number[kind] = self.current_number.get(kind, 0) + 1
        return self.current_number[kind]

    def add_document(self, doc, sign=1):
        for it in doc.get("items") or []:
            code = (it.get("taxGroupCode") or "").upper()
            slot = self.tax_totals.setdefault(code, [0.0, 0.0])
            slot[0] += sign * float(it.get("finalAmount") or 0)
            slot[1] += sign * float(it.get("finalTaxAmount") or 0)
        for p in doc.get("payments") or []:
            code = int(p.get("typeCode") or 0)
            self.payment_totals[code] = self.payment_totals.get(code, 0.0) + sign * float(p.get("amount") or 0)
            if code == CASH_TYPE_CODE:
                paid = float(p.get("amount") or 0) - float(p.get("change") or 0)
                if sign > 0:
                    self.cash_in += paid
                else:
                    self.cash_out += paid
        self.total += sign * float(doc.get("totalAmount") or 0)
        self.receipt_count += 1
        self.last_receipt_number = max(self.last_receipt_number, int(doc.get("number") or 0))

    @property
    def balance(self):
        return m2(self.cash_in - self.cash_out)


class State:
    """Всё, что помнит имитатор между запросами."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.started_at = now()
        self.numbers = {}              # сквозные номера по видам документов
        self.documents = {"receipt": [], "return": [], "alternative": [],
                          "nonfiscal": [], "report": [], "cashoperation": []}
        self.by_operation_id = {}
        self.shift = Shift()
        self.grand_total = 0.0
        self.grand_tax = 0.0
        self.annual_total = 0.0
        self.annual_tax = 0.0
        self.alt_series = "AA"
        self.alt_next = 1
        self.use_alternative_receipts = False
        self.tax_authority_online = True   # для режима FiscalThenAlternativeReceipt

    # ── номера ──

    def next_number(self, kind):
        self.numbers[kind] = self.numbers.get(kind, 0) + 1
        return self.numbers[kind]

    # ── карточка устройства ──

    def device(self, device_id=None):
        d = SPEC.blank("FiscalDeviceDto")
        d.update({
            "id": device_id or DEMO_DEVICE_ID,
            "name": "Sunmi V2s (имитатор)",
            "serialNumber": "DEMO-0001",
            "registrationNumber": "DEMO-REG-0001",
            "model": "Sunmi V2s + SoftLider FiscalCloud",
            "organizationName": "DEMO SRL",
            "idnx": "1000000000000",
            "address": "mun. Chişinău, str. Demo 1",
            "subdivisionCode": "01",
            "mevKeyEncrypted": "",
            "isFiscalized": True,
            "isDeregistered": False,
            "createdDateTime": iso(self.started_at),
            "fiscalizedDateTime": iso(self.started_at),
            "deregisteredDateTime": None,
            "lastOperationNumber": self.numbers.get("receipt", 0),
            "logo": "",
            "useAlternativeReceipts": self.use_alternative_receipts,
            "taxGroups": [dict(g) for g in TAX_GROUPS],
            "paymentTypes": [dict(p) for p in PAYMENT_TYPES],
        })
        lic = SPEC.blank("FiscalDeviceLicenseDataDto")
        lic.update({"fiscalDeviceId": d["id"], "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, "license")),
                    "activeUntil": iso(self.started_at + datetime.timedelta(days=365))})
        d["licenseData"] = lic
        pos = SPEC.blank("FiscalDevicePointOfSaleDto")
        pos.update({"rowNumber": 1, "id": DEMO_POS_ID, "code": "01", "allowFreeSale": True,
                    "useBankTerminals": True, "bankTerminalsIDList": "MAIB-01"})
        d["pointsOfSale"] = [pos]
        rng = SPEC.blank("FiscalDeviceAlternativeReceiptsRangeDto")
        rng.update({"fiscalDeviceId": d["id"], "rowNumber": 1,
                    "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, "range")),
                    "dateAdded": iso(self.started_at), "dateExpended": None,
                    "series": self.alt_series, "startNumber": 1, "endNumber": 1000,
                    "numberLength": 6, "willSoonBeExpended": False, "expendedCompletely": False})
        d["alternativeReceiptsRanges"] = [rng]
        hist = []
        for g in TAX_GROUPS:
            h = SPEC.blank("FiscalDeviceTaxGroupHistoryEntryDto")
            h.update({"rowNumber": g["rowNumber"], "enabled": True, "code": g["code"], "rate": g["rate"],
                      "ratePresentation": "%g %%" % g["rate"], "dateTime": iso(self.started_at)})
            hist.append(h)
        d["taxGroupsHistoryEntries"] = hist
        return d

    def device_short(self, device_id=None):
        s = SPEC.blank("FiscalDeviceShortInfo")
        d = self.device(device_id)
        for k in s:
            if k in d:
                s[k] = d[k]
        return s

    # ── общая шапка документа ──

    def head(self, schema, kind, point_of_sale_id=None):
        doc = SPEC.blank(schema)
        dev = self.device()
        number = self.next_number(kind)
        current = self.shift.next_current(kind)
        t = now()
        doc.update({
            "fiscalDeviceId": dev["id"],
            "id": str(uuid.uuid4()),
            "uniqueId": str(uuid.uuid4()),
            "authorId": str(uuid.uuid5(uuid.NAMESPACE_DNS, "demo-user")),
            "authorUserName": "Demo",
            "number": number,
            "numberPresentation": "%06d" % number,
            "currentNumber": current,
            "currentNumberPresentation": "%06d" % current,
            "dateTime": iso(t),
            "dateTimePresentation": human(t),
            "organizationName": dev["organizationName"],
            "idnx": dev["idnx"],
            "address": dev["address"],
            "pointOfSaleId": point_of_sale_id or DEMO_POS_ID,
            "pointOfSaleCode": "01",
            "mevId": str(uuid.uuid4()),
            "mevDateTime": iso(t),
            "mevDateTimePresentation": human(t),
            "printFormMediaType": None,
            "printFormContent": None,
            "printErrorMessage": None,
            "licenseMessage": None,
            "additionalData": None,
        })
        return doc

    def store(self, kind, doc):
        self.documents[kind].append(doc)
        return doc

    def find(self, kind, doc_id):
        for d in self.documents[kind]:
            if d.get("id") == doc_id:
                return d
        return None

    def page(self, kind, start_index, count):
        items = self.documents[kind]
        start = max(0, int(start_index or 0))
        take = max(0, int(count if count is not None else 100))
        return items[start:start + take], len(items)


STATE = State()
