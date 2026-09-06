# MSI-установщик Contragenti

Как MSI и мастер настройки ставят Demo CRM и Contragenti на чистый Windows
и при необходимости **сами вызывают команду `python` в PowerShell** — на
свежих Windows интерпретатор ставится автоматически. Дальше — те же шаги,
что в [INSTALL_WINDOWS_ru.md](INSTALL_WINDOWS_ru.md), без ручных команд.

Репозиторий: [github.com/PavelTuhari/Contragenti](https://github.com/PavelTuhari/Contragenti).

**Скачать установщик:**

| Файл | Когда |
|---|---|
| **[Contragenti-1.3.0-setup.exe](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.0-setup.exe)** | Рекомендуется. Обычный exe **без Windows Installer**; работает там, где MSI запрещён политикой |
| [Contragenti-1.3.0-win64.msi](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.0-win64.msi) | Если в организации ставят только MSI (SCCM/Intune, групповые политики) |

---

## Если MSI не запускается: «The system administrator has set policies to prevent this installation»

Это код 1625 Windows Installer: политика (обычно `DisableUserInstalls`,
запрет MSI из интернета или установок не от администратора) не пускает
именно **msiexec**. Программа тут ни при чём. Берите
**`Contragenti-1.3.0-setup.exe`** — он Windows Installer не вызывает:
распаковывает программу в `%LOCALAPPDATA%\Contragenti`, создаёт ярлыки
(рабочий стол, «Пуск»), запись в «Программы и компоненты» (HKCU, без
прав администратора) и запускает мастер настройки. Удаление — через
«Программы и компоненты» или «Пуск → Contragenti → Удалить Contragenti».

Ключи: `/S` — тихо; `/S /D=C:\Contragenti` — тихо в каталог;
`--extract-only D:\Contragenti` — только распаковать (портативно, без
ярлыков и реестра); `--no-shortcuts`, `--no-wizard`, `--lang ro|en|ru`.

Предупреждение браузера «isn't commonly downloaded» относится к обоим
файлам: они не подписаны сертификатом разработчика (для его снятия нужен
платный code-signing сертификат и накопленная репутация SmartScreen).
«⋯» → «Keep», затем сверьте sha256 с `release.json`:

```powershell
Get-FileHash .\Contragenti-1.3.0-setup.exe
```

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

## Python: два вида Windows

Contragenti.exe и Demo CRM **работают без системного Python** — это
замороженные exe. Python нужен для `sdk/python` и для запуска из
исходников. Мастер сначала проверяет `python -c "import sys; print(sys.version)"`
(и `py -3`, `python3`); если отвечает номером версии — шаг готов, любая 3.x.

Если Python нет, мастер смотрит, какой это Windows (строка «Вид Windows»
в техническом паспорте), и ставит его подходящим способом:

| Вид Windows | Признак | Как ставится |
|---|---|---|
| **Современный** — Windows 10 с 1903 (сборка 18362+) и Windows 11 | есть псевдоним `python` от App Installer (`%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe`) или `winget` | 1) `winget install -e --id Python.Python.3.12 --scope user` — тихо, без кликов; 2) если winget нет — в PowerShell выполняется команда `python`: Windows сам открывает Microsoft Store и ставит Python «в одно касание» |
| **Старый** — Windows 8.1, ранние Windows 10 (до 1903), LTSC/сборки без Store | псевдонима и winget нет | скачивается официальный установщик **python.org** (3.12.10 — последний 3.12 с установщиком; для Windows 7/8 — 3.8.10, x64/x86/ARM64 по архитектуре), проверяется подпись Python Software Foundation (`Get-AuthenticodeSignature`), затем тихая установка в профиль пользователя: `InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_test=0` |

Порядок на современном Windows: winget → Store → python.org (если первые
два не сработали, старый способ работает и там). После установки мастер
перечитывает PATH из реестра и ждёт, пока `python` начнёт отвечать. Что
именно сработало, видно в логе и в строке шага: «Python установлен: python
3.12.10 (через winget)».

В окне мастера при отсутствии Python появляется кнопка: на современном
Windows — «Установить Python (winget / Microsoft Store)», на старом —
«Установить Python 3.12 с python.org». В режиме без окна (`--check`)
используются только тихие способы (winget, python.org) — Store требует
клика в его окне.

Снять галочку «Если нет Python — установить…» или передать `--no-python` /
`--offline` — шаг пропускается. Установщик с python.org сохраняется в
`logs\` (можно запустить вручную).

Вручную:

```powershell
# современный Windows
winget install -e --id Python.Python.3.12 --scope user
# или просто
python
# старый Windows: скачать https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe
.\python-3.12.10-amd64.exe /passive InstallAllUsers=0 PrependPath=1 Include_launcher=1
```

После установки откройте новое окно PowerShell и проверьте:

```powershell
python -c "import sys; print(sys.version)"
```

> Windows 7 сам MSI не запустит: Contragenti.exe собран на Python 3.12,
> которому нужен Windows 8.1 и новее. Для Windows 7 остаётся запуск из
> исходников на Python 3.8 (`INSTALL_WINDOWS_ru.md`).

---

## Дальше — те же настройки, что в статье

После Python мастер делает шаги из
[INSTALL_WINDOWS_ru.md](INSTALL_WINDOWS_ru.md) на уже установленной копии:

| Шаг | Что делает |
|---|---|
| Технический паспорт | ОС, сборка, память, диск, Chrome, Python, версии файлов, размер баз |
| Google Chrome | реестр и типичные папки; если нет — кнопка «Скачать Chrome» |
| Python | нет — ставит: современный Windows через winget / Store, старый — установщиком с python.org (см. выше) |
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
| `Python was not found` (современный Windows) | В PowerShell выполните `python` без аргументов — Windows поставит его сам; или `winget install -e --id Python.Python.3.12`. Затем новое окно PowerShell. |
| `python не является внутренней или внешней командой` (старый Windows) | Кнопка мастера «Установить Python 3.12 с python.org» или установщик из `logs\python-3.12.10-amd64.exe`. |
| Команда python так и не заработала | Откройте новое окно PowerShell (PATH обновляется для новых процессов); проверьте `py -3 --version`. |
| Chrome не найден | Кнопка «Скачать Chrome»; без него портал date.gov.md недоступен |
| Самопроверка Demo CRM FAIL | Смотрите `logs\selftest_democrm.log`; отчёт мастера |

Пошаговая ручная установка из исходников (venv, `crm.ini`, ярлыки) — в
[INSTALL_WINDOWS_ru.md](INSTALL_WINDOWS_ru.md).
