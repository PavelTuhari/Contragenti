# Постановка: Contragenti и Demo CRM для macOS

Это задание для ИИ-модели (Claude Code или аналог), запущенной **на Mac с
клоном этого репозитория и установленным Xcode**. Цель — получить на macOS
полный аналог того, что на Windows даёт `Contragenti-<версия>-setup.exe`:
утилита Contragenti, мастер настройки, Demo CRM, SDK, стартовые базы, ярлыки,
самообновление — и **нативную Demo CRM для macOS, собранную в Xcode**, по
исходникам Delphi из `crm_delphi/`.

Документ самодостаточен: все факты о том, как устроена Windows-версия и что
именно делает Delphi-CRM, собраны здесь, с указанием файлов и строк, где это
можно перепроверить. Не додумывай поведение — открой указанный файл.

Язык проекта: код и комментарии по-русски, интерфейс на трёх языках
(ro / en / ru, румынский по умолчанию), дедупликация всегда по IDNO,
никаких модальных окон в CRM (см. §6.4). Всё, что здесь помечено
**«обязательно»**, — часть приёмки.

---

## 0. Как работать (порядок и правила)

1. Прочитай этот файл целиком, затем `INTEGRATION.md`, `API_ru.md`,
   `crm_delphi/README_ru.md`, `AGENTS.md` (правила репозитория).
2. Ничего из Windows-части не ломай: `setup.py`, `installer_exe.py`,
   `setup_wizard.py`, `tools/*.py`, `crm_delphi/*` остаются как есть и
   продолжают собираться на Windows. Всё для Mac — в **новых** файлах и
   каталогах (§8), плюс минимальные правки в `company_search.py` только там,
   где это явно указано (§2.3).
3. Работай по фазам (§9); после каждой фазы — коммит с осмысленным
   сообщением по-русски, `git push`. Перед пушем — проверка диффа на секреты
   (пароли, ключи, `Bearer`, `api_key`), как в `AGENTS.md`.
4. Не пиши `.md`-документы, кроме тех, что перечислены в §8, и не создавай
   абстракций «на будущее». Три похожие строки лучше преждевременного
   обобщения.
5. Если что-то из постановки на macOS невозможно (нет API, ограничение
   Gatekeeper и т.п.) — сделай всё остальное полностью и явно напиши в
   `INSTALL_MACOS_ru.md`, что и почему выпущено, — не сокращай объём молча.

---

## 1. Что есть сейчас (Windows) — карта компонентов

| Компонент | Реализация | Где |
|---|---|---|
| **Contragenti** — утилита поиска | Python 3.12 + Tkinter, Selenium + Chrome, SQLite; локальный HTTP-API на `127.0.0.1:9393` | `company_search.py` (один файл) |
| **Мастер настройки** («Contragenti — настройка и обновление») | Python + Tkinter; паспорт системы, Chrome, Python, обновление из GitHub по `release.json`, стартовая база, `crm.ini`, seed, самопроверка, отчёт | `setup_wizard.py` |
| **Установщик** | Тонкий PyInstaller-exe: качает `release/Contragenti-<v>-app.zip`, sha256, распаковка, ярлыки, «Программы и компоненты» | `installer_exe.py`, `tools/build_exe_installer.py` |
| **MSI** | cx_Freeze `bdist_msi` — полностью автономный вариант | `setup.py` |
| **Demo CRM** | Delphi 10.2 (VCL + FireDAC/SQLite), один exe, формы строятся в коде, без `.dfm` | `crm_delphi/` |
| **SDK** | Python и C++ обёртки вызова Contragenti | `sdk/python/contragenti_sdk.py`, `sdk/cpp/contragenti_sdk.h` |
| **Манифест релиза** | версия, ссылки, размеры, sha256, список компонентов | `release.json` |
| **Стартовые базы** | `companies.db` (~219 компаний date.gov.md) из `data/companies_seed.zip`; `DemoCRM/clients.db` генерируется `ContragentiCRM.exe --seed-demo` при сборке | `setup.py:41-73` |

### 1.1. Что делает `setup.py` при сборке (что должно оказаться в установке)

`build/exe.win-amd64-3.12/` после `python setup.py build_exe`
(`setup.py:101-171`):

- `Contragenti.exe` (замороженный `company_search.py`), `ContragentiSetup.exe`
  (`setup_wizard.py`), `Demo CRM.exe` (обёртка `run_demo_crm.py`, только
  чтобы у CRM был свой ярлык);
- `companies.db` — стартовая база; `data/companies_seed.zip` — запасная копия;
- `DemoCRM/ContragentiCRM.exe`, `DemoCRM/clients.db` (демо-фирма, уже
  засеянная), `DemoCRM/lang.json`, `DemoCRM/processes.json`,
  `DemoCRM/sample_card.xml`, `DemoCRM/README_ru.md`;
- `sdk/`, инструкции `*.md`, `VERSION`, `release.json`, `app_icon.ico`.

### 1.2. Где лежат данные на Windows (правило, которое надо повторить)

Программы пишут **рядом с собой**, если туда можно писать и это не
`Program Files` (портативная копия, запуск из исходников). Иначе —
в профиль пользователя. Правило действует и под администратором, чтобы у
админа и обычного пользователя не было разных баз
(`company_search.py:87-110`, `crm_delphi/uClientsDB.pas:87-118`,
`run_demo_crm.py:37-47`, `setup_wizard.py:295-331`):

| Данные | Windows | **macOS (делай так)** |
|---|---|---|
| `companies.db`, `tms_config.json`, `settings.json` | `%LOCALAPPDATA%\Contragenti\` | `~/Library/Application Support/Contragenti/` |
| `clients.db`, `crm.ini`, `reports/` Demo CRM | `%LOCALAPPDATA%\Contragenti\DemoCRM\` | `~/Library/Application Support/Contragenti/DemoCRM/` |
| Логи и отчёты мастера (`install.log`, `install_report_*.txt`) | `%LOCALAPPDATA%\Contragenti\logs\` | `~/Library/Logs/Contragenti/` |
| Язык Demo CRM | `HKCU\Software\DemoCRM\Language` (`ro`/`en`/`ru`) | `UserDefaults` домена `md.una.contragenti.democrm`, ключ `Language` |
| Язык мастера | `HKCU\Software\DemoCRM\Language` (тот же ключ) | тот же `UserDefaults`-ключ, читать через `defaults read` из Python |

При первом запуске из установки в профиль **копируются** стартовые
`companies.db` и `clients.db` (если их там ещё нет) — пользователь сразу
видит данные. Переустановка данные не трогает.

---

## 2. Часть A — установка Contragenti на macOS

### 2.1. Форма поставки

Собрать **два** артефакта (оба публикуются в `release/`, ссылки и sha256 —
в `release.json`, см. §7):

1. **`Contragenti-<версия>-macos.pkg`** — установщик `pkgbuild`/`productbuild`
   в `/Applications/Contragenti/` (аналог MSI: всё внутри, без интернета).
2. **`contragenti-macos-install.sh`** — тонкий скрипт-установщик (аналог
   `setup.exe`): скачивает `Contragenti-<версия>-macos-app.zip` по
   `release.json`, проверяет sha256, распаковывает в
   `~/Applications/Contragenti/` (без `sudo`) или, с `--system`, в
   `/Applications/Contragenti/` (спросит пароль через `sudo`), затем
   запускает мастер. Запуск одной строкой:
   `curl -fsSL https://raw.githubusercontent.com/PavelTuhari/Contragenti/main/release/contragenti-macos-install.sh | bash`.
   Флаги: `--dir PATH`, `--no-wizard`, `--no-shortcuts`, `--lang ro|en|ru`,
   `--offline-payload FILE.zip` (взять готовый zip с диска — для тестов).

Что внутри `Contragenti-<версия>-macos-app.zip` (и в `.pkg`):

```
Contragenti/
  Contragenti.app/            ← утилита (py2app или PyInstaller --windowed .app bundle)
  Contragenti Setup.app/      ← мастер настройки (тот же способ сборки)
  Demo CRM.app/               ← нативная CRM из Xcode (Часть B)
  companies.db  data/companies_seed.zip
  DemoCRM/clients.db  DemoCRM/lang.json  DemoCRM/processes.json  DemoCRM/sample_card.xml
  sdk/  *.md  VERSION  release.json  app_icon.icns
```

Python внутри `.app`-бандлов должен быть **встроен** (py2app/PyInstaller
кладут интерпретатор и `tkinter` в бандл): пользователю не нужен ни
Homebrew, ни системный Python — ровно как на Windows, где exe работают без
Python. Chrome нужен (Selenium Manager сам скачает chromedriver).
Архитектура: universal2, либо две сборки (arm64 + x86_64) — тогда два zip и
два набора полей в `release.json` (`macos_arm64_*`, `macos_x86_64_*`).

**Обязательно:** `Contragenti.app` должен запускаться двойным щелчком после
`xattr -d com.apple.quarantine` (подписи Apple Developer ID нет — как и
code-signing на Windows; в `INSTALL_MACOS_ru.md` описать «Открыть в обход
Gatekeeper»: правый клик → Открыть). Если есть `codesign --sign -`
(ad-hoc) — применить, это убирает часть предупреждений.

### 2.2. Ярлыки и «Программы и компоненты» — аналоги

| Windows | macOS |
|---|---|
| Ярлыки на рабочем столе, папка в «Пуск» | Симлинки `~/Applications/Contragenti/*.app` → `/Applications` (или `~/Applications`) + Launchpad подхватывает сам; опционально `open -a` в Dock через `defaults write com.apple.dock persistent-apps` — **не обязательно** |
| Запись в «Программы и компоненты» + `--uninstall` | `Contragenti Setup.app --uninstall` удаляет каталог установки, симлинки, `LaunchAgents`; **данные в `~/Library/Application Support/Contragenti` спрашивает** (в CLI — флаг `--purge-data`) |
| Автозапуск мастера после установки | `.sh` запускает `open "Contragenti Setup.app" --args --lang <lang>`; `.pkg` — postinstall-скрипт делает то же |

### 2.3. Правки в `company_search.py` (минимальные, только эти)

`company_search.py` уже кроссплатформенный (README: macOS/Windows/Linux). Что
надо добавить, не ломая Windows:

1. `_data_dir()` (строки 87-110): на `sys.platform == "darwin"` при
   невозможности писать рядом с программой (или если программа внутри
   `/Applications`/`~/Applications` или `.app`-бандла) использовать
   `~/Library/Application Support/Contragenti`, а не `LOCALAPPDATA`
   (его на Mac нет — сейчас упадёт в `~/Contragenti`). То же — для
   `SETTINGS_PATH`/`TMS_CONFIG_PATH` (они идут через `DATA_DIR`, менять не
   надо).
2. `_app_dir()` (68-73): для `.app`-бандла `sys.executable` лежит в
   `Contents/MacOS/`, а данные-соседи (`companies.db`) — в
   `Contents/Resources/`. Учесть: если `sys.frozen` и путь содержит
   `.app/Contents/MacOS`, считать «каталогом программы» родителя `.app`
   (там лежат `companies.db`, `DemoCRM/`, `sdk/`).
3. Самообновление из git (`_git_repo_dir`, `GitUpdateWorker`) уже работает
   на Mac при запуске из клона — **не трогать**; для `.app`-бандла оно
   отключено по построению (`sys.frozen`), обновление бандла делает мастер
   (§3.4).
4. Трей (`pystray`) на macOS работает через `AppKit`; проверить, что
   `--no-tray` не нужен по умолчанию; если иконка в строке меню ведёт себя
   плохо — включать трей на Mac только по флагу `--tray`, а `pystray`
   оставить в `requirements.txt`.
5. Пути к Chrome: Selenium сам найдёт `/Applications/Google Chrome.app`;
   в `run_selftest()` и мастере проверять именно этот путь.

Всё остальное (порт 9393, `/pick`, `/open`, `/card`, `/search`, `/health`,
XML-карточка, три языка, источники date.gov.md/data2b.md/БД) работает как
есть и **меняться не должно** — это контракт для CRM и SDK.

---

## 3. Часть A — мастер настройки для macOS

`setup_wizard.py` — Windows-only (`winreg`, `ctypes.windll`, PowerShell,
winget, `msiexec`). Для Mac сделать **`setup_wizard_macos.py`** (тот же
Tkinter-стиль, те же три языка, та же структура шагов и тот же формат
`install.log`/отчёта), не копируя Windows-ветки. Общие функции
(`_urlopen` с certifi-фолбэком, чтение `release.json`, сверка sha256,
слияние `companies_seed.zip` в `companies.db` по IDNO, генерация отчёта)
вынести в `setup_common.py` и **импортировать из обоих мастеров** — это
единственное допустимое изменение в `setup_wizard.py` (замена локальных
функций на импорт, поведение не меняется).

### 3.1. Шаги (одинаковые ключи `st_*`, см. `setup_wizard.py:105-115`)

| Шаг | Windows | macOS |
|---|---|---|
| `st_passport` — технический паспорт | ОС, сборка, память, диск, Chrome, Python, версии файлов, размер баз | `sw_vers`, `uname -m`, память (`sysctl hw.memsize`), диск (`shutil.disk_usage`), Chrome (`/Applications/Google Chrome.app/Contents/Info.plist` → `CFBundleShortVersionString`), Python, версии файлов, счётчики строк в базах |
| `st_chrome` | реестр и папки | `Info.plist`; если нет — кнопка «Скачать Chrome» (`open https://www.google.com/chrome/`) |
| `st_python` | winget → Store → python.org | Нужен только для `sdk/python`. Порядок: `python3` уже есть (Xcode CLT / Homebrew) → `brew install python@3.12` (если есть `brew`) → официальный `python-3.12.x-macos11.pkg` с python.org с проверкой подписи (`pkgutil --check-signature`, издатель «Python Software Foundation»), тихая установка `installer -pkg … -target CurrentUserHomeDirectory`. `--no-python` пропускает |
| `st_net` — доступ к GitHub | `release.json` | то же, через `setup_common` |
| `st_release` — новая версия | сравнить с `VERSION`, предложить MSI | сравнить с `VERSION`; предложить скачать `Contragenti-<v>-macos.pkg` **или** обновить на месте (§3.4) |
| `st_update` — компоненты | по `components` из `release.json` | то же: список `components` **плюс** (новое) `macos_components` — файлы `Demo CRM.app` не обновляются пофайлово; для CRM обновление = скачать `Contragenti-<v>-macos-democrm.zip` и заменить бандл целиком |
| `st_db` — стартовая база | `companies_seed.zip` → merge по IDNO | то же |
| `st_config` | `crm.ini`, `HKCU\Software\DemoCRM\Language`, `logs\` | `crm.ini` в `~/Library/Application Support/Contragenti/DemoCRM/` с `launcher=<путь к Contragenti.app/Contents/MacOS/Contragenti>` и `lang`; язык — `defaults write md.una.contragenti.democrm Language <ro/en/ru>`; каталог логов |
| `st_seed` | `ContragentiCRM.exe --seed-demo` | `"Demo CRM.app/Contents/MacOS/Demo CRM" --seed-demo` (CLI-режим бандла, §6.5) |
| `st_shortcuts` | ярлыки | симлинки/наличие в `/Applications` |
| `st_selftest` | `--selftest` обеих программ | то же |

Режимы, как у Windows-мастера: окно (по умолчанию), `--check` без окна,
`--lang`, `--offline`, `--no-python`, `--no-seed`, `--uninstall [--silent]
[--purge-data]`, `--auto --shot файл.png` (снимок окна для акта —
`screencapture -l <windowid>` или через Tk `winfo id`).

### 3.2. Отчёт об ошибках

Формат `install_report_<дата>.txt` (паспорт + шаги + лог) сохранить как в
`setup_wizard.py:883` и далее; вместо «событий Windows Installer» —
последние строки `log show --predicate 'process == "installer"' --last 1h`
(если установка была через `.pkg`) или ничего. Кнопки «Сообщить на GitHub»
(`issues/new` с телом) и «Отправить на e-mail» (`mailto:`) — те же, через
`webbrowser`.

### 3.3. Ключ `Language`

Windows-мастер и Delphi-CRM делят один ключ реестра. На Mac делят один
`UserDefaults`-домен `md.una.contragenti.democrm`. Мастер (Python) читает
и пишет через `subprocess.run(["defaults", "read"/"write", …])` — без
PyObjC-зависимости.

### 3.4. Обновление бандлов на месте

`st_release`: если в `release.json` версия новее и есть
`macos_app_zip_url`, предложить «Обновить»: скачать zip во временный
каталог, проверить sha256, остановить работающие `Contragenti.app` /
`Demo CRM.app` (`pkill -f`), заменить содержимое каталога установки
(кроме баз и `crm.ini` — они и так в профиле), перезапустить мастер.
Это аналог того, что на Windows делает тонкий `setup.exe` при
переустановке.

---

## 4. Часть B — Demo CRM для macOS в Xcode: общие требования

**Цель:** нативное приложение `Demo CRM.app` (Swift 5.9+, SwiftUI +
AppKit где нужно, минимальная macOS 13), функционально равное
`crm_delphi/ContragentiCRM.exe`, с **той же базой `clients.db`** (схема §5),
**теми же `lang.json` и `processes.json`** (читаются как есть из
`DemoCRM/` рядом с бандлом или из `Contents/Resources` — приоритет у
внешнего файла, чтобы мастер мог обновлять переводы без пересборки), **тем
же контрактом с Contragenti** (§6.3) и **тем же набором CLI-режимов** (§6.5).

Проект: `crm_macos/DemoCRM.xcodeproj` (или `Package.swift` + `xcodegen` —
на выбор, но `xcodebuild -scheme "Demo CRM" -configuration Release build`
должен собирать бандл без ручных шагов). Зависимости: только системные
фреймворки (`SQLite3` через `import SQLite3`, `Foundation`, `AppKit`,
`SwiftUI`, `PDFKit`, `Compression`/`libz`). Сторонних пакетов не добавлять —
Delphi-версия обходится VCL + FireDAC + `System.Zip`, и xlsx/pdf там
написаны вручную (`uXlsx.pas`, `uPdf.pas`); повтори это (xlsx =
zip с XML-файлами, `inlineStr`; PDF через `PDFKit`/`NSPrintOperation`
допустим — это проще, чем ручной CIDFont, результат тот же).

Стиль: EspoCRM-подобная палитра из `uEspoTheme.pas` (боковая панель,
плоские кнопки, цветные бейджи стадий) — перенести цвета константами.

---

## 5. Схема `clients.db` (обязательно один в один)

DDL: `crm_delphi/uClientsDB.pas:148-164` (`clients`) и
`crm_delphi/uCrmData.pas:357-392` (остальное), миграции
`uCrmData.pas:493-543`. Внешних ключей нет (ссылки — обычные INTEGER),
единственный индекс `ix_clients_denumire`; `clients.idno` и `users.login`
— UNIQUE.

| Таблица | Колонки |
|---|---|
| `clients` | `id` PK AUTOINCREMENT; `idno` TEXT UNIQUE; `denumire` TEXT NOT NULL; `forma_juridica`, `inregistrare`, `lichidata`, `adresa`, `administrator`, `details`, `source` TEXT; `added_at` TEXT DEFAULT `datetime('now','localtime')`; миграцией: `client_type`, `phone`, `email`, `notes`, `contact_person` TEXT |
| `contacts` | `id`; `name` NOT NULL; `client_id` INTEGER; `position`, `phone`, `email`, `notes` |
| `leads` | `id`; `name` NOT NULL; `company`, `status`, `source`, `phone`, `email`, `notes`; `client_id`; `created_at` |
| `deals` | `id`; `title` NOT NULL; `client_id`; `stage`; `amount` REAL 0; `close_date`; `notes`; `created_at` |
| `items` | `id`; `code`; `name` NOT NULL; `kind`; `unit_`; `price` REAL 0; `vat` REAL 20; `stock` REAL 0; `notes` |
| `orders` | `id`; `number` NOT NULL; `order_date`; `client_id`; `kind`; `status`; `total` REAL 0; `advance` REAL 0; `paid` REAL 0; `due_date`; `ship_date`; `notes`; `posted` INTEGER 0; `erp_batch`; `erp_sent_at`; `created_at`; миграцией: `project_id` INTEGER |
| `order_lines` | `id`; `order_id` INTEGER NOT NULL; `item_id` INTEGER NOT NULL; `qty` REAL 1; `price` REAL 0; `sum` REAL 0 |
| `users` | `id`; `login` TEXT UNIQUE NOT NULL; `pass_hash` TEXT NOT NULL; `full_name`; `created_at` |
| `tasks` | `id`; `subject` NOT NULL; `kind`; `due_at`; `client_id`; `deal_id`; `done` INTEGER 0; `notes`; `created_at`; миграцией: `project_id`, `stage`, `priority`, `assignee`, `plan_start`, `hours_plan` REAL, `hours_fact` REAL, `depends_on` INTEGER, `seq` INTEGER |
| `projects` | `id`; `name` NOT NULL; `client_id`; `kind`; `status`; `tender_no`; `tender_deadline`; `budget` REAL 0; `prepay_pct` REAL 0; `prepaid` REAL 0; `paid` REAL 0; `start_date`; `due_date`; `manager`; `notes`; `created_at` |

Правила, которые CRM на Mac обязана повторить:

- **Миграции** — `PRAGMA table_info` → `ALTER TABLE … ADD COLUMN` для
  недостающих колонок; после миграции `tasks.stage` заполняется из `done`,
  `tasks.priority = 'Обычный'`, `tasks.plan_start = due_at`. База, которую
  создала Delphi-версия, должна открываться Mac-версией **и наоборот**.
- **Пароль**: `SHA-256("crm:" + lower(login) + ":" + password)`
  (`uCrmData.pas:518-521`); при пустой `users` создаётся `admin/admin`.
- **Значения перечислений хранятся по-русски** (канонические
  `ENUM_*` в `uCrmData.pas:150-167`), а переводы в `lang.json → enums`
  позиционные — порядок массива обязан совпадать с каноническим. Не
  переводить значения в БД.
- **Дедупликация клиентов** — по `idno` (`uClientsDB.pas:237-271`):
  есть такой `idno` → `duplicate`, вставки нет; пустой `idno` — вставлять
  всегда; при исключении UNIQUE на вставке — перепроверить и вернуть
  `duplicate`.
- **Проведение заказа** (`Провести`): только в статусе Выполнен/Оплачен и
  один раз (`posted=1`); Продажа → `items.stock −= qty`, Производство →
  `stock += qty`, Услуга → без изменений (`uCrmData.pas`, поиск
  `PostOrder`).
- **Конверсия лида** «В клиенты» (`uCrmData.pas:967-975`, `ConvertLead`):
  всегда вставляет нового клиента (`denumire` = компания лида или его имя,
  `contact_person` = имя, `phone`/`email` из лида, `client_type = 'Клиент'`,
  `source = 'lead'`), проставляет `leads.client_id` и статус
  `Конвертирован`; повторный вызов — «уже конвертирован», без вставки.

---

## 6. Часть B — экраны, интеграция, i18n, CLI

### 6.1. Экраны (все — в одном окне, боковая навигация; `uMainForm.pas:398-426`)

| Раздел | Что показывает | Действия |
|---|---|---|
| **Рабочий стол** (`uWorkspace.pas`) | 8 плиток стадий: Предложение, Переговоры, Готово к заказу, Ожидает аванс, В работе/производство, Готово к отгрузке, Отгружено — ждём оплату, Закрыто; в каждой — количество, сумма, просрочено; полоса ERP (проверить связь, отправить базу); сводка, последние заказы, ближайшие задачи | клик по плитке → раздел с фильтром |
| **Канбан** (`uKanban.pas`, `uBoardCards.pas`) | 5 досок: Заказы (5 колонок процесса), Сделки (5 стадий воронки), Задачи (Просрочено/Сегодня/Позже/Выполнено), Проекты (9 статусов), Задачи проекта (5 стадий + выбор проекта) | перетаскивание с анимацией, кнопки ←/→, двойной клик — карточка |
| **Бизнес-процесс** (`uProcess.pas`) | диаграмма дорожек из `processes.json`: узлы `start/step/gate/end`, рёбра, владелец, SLA | клик по узлу — его карточки и описание; двойной клик — раздел с фильтром; перетаскивание карточки между узлами меняет стадию; описание редактируется и **сохраняется в processes.json** |
| **План работ (Гант)** (`uGantt.pas`) | строки = заказы (план/факт, красный просрочен, зелёный закрыт, линия «сегодня»), строки производства раскрываются в операции; режим «Проекты и задачи» со стрелками зависимостей | перетаскивание — сдвиг, за край — растяжение |
| **Клиенты** | список (Название, IDNO, Форма, Адрес, Руководитель, Добавлен); пресеты Все / Добавлены сегодня / С юр. адресом; поиск по названию/IDNO/руководителю | **«Создать из реестра»** (§6.3), Удалить, Обновить; карточка: поля реестра только чтение + редактируемые Тип/Телефон/E-mail/Контактное лицо, Сохранить |
| **Контакты, Лиды, Сделки, Номенклатура, Заказы, Проекты, Календарь** (`uEntityPage.pas`) | общая страница: заголовок, Создать/Обновить/Удалить, пресеты, поиск, список, встроенный редактор с типизированными полями (text/memo/number/money/date/enum/lookup/bool) | Лиды → «В клиенты»; Календарь → «Выполнено», переключатель «Календарь» (сетка месяца); Проекты → «Задачи проекта», «План (Гант)»; Заказы → панель строк `+ Строка`, `Убрать строку`, **`Провести`** |
| **Календарь-сетка** (`uCalendarView.pas`) | 7×6 месяц, ‹ › и Сегодня | перетаскивание задачи на другой день меняет `due_at`; двойной клик — задача |
| **Отчёты** (`uReports.pas`) | 6 отчётов: `process`, `receivables`, `sales_by_client`, `funnel`, `stock`, `projects`; предпросмотр таблицы | Excel / PDF в `<данные>/reports/<slug>_yyyy-mm-dd.xlsx|pdf`; «Открыть папку» |
| **Настройки** | путь к Contragenti, ERP url/key/client_id, язык, новый пароль | Сохранить → `crm.ini` + `UserDefaults` |
| **Вход** | панель поверх окна (не отдельное окно): пользователь, пароль, язык | неверный пароль — отказ; по умолчанию `admin/admin` |

### 6.2. `crm.ini` (`uMainForm.pas:1136-1176`)

```ini
[contragenti]
launcher=/Applications/Contragenti/Contragenti.app/Contents/MacOS/Contragenti
lang=ru
[erp]
url=http://127.0.0.1:9000
key=
client_id=demo-crm
```

Живёт в каталоге данных CRM (§1.2). `launcher` может указывать и на
`company_search.py` — тогда запускать `<dir>/.venv/bin/python` → `python3`.
Если `launcher` не задан, искать (`uMainForm.pas:1271-1291`, порядок):
`<app>/../Contragenti.app/Contents/MacOS/Contragenti`,
`<app>/../../Contragenti.app/…`, `<app>/../company_search.py`,
`/Applications/Contragenti/Contragenti.app/…`,
`~/Applications/Contragenti/Contragenti.app/…`; первый найденный — записать
в ini.

### 6.3. Интеграция с Contragenti — «Создать из реестра» (обязательно один в один)

Delphi **запускает процесс**, HTTP-API не использует
(`uMainForm.pas:1293-1335`, `uContragenti.pas:120-225`):

1. временный файл `$TMPDIR/contragenti_<tick>.xml`;
2. запуск `launcher --pick --out "<tmp.xml>" --lang <lang> [--q "<текст
   из поля поиска клиентов>"] --no-server --no-tray`;
3. ожидание завершения без блокировки UI, таймаут **5 минут** → убить
   процесс, сообщение «Истекло время ожидания»;
4. файла нет → «Контрагент не выбран» (это не ошибка); есть → разобрать
   UTF-8 XML, удалить файл;
5. `AddFromCard` → три исхода: добавлено / дубликат по IDNO / отмена — в
   строку сообщений.

Формат карточки — `INTEGRATION.md §2`, образец `crm_delphi/sample_card.xml`.
Маппинг (`uContragenti.pas:267-305` → `uClientsDB.pas:251-257`):

| XML | колонка `clients` |
|---|---|
| `<idno>` (или атрибут корня `idno`) | `idno` |
| `<denumire>` | `denumire` |
| `<forma_juridica>` | `forma_juridica` |
| `<inregistrare>` | `inregistrare` |
| `<lichidata>` | `lichidata` |
| `<adresa>` | `adresa` |
| `<administratori>` | `administrator` |
| `<details_text>` | `details` |
| `<founders>`, `<debts>` | разобрать в модель карточки, **в БД не хранятся** (как в Delphi) |
| — | `source` = атрибут корня `source` (в Delphi захардкожено `date.gov.md`; на Mac брать атрибут, по умолчанию `date.gov.md`) |

Корень обязан быть `<counterparty>`; карточка без `idno` и без
`denumire` отклоняется.

На Mac Contragenti сам решит открыть Chrome; CRM не должна ждать в
главном потоке (`Process` + `terminationHandler` или `async`).

### 6.4. i18n и стиль сообщений

- `lang.json`: ключи `_comment`, `default` (= `ro`), `languages[]`,
  `ro|en|ru → { strings: {…163 ключа}, enums: {…15 списков} }`; префиксы
  ключей: `app, btn, calendar, card, col, erp, gantt, kanban, login, msg,
  nav, preset, process, report, reports, settings, workspace`. Нет ключа —
  показать сам ключ (так делает Delphi). Файл берётся рядом с бандлом
  (`DemoCRM/lang.json`), иначе из `Contents/Resources`.
- `processes.json`: `{ processes: [ { id, title{ro,en,ru}, lanes[{title}],
  nodes[{id, kind, board?, col?, x, y, title, owner, desc, sla_days?}],
  edges[{from, to, label?}] } ] }` — три процесса: `sales_to_cash`
  (13 узлов), `tasks` (5), `project` (11). `board`/`col` связывают узел с
  доской канбана и её колонкой (0-based).
- **Никаких модальных окон**: сообщения — в цветную строку внизу окна
  (`Say(mkOk|mkWarn|mkErr)`), удаление — повторным нажатием «Удалить»,
  редакторы — встроенные панели. Это правило репозитория
  (`INTEGRATION.md §5`), оно же нужно для headless-тестов.

### 6.5. CLI-режимы бандла (`ContragentiCRM.dpr:319-362`) — обязательно

Бинарник `Demo CRM.app/Contents/MacOS/Demo CRM` принимает первый аргумент:

| Аргумент | Действие | Коды выхода |
|---|---|---|
| — | GUI | — |
| `--selftest` | разбор встроенного `<counterparty>` (denumire, idno, 1 founder, 1 debt) + во временной БД `AddFromCard` → added, повтор → duplicate, `Count = 1`; печать `[OK]/[FAIL]` и `CRM self-test: True/False` | 0 / 1 |
| `--import <file.xml>` | импорт карточки в `clients.db` без окна | 0 добавлено/дубликат, 2 файла нет, 3 не разобран, 4 не сохранён |
| `--seed-demo [dbPath]` | демо-данные (§6.6) | 0 / 2 |
| `--dml-test` | seed + полный CRUD во временной БД | 0 / 1 |
| `--gui-test [outDir] [launcher]` | сценарный прогон UI со снимками и `report.html` (§9, фаза 5) | 0 / 1 / 2 |

`--lang` флага нет — язык из `UserDefaults` (аналог реестра).

### 6.6. Демо-данные (`uTestData.pas:291-616`, идемпотентно)

15 клиентов + 2 партнёра; 20 контактов; 12 лидов; 12 сделок + по одной
тендерной на проект (10); 18 номенклатур + 3 проектных; 18 заказов
`0001…0018` (1–3 строки, всего 36) + производственный `PR-10xx` для каждого
проекта в статусе Производство/Сдача/Оплата/Закрыт (в демо-наборе таких 5,
по одной строке); 24 задачи (первые 4 выполнены) + задачи проектов из
11 шагов `PROJECT_STEPS` (шаг «аванс» пропускается при `prepay_pct = 0`;
проигранные тендеры — только 2 шага); 10 проектов. Авансы/оплаты/отгрузки
заполняются по статусу так, чтобы **все плитки рабочего стола были не
пустые**. Наборы названий/сумм — взять из `uTestData.pas` как есть, чтобы
базы, засеянные на Windows и на Mac, совпадали по содержанию.

**Эталон в репозитории** (оба файла отслеживаются git'ом, это вывод
`ContragentiCRM.exe --seed-demo` в пустую базу): `crm_delphi/clients.db` и
`crm_delphi/seed.log`. Ожидаемые счётчики `SELECT count(*)`:

| clients | contacts | leads | deals | items | orders | order_lines | tasks | projects | users |
|---|---|---|---|---|---|---|---|---|---|
| 17 | 20 | 12 | 22 | 21 | 23 | 41 | 124 (24 + 100 по проектам) | 10 | 9 (8 сотрудников демо-фирмы + `admin`) |

Строка из `seed.log`: `Добавлено: клиентов 17, контактов 20, лидов 12,
сделок 22, номенклатуры 21, заказов 23 (строк 41), задач 24, проектов 10
(задач по проектам 100), сотрудников 8`.

Счётчик `сотрудников` появился вместе с разделом «Сотрудники»
(см. [STAFF_ERP_ru.md](STAFF_ERP_ru.md)); девять остальных не менялись —
именно по ним и сверяются порты. Эталоны других режимов — `crm_delphi/st.log`
(`--selftest`) и `crm_delphi/dml_test.log` (`--dml-test`): Mac-версия
должна печатать те же `[OK]`-строки по смыслу. Стартовая база компаний
Contragenti — `data/companies_seed.zip` (внутри `companies.db`, 219
записей); отдельно `companies.db` в репозитории не хранится.

---

## 7. `release.json` и `tools/make_release.py` — что добавить

Не ломая существующие поля (`msi_*`, `exe_*`, `app_zip_*`, `update_zip*`,
`components`), добавить:

```json
"macos_pkg_url": "…/release/Contragenti-<v>-macos.pkg", "macos_pkg_size": 0, "macos_pkg_sha256": "…",
"macos_app_zip_url": "…/release/Contragenti-<v>-macos-app.zip", "macos_app_zip_size": 0, "macos_app_zip_sha256": "…",
"macos_install_sh": "…/release/contragenti-macos-install.sh",
"macos_democrm_zip_url": "…/release/Contragenti-<v>-macos-democrm.zip", "macos_democrm_zip_size": 0, "macos_democrm_zip_sha256": "…"
```

Скрипт сборки на Mac — `tools/build_macos.sh` (или `.py`): собирает оба
`.app` из Python (py2app/PyInstaller), `xcodebuild` для CRM, засевает
`DemoCRM/clients.db` через `"Demo CRM" --seed-demo` (как `setup.py:41-73`),
складывает `Contragenti-<v>-macos-app.zip`, `.pkg`, `democrm.zip`, считает
sha256 и **дописывает** поля в `release.json` через новую функцию в
`tools/make_release.py` (`copy_macos_artifacts(ver)` + расширение
`update_manifest`, по образцу `copy_app_zip`). Сборка на Windows про эти
поля не знает и не должна их затирать: `update_manifest` меняет только
свои ключи (так уже сделано для `app_zip_*` — сохранить этот принцип).

Крупные бинарники в `release/` — это принятая в репозитории практика (см.
`release/README.md`), пуш `.pkg` и zip'ов допустим; старые версии того же
типа удаляются при копировании (как `copy_artifact`).

---

## 8. Какие файлы создать (и только их)

| Файл/каталог | Назначение |
|---|---|
| `crm_macos/` | Xcode-проект Demo CRM: `DemoCRM.xcodeproj` (или `Package.swift` + `project.yml`), `Sources/…`, `Resources/` (иконка `.icns`, копии `lang.json`/`processes.json`/`sample_card.xml` только как запасные), `README_ru.md` (как собрать, как прогнать `--selftest`/`--gui-test`) |
| `setup_wizard_macos.py` | мастер для macOS (§3) |
| `setup_common.py` | общий код двух мастеров (§3) |
| `tools/build_macos.sh` | сборка всех Mac-артефактов и обновление `release.json` |
| `tools/macos/` | `Info.plist`-шаблоны, `postinstall` для `.pkg`, `contragenti-macos-install.sh` (исходник тонкого установщика, копируется в `release/`) |
| `INSTALL_MACOS_ru.md` | инструкция пользователя (по образцу `INSTALL_MSI_ru.md`): установка одной строкой, `.pkg`, Gatekeeper, где данные, как обновляться, как удалить, типичные сбои |
| `INSTALL_MACOS_RO.md` | короткая версия на румынском (по образцу `INSTALL_RO.md`) |
| правки: `company_search.py` (§2.3), `tools/make_release.py` (§7), `release.json` (§7), `README.md` (раздел «macOS» со ссылками), `AGENTS.md` (порядок выпуска для Mac, правило «два мастера — один `setup_common`»), `.gitignore` (`crm_macos/build/`, `*.xcuserstate`, `DerivedData/`) | |

---

## 9. Фазы и приёмка

Каждая фаза заканчивается коммитом и пушем; критерии — исполняемые, без
«примерно работает».

1. **Contragenti на Mac из исходников.** `python3 company_search.py
   --selftest` → 8/8; `_data_dir()` на Mac даёт `~/Library/Application
   Support/Contragenti` при запуске из `/Applications`; самообновление из
   git работает (`Файл → Проверить обновления` → «уже последняя версия»).
2. **Бандлы `Contragenti.app` и `Contragenti Setup.app`.** Собираются
   `tools/build_macos.sh`; `Contragenti.app/Contents/MacOS/Contragenti
   --selftest` → 8/8 без системного Python (проверить на чистом
   пользователе: `sudo sysadminctl -addUser test …` или хотя бы с `PATH=`
   без Homebrew); `/health` на 9393 отвечает версией.
3. **Мастер macOS.** `setup_wizard_macos.py --check --offline --no-seed
   --no-python` → код 0, `install.log` в `~/Library/Logs/Contragenti/`,
   `crm.ini` создан, `defaults read md.una.contragenti.democrm Language`
   отвечает; `--uninstall --silent` убирает установку, оставляет данные.
4. **Demo CRM в Xcode — данные и CLI.** `xcodebuild … build` без ошибок;
   `"Demo CRM" --selftest` → `CRM self-test: True`, код 0; `--seed-demo` в
   пустую базу даёт **ровно те же** счётчики, что `ContragentiCRM.exe
   --seed-demo` на Windows — таблица в §6.6, сверить `SELECT count(*)` по
   всем таблицам с эталонной `crm_delphi/clients.db` и `crm_delphi/seed.log`
   из репозитория; `--dml-test` → 0; база, засеянная Delphi
   (`crm_delphi/clients.db` из репозитория), открывается Mac-версией без
   ошибок и после миграции содержит все колонки из §5; `--import
   crm_delphi/sample_card.xml` дважды → первый раз добавлено, второй —
   дубликат.
5. **Demo CRM — интерфейс.** Все разделы из §6.1 присутствуют; «Создать из
   реестра» реально запускает `Contragenti.app` с `--pick --out … --lang
   … --no-server --no-tray` и после выбора добавляет клиента, повторный
   выбор той же компании даёт «дубликат»; перетаскивание на канбане, в
   процессе, на Ганте и в календаре меняет стадию/дату в БД; все 6
   отчётов экспортируются в `.xlsx` и `.pdf`, xlsx открывается Numbers/
   Excel; смена языка в панели входа переключает интерфейс и сохраняется в
   `UserDefaults`; ни одного `NSAlert`/модального окна в сценариях
   (`grep -r "NSAlert\|\.alert(" Sources` пусто или обосновано в
   `README_ru.md`). `--gui-test` прогоняет сценарий по образцу
   `uGuiSelfTest.pas` (вход, неверный пароль, смена языка, импорт +
   дубликат, фильтры, настройки, удаление двойным нажатием, реальный вызов
   Contragenti, CRUD всех разделов, проведение заказа, канбан/процесс/Гант/
   календарь, все экспорты) со снимками `screencapture` и `report.html`.
6. **Установщик и релиз.** `.pkg` ставится на чистую машину (или чистого
   пользователя), после установки мастер запускается сам; тонкий
   `contragenti-macos-install.sh` качает zip по `release.json`, сверяет
   sha256, ставит в `~/Applications/Contragenti`, запускает мастер;
   `release.json` содержит все поля §7 с верными sha256 и ссылки отвечают
   HTTP 200; `INSTALL_MACOS_ru.md`/`INSTALL_MACOS_RO.md` написаны;
   `README.md` и `AGENTS.md` дополнены.

Итог работы — сообщение пользователю: что собрано, размеры артефактов,
что проверено (по пунктам выше), что не удалось и почему.
