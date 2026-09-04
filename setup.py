"""
Сборка Contragenti в exe и MSI-инсталлятор для Windows.

Использование:
    .venv\\Scripts\\python setup.py build          # только exe (build/exe.win-amd64-3.12/)
    .venv\\Scripts\\python setup.py bdist_msi       # exe + MSI-инсталлятор (dist/*.msi)
"""

import sys
from cx_Freeze import setup, Executable

APP_VERSION = "1.0.0"

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
        ("LICENSE", "LICENSE"),
    ],
}

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
