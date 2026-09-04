# Demo CRM — SDK-интеграция с Contragenti

Демонстрационное CRM-приложение на **Delphi 10.2 Tokyo** (VCL + FireDAC/SQLite),
которое ведёт свою личную базу клиентов и заводит новых контрагентов, вызывая
приложение **Contragenti**: то открывается на поиске по государственному
реестру date.gov.md, а после выбора возвращает XML полной карточки.

```
CRM  ──запуск с фильтром──►  Contragenti (поиск в date.gov.md)
                                     │ пользователь выбирает контрагента
CRM  ◄──── XML карточки ──────────────┘
  └─ разбор XML → запись в личную SQLite (дедупликация по IDNO)
```

Так CRM не знает ничего о reCAPTCHA, Selenium и структуре портала — вся эта
работа остаётся внутри Contragenti, а наружу отдаётся простой XML-контракт.

---

## Интерфейс — как у бесплатной EspoCRM

Окно повторяет тему «Espo» (палитра и размеры взяты из исходников
EspoCRM, `frontend/less/espo`): левая навигация 232 px с пунктами
Главная / Клиенты / Контакты / Лиды / Сделки / Календарь / Настройки
(активный пункт `#dee1e7`), верхняя полоса с глобальным поиском, «+»
(быстрое создание), уведомлениями и пользователем; заголовок раздела
с синей кнопкой `btn-primary` (`#5589ca`) «Создать клиента», строка
фильтров (пресет «Все / Добавлены сегодня / С юридическим адресом» +
поиск), белая таблица с чекбоксами и приглушёнными заголовками
колонок, панель «Обзор» выбранной записи в две колонки label/value,
дашлеты на «Главной». Рабочий раздел — «Клиенты»; остальные пункты
показаны для вида навигации. Строка сообщений внизу использует цвета
`label-state` EspoCRM (primary / success / warning / danger).

## Из чего состоит

| Файл | Назначение |
|---|---|
| `uGuiSelfTest.pas` | встроенный GUI-самотест: ведёт форму по шагам, снимает её через `GetFormImage`, пишет `report.html` |
| `uContragenti.pas` | **SDK-модуль**: класс `TContragentiClient` — запуск Contragenti в режиме выбора, ожидание, разбор XML в запись `TCounterpartyCard`. Не зависит от VCL. |
| `uClientsDB.pas` | Личная база клиентов на SQLite через FireDAC (движок слинкован статически — внешняя `sqlite3.dll` не нужна). Дедупликация по IDNO. |
| `uMainForm.pas` | Главное окно (список клиентов, кнопки, поиск). Интерфейс строится в коде. |
| `ContragentiCRM.dpr` | Точка входа: GUI и два headless-режима. |
| `build.bat` | Сборка консольным `dcc32.exe` без открытия IDE. |
| `sample_card.xml` | Эталонная карточка Contragenti — для проверки без запуска GUI. |

---

## Сборка

Нужна установленная RAD Studio 10.2 Tokyo (переменная `BDS` или путь по
умолчанию в `build.bat`).

```bat
build.bat
```

Получится `ContragentiCRM.exe`. В IDE проект тоже открывается — файлы `.pas`
самодостаточны, форма создаётся кодом, `.dfm` не нужен.

> Исходники сохранены в UTF-8 **с BOM** — иначе `dcc32` читает их как ANSI и
> портит кириллические строки в интерфейсе.

---

## Запуск

```bat
ContragentiCRM.exe                     графический интерфейс
ContragentiCRM.exe --import card.xml   импорт карточки из XML (без окна)
ContragentiCRM.exe --selftest          проверка базы и разбора XML
ContragentiCRM.exe --gui-test [dir]    GUI-самотест со снимками и report.html
```

Интерфейс без модальных окон: все сообщения выводятся в строку внизу окна
и различаются цветом (серый — информация, зелёный — успех, янтарный —
предупреждение/запрос подтверждения, красный — ошибка). Настройки
раскрываются панелью внутри окна, удаление подтверждается повторным
нажатием «Удалить». Необработанные исключения тоже попадают в строку
сообщений (`Application.OnException`), а не в MessageBox.

`--gui-test` работает в отдельной базе `dir\test_clients.db`, рабочая
`clients.db` не затрагивается. Дисплей не нужен: форма рисуется в память.

**Кнопка «Добавить из реестра…»** запускает Contragenti с введённым фильтром,
ждёт выбора и заводит выбранного контрагента. Путь к `Contragenti.exe`
задаётся в «Настройки…» (по умолчанию ищется рядом и в
`%LOCALAPPDATA%\Contragenti`).

Личная база — `clients.db` рядом с программой, настройки — `crm.ini`.

---

## SDK: как встроить в своё приложение

```pascal
uses uContragenti;

var
  Cli: TContragentiClient;
  Card: TCounterpartyCard;
begin
  Cli := TContragentiClient.Create;
  try
    Cli.LauncherExe := 'C:\...\Contragenti.exe';
    Cli.Lang := 'ru';
    if Cli.Pick('UNISIM', Card) then
      // Card.Idno, Card.Denumire, Card.Adresa, Card.Administratori,
      // Card.Founders[], Card.Debts[] ...
    else
      ShowMessage('Отменено: ' + Cli.LastError);
  finally
    Cli.Free;
  end;
end;
```

`ParseCardXml` / `ParseCardFile` доступны отдельно — если XML уже получен
другим способом (например, через локальный HTTP-API Contragenti на порту 9393).

---

## Проверено

- `--selftest` — разбор XML и SQLite с дедупликацией: **PASS**
- `--import sample_card.xml` — карточка заведена (клиент #1), повторный
  импорт → **DUP** (дубликат по IDNO не создаётся)
- содержимое `clients.db` сверено независимо: все поля на месте
- GUI-режим запускается, окно и список отображаются, кириллица корректна
- `--gui-test shots_gui` — **16/16**: импорт двух карточек, дубликат,
  фильтр, панель настроек, удаление без выбора, двухшаговое удаление,
  затем **реальный вызов SDK**: настоящая кнопка «Добавить из реестра»
  запускает Contragenti (`python company_search.py --pick --auto-pick
  --shots-dir …`), тот возвращает XML, CRM сохраняет карточку; повторный
  вызов отсекается как дубликат. Contragenti сам снимает своё окно и
  страницы портала в каталог отчёта (`sdk_*.png`). Отчёт
  `shots_gui/report.html` со ссылками на `NN_*.png`.
- Тест выявил и помог исправить: ошибку `List(Filter)` (параметр
  задавался до SQL — исключение уходило в модальный MessageBox);
  падение Chrome 152 с опцией `excludeSwitches=enable-automation`;
  возврат карточки без деталей в auto-pick (поток поиска ещё закрывал
  Chrome, и дозагрузка деталей пропускалась).
- Портал date.gov.md после нескольких поисков подряд включает reCAPTCHA —
  auto-pick поэтому сначала берёт компанию из локальной базы-кэша
  Contragenti и идёт на портал только если её там нет. Капчу
  приложение не обходит: при таймауте Contragenti сохраняет снимок
  страницы (`sdk_0_portal_timeout.png`) и завершается без XML, CRM
  показывает янтарное «Выбор отменён».

Что **не** проверено вживую: полный цикл «кнопка → выбор в Contragenti → XML»
требует интерактивного выбора в окне Contragenti. Контракт проверен по обе
стороны — Contragenti пишет XML этого формата (`--pick --out`), CRM его
разбирает (эталон `sample_card.xml` получен из `build_card_xml`).

---

## Контракт XML

Contragenti в режиме `--pick --out file.xml` записывает:

```xml
<counterparty source="date.gov.md" idno="..." updated="...">
  <idno>...</idno>
  <denumire>...</denumire>
  <inregistrare>...</inregistrare>
  <forma_juridica>...</forma_juridica>
  <lichidata>...</lichidata>
  <adresa>...</adresa>
  <administratori>...</administratori>
  <founders>
    <founder name="..." share="..."/>
  </founders>
  <debts currency="MDL">
    <debt nr="..." type="..." sum="..."/>
  </debts>
  <details_text>...</details_text>
</counterparty>
```
