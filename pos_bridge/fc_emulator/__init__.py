# -*- coding: utf-8 -*-
"""
Имитатор FiscalCloud, совместимый с сервисом SoftLider по всему контракту.

Отличие от простого заглушечного ответчика: маршруты, параметры и формы
ответов берутся из самого описания API (`fiscalcloud-openapi.json`), а не
пишутся по образцу. Поэтому в ответе есть **каждое** объявленное поле, а не
только те, что понадобились разработчику имитатора, и добавление точки в
описании не проходит незамеченным — проверка соответствия сразу об этом
скажет (`python -m pos_bridge fc-conformance`).

Это отдельная программа: с окном на рабочем месте и службой на сервере.

    python -m pos_bridge.fc_emulator            окно
    python -m pos_bridge.fc_emulator serve      сервер (Linux, systemd)
"""

from .server import (build_app, configure, STATE, DEMO_API_KEY, DEMO_API_SECRET,  # noqa: F401
                     DEMO_DEVICE_ID, DEMO_POS_ID)
from .service import Emulator, setup_logging, unit_text  # noqa: F401
from .spec import SPEC  # noqa: F401
from . import settings  # noqa: F401
