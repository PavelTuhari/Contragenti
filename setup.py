"""
Сборка Contragenti в exe и MSI-инсталлятор для Windows.

Использование:
    .venv\\Scripts\\python setup.py build          # только exe (build/exe.win-amd64-3.12/)
    .venv\\Scripts\\python setup.py bdist_msi       # exe + MSI-инсталлятор (dist/*.msi)

Demo CRM (crm_delphi/) — готовый Delphi-бинарник ContragentiCRM.exe —
включается в установку целиком (подкаталог DemoCRM/) вместе с ярлыком
«Demo CRM (SDK Contragenti)» на рабочем столе. Он уже собран и лежит в
репозитории (crm_delphi/ContragentiCRM.exe); чтобы пересобрать заново из
исходников, нужен RAD Studio/dcc32 — см. crm_delphi/build.bat. Если файла
нет, сборка просто пропускает Demo CRM с предупреждением (Contragenti
собирается и без неё).

Мастер настройки (setup_wizard.py → «ContragentiSetup.exe») идёт первым в
списке Executable: именно первый exe cx_Freeze запускает по галочке «Launch
on finish» в конце установки (launch_on_finish=True). Мастер докачивает из
GitHub свежие компоненты и стартовую базу (release.json, data/), настраивает
crm.ini и реестр, заполняет демо-данные, прогоняет самопроверку и при ошибках
собирает отчёт (паспорт системы + лог) для отправки разработчику. Он же
доступен из меню «Пуск» — «Contragenti — настройка и обновление».
"""

import os
import subprocess
import sys
import zipfile
from cx_Freeze import setup, Executable

APP_VERSION = "1.3.3"   # то же значение — в VERSION, release.json и company_search.py

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEMO_CRM_EXE = os.path.join(_HERE, "crm_delphi", "ContragentiCRM.exe")
_HAS_DEMO_CRM = os.path.exists(_DEMO_CRM_EXE)
if not _HAS_DEMO_CRM:
    print(f"[setup.py] предупреждение: {_DEMO_CRM_EXE} не найден — "
          "Demo CRM не будет включена в установку (см. crm_delphi/build.bat)")


def _prepare_seed_dbs():
    """Базы с данными для установки: companies.db (стартовая база компаний
    date.gov.md из data/companies_seed.zip) и DemoCRM/clients.db (полный
    демонстрационный набор фирмы — ContragentiCRM.exe --seed-demo). После
    установки в Program Files программы при первом запуске копируют их в
    %LOCALAPPDATA%\\Contragenti и работают с копиями."""
    seed_dir = os.path.join(_HERE, "build", "seed")
    os.makedirs(seed_dir, exist_ok=True)
    companies = os.path.join(seed_dir, "companies.db")
    with zipfile.ZipFile(os.path.join(_HERE, "data", "companies_seed.zip")) as z:
        with open(companies, "wb") as f:
            f.write(z.read("companies.db"))
    clients = ""
    if _HAS_DEMO_CRM:
        clients = os.path.join(seed_dir, "clients.db")
        if os.path.exists(clients):
            os.remove(clients)
        # GUI-exe не пишет в pipe — вывод в файл
        with open(os.path.join(seed_dir, "seed.log"), "w", encoding="utf-8", errors="replace") as log:
            subprocess.run([_DEMO_CRM_EXE, "--seed-demo", clients], stdout=log, stderr=subprocess.STDOUT,
                           timeout=300, check=True)
        for extra in ("clients.db-journal",):
            try:
                os.remove(os.path.join(seed_dir, extra))
            except OSError:
                pass
    print(f"[setup.py] стартовые базы: {companies} ({os.path.getsize(companies)} байт)"
          + (f", {clients} ({os.path.getsize(clients)} байт)" if clients else ""))
    return companies, clients


_BUILDING = any(a.startswith(("build", "bdist")) for a in sys.argv[1:])
_SEED_COMPANIES, _SEED_CLIENTS = _prepare_seed_dbs() if _BUILDING else ("", "")

build_exe_options = {
    "packages": [
        "tkinter",
        "selenium",
        "openpyxl",
        "PIL",
        "pystray",
        "sqlite3",
        "xml",
        "http",
        "queue",
        "threading",
        "argparse",
        "csv",
        "json",
        "datetime",
        "oracledb",
    ],
    # certifi — запасной набор корневых сертификатов для мастера настройки:
    # хранилище Windows на свежем сервере не знало цепочку GitHub
    "includes": ["tms_export", "certifi"],
    "excludes": ["test", "unittest"],
    "include_files": [
        ("README.md", "README.md"),
        ("GUIDE_ru.md", "GUIDE_ru.md"),
        ("API_ru.md", "API_ru.md"),
        ("INTEGRATION.md", "INTEGRATION.md"),
        ("INSTALL_WINDOWS_ru.md", "INSTALL_WINDOWS_ru.md"),
        ("INSTALL_MSI_ru.md", "INSTALL_MSI_ru.md"),
        ("INSTALL_RO.md", "INSTALL_RO.md"),
        ("LICENSE", "LICENSE"),
        ("app_icon.ico", "app_icon.ico"),
        # версия установки и манифест обновления — их сравнивает мастер настройки
        ("VERSION", "VERSION"),
        ("release.json", "release.json"),
        # стартовая база компаний: запасная копия на случай компьютера без интернета
        ("data/companies_seed.zip", "data/companies_seed.zip"),
        # SDK для Python/C++ — чтобы интеграция была под рукой сразу после установки
        ("sdk", "sdk"),
    ],
}

if _SEED_COMPANIES:
    # база компаний с данными — утилита сразу не пустая
    build_exe_options["include_files"].append((_SEED_COMPANIES, "companies.db"))

if _HAS_DEMO_CRM:
    build_exe_options["include_files"] += [
        (_DEMO_CRM_EXE, "DemoCRM/ContragentiCRM.exe"),
        # переводы интерфейса и описания бизнес-процессов лежат рядом с exe
        # и правятся без пересборки
        ("crm_delphi/lang.json", "DemoCRM/lang.json"),
        ("crm_delphi/processes.json", "DemoCRM/processes.json"),
        ("crm_delphi/README_ru.md", "DemoCRM/README_ru.md"),
        ("crm_delphi/sample_card.xml", "DemoCRM/sample_card.xml"),
    ]
    if _SEED_CLIENTS:
        # демо-база CRM с клиентами, сделками, заказами и задачами
        build_exe_options["include_files"].append((_SEED_CLIENTS, "DemoCRM/clients.db"))

# Тихий запуск GUI-приложения (без консольного окна)
base = "Win32GUI" if sys.platform == "win32" else None

executables = [
    # Первым — мастер настройки: cx_Freeze запускает executables[0] по галочке
    # «Launch on finish» в конце установки.
    Executable(
        "setup_wizard.py",
        base=base,
        target_name="ContragentiSetup.exe",
        icon="app_icon.ico",
        shortcut_name="Contragenti — настройка и обновление",
        shortcut_dir="ProgramMenuFolder",
    ),
    Executable(
        "company_search.py",
        base=base,
        target_name="Contragenti.exe",
        icon="app_icon.ico",
        shortcut_name="Contragenti",
        shortcut_dir="DesktopFolder",
    ),
]

if _HAS_DEMO_CRM:
    # cx_Freeze создаёт Executable только из .py-скрипта, поэтому готовый
    # ContragentiCRM.exe запускается через тонкий Python-лаунчер
    # (run_demo_crm.py) — это даёт Demo CRM собственный ярлык на рабочем столе.
    executables.append(
        Executable(
            "run_demo_crm.py",
            base=base,
            target_name="Demo CRM.exe",
            icon="app_icon.ico",
            shortcut_name="Demo CRM (SDK Contragenti)",
            shortcut_dir="DesktopFolder",
        )
    )

bdist_msi_options = {
    "upgrade_code": "{8E2C6C7A-6B0B-4C2C-9C7A-3B2D4E5F6A7B}",
    "add_to_path": False,
    # установка для всех пользователей в Program Files (msiexec попросит права
    # администратора); данные программы пишут в %LOCALAPPDATA%\Contragenti
    "all_users": True,
    "initial_target_dir": r"[ProgramFilesFolder]\Contragenti",
    "install_icon": "app_icon.ico",
    # в конце установки — галочка «Launch on finish»: запускает мастер настройки
    "launch_on_finish": True,
    # …а при тихой установке (msiexec /i … /qn) диалога нет, поэтому мастер
    # запускается пользовательским действием после InstallFinalize
    "data": {
        "CustomAction": [
            ("LaunchWizardAfterInstall", 226, "TARGETDIR", '"[TARGETDIR]ContragentiSetup.exe"'),
        ],
        "InstallExecuteSequence": [
            ("LaunchWizardAfterInstall", "NOT Installed AND NOT REMOVE", 6601),
        ],
    },
    "summary_data": {
        "author": "Pavel Tuhari",
        "comments": "Contragenti — поиск юридических лиц Молдовы (date.gov.md)",
    },
}

setup(
    name="Contragenti",
    version=APP_VERSION,
    description="Contragenti — поиск юридических лиц Молдовы (date.gov.md)",
    options={
        "build_exe": build_exe_options,
        "bdist_msi": bdist_msi_options,
    },
    executables=executables,
)
