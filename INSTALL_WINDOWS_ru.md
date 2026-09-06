# Установка демо-программы и утилиты получения атрибутов контрагентов на Windows

Пошаговая статья: как на обычном Windows 10/11 поставить **Demo CRM** и
нативную утилиту **Contragenti**, которая забирает карточку юридического лица
с портала открытых данных **date.gov.md** и отдаёт атрибуты (IDNO, название,
адрес, руководители, учредители, задолженность перед бюджетом) во внешнюю
программу — в демо-CRM, в 1С или в любой другой клиент.

Репозиторий: [github.com/PavelTuhari/Contragenti](https://github.com/PavelTuhari/Contragenti).

**Открыть HTML как страницу в браузере:**
https://raw.githack.com/PavelTuhari/Contragenti/main/docs/ustanovka-demo-crm-windows.html

(ссылка `github.com/…/blob/…html` показывает исходник, а не страницу.)

---

## Быстрый путь: MSI-установщик и мастер настройки

Всё, что описано ниже руками (Python, зависимости, `crm.ini`, ярлыки,
самопроверка), на чистом Windows делает установщик и мастер настройки —
Git **не нужен**, нужен Google Chrome. Если команда `python` ещё не работает,
мастер в PowerShell запускает `python` — на свежих Windows интерпретатор
ставится сам. Подробно — [INSTALL_MSI_ru.md](INSTALL_MSI_ru.md).

1. Скачайте установщик из репозитория:
   **[release/Contragenti-1.3.2-setup.exe](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.2-setup.exe)**
   (обычный exe без Windows Installer; если у вас в организации ставят
   только MSI — [Contragenti-1.3.2-win64.msi](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.2-win64.msi);
   рядом лежит `Contragenti-update-1.3.2.zip` — пакет обновления, его
   мастер скачивает сам; ссылки и sha256 в `release.json`) и запустите. Установка идёт в
   `C:\Program Files\Contragenti` (запрос прав администратора; без них —
   `Contragenti-1.3.2-setup.exe /D=%LOCALAPPDATA%\Contragenti`). В установке уже
   есть базы с данными: `companies.db` (компании date.gov.md) и
   `DemoCRM\clients.db` (демо-фирма); рабочие копии программы держат в
   `%LOCALAPPDATA%\Contragenti`. На рабочем столе появляются ярлыки
   **Contragenti** и **Demo CRM (SDK Contragenti)**, в меню «Пуск» —
   **Contragenti — настройка и обновление**.
2. Мастер настройки (`ContragentiSetup.exe`) запускается сам — и после
   setup.exe, и после MSI, в том числе тихого `msiexec /i … /qn`. Язык мастера
   (română / english / русский) выбирается вверху и сразу запоминается в
   реестре — Demo CRM откроется на том же языке.
3. Отметьте шаги (по умолчанию включены все) и нажмите **Выполнить**:

   | Шаг | Что делает | Если не получилось |
   |---|---|---|
   | Технический паспорт | ОС, сборка, память, диск, Chrome, Python, версии файлов, размер баз | попадает в отчёт |
   | Google Chrome | ищет `chrome.exe` в реестре и типичных папках | кнопка «Скачать Chrome» (нужен для портала) |
   | Python | команда `python` в PowerShell; если не работает — Windows ставит интерпретатор сам | кнопка «Установить Python»; exe и Demo CRM работают и без него |
   | Доступ к GitHub | читает `release.json` из репозитория | шаги обновления пропускаются, программы работают |
   | Новая версия | сравнивает `version` с файлом `VERSION` установки | если новее и есть `msi_url` — предлагает скачать MSI |
   | Обновление компонентов | докачивает из GitHub `DemoCRM\ContragentiCRM.exe`, `lang.json`, `processes.json`, инструкции, SDK (список — `components` в `release.json`); старые файлы остаются как `.bak` | ошибка по файлу — в отчёт, остальные обновляются |
   | Стартовая база компаний | скачивает `data/companies_seed.zip` и сливает в `companies.db` по IDNO (свои записи не трогаются); без интернета берёт копию из установки | — |
   | Настройка | `DemoCRM\crm.ini` (`launcher=…\Contragenti.exe`, язык), `HKCU\Software\DemoCRM\Language`, папка `logs\` | — |
   | Демо-данные | `ContragentiCRM.exe --seed-demo`: клиенты, сделки, заказы, задачи — чтобы канбан, схема процесса и отчёты не были пустыми | можно снять галочку |
   | Ярлыки | проверяет ярлыки на рабочем столе | — |
   | Самопроверка | `Contragenti.exe --selftest` и `ContragentiCRM.exe --selftest` | результат в отчёт |

4. В конце — зелёная строка «Готово» и кнопка **Запустить Contragenti и Demo
   CRM**. Если есть ошибки, мастер сохраняет отчёт `logs\install_report_<дата>.txt`
   (технический паспорт + лог установки + ошибки + последние события Windows
   Installer из журнала приложений) и предлагает отправить его разработчику:
   **Сообщить на GitHub** открывает заготовку issue, **Отправить на e-mail** —
   письмо; полный отчёт при этом копируется в буфер обмена. Автоматически
   ничего не отправляется — только то, что подтвердит пользователь.

Мастер можно запускать повторно в любое время (меню «Пуск») — например,
чтобы подтянуть свежую Demo CRM из GitHub без переустановки. Без окна:

```powershell
& "$env:LOCALAPPDATA\Contragenti\ContragentiSetup.exe" --check
```

Лог всех запусков — `%LOCALAPPDATA%\Contragenti\logs\install.log`.

---

## Зачем две программы, а не одна

| Программа | Что это | Откуда атрибуты |
|---|---|---|
| **Contragenti** | Desktop-утилита (Python + Tkinter + Chrome) | Ищет компанию на date.gov.md, показывает карточку, копит локальную SQLite `companies.db`, отдаёт XML |
| **Demo CRM** | Готовый `ContragentiCRM.exe` (Delphi/VCL, стиль EspoCRM) | Своя база клиентов `clients.db`. Кнопка «из реестра» запускает Contragenti и записывает выбранную карточку |

CRM **не ходит** на портал и **не решает** капчу. Она только вызывает утилиту:

```
Demo CRM  ── фильтр (название / IDNO) ──►  Contragenti  ──►  Chrome  ──►  date.gov.md
                ▲                                                    │
                └──────── XML полной карточки ───────────────────────┘
                         запись в clients.db (дедупликация по IDNO)
```

Портал закрыт невидимой reCAPTCHA: `curl` и серверный скрапер получают HTTP 400.
Токен выдаёт только настоящий браузер, поэтому Contragenti запускает **Google
Chrome** и проходит форму как пользователь. Капчу утилита не обходит.

---

## Что должно быть на компьютере

Проверено на Windows 10, Python 3.12, Chrome.

| Компонент | Зачем | Как проверить |
|---|---|---|
| **Windows 10/11** 64-bit | Окна Tk и VCL, трей, ярлыки | `winver` |
| **Python 3.12+** с Tkinter | Сама утилита | `py -3.12 -c "import tkinter; print(tkinter.TkVersion)"` |
| **Google Chrome** | Шлюз к date.gov.md | `%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe` |
| **Git** | Клонирование репозитория | `"C:\Program Files\Git\cmd\git.exe" --version` |

RAD Studio **не нужна**: `crm_delphi\ContragentiCRM.exe` уже лежит в репозитории.
Драйвер Chrome подтягивает Selenium Manager — `chromedriver` вручную ставить
не надо.

> Команда `python` из Microsoft Store часто оказывается заглушкой
> («Python was not found»). На Windows используйте **`py -3.12`** или полный
> путь `...\Python312\python.exe`.

Установка Python: [python.org/downloads](https://www.python.org/downloads/) —
галочка **«tcl/tk and IDLE»** должна быть включена. Chrome: обычный установщик
Google. Git: [git-scm.com](https://git-scm.com/download/win).

---

## 1. Клонировать репозиторий

В PowerShell:

```powershell
& "C:\Program Files\Git\cmd\git.exe" clone https://github.com/PavelTuhari/Contragenti.git
cd Contragenti
```

Каталог может быть любым (`C:\Contragenti`, `C:\grok\Contragenti`, папка в
профиле). Дальше в примерах — текущий каталог клона.

В `crm_delphi\ContragentiCRM.exe` должен быть настоящий файл (~5 МБ), не
указатель Git LFS. Если вместо exe текстовая заглушка — выполните
`git lfs pull`.

---

## 2. Виртуальное окружение и зависимости

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -U pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Проверка импорта:

```powershell
.\.venv\Scripts\python.exe -c "import selenium, openpyxl, PIL, pystray; print('ok', selenium.__version__)"
```

---

## 3. Самопроверка до открытия окон

Утилита:

```powershell
.\.venv\Scripts\python.exe company_search.py --selftest
```

Ожидается `Contragenti self-test: PASS` (база, i18n, XML, сокет, парсеры).

Demo CRM:

```powershell
.\crm_delphi\ContragentiCRM.exe --selftest
```

Ожидается разбор XML и `CRM self-test: True`. Дополнительно можно завести
эталонную карточку без портала:

```powershell
.\crm_delphi\ContragentiCRM.exe --import .\crm_delphi\sample_card.xml
```

Повторный импорт той же карточки даёт дубликат по IDNO — так и должно быть.

---

## 4. Связать CRM с утилитой

Demo CRM читает `crm_delphi\crm.ini`. Если файла нет, по умолчанию ищется
`Contragenti.exe` рядом или в `%LOCALAPPDATA%\Contragenti`. При запуске из
исходников укажите сам скрипт — SDK сам возьмёт `.venv\Scripts\python.exe`:

```ini
[contragenti]
launcher=C:\Contragenti\company_search.py
lang=ru
```

Подставьте **свой** абсолютный путь к `company_search.py`. Файл можно создать
блокнотом или так:

```powershell
@"
[contragenti]
launcher=$pwd\company_search.py
lang=ru
"@ | Set-Content -Encoding utf8 .\crm_delphi\crm.ini
```

Путь позже меняется в Demo CRM: **Настройки** → поле лаунчера → **Сохранить**.

---

## 5. Запуск двух окон

Из корня клона:

```powershell
# Утилита карточек date.gov.md (окно + локальный API :9393)
Start-Process -FilePath "$pwd\.venv\Scripts\pythonw.exe" `
  -ArgumentList "`"$pwd\company_search.py`" --lang ru" `
  -WorkingDirectory $pwd

# Demo CRM
Start-Process -FilePath "$pwd\crm_delphi\ContragentiCRM.exe" `
  -WorkingDirectory "$pwd\crm_delphi"
```

Либо готовые ярлыки из корня репозитория:

```text
start-contragenti.bat
start-demo-crm.bat
```

Что должно появиться:

| Окно | Заголовок | Признак жизни |
|---|---|---|
| Contragenti | «Поиск компаний — date.gov.md» | http://127.0.0.1:9393/health → `{"status":"ok"}` |
| Demo CRM | «Demo CRM» | раздел **Клиенты**, кнопка добавления из реестра |

Проверка API из PowerShell:

```powershell
(Invoke-WebRequest http://127.0.0.1:9393/health -UseBasicParsing).Content
```

---

## 6. Первый контрагент: атрибуты с date.gov.md

1. В **Demo CRM** откройте **Клиенты**.
2. Нажмите кнопку добавления из реестра (в интерфейсе — в духе EspoCRM
   «Создать клиента» / «Добавить из реестра»).
3. Откроется Contragenti уже с фильтром. Если фильтр пустой — введите название
   или IDNO на вкладке **Онлайн-поиск** и нажмите **Поиск**.
4. Откроется **видимое** окно Chrome, утилита заполнит форму портала.
   Не включайте «Скрытый браузер»: в headless Google почти всегда показывает
   ручную капчу, и запрос падает по таймауту.
5. Если Google всё же покажет проверку — решите её в окне Chrome.
6. Выберите строку компании. Contragenti догрузит карточку (учредители,
   задолженность), запишет XML и вернёт его в CRM.
7. В списке клиентов появится запись. Повторный выбор того же IDNO не создаст
   второго клиента.

Те же атрибуты можно получить без CRM — из браузера на этой машине:

```
http://127.0.0.1:9393/pick?q=UNISIM&lang=ru
```

или из уже накопленной базы утилиты:

```
http://127.0.0.1:9393/card?idno=1003600116460&format=xml
```

Карточка в XML выглядит так:

```xml
<counterparty source="date.gov.md" idno="1003600116460" updated="...">
  <idno>1003600116460</idno>
  <denumire>CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.</denumire>
  <inregistrare>30.03.2001</inregistrare>
  <forma_juridica>Societate cu raspundere limitata</forma_juridica>
  <lichidata>Nu</lichidata>
  <adresa>...</adresa>
  <administratori>...</administratori>
  <founders>
    <founder name="..." share="..."/>
  </founders>
  <debts currency="MDL">
    <debt nr="1" type="..." sum="..."/>
  </debts>
  <details_text>...</details_text>
</counterparty>
```

---

## Ярлыки на рабочем столе

```powershell
$Wsh = New-Object -ComObject WScript.Shell
$root = (Resolve-Path .).Path
$desk = [Environment]::GetFolderPath('Desktop')

$a = $Wsh.CreateShortcut((Join-Path $desk 'Contragenti.lnk'))
$a.TargetPath = Join-Path $root '.venv\Scripts\pythonw.exe'
$a.Arguments  = "`"$(Join-Path $root 'company_search.py')`" --lang ru"
$a.WorkingDirectory = $root
$a.IconLocation = "$(Join-Path $root 'app_icon.ico'),0"
$a.Save()

$b = $Wsh.CreateShortcut((Join-Path $desk 'Demo CRM (SDK Contragenti).lnk'))
$b.TargetPath = Join-Path $root 'crm_delphi\ContragentiCRM.exe'
$b.WorkingDirectory = Join-Path $root 'crm_delphi'
$b.Save()
```

---

## Типичные сбои на Windows

| Симптом | Что сделать |
|---|---|
| `Python was not found` | Не `python`, а `py -3.12` или полный путь к `Python312\python.exe`. В «Параметры → Приложения → псевдонимы выполнения» отключите заглушки Store. |
| `No module named '_tkinter'` | Переустановите Python 3.12 с компонентом tcl/tk. |
| CRM: «Не найден Contragenti» | Проверьте `crm_delphi\crm.ini`: `launcher=` указывает на существующий `company_search.py` или `Contragenti.exe`. |
| API 9393 молчит, окна нет | Запустите `.\.venv\Scripts\python.exe company_search.py --lang ru` (не `pythonw`) — ошибка будет в консоли. |
| Поиск висит / таймаут | Выключите «Скрытый браузер». Пройдите капчу в открытом Chrome. Не гоняйте пачку поисков подряд: портал включает проверку. |
| Chrome не стартует | Установите стабильный Google Chrome. Selenium Manager качает драйвер сам. |
| `ContragentiCRM.exe` «не Windows» | Файл не докачался (LFS/обрыв). Скачайте сырой exe с GitHub или `git lfs pull`. |

---

## Что куда пишется

| Файл | Где | Содержимое |
|---|---|---|
| `companies.db` | каталог Contragenti | накопленные компании с портала |
| `clients.db` | `crm_delphi\` | клиенты демо-CRM |
| `crm.ini` | `crm_delphi\` | путь к лаунчеру и язык |

Обе базы — обычный SQLite на диске, сервера и аккаунтов нет. HTTP на
`127.0.0.1:9393` — это IPC для 1С и браузера, наружу он не публикуется.

---

## Дальше по документации

| Документ | Когда нужен |
|---|---|
| [GUIDE_ru.md](GUIDE_ru.md) | работа в окне Contragenti, скриншоты |
| [crm_delphi/README_ru.md](crm_delphi/README_ru.md) | Demo CRM: кнопки, `--import`, `--gui-test` |
| [INTEGRATION.md](INTEGRATION.md) | встроить тот же XML-контракт в свою программу |
| [API_ru.md](API_ru.md) | HTTP: `/search`, `/card`, `/pick` |
| [NATIVE_ru.md](NATIVE_ru.md) | почему это нативное приложение, а не сайт |

Данные предоставляет портал открытых данных Правительства Республики Молдова
(date.gov.md). Утилита работает с публичной формой так же, как человек в
браузере.
