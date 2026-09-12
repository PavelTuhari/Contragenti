# Касса Sunmi (SoftLider FiscalCloud + MAIB) и реальные данные OfficePlus

Два дела, одна цепочка:

1. **Прослойка `pos_bridge`** — отдаёт кассе товары и цены, принимает от неё
   продажи и кладёт их обратно в учёт. Работает по тому же принципу, что и
   FiscalCloud: те же заголовки и подпись, описание на `/api-docs`,
   песочница на `/api-playground`.
2. **Реальные данные OfficePlus** — клиенты и товары берутся из Oracle
   (`TMS_UNIVERS`, `TMS_ORG`, `TMS_MPT`). Демонстрационный режим остаётся
   отдельным: демо-база не смешивается с рабочей.

---

## 1. Что происходит в цепочке

```
  учёт                      прослойка pos_bridge            касса
  ────                      ───────────────────             ─────
  Demo CRM (SQLite)   ──┐                                  Sunmi + SoftLider
  OfficePlus (Oracle) ──┴─▶ каталог товаров и цен  ──────▶  фискальный чек
        ▲                                                   оплата картой MAIB
        │                                                        │
        └──── заказы POS-… ◀── принятые продажи ◀── /receipts ◀───┘
```

Товар уходит на кассу с ценой и группой НДС; чек возвращается с номером,
идентификатором в СИА МЭВ, разбивкой по НДС и RRN банковской операции;
прослойка кладёт его в учёт заказом.

## 2. Запуск демонстрации (кассы не нужно)

```bash
.venv/bin/python -m pos_bridge demo --sandbox
```

Поднимаются два сервиса и прогоняется полный круг:

| Адрес | Что это |
|---|---|
| `http://127.0.0.1:50700` | демо-эмулятор FiscalCloud вместо настоящей кассы |
| `http://127.0.0.1:50800` | прослойка |
| `http://127.0.0.1:50800/api-docs` | описание API (ReDoc — как `redoc-static.html` у FiscalCloud) |
| `http://127.0.0.1:50800/api-playground` | песочница (можно жать «Try it out») |
| `http://127.0.0.1:50800/openapi.json` | машинное описание |

`--sandbox` кладёт данные во временную папку и работает с **копией** базы
учёта: рабочие базы демонстрация не трогает.

Без окон и с кодом возврата:

```bash
.venv/bin/python -m pos_bridge selftest     # 0 — всё прошло
```

Проверяется: подпись по правилам FiscalCloud и отказ на чужой подписи,
чтение каталога из учёта, продажа с оплатой картой и наличными, приём чеков,
запись продажи заказом в учёт, повтор операции с тем же `id` (второй чек не
печатается), перенос реальных данных OfficePlus в отдельную базу.

## 3. API прослойки

Заголовки — как у FiscalCloud: `Api-Key`, `Api-Timestamp` (UTC, миллисекунды),
`Api-Signature` = HMAC-SHA256 от склейки
`Api-DeviceId + Api-PointOfSaleId + Api-Timestamp + МЕТОД + путь с параметрами + тело`.
На петлевом адресе без заданных ключей подпись не требуется — так удобно
пробовать запросы в песочнице.

| Точка | Назначение |
|---|---|
| `GET /api/v1/catalog/goods` | товары и цены для кассы; `since` отдаёт только изменившиеся |
| `GET /api/v1/catalog/goods/{barcode}` | товар по штрих-коду (сканер) |
| `POST /api/v1/catalog/sync` | перечитать каталог из учёта (`demo` / `erp` / `file`) |
| `POST /api/v1/pos/sale` | продажа: фискальный чек и оплата картой |
| `POST /api/v1/pos/return` | возврат |
| `POST /api/v1/pos/closeday` | закрытие дня: Z-отчёт и сверка терминала |
| `POST /api/v1/pos/totals` | промежуточные итоги: X-отчёт |
| `POST /api/v1/pos/pull` | забрать чеки из FiscalCloud (в том числе пробитые на самой кассе) |
| `POST /api/v1/pos/export` | выгрузить принятые продажи в учёт |
| `GET /api/v1/pos/sales` | что уже принято |
| `GET /api/v1/pos/status` | устройство, группы НДС, виды оплат, очередь выгрузки |
| `GET /api/v1/erp/clients` | организации OfficePlus (Oracle) |
| `GET /api/v1/erp/goods` | товары OfficePlus напрямую из Oracle |

Пример продажи:

```bash
curl -s -X POST http://127.0.0.1:50800/api/v1/pos/sale \
  -H 'Content-Type: application/json' -d '{
    "id": "smena-1-chek-17",
    "items": [{"goodId": "crm-7", "quantity": 3},
              {"barcode": "4840000000017", "quantity": 2, "discountPercent": -10}],
    "payments": [{"amount": 100, "card": true}, {"amount": 558.5}]
  }'
```

В ответе — чек целиком: номер, суммы, НДС по группам, RRN банковской
операции и номер созданного заказа в учёте.

## 4. Что берётся у самой кассы

Группы НДС и виды оплат не зашиты в код: прослойка читает их у устройства
(`GET /api/v1/devices/{id}`) и по ним подбирает `TaxGroupCode` для каждой
строки. В демо-эмуляторе это A 20 %, B 8 %, C 12 %, N 0 % и оплаты
«Numerar» / «Card bancar (MAIB)».

У товаров OfficePlus группа НДС уже готова: `TMS_UNIVERS.CODTVA` — это та же
буква, что `TaxGroupCode` в FiscalCloud, пересчитывать ничего не нужно.

## 5. Реальные данные OfficePlus

Демо-режим остаётся как был: `clients.db` с генератором. Реальные данные
идут в отдельную базу, режимы не смешиваются.

```bash
export TMS_PASSWORD=…        # схема организаций (paralax)
export GOODS_PASSWORD=…      # схема товаров (BONUS2019)
.venv/bin/python -m pos_bridge check-oracle          # проверить доступ
.venv/bin/python -m pos_bridge import-erp            # клиенты и товары -> erp.db
.venv/bin/python -m pos_bridge sync --source erp     # каталог кассы из Oracle
```

| Что | Откуда |
|---|---|
| Клиенты | `TMS_UNIVERS` (TIP='O') + `TMS_ORG`: `DENUMIREA`/`NAMERUS`, `CODFISCAL`, `ADRESS`, `DIRECTOR` |
| Товары | `TMS_UNIVERS` (TIP='P') + `TMS_MPT`: `DENUMIREA`, `UM`, `CODTVA`, `STRIH1_CODPRODUCER` (штрих-код), `MATPRET` (цена) |
| Сотрудники | `A$ADM`/`A$ADP` + `TMS_MUNC` — отдельный обмен, см. [STAFF_ERP_ru.md](STAFF_ERP_ru.md) |

Пароли только в окружении или в `pos_bridge_config.json` (он в `.gitignore`);
образец настроек — `pos_bridge_config.example.json`.

**Сервер 11.2 и thin-режим.** `oracledb` по умолчанию работает без Oracle
Instant Client, но со старым сервером нужен «толстый» режим: путь к клиенту
задаётся в `oracle.client_dir` или переменной `ORACLE_CLIENT_DIR`.

## 6. Боевой запуск

```bash
.venv/bin/python -m pos_bridge serve --port 50800
```

Адрес и ключи FiscalCloud — в `pos_bridge_config.json` (`base_url`
`http://localhost:50700` для локального сервиса SoftLider или
`https://cloud.fiscalcloud.md` для облака). Кассовое приложение Sunmi
обращается к прослойке, а не к FiscalCloud напрямую: так товары, цены и
продажи остаются связаны с учётом, а ключ фискального сервиса не уезжает
на устройство.

Зависимости — те же, что у хаба (`requirements-hub.txt`: fastapi, uvicorn,
oracledb).
