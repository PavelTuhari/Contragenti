# -*- coding: utf-8 -*-
"""
Имитатор FiscalCloud (SoftLider) — тот, что подменяет кассу Sunmi.

Сам имитатор живёт в пакете `fc_emulator`: он собран по описанию API
(`fiscalcloud-openapi.json`), закрывает все 35 объявленных операций и
отвечает документами, в которых есть каждое объявленное поле. Проверка
соответствия — `python -m pos_bridge fc-conformance`.

Здесь оставлены прежние имена, чтобы остальной код прослойки не менялся.
"""

from .fc_emulator import DEMO_API_KEY, DEMO_API_SECRET, DEMO_DEVICE_ID, DEMO_POS_ID, STATE, build_app  # noqa: F401
from .fc_emulator.state import PAYMENT_TYPES, TAX_GROUPS  # noqa: F401

__all__ = ["build_app", "STATE", "DEMO_API_KEY", "DEMO_API_SECRET", "DEMO_DEVICE_ID", "DEMO_POS_ID",
           "TAX_GROUPS", "PAYMENT_TYPES"]
