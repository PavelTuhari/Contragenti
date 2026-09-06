"""Лаунчер для Demo CRM внутри MSI-инсталлятора Contragenti.

Сама Demo CRM написана на Delphi (см. crm_delphi/) и не может быть
заморожена cx_Freeze вместе с Contragenti — это готовый бинарник
ContragentiCRM.exe, который кладётся в подкаталог DemoCRM/ установки
(см. setup.py, include_files). Этот скрипт — тонкая Python-обёртка вокруг
него, нужна только чтобы у Demo CRM был свой ярлык в меню Пуск/на рабочем
столе средствами cx_Freeze (Executable создаётся только из .py-скрипта).

При первом запуске также готовит crm.ini, чтобы кнопка «Создать клиента»
сразу работала — путь к Contragenti.exe уже известен (лежит рядом,
на уровень выше DemoCRM/).
"""

import os
import subprocess
import sys


def _app_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def _writable(path):
    probe = os.path.join(path, "~w%d.tmp" % os.getpid())
    try:
        with open(probe, "w") as f:
            f.write("")
        os.remove(probe)
        return True
    except OSError:
        return False


def _crm_data_dir(demo_dir):
    """Тот же выбор, что делает сама CRM (CrmDataDir в uClientsDB.pas): рядом с
    exe, если туда можно писать, иначе %LOCALAPPDATA%\\Contragenti\\DemoCRM."""
    in_pf = any(os.environ.get(e) and os.path.normcase(os.path.abspath(demo_dir)).startswith(
        os.path.normcase(os.path.abspath(os.environ[e])) + os.sep)
        for e in ("ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"))
    if _writable(demo_dir) and not in_pf:
        return demo_dir
    d = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "Contragenti", "DemoCRM")
    os.makedirs(d, exist_ok=True)
    return d


def _ensure_crm_ini(demo_dir, contragenti_exe):
    ini_path = os.path.join(_crm_data_dir(demo_dir), "crm.ini")
    if os.path.exists(ini_path):
        return  # не перезаписываем настройки, которые уже мог поменять пользователь
    with open(ini_path, "w", encoding="utf-8") as f:
        f.write("[contragenti]\n")
        f.write(f"launcher={contragenti_exe}\n")
        f.write("lang=ru\n")


def main():
    root = _app_dir()
    demo_dir = os.path.join(root, "DemoCRM")
    demo_exe = os.path.join(demo_dir, "ContragentiCRM.exe")
    contragenti_exe = os.path.join(root, "Contragenti.exe")

    if not os.path.exists(demo_exe):
        import ctypes
        ctypes.windll.user32.MessageBoxW(
            0,
            f"Demo CRM не найдена: {demo_exe}\n\n"
            "Переустановите Contragenti или соберите crm_delphi заново.",
            "Demo CRM", 0x10,
        )
        return 1

    _ensure_crm_ini(demo_dir, contragenti_exe)
    subprocess.Popen([demo_exe], cwd=demo_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
