# Demo CRM для macOS — нативная версия в Xcode

Порт `crm_delphi/` на Swift 5.9 + AppKit по постановке
[PORT_MACOS_ru.md](../PORT_MACOS_ru.md), часть B. Та же база `clients.db`
(схема, миграции, канонические русские значения перечислений,
`SHA-256("crm:" + login + ":" + пароль)`), те же `lang.json` /
`processes.json` (читаются из `DemoCRM/` рядом с бандлом, иначе из
`Contents/Resources`), тот же контракт с Contragenti (запуск процесса
`--pick --out … --lang … [--q …] --no-server --no-tray`, таймаут 5 минут,
дедупликация по IDNO) и те же CLI-режимы, что у `ContragentiCRM.exe`.

Интерфейс собран целиком на AppKit (программно, без storyboard): панельная
раскладка VCL переносится на `NSView` один в один, перетаскивание на канбане,
схеме процесса, Ганте и в календаре, а также встроенный GUI-самотест идут
теми же методами, что и мышь. SwiftUI не используется. Сторонних пакетов
нет: SQLite3, CryptoKit, Compression, CoreGraphics/CoreText (PDF).

## Сборка

```bash
cd crm_macos
xcodebuild -project DemoCRM.xcodeproj -scheme "Demo CRM" -configuration Release build
```

Бандл: `build/…/Release/Demo CRM.app` (по умолчанию DerivedData; для
`-derivedDataPath build/DerivedData` — `build/DerivedData/Build/Products/Release/`).
Проект описан в `project.yml`; после добавления файлов — `xcodegen generate`
(готовый `DemoCRM.xcodeproj` лежит в репозитории, xcodegen для сборки не нужен).
Подпись ad-hoc (`CODE_SIGN_IDENTITY=-`), sandbox выключен.

## Режимы командной строки

Бинарник: `"Demo CRM.app/Contents/MacOS/Demo CRM"`.

| Аргумент | Действие | Код выхода |
|---|---|---|
| — | окно CRM | — |
| `--selftest` | разбор встроенного `<counterparty>` + добавление/дубликат во временной БД | 0 / 1 |
| `--import file.xml` | импорт карточки в `clients.db` без окна | 0 добавлено/дубликат, 2 файла нет, 3 не разобран, 4 не сохранён |
| `--seed-demo [база]` | демо-данные, идемпотентно (счётчики совпадают с Windows: 17 клиентов, 20 контактов, 12 лидов, 22 сделки, 21 позиция, 23 заказа, 41 строка, 124 задачи, 10 проектов) | 0 / 2 |
| `--dml-test` | seed + CRUD всех сущностей, проводка, конвертация, отчёты (110 проверок) | 0 / 1 |
| `--gui-test [каталог] [launcher]` | сценарий из 81 шага со снимками и `report.html`; реальный вызов Contragenti | 0 / 1 / 2 |

Язык интерфейса — `defaults read md.una.contragenti.democrm Language`
(`ro`/`en`/`ru`), флага `--lang` нет.

## Где данные

Рядом с бандлом в `DemoCRM/` (`clients.db`, `crm.ini`, `reports/`), если
туда можно писать и бандл не в `/Applications` или `~/Applications`; иначе
`~/Library/Application Support/Contragenti/DemoCRM/` (при первом запуске туда
копируются `clients.db` и `crm.ini` из установки). GUI-самотест работает в
своей базе `<каталог>/test_clients.db`.

## Проверка

```bash
APP="build/DerivedData/Build/Products/Release/Demo CRM.app/Contents/MacOS/Demo CRM"
"$APP" --selftest                       # CRM self-test: True
"$APP" --seed-demo /tmp/demo.db         # счётчики как на Windows
"$APP" --dml-test                       # DML-тест: 110 проверок, FAIL = 0
"$APP" --import ../crm_delphi/sample_card.xml   # OK, второй раз — DUP
"$APP" --gui-test "$PWD/gui_test"       # GUI self-test: 81/81 — True, gui_test/report.html
```

Модальных окон нет: `grep -r "NSAlert\|\.alert(" Sources` пуст. Сообщения —
в цветной строке внизу, удаление — повторным нажатием, редакторы — панели
внутри страниц, ошибки SQLite — в ту же строку.

Снимки чужих окон (Contragenti/Chrome) во время вызова SDK делаются через
`CGWindowListCreateImage` и требуют права «Запись экрана» для процесса;
без него в отчёт попадают только снимки самой CRM и снимки, которые
Contragenti пишет по `--shots-dir`.
