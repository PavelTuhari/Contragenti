# MSI-установщик Contragenti

Как MSI и мастер настройки ставят Demo CRM и Contragenti на чистый Windows
и при необходимости **сами вызывают команду `python` в PowerShell** — на
свежих Windows интерпретатор ставится автоматически. Дальше — те же шаги,
что в [INSTALL_WINDOWS_ru.md](INSTALL_WINDOWS_ru.md), без ручных команд.

Репозиторий: [github.com/PavelTuhari/Contragenti](https://github.com/PavelTuhari/Contragenti).

**Скачать установщик:**
[release/Contragenti-1.1.0-win64.msi](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.1.0-win64.msi)

---

## Что делает MSI

`Contragenti-<версия>-win64.msi` копирует программы в
`%LOCALAPPDATA%\Contragenti` **без прав администратора**:

| Что | Куда |
|---|---|
| Contragenti.exe | замороженная утилита (портал date.gov.md) |
| DemoCRM\ContragentiCRM.exe | Demo CRM |
| Contragenti Setup.exe | мастер настройки и обновления |
| sdk\, инструкции, VERSION, release.json | рядом |
| data\companies_seed.zip | запасная стартовая база без интернета |

Ярлыки: **Contragenti** и **Demo CRM (SDK Contragenti)** на рабочем столе,
**Contragenti — настройка и обновление** в меню «Пуск».

На последнем экране оставьте галочку **Launch on finish** — откроется мастер.
Его же можно запустить позже из «Пуск».

Git на компьютере не нужен. Google Chrome нужен для портала.

---

## Python: команда `python` в PowerShell

Версия **не фиксируется** (не 3.12 и не exe с python.org). На последних
Windows в PowerShell достаточно написать `python` — система ставит
интерпретатор сама (App Installer / Microsoft Store). После этого команда
начинает работать, и можно идти дальше.

Мастер делает то же самое:

1. Проверяет, отвечает ли `python -c "import sys; print(sys.version)"`
   номером версии. Если да — шаг готов (любая 3.x).
2. Если нет — запускает в PowerShell ту же команду `python` (без аргументов:
   так Windows и ставит Python). Ждёт окончания и снова проверяет `python`.
3. Contragenti.exe и Demo CRM **работают и без системного Python** (это
   замороженные exe). Команда `python` нужна для `sdk/python` и для запуска
   из исходников.

Снять галочку в окне мастера или передать `--no-python` / `--offline` —
шаг пропускается.

Вручную, если мастер ещё не запускали:

```powershell
python
```

После установки откройте новое окно PowerShell и проверьте:

```powershell
python -c "import sys; print(sys.version)"
```

---

## Дальше — те же настройки, что в статье

После Python мастер делает шаги из
[INSTALL_WINDOWS_ru.md](INSTALL_WINDOWS_ru.md) на уже установленной копии:

| Шаг | Что делает |
|---|---|
| Технический паспорт | ОС, сборка, память, диск, Chrome, Python, версии файлов, размер баз |
| Google Chrome | реестр и типичные папки; если нет — кнопка «Скачать Chrome» |
| Python | команда `python` в PowerShell: если не работает — Windows ставит сам |
| Доступ к GitHub | читает `release.json` |
| Новая версия | сравнивает с `VERSION`; если новее и есть `msi_url` — предлагает MSI |
| Обновление компонентов | zip `release/Contragenti-update-*.zip` или файлы из `components` |
| Стартовая база компаний | `data/companies_seed.zip` → `companies.db` по IDNO (свои записи не трогаются) |
| Настройка | `DemoCRM\crm.ini` (`launcher=…\Contragenti.exe`, язык), `HKCU\Software\DemoCRM\Language`, `logs\` |
| Демо-данные | `ContragentiCRM.exe --seed-demo` |
| Ярлыки | проверяет ярлыки на рабочем столе |
| Самопроверка | `Contragenti.exe --selftest` и `ContragentiCRM.exe --selftest` |

Язык мастера (română / english / русский) выбирается вверху и сразу
пишется в реестр — Demo CRM откроется на том же языке.

Без окна:

```powershell
& "$env:LOCALAPPDATA\Contragenti\Contragenti Setup.exe" --check
```

Только настройка, без GitHub и без команды python:

```powershell
& "$env:LOCALAPPDATA\Contragenti\Contragenti Setup.exe" --check --offline --no-seed --no-python
```

Лог: `%LOCALAPPDATA%\Contragenti\logs\install.log`.
При ошибках — `logs\install_report_<дата>.txt` (паспорт + лог + события
MsiInstaller). Кнопки «Сообщить на GitHub» / «Отправить на e-mail» только
открывают заготовку; автоматически ничего не уходит.

---

## Сборка MSI из исходников

Нужны Python и зависимости проекта (`cx_Freeze` — из окружения сборки):

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -U pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m pip install cx_Freeze
.\.venv\Scripts\python.exe setup.py bdist_msi
.\.venv\Scripts\python.exe tools\make_release.py
```

Результат:

- `dist\Contragenti-1.1.0-win64.msi`
- копия в `release\`, плюс обновлённые `msi_url` / sha256 в `release.json`

Первый `Executable` в `setup.py` — `setup_wizard.py` («Contragenti Setup.exe»):
cx_Freeze запускает именно его по «Launch on finish». Порядок не менять.

Перед коммитом:

```powershell
.\.venv\Scripts\python.exe setup_wizard.py --check --offline --no-seed
```

код возврата 0.

---

## Типичные сбои

| Симптом | Что сделать |
|---|---|
| `Python was not found` | В PowerShell выполните `python` без аргументов — Windows поставит его сам. Затем новое окно PowerShell. |
| Команда python так и не заработала | Мастер: кнопка «Установить Python (команда python)». Нужен интернет. |
| Chrome не найден | Кнопка «Скачать Chrome»; без него портал date.gov.md недоступен |
| Самопроверка Demo CRM FAIL | Смотрите `logs\selftest_democrm.log`; отчёт мастера |

Пошаговая ручная установка из исходников (venv, `crm.ini`, ярлыки) — в
[INSTALL_WINDOWS_ru.md](INSTALL_WINDOWS_ru.md).
