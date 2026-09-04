# Интеграция Contragenti — единый гайд для ИИ и разработчиков

Этот файл — самодостаточная точка входа для того, чтобы **любое приложение
(Delphi / Python / C++ / 1С / веб)** быстро подключило поиск контрагентов
Молдовы (портал `date.gov.md`) и записало полученные поля в **свою**
внутреннюю базу данных. Ссылка на этот репозиторий — единственное, что
для этого нужно; остальные документы (`API_ru.md`, `TECHNICAL_ru.md`)
раскрывают детали, но их читать не обязательно.

Если тебя попросили «подключить Contragenti» и у тебя нет доступа к живому
порталу для проверки — ориентируйся на готовый рабочий пример
**`crm_delphi/`** (Delphi VCL + SQLite): это полная эталонная интеграция,
собранная и протестированная (см. `crm_delphi/act_testirovaniya.html`).
Три файла оттуда стоит прочитать первыми:

| Файл | Что показывает |
|---|---|
| [`crm_delphi/uContragenti.pas`](crm_delphi/uContragenti.pas) | SDK-обёртка вызова (Delphi, без VCL-зависимостей) — переносится в C++/Python один в один по логике |
| [`crm_delphi/uClientsDB.pas`](crm_delphi/uClientsDB.pas) | Как разложить карточку по своим таблицам (SQLite, дедупликация по IDNO) |
| [`crm_delphi/uMainForm.pas`](crm_delphi/uMainForm.pas) | Как дёрнуть SDK по кнопке и обработать 3 исхода (добавлено / дубликат / отмена) |

---

## 1. Контракт в двух словах

Contragenti — не библиотека, а **отдельный процесс**. Интеграция = запустить
его с нужными флагами, дождаться завершения, прочитать файл с XML-карточкой,
разложить поля по своим колонкам. Никакого API-ключа, HTTP-сервера или
компиляции чужого кода не требуется — только `CreateProcess`/`subprocess`.

```
<путь к Contragenti или python company_search.py> --pick --out <файл.xml> \
    --lang ru --q "<стартовый фильтр>" --no-server --no-tray
```

Процесс открывает окно поиска, пользователь выбирает компанию и жмёт
«Вернуть контрагента» → процесс пишет XML в `<файл.xml>` и завершается
(exit code `0`). Если пользователь закрыл окно без выбора — файла не будет,
exit code всё равно `0` (это не ошибка, а отказ пользователя).

### Полный список флагов (см. `company_search.py`, `argparse` в конце файла)

| Флаг | Значение |
|---|---|
| `--pick` | Включить одноразовый режим выбора (обязателен для интеграции) |
| `--out FILE` | Куда писать XML карточки. Без него XML уходит в stdout |
| `--q "ТЕКСТ"` | Стартовый фильтр — сразу показывает результаты поиска |
| `--lang ru\|ro\|en` | Язык интерфейса окна |
| `--no-server` | Не поднимать локальный HTTP-API (не нужен для одноразового вызова) |
| `--no-tray` | Не создавать иконку в системном трее |
| `--auto-pick` | **Для автотестов**: не ждать пользователя, вернуть первый результат поиска автоматически (сначала проверяет локальный кэш, на портал идёт только если компании там нет — см. §5) |
| `--shots-dir DIR` | Сохранять снимки портала и своего окна в `DIR` (используется `crm_delphi`-самотестом, для интеграции не нужен) |
| `--selftest` | Проверка XML-парсера и SQLite без сети — быстрый способ проверить, что окружение готово |

Также доступен **резидентный HTTP-режим** (`GET /pick?...` на
`127.0.0.1:9393`) — если твоё приложение уже держит процесс живым или
пишет на 1С/BSL, читай **[API_ru.md](API_ru.md)**. Он даёт то же самое, но
через HTTP вместо CLI, плюс параметр `return_to` для веб-редиректа.

---

## 2. Формат XML-карточки и куда класть поля

```xml
<?xml version="1.0" encoding="UTF-8"?>
<counterparty source="date.gov.md" idno="1003600116460" updated="2026-08-11T00:58:37">
  <idno>1003600116460</idno>
  <denumire>CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.</denumire>
  <inregistrare>30.03.2001</inregistrare>
  <forma_juridica>Societate cu răspundere limitată</forma_juridica>
  <lichidata>Nu</lichidata>
  <adresa>mun. Chişinău, sec. Buiucani, str. Alba-Iulia, 75/B</adresa>
  <administratori>TUHARI PAVEL [Administrator]</administratori>
  <founders>
    <founder name="TUHARI PAVEL" share="100,00"/>
  </founders>
  <debts currency="MDL">
    <debt nr="1" type="Bugetul de stat" sum="0,00"/>
  </debts>
  <details_text>…полный текст карточки одним блоком, для полнотекстового поиска…</details_text>
</counterparty>
```

### Таблица соответствия (используй как основу своей схемы)

| XML-элемент | Тип | Рекомендуемая колонка | Примечание |
|---|---|---|---|
| `@idno` / `<idno>` | строка, 13 цифр | `idno` (**UNIQUE**, ключ дедупликации) | Совпадает с IDNO/CIF — по нему делай upsert, не по названию |
| `<denumire>` | строка | `name` / `denumire` | Полное юридическое название |
| `<inregistrare>` | `ДД.ММ.ГГГГ` | `reg_date` | Дата регистрации; парсить как строку или `date`, формат европейский |
| `<forma_juridica>` | строка | `legal_form` | «Societate cu răspundere limitată» и т.п. |
| `<lichidata>` | `Da` / `Nu` | `is_liquidated` (bool) | `Da` = ликвидирована |
| `<adresa>` | строка | `address` | Юридический адрес одной строкой |
| `<administratori>` | строка | `managers` | Может содержать несколько имён через `;` — при необходимости разбить |
| `<founders>/<founder@name,@share>` | массив | отдельная таблица `founders(company_idno, name, share)` | `share` — строка с процентом, десятичный разделитель `,` |
| `<debts>/<debt@nr,@type,@sum>`, `<debts@currency>` | массив | отдельная таблица `debts(company_idno, type, sum, currency)` | Пусто, если долгов нет |
| `<details_text>` | текст | `details_text` / `search_text` | Готовый текст для полнотекстового индекса, дублирует остальные поля |
| `@source`, `@updated` | атрибуты корня | `source`, `updated_at` | `source` всегда `date.gov.md`; `updated_at` — момент получения с портала |

`founders` и `debts` могут быть пустыми элементами без дочерних узлов —
это не ошибка, а «нет данных».

---

## 3. Быстрый старт по языкам

Готовые обёртки лежат в [`sdk/`](sdk/) — скопируй файл целиком в свой проект.

### Python — [`sdk/python/contragenti_sdk.py`](sdk/python/contragenti_sdk.py)

```python
from contragenti_sdk import pick_counterparty

card = pick_counterparty(q="UNISIM", lang="ru")
if card:
    my_db.execute(
        "INSERT OR IGNORE INTO clients(idno, name, address, legal_form) "
        "VALUES (?, ?, ?, ?)",
        (card["idno"], card["denumire"], card["adresa"], card["forma_juridica"]),
    )
```

### Delphi — [`crm_delphi/uContragenti.pas`](crm_delphi/uContragenti.pas)

```pascal
var
  Client: TContragentiClient;
  Card: TCounterpartyCard;
begin
  Client := TContragentiClient.Create;
  try
    Client.LauncherExe := 'Contragenti.exe';      // или путь к company_search.py
    if Client.Pick('UNISIM', Card) then
      MyDB.AddFromCard(Card, NewId);              // см. uClientsDB.pas
  finally
    Client.Free;
  end;
end;
```

### C++ — [`sdk/cpp/contragenti_sdk.h`](sdk/cpp/contragenti_sdk.h)

```cpp
#include "contragenti_sdk.h"

ContragentiCard card;
if (PickCounterparty(L"Contragenti.exe", L"UNISIM", L"ru", 300000, card)) {
    db.Insert(card.idno, card.denumire, card.adresa, card.formaJuridica);
}
```

Разбор аргументов, `CreateProcess`/`subprocess`, ожидание файла и парсинг
XML уже сделаны в каждой обёртке — самим писать это не нужно, только
подставить свои `INSERT`.

---

## 4. Готовое приложение целиком, если нужен образец «под ключ»

**`crm_delphi/`** — не просто SDK, а полностью рабочее demo-CRM приложение
(Delphi VCL, интерфейс в стиле EspoCRM, SQLite): кнопка «Создать клиента» →
запуск Contragenti → сохранение карточки → список с дедупликацией. Его
можно:

- изучить как образец «от кнопки до строки в БД» (`uMainForm.pas` →
  `OnAddClick` → `FCli.Pick` → `FDB.AddFromCard`);
- скомпилировать (`crm_delphi/build.bat`, нужен RAD Studio/dcc32) и
  запустить бок о бок с Contragenti — оно ставится вместе в один
  MSI-инсталлятор (`setup.py`, каталог `DemoCRM/` внутри установки);
- прогнать через встроенный самотест (`ContragentiCRM.exe --gui-test`,
  без дисплея не работает, но не требует внешней автоматизации) — отчёт
  и все скриншоты собираются в один HTML-файл
  (`crm_delphi/act_testirovaniya.html`).

---

## 5. Особенности, которые важно не сломать при доработке

- **reCAPTCHA портала.** Форма `date.gov.md` защищена невидимой капчей —
  запросы должны идти через настоящий видимый Chrome (управляется через
  Selenium), не headless и не через `curl`/`requests`. Обходить капчу
  нельзя и не нужно: если она показалась, дождись решения пользователем
  или используй `--auto-pick` с локальным кэшем (см. ниже) — обходных
  путей в коде намеренно нет.
- **`--auto-pick` сначала проверяет локальную базу.** Если компания уже
  когда-то была найдена (лежит в `companies.db`), `--auto-pick` берёт её
  оттуда и не трогает портал — так автотесты не упираются в капчу при
  частых прогонах. На реальный портал `--auto-pick` идёт только для
  компаний, которых в кэше ещё нет.
- **Дедупликация — всегда по IDNO**, не по названию (названия в реестре
  пишутся с вариациями регистра/диакритики).
- **Кодировка — UTF-8** везде: XML, SQLite, консольный вывод. На Windows
  файлы с кириллицей обязаны иметь UTF-8 BOM для компиляторов, которые
  этого требуют (Delphi/dcc32); для Python/C++ это не нужно.
- **Никаких модальных окон** в demo-CRM — если дорабатываешь `crm_delphi`,
  используй строку сообщений внизу окна (`Say(mkOk/mkWarn/mkErr, …)`) и
  `Application.OnException`, а не `MessageBox`/`ShowMessage`: модальные
  диалоги блокируют автоматизацию и headless-тесты.
