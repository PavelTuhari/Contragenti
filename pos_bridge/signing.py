# -*- coding: utf-8 -*-
"""
Подпись запросов по правилам FiscalCloud (раздел Authentication).

Подписывается строка, собранная встык:
    Api-DeviceId (если есть) + Api-PointOfSaleId (если есть) + Api-Timestamp
    + метод в верхнем регистре + путь с параметрами запроса + тело запроса.
Алгоритм — HMAC-SHA256 секретным ключом, результат в hex нижним регистром.

Тот же модуль проверяет входящие запросы к самой прослойке: правило одно,
чтобы кассовое приложение писало код подписи один раз.
"""

import hashlib
import hmac
import time

# допустимое расхождение часов, мс (в FiscalCloud — ±10 минут)
CLOCK_SKEW_MS = 10 * 60 * 1000


def now_ms():
    return int(time.time() * 1000)


def signature(secret, timestamp, method, path_and_query,
              device_id="", point_of_sale_id="", body=""):
    """HMAC-SHA256 в hex нижним регистром."""
    data = "".join([
        device_id or "",
        point_of_sale_id or "",
        str(timestamp),
        (method or "").upper(),
        path_and_query or "",
        body or "",
    ])
    return hmac.new(secret.encode("utf-8"), data.encode("utf-8"), hashlib.sha256).hexdigest()


def headers_for(api_key, secret, method, path_and_query, device_id="",
                point_of_sale_id="", body="", timestamp=None):
    """Готовый набор заголовков запроса."""
    ts = str(timestamp if timestamp is not None else now_ms())
    out = {
        "Api-Key": api_key,
        "Api-Timestamp": ts,
        "Api-Signature": signature(secret, ts, method, path_and_query,
                                   device_id, point_of_sale_id, body),
        "Content-Type": "application/json",
    }
    if device_id:
        out["Api-DeviceId"] = device_id
    if point_of_sale_id:
        out["Api-PointOfSaleId"] = point_of_sale_id
    return out


def check(secret, headers, method, path_and_query, body="", skew_ms=CLOCK_SKEW_MS):
    """Проверка входящей подписи. Возвращает (ок, причина)."""
    ts = headers.get("api-timestamp") or headers.get("Api-Timestamp")
    sig = headers.get("api-signature") or headers.get("Api-Signature")
    dev = headers.get("api-deviceid") or headers.get("Api-DeviceId") or ""
    pos = headers.get("api-pointofsaleid") or headers.get("Api-PointOfSaleId") or ""
    if not ts or not sig:
        return False, "нет Api-Timestamp или Api-Signature"
    try:
        ts_val = int(ts)
    except ValueError:
        return False, "Api-Timestamp не число"
    if abs(now_ms() - ts_val) > skew_ms:
        return False, "часы разошлись больше допустимого"
    expected = signature(secret, ts, method, path_and_query, dev, pos, body)
    if not hmac.compare_digest(expected, sig.lower()):
        return False, "подпись не сходится"
    return True, ""
