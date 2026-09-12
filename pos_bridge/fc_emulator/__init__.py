# -*- coding: utf-8 -*-
"""
Имитатор FiscalCloud, совместимый с сервисом SoftLider по всему контракту.

Отличие от простого заглушечного ответчика: маршруты, параметры и формы
ответов берутся из самого описания API (`fiscalcloud-openapi.json`), а не
пишутся по образцу. Поэтому в ответе есть **каждое** объявленное поле, а не
только те, что понадобились разработчику имитатора, и добавление точки в
описании не проходит незамеченным — проверка соответствия сразу об этом
скажет (`python -m pos_bridge fc-conformance`).
"""

from .server import build_app, STATE, DEMO_API_KEY, DEMO_API_SECRET, DEMO_DEVICE_ID, DEMO_POS_ID  # noqa: F401
from .spec import SPEC  # noqa: F401
