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
"""

import os
import sys
from cx_Freeze import setup, Executable

APP_VERSION = "1.0.0"

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEMO_CRM_EXE = os.path.join(_HERE, "crm_delphi", "ContragentiCRM.exe")
_HAS_DEMO_CRM = os.path.exists(_DEMO_CRM_EXE)
if not _HAS_DEMO_CRM:
    print(f"[setup.py] предупреждение: {_DEMO_CRM_EXE} не найден — "
          "Demo CRM не будет включена в установку (см. crm_delphi/build.bat)")

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
    "includes": ["tms_export"],
    "excludes": ["test", "unittest"],
    "include_files": [
        ("README.md", "README.md"),
        ("GUIDE_ru.md", "GUIDE_ru.md"),
        ("API_ru.md", "API_ru.md"),
        ("INTEGRATION.md", "INTEGRATION.md"),
        ("LICENSE", "LICENSE"),
    ],
}

if _HAS_DEMO_CRM:
    build_exe_options["include_files"] += [
        (_DEMO_CRM_EXE, "DemoCRM/ContragentiCRM.exe"),
        # переводы интерфейса лежат рядом с exe и правятся без пересборки
        ("crm_delphi/lang.json", "DemoCRM/lang.json"),
        ("crm_delphi/README_ru.md", "DemoCRM/README_ru.md"),
        ("crm_delphi/sample_card.xml", "DemoCRM/sample_card.xml"),
    ]

# Тихий запуск GUI-приложения (без консольного окна)
base = "Win32GUI" if sys.platform == "win32" else None

executables = [
    Executable(
        "company_search.py",
        base=base,
        target_name="Contragenti.exe",
        icon="app_icon.ico",
        shortcut_name="Contragenti",
        shortcut_dir="DesktopFolder",
    )
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
    "all_users": False,
    "initial_target_dir": r"[LocalAppDataFolder]\Contragenti",
    "install_icon": "app_icon.ico",
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
