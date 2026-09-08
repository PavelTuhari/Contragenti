# Установка Contragenti и Demo CRM на macOS

Полный аналог Windows-установки: утилита **Contragenti** (поиск по реестру
date.gov.md, локальный API `127.0.0.1:9393`), нативная **Demo CRM** (Swift,
собирается в Xcode из `crm_macos/`), мастер настройки **Contragenti Setup**,
стартовые базы, SDK и самообновление. Проверено на macOS 26 (Apple Silicon);
минимальная версия для Demo CRM — macOS 13.

Репозиторий: [github.com/PavelTuhari/Contragenti](https://github.com/PavelTuhari/Contragenti).

**Архитектура:** сборки публикуются для **arm64** (Apple Silicon, поле
`macos_arch` в `release.json`). На Intel Mac бандлы Python не запустятся —
там используйте запуск из исходников (§ «Из исходников») или соберите
артефакты на Intel-машине скриптом `tools/build_macos.sh` (он кладёт в
`release.json` те же поля для своей архитектуры).

---

## 1. Установка одной строкой (рекомендуется)

```bash
curl -fsSL https://raw.githubusercontent.com/PavelTuhari/Contragenti/main/release/contragenti-macos-install.sh | bash
```

Скрипт — аналог тонкого `Contragenti-<версия>-setup.exe`: читает
`release.json`, скачивает `Contragenti-<версия>-macos-app.zip`, сверяет
sha256, распаковывает в **`~/Applications/Contragenti`** (без `sudo`),
снимает карантин Gatekeeper, ставит симлинки в `~/Applications` (их видит
Launchpad) и запускает мастер настройки.

Флаги (после `bash -s --`):

| Флаг | Что делает |
|---|---|
| `--system` | ставить в `/Applications/Contragenti` (спросит пароль через `sudo`, если каталог недоступен) |
| `--dir PATH` | свой каталог |
| `--lang ro\|en\|ru` | язык мастера и Demo CRM (по умолчанию — из локали) |
| `--no-wizard` | не запускать мастер |
| `--no-shortcuts` | без симлинков в `~/Applications` |
| `--offline-payload FILE.zip` | взять готовый zip с диска (тесты, установка без сети) |

Пример: `curl -fsSL …/contragenti-macos-install.sh | bash -s -- --system --lang ru`.

## 2. Установщик `.pkg` (без интернета)

**[Contragenti-1.3.7-macos.pkg](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.7-macos.pkg)** —
аналог MSI: всё внутри, ставит в `/Applications/Contragenti` (запросит
пароль администратора), после установки сам открывает мастер настройки
(postinstall). Тихо: `sudo installer -pkg Contragenti-1.3.7-macos.pkg -target /`.

Пакет не подписан сертификатом Apple Developer ID (как и exe на Windows):
если Gatekeeper не даёт открыть `.pkg` — правый клик → **Открыть** → «Открыть».
sha256 всех файлов — в `release.json`:

```bash
shasum -a 256 Contragenti-1.3.7-macos.pkg
```

## 3. Gatekeeper: «приложение не удаётся открыть»

Бандлы подписаны ad-hoc (`codesign --sign -`), а не Developer ID. Установщик
и мастер снимают карантин (`xattr -dr com.apple.quarantine`). Если бандл
скопирован вручную (например, распакован из zip в Finder):

- правый клик по приложению → **Открыть** → «Открыть» (один раз), или
- в терминале: `xattr -dr com.apple.quarantine ~/Applications/Contragenti`.

## 4. Что внутри установки

```
Contragenti/
  Contragenti.app          утилита (Python и tkinter встроены — системный Python не нужен)
  Contragenti Setup.app    мастер настройки и обновления
  Demo CRM.app             нативная CRM (Swift/AppKit, Xcode)
  companies.db             стартовая база компаний date.gov.md
  data/companies_seed.zip  её запасная копия
  DemoCRM/clients.db       демо-фирма (17 клиентов, 23 заказа, 10 проектов, 124 задачи…)
  DemoCRM/lang.json, processes.json, sample_card.xml
  sdk/  *.md  VERSION  release.json  app_icon.icns
```

Google Chrome нужен для портала date.gov.md (Selenium Manager сам скачает
chromedriver). Python нужен **только** для `sdk/python` — мастер проверит
`python3` и при желании поставит 3.12 (Homebrew, иначе pkg с python.org с
проверкой подписи).

## 5. Где лежат данные

Правило то же, что на Windows: если рядом с программой можно писать и это не
`/Applications` / `~/Applications` — данные лежат там (портативная копия,
запуск из клона). Иначе — в профиле:

| Данные | Где |
|---|---|
| `companies.db`, `tms_config.json`, `settings.json` | `~/Library/Application Support/Contragenti/` |
| `clients.db`, `crm.ini`, `reports/` Demo CRM | `~/Library/Application Support/Contragenti/DemoCRM/` |
| логи и отчёты мастера (`install.log`, `install_report_*.txt`) | `~/Library/Logs/Contragenti/` |
| язык Demo CRM | `defaults read md.una.contragenti.democrm Language` (`ro`/`en`/`ru`) |

При первом запуске стартовые базы из установки копируются в профиль;
переустановка данные не трогает.

## 6. Мастер настройки

Открывается сам после установки; позже — `Contragenti Setup.app` в каталоге
установки. Шаги те же, что у Windows-мастера: технический паспорт
(`sw_vers`, `uname -m`, память, диск, Chrome из `Info.plist`, `python3`),
Chrome, Python, доступ к GitHub, новая версия, обновление компонентов,
стартовая база (слияние по IDNO), `crm.ini` + UserDefaults, демо-данные
(`Demo CRM --seed-demo`), ярлыки, самопроверка обеих программ. Отчёт
`install_report_<дата>.txt` (паспорт + шаги + лог + последние события
`installer`) и кнопки «Сообщить на GitHub» / «Отправить на e-mail».

Без окна:

```bash
"/Applications/Contragenti/Contragenti Setup.app/Contents/MacOS/Contragenti Setup" --check --lang ru
```

Флаги: `--check`, `--lang`, `--offline`, `--no-python`, `--no-seed`,
`--no-update`, `--auto --shot файл.png` (снимок окна для акта — нужно право
«Запись экрана»), `--uninstall [--silent] [--purge-data]`.

## 7. Обновление

- **Мастер**: шаг «Новая версия» сравнивает `VERSION` с `release.json`; если
  новее — предлагает обновить на месте (скачать `macos-app.zip`, сверить
  sha256, остановить программы, заменить бандлы; базы и `crm.ini` в профиле
  не трогаются) или скачать `.pkg`. Шаг «Обновление компонентов» кладёт
  поверх установки файлы из `components` + `macos_components`; `Demo CRM.app`
  обновляется целиком zip-ом (`macos_democrm_zip_url`).
- **Из клона репозитория** (`python3 company_search.py`): утилита сама
  проверяет GitHub при старте и по «Файл → Проверить обновления»
  (`git pull --ff-only`, только при чистой рабочей копии).

## 8. Удаление

```bash
"/Applications/Contragenti/Contragenti Setup.app/Contents/MacOS/Contragenti Setup" --uninstall --silent
```

Удаляет каталог установки, симлинки в `~/Applications` и LaunchAgents;
данные в `~/Library/Application Support/Contragenti` остаются (в окне —
спрашивает; `--purge-data` удаляет их и ключ UserDefaults).

## 9. Из исходников (разработчику)

```bash
git clone https://github.com/PavelTuhari/Contragenti.git && cd Contragenti
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt   # brew install python-tk@3.12
.venv/bin/python company_search.py --selftest      # 8/8
cd crm_macos && xcodebuild -scheme "Demo CRM" -configuration Release build
.venv/bin/python setup_wizard_macos.py --check --offline --no-seed --no-python
```

Сборка всех артефактов (нужны Xcode и `.venv/bin/pip install pyinstaller`):
`tools/build_macos.sh` → `release/Contragenti-<v>-macos-app.zip`,
`-macos-democrm.zip`, `-macos.pkg`, `contragenti-macos-install.sh`, поля
`macos_*` в `release.json` (`tools/make_release.py --macos`).

## 10. Типичные сбои

| Симптом | Что делать |
|---|---|
| «Contragenti.app повреждено / не удаётся открыть» | карантин: `xattr -dr com.apple.quarantine <путь к Contragenti>` или правый клик → Открыть |
| `bad CPU type in executable` | сборка arm64 на Intel Mac — запускайте из исходников или соберите на Intel |
| Chrome не найден | `/Applications/Google Chrome.app` обязателен для портала; data2b.md работает и без него |
| Demo CRM: «Не найден Contragenti» | Настройки → путь к `Contragenti.app/Contents/MacOS/Contragenti` (или к `company_search.py`) → Сохранить |
| Мастер: `CERTIFICATE_VERIFY_FAILED` | мастер повторит запрос с корнями certifi из бандла; проверка сертификата не отключается |
| Снимок `--shot` пустой | дайте терминалу/мастеру право «Запись экрана» в Системных настройках |
| Не выпущено | сборки x86_64 (нет Intel-машины); снимки чужих окон в GUI-тесте Demo CRM без права «Запись экрана» |

Короткая версия на румынском — [INSTALL_MACOS_RO.md](INSTALL_MACOS_RO.md).
Постановка, по которой сделан порт, — [PORT_MACOS_ru.md](PORT_MACOS_ru.md);
Demo CRM — [crm_macos/README_ru.md](crm_macos/README_ru.md).
