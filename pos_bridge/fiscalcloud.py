# -*- coding: utf-8 -*-
"""
Клиент FiscalCloud (SoftLider) — тот самый сервис, через который касса
Sunmi печатает фискальный чек и проводит оплату на банковском терминале
MAIB.

Покрыты разделы, нужные прослойке:
    POST /api/v1/operations/sale               продажа (чек + оплата картой)
    POST /api/v1/operations/return             возврат
    POST /api/v1/operations/closeday           закрытие дня (Z-отчёт)
    POST /api/v1/operations/intermediatetotals промежуточные итоги (X-отчёт)
    GET  /api/v1/receipts, /receipts/full      выданные чеки
    GET  /api/v1/devices, /devices/{id}        устройство: группы НДС и виды оплат

Подпись запроса — по правилам FiscalCloud (модуль signing). Сетевой слой —
стандартный urllib, лишних зависимостей у прослойки нет.
"""

import json
import urllib.error
import urllib.parse
import urllib.request

from . import signing

# виды оплаты фискального устройства (уточняются у самого устройства)
PAY_CASH = 0
PAY_CARD = 1


class FiscalCloudError(Exception):
    def __init__(self, message, status=0, payload=None):
        super().__init__(message)
        self.status = status
        self.payload = payload or {}


class FiscalCloudClient:
    def __init__(self, cfg):
        f = cfg["fiscalcloud"] if "fiscalcloud" in cfg else cfg
        self.base_url = (f.get("base_url") or "").rstrip("/")
        self.api_key = f.get("api_key") or ""
        self.api_secret = f.get("api_secret") or ""
        self.device_id = f.get("device_id") or ""
        self.point_of_sale_id = f.get("point_of_sale_id") or ""
        self.timeout = float(f.get("timeout") or 30)

    @property
    def configured(self):
        return bool(self.base_url and self.api_key and self.api_secret)

    # ── транспорт ──

    def _call(self, method, path, body=None, query=None, with_device=True):
        if not self.base_url:
            raise FiscalCloudError("не задан адрес FiscalCloud")
        path_and_query = path
        if query:
            clean = {k: v for k, v in query.items() if v not in (None, "")}
            if clean:
                path_and_query += "?" + urllib.parse.urlencode(clean)
        raw = json.dumps(body, ensure_ascii=False) if body is not None else None
        headers = signing.headers_for(
            self.api_key, self.api_secret, method, path_and_query,
            device_id=self.device_id if with_device else "",
            point_of_sale_id=self.point_of_sale_id if with_device else "",
            body=raw or "")
        req = urllib.request.Request(
            self.base_url + path_and_query, method=method.upper(),
            data=raw.encode("utf-8") if raw is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                text = resp.read().decode("utf-8", "replace")
                status = resp.status
        except urllib.error.HTTPError as exc:
            text = exc.read().decode("utf-8", "replace")
            status = exc.code
        except urllib.error.URLError as exc:
            raise FiscalCloudError("FiscalCloud недоступен: %s" % exc.reason)
        try:
            data = json.loads(text) if text else {}
        except ValueError:
            raise FiscalCloudError("ответ не JSON (HTTP %s): %s" % (status, text[:200]), status)
        if status >= 400 or (isinstance(data, dict) and data.get("success") is False):
            msg = (data.get("message") if isinstance(data, dict) else "") or ("HTTP %s" % status)
            raise FiscalCloudError(msg, status, data)
        return data

    @staticmethod
    def _payload(data):
        """Полезная часть ответа: FiscalCloud заворачивает её в ApiResponse."""
        if isinstance(data, dict) and "data" in data and "success" in data:
            return data["data"]
        return data

    # ── операции ──

    def sale(self, items, payments, modifications=None, receipt_mode="FiscalReceiptOnly",
             email="", phone="", operation_id=None, print_receipt=True, comment=""):
        body = {
            "receiptMode": receipt_mode,
            "print": bool(print_receipt),
            "printOnServer": True,
            "sendToEmail": bool(email),
            "emailAddress": email or None,
            "sendToPhone": bool(phone),
            "phoneNumber": phone or None,
            "items": items,
            "payments": payments,
            "amountModifications": modifications or [],
        }
        if operation_id:
            body["id"] = operation_id
        if comment:
            body["additionalFooterText"] = comment
        return self._payload(self._call("POST", "/api/v1/operations/sale", body))

    def do_return(self, items, payments, operation_id=None):
        body = {"items": items, "payments": payments, "print": True, "printOnServer": True}
        if operation_id:
            body["id"] = operation_id
        return self._payload(self._call("POST", "/api/v1/operations/return", body))

    def close_day(self):
        return self._payload(self._call("POST", "/api/v1/operations/closeday", {}))

    def intermediate_totals(self):
        return self._payload(self._call("POST", "/api/v1/operations/intermediatetotals", {}))

    # ── чтение ──

    def receipts(self, start_index=0, count=100, full=False):
        path = "/api/v1/receipts/full" if full else "/api/v1/receipts"
        data = self._payload(self._call("GET", path, query={"startIndex": start_index, "count": count}))
        if isinstance(data, dict):
            return data.get("data") or [], int(data.get("totalCount") or 0)
        return data or [], len(data or [])

    def receipt(self, receipt_id):
        return self._payload(self._call("GET", "/api/v1/receipts/%s" % receipt_id))

    def devices(self):
        data = self._payload(self._call("GET", "/api/v1/devices", with_device=False))
        if isinstance(data, dict):
            return data.get("data") or []
        return data or []

    def device(self, device_id=None):
        return self._payload(self._call("GET", "/api/v1/devices/%s" % (device_id or self.device_id)))

    # ── помощники ──

    @staticmethod
    def item(name, quantity, price, tax_group="A", good_id=None, discount_percent=0.0, comment=""):
        row = {"name": name, "quantity": round(float(quantity), 3),
               "price": round(float(price), 2), "taxGroupCode": tax_group}
        if good_id:
            row["goodId"] = str(good_id)
        if discount_percent:
            row["modifierMode"] = "ByPercent"
            row["modifierValue"] = round(float(discount_percent), 2)
        if comment:
            row["comment"] = comment
        return row

    @staticmethod
    def payment(amount, by_card=False, type_code=None, bank_terminal=None):
        row = {"typeCode": PAY_CARD if by_card else PAY_CASH if type_code is None else int(type_code),
               "amount": round(float(amount), 2),
               "useBankTerminal": bool(by_card)}
        if bank_terminal:
            row["bankTerminal"] = bank_terminal
        return row

    @staticmethod
    def tax_groups(device):
        """[(код, ставка)] из карточки устройства."""
        return [(g.get("code"), float(g.get("rate") or 0))
                for g in (device or {}).get("taxGroups") or [] if g.get("enabled", True)]

    @staticmethod
    def payment_types(device):
        return [(int(p.get("code")), p.get("name"))
                for p in (device or {}).get("paymentTypes") or [] if p.get("enabled", True)]
