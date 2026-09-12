# -*- coding: utf-8 -*-
"""Схема комплекса — рисуется прямо в книге, без внешних картинок."""

DIAGRAM = """
<figure class="scheme">
<svg viewBox="0 0 980 470" width="980" height="470" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Схема комплекса: реестр, CRM, хаб, ERP, касса"
     xmlns="http://www.w3.org/2000/svg" style="width:100%;height:auto;max-width:980px;background:#fff;border:1px solid #e3e7ee;border-radius:10px">
  <defs>
    <marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
      <path d="M0 0 L10 5 L0 10 z" fill="#5b6b86"/>
    </marker>
    <style>
      .box{fill:#fff;stroke:#c7d2e4;stroke-width:1.5;rx:10}
      .accent{fill:#eaf2fd;stroke:#1a6fd4}
      .warm{fill:#fff6e8;stroke:#d9a441}
      .green{fill:#eef8f0;stroke:#4f9d69}
      .t{font:600 14px system-ui,-apple-system,sans-serif;fill:#1d2330}
      .s{font:12px system-ui,-apple-system,sans-serif;fill:#5b6b86}
      .l{font:11px system-ui,-apple-system,sans-serif;fill:#5b6b86}
      .line{stroke:#5b6b86;stroke-width:1.6;fill:none;marker-end:url(#a)}
      .dash{stroke-dasharray:5 4}
      .cap{font:600 12px system-ui,sans-serif;fill:#8794aa;letter-spacing:.06em}
    </style>
  </defs>

  <text class="cap" x="24" y="26">ИСТОЧНИК</text>
  <text class="cap" x="272" y="26">УЧЁТ</text>
  <text class="cap" x="600" y="26">ОБМЕН</text>
  <text class="cap" x="822" y="26">КАССА</text>

  <rect class="box" x="24" y="44" width="190" height="78" rx="10"/>
  <text class="t" x="40" y="70">date.gov.md</text>
  <text class="s" x="40" y="90">Государственный реестр</text>
  <text class="s" x="40" y="108">организаций Молдовы</text>

  <rect class="box accent" x="24" y="150" width="190" height="96" rx="10"/>
  <text class="t" x="40" y="176">Contragenti</text>
  <text class="s" x="40" y="196">Python · поиск, карточка,</text>
  <text class="s" x="40" y="213">XML, локальный API :9393</text>
  <text class="l" x="40" y="233">companies.db</text>

  <rect class="box accent" x="272" y="120" width="230" height="126" rx="10"/>
  <text class="t" x="290" y="146">Demo CRM</text>
  <text class="s" x="290" y="166">Delphi · Windows</text>
  <text class="s" x="290" y="184">Swift/AppKit · macOS</text>
  <text class="s" x="290" y="202">клиенты, сделки, заказы,</text>
  <text class="s" x="290" y="220">проекты, задачи, отчёты</text>
  <text class="l" x="290" y="238">clients.db · lang.json · processes.json</text>

  <rect class="box" x="272" y="286" width="230" height="90" rx="10"/>
  <text class="t" x="290" y="312">Сотрудники</text>
  <text class="s" x="290" y="332">регистрация, доступ,</text>
  <text class="s" x="290" y="350">отчёт по людям</text>
  <text class="l" x="290" y="368">users + sync_log (триггеры)</text>

  <rect class="box green" x="560" y="44" width="200" height="96" rx="10"/>
  <text class="t" x="578" y="70">Хаб (FastAPI)</text>
  <text class="s" x="578" y="90">приём пакетов,</text>
  <text class="s" x="578" y="108">обмен сотрудниками,</text>
  <text class="s" x="578" y="126">чтение справочника</text>

  <rect class="box green" x="560" y="170" width="200" height="126" rx="10"/>
  <text class="t" x="578" y="196">ERP OfficePlus</text>
  <text class="s" x="578" y="216">Oracle · C++Builder</text>
  <text class="s" x="578" y="234">TMS_UNIVERS, TMS_ORG,</text>
  <text class="s" x="578" y="252">TMS_MPT, TMS_MUNC</text>
  <text class="s" x="578" y="270">A$ADM / A$ADP — люди</text>
  <text class="l" x="578" y="288">очередь A$CRM_SYNC</text>

  <rect class="box green dash" x="560" y="322" width="200" height="62" rx="10"
        style="stroke-dasharray:6 4"/>
  <text class="t" x="578" y="348">MySQL / MariaDB</text>
  <text class="s" x="578" y="368">та же схема — замена Oracle</text>

  <rect class="box warm" x="800" y="120" width="160" height="110" rx="10"/>
  <text class="t" x="816" y="146">pos_bridge</text>
  <text class="s" x="816" y="166">товары и цены</text>
  <text class="s" x="816" y="184">на кассу,</text>
  <text class="s" x="816" y="202">продажи обратно</text>
  <text class="l" x="816" y="220">:50800 /api-docs</text>

  <rect class="box warm" x="800" y="262" width="160" height="122" rx="10"/>
  <text class="t" x="816" y="288">Касса Sunmi</text>
  <text class="s" x="816" y="308">FiscalCloud</text>
  <text class="s" x="816" y="326">(SoftLider) :50700</text>
  <text class="s" x="816" y="344">терминал MAIB</text>
  <text class="l" x="816" y="364">имитатор — та же</text>
  <text class="l" x="816" y="378">спецификация</text>

  <path class="line" d="M119 122 L119 150"/>
  <path class="line" d="M214 190 L272 175"/>
  <text class="l" x="218" y="176">XML-карточка</text>
  <path class="line" d="M387 246 L387 286"/>
  <path class="line" d="M502 160 L560 100"/>
  <text class="l" x="500" y="122">пакеты</text>
  <path class="line" d="M502 330 L560 250"/>
  <text class="l" x="496" y="306">очередь</text>
  <path class="line" d="M660 140 L660 170"/>
  <path class="line" d="M660 296 L660 322" style="stroke-dasharray:5 4"/>
  <path class="line" d="M760 200 L800 170"/>
  <text class="l" x="748" y="160">товары</text>
  <path class="line" d="M880 230 L880 262"/>
  <text class="l" x="888" y="250">продажа</text>
  <path class="line" d="M838 262 L838 230" />
  <text class="l" x="742" y="250">чек</text>
  <path class="line" d="M800 300 L502 330" style="stroke-dasharray:5 4"/>
  <text class="l" x="590" y="326">продажи в учёт заказами</text>
</svg>
<figcaption>Путь данных: реквизиты вводятся один раз в реестре, дальше идут по всем системам
и возвращаются в учёт продажей с кассы.</figcaption>
</figure>
"""
