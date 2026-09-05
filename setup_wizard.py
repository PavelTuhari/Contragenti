"""
Мастер настройки после установки Contragenti (Windows).

Запускается MSI-инсталлятором на последнем шаге («Launch on finish») и
доступен позже из меню «Пуск» как «Contragenti — настройка и обновление».
Делает всё, что описано в INSTALL_WINDOWS_ru.md, но на уже установленной
копии и без ручных шагов:

  1. технический паспорт компьютера (ОС, память, диск, Chrome, Python, сеть);
  2. Python: если команда python ещё не работает, мастер в PowerShell
     запускает `python` — на свежих Windows интерпретатор ставится сам
     (App Installer / Store), без привязки к версии 3.12 и без exe с python.org;
  3. обновление компонентов из GitHub (Demo CRM, переводы, описания
     процессов, инструкции) — по списку из release.json репозитория;
     если в репозитории вышла новая версия MSI — предлагает скачать её;
  4. стартовая база компаний date.gov.md: zip из репозитория (data/
     companies_seed.zip), сливается с локальной companies.db по ключу IDNO —
     существующие записи не трогаются;
  5. настройка: crm.ini для Demo CRM (путь к Contragenti.exe, язык), язык в
     реестре (HKCU\\Software\\DemoCRM\\Language), каталог логов;
  6. демонстрационные данные Demo CRM (--seed-demo) — по желанию;
  7. самопроверка обеих программ (--selftest).

Каждый шаг пишется в install.log. Если что-то не так — собирается отчёт
(паспорт + лог + ошибки + последние события Windows Installer) и предлагается
отправить его разработчику: открыть заготовку issue на GitHub или письмо
(mailto) — отправляет сам пользователь, автоматически ничего не уходит.

Режимы:
    "Contragenti Setup.exe"            окно мастера (по умолчанию)
    "Contragenti Setup.exe" --check    без окна: все шаги, лог, код возврата
    "Contragenti Setup.exe" --lang ro  язык мастера (ro | en | ru)
    "Contragenti Setup.exe" --offline  не ходить в GitHub и не вызывать python
    "Contragenti Setup.exe" --no-python  не запускать команду python, даже если его нет
    "Contragenti Setup.exe" --auto --shot файл.png
                                       окно, шаги запускаются сами, в конце
                                       снимок своего окна (PrintWindow) и выход —
                                       для акта тестирования
"""

import ctypes
import datetime
import io
import json
import locale
import os
import platform
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
import urllib.request
import webbrowser
import zipfile

try:
    import winreg
except ImportError:  # не Windows — мастер только для Windows
    winreg = None

REPO = "PavelTuhari/Contragenti"
RAW_BASE = f"https://raw.githubusercontent.com/{REPO}/main/"
RELEASE_URL = RAW_BASE + "release.json"
REG_KEY = r"Software\DemoCRM"
NET_TIMEOUT = 12
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

# ────────────────────────────── i18n ──────────────────────────────

LANGS = ("ro", "en", "ru")
LANG_NAMES = {"ro": "Română", "en": "English", "ru": "Русский"}

TR = {
    "ru": {
        "title": "Contragenti — настройка после установки",
        "intro": "Мастер настроит компьютер так, чтобы Contragenti, Demo CRM и SDK заработали сразу. "
                 "Отметьте нужные шаги и нажмите «Выполнить».",
        "language": "Язык:",
        "opt_python": "Если нет Python — выполнить в PowerShell команду python (Windows ставит сам)",
        "opt_update": "Обновить компоненты из GitHub (Demo CRM, переводы, описания процессов)",
        "opt_db": "Загрузить стартовую базу компаний date.gov.md (zip из GitHub)",
        "opt_seed": "Заполнить Demo CRM демонстрационными данными",
        "opt_selftest": "Выполнить самопроверку Contragenti и Demo CRM",
        "opt_shortcuts": "Проверить ярлыки на рабочем столе",
        "run": "Выполнить",
        "close": "Закрыть",
        "open_report": "Открыть отчёт",
        "send_github": "Сообщить на GitHub",
        "send_mail": "Отправить на e-mail",
        "open_logs": "Папка логов",
        "copy": "Скопировать отчёт",
        "start_apps": "Запустить Contragenti и Demo CRM",
        "st_passport": "Технический паспорт системы",
        "st_chrome": "Google Chrome",
        "st_python": "Python",
        "st_net": "Доступ к GitHub",
        "st_release": "Новая версия в репозитории",
        "st_update": "Обновление компонентов",
        "st_db": "Стартовая база компаний",
        "st_config": "Настройка Demo CRM и реестра",
        "st_seed": "Демонстрационные данные Demo CRM",
        "st_shortcuts": "Ярлыки",
        "st_selftest": "Самопроверка",
        "ok": "OK",
        "warn": "ВНИМАНИЕ",
        "fail": "ОШИБКА",
        "skip": "пропущено",
        "done_ok": "Готово: все шаги выполнены. Contragenti и Demo CRM готовы к работе.",
        "done_warn": "Готово с замечаниями (%d). Программы работают, но посмотрите отчёт.",
        "done_fail": "Есть ошибки (%d). Отчёт с техническим паспортом и логом сохранён:\n%s\n"
                     "Отправьте его разработчику — кнопки ниже откроют заготовку issue или письма.",
        "chrome_missing": "Chrome не найден. Он нужен Contragenti для портала date.gov.md — "
                          "установите с google.com/chrome.",
        "chrome_get": "Скачать Chrome",
        "python_missing": "Команда python не работает. Contragenti.exe и Demo CRM работают без него; "
                          "нужен для sdk/python. В PowerShell выполните: python",
        "python_get": "Установить Python (команда python)",
        "python_offline": "Python не найден, команда python пропущена (нет сети / --offline).",
        "net_fail": "GitHub недоступен (%s). Обновление и загрузка базы пропущены; "
                    "программы работают и без них.",
        "new_version": "В репозитории версия %s (установлена %s). Скачать новый установщик?",
        "download_msi": "Скачать новую версию",
        "report_saved": "Отчёт сохранён: %s",
        "clipboard": "Полный отчёт скопирован в буфер обмена — вставьте его в issue или письмо.",
        "issue_title": "Установка Contragenti %s: %s",
        "mail_subject": "Contragenti: отчёт об установке (%s)",
    },
    "en": {
        "title": "Contragenti — post-install setup",
        "intro": "This wizard configures the computer so that Contragenti, Demo CRM and the SDK work right away. "
                 "Tick the steps you need and press Run.",
        "language": "Language:",
        "opt_python": "If Python is missing, run python in PowerShell (Windows installs it)",
        "opt_update": "Update components from GitHub (Demo CRM, translations, process descriptions)",
        "opt_db": "Download the starter company database from date.gov.md (zip from GitHub)",
        "opt_seed": "Fill Demo CRM with demo data",
        "opt_selftest": "Run self-tests of Contragenti and Demo CRM",
        "opt_shortcuts": "Check desktop shortcuts",
        "run": "Run",
        "close": "Close",
        "open_report": "Open report",
        "send_github": "Report on GitHub",
        "send_mail": "Send by e-mail",
        "open_logs": "Logs folder",
        "copy": "Copy report",
        "start_apps": "Start Contragenti and Demo CRM",
        "st_passport": "System passport",
        "st_chrome": "Google Chrome",
        "st_python": "Python",
        "st_net": "GitHub access",
        "st_release": "New version in the repository",
        "st_update": "Component update",
        "st_db": "Starter company database",
        "st_config": "Demo CRM and registry setup",
        "st_seed": "Demo CRM demo data",
        "st_shortcuts": "Shortcuts",
        "st_selftest": "Self-test",
        "ok": "OK",
        "warn": "WARNING",
        "fail": "ERROR",
        "skip": "skipped",
        "done_ok": "Done: all steps completed. Contragenti and Demo CRM are ready.",
        "done_warn": "Done with warnings (%d). The programs work, but please check the report.",
        "done_fail": "There are errors (%d). A report with the system passport and log is saved:\n%s\n"
                     "Send it to the developer — the buttons below open an issue or e-mail draft.",
        "chrome_missing": "Chrome not found. Contragenti needs it for the date.gov.md portal — "
                          "install it from google.com/chrome.",
        "chrome_get": "Get Chrome",
        "python_missing": "The python command does not work. Contragenti.exe and Demo CRM work without it; "
                          "it is needed for sdk/python. In PowerShell run: python",
        "python_get": "Install Python (python command)",
        "python_offline": "Python not found; python command skipped (offline / --offline).",
        "net_fail": "GitHub is unreachable (%s). Update and database download skipped; "
                    "the programs work without them.",
        "new_version": "The repository has version %s (installed %s). Download the new installer?",
        "download_msi": "Download new version",
        "report_saved": "Report saved: %s",
        "clipboard": "The full report is copied to the clipboard — paste it into the issue or e-mail.",
        "issue_title": "Contragenti %s install: %s",
        "mail_subject": "Contragenti: installation report (%s)",
    },
    "ro": {
        "title": "Contragenti — configurare după instalare",
        "intro": "Asistentul configurează calculatorul astfel încât Contragenti, Demo CRM și SDK să funcționeze imediat. "
                 "Bifați pașii necesari și apăsați „Execută”.",
        "language": "Limba:",
        "opt_python": "Dacă lipsește Python — execută python în PowerShell (Windows îl instalează)",
        "opt_update": "Actualizează componentele din GitHub (Demo CRM, traduceri, descrieri de procese)",
        "opt_db": "Descarcă baza inițială de companii date.gov.md (zip din GitHub)",
        "opt_seed": "Completează Demo CRM cu date demonstrative",
        "opt_selftest": "Execută autoverificarea Contragenti și Demo CRM",
        "opt_shortcuts": "Verifică scurtăturile de pe desktop",
        "run": "Execută",
        "close": "Închide",
        "open_report": "Deschide raportul",
        "send_github": "Raportează pe GitHub",
        "send_mail": "Trimite prin e-mail",
        "open_logs": "Dosarul cu loguri",
        "copy": "Copiază raportul",
        "start_apps": "Pornește Contragenti și Demo CRM",
        "st_passport": "Pașaportul tehnic al sistemului",
        "st_chrome": "Google Chrome",
        "st_python": "Python",
        "st_net": "Acces la GitHub",
        "st_release": "Versiune nouă în repozitoriu",
        "st_update": "Actualizarea componentelor",
        "st_db": "Baza inițială de companii",
        "st_config": "Configurare Demo CRM și registru",
        "st_seed": "Date demonstrative Demo CRM",
        "st_shortcuts": "Scurtături",
        "st_selftest": "Autoverificare",
        "ok": "OK",
        "warn": "ATENȚIE",
        "fail": "EROARE",
        "skip": "omis",
        "done_ok": "Gata: toți pașii au fost executați. Contragenti și Demo CRM sunt pregătite.",
        "done_warn": "Gata, cu observații (%d). Programele funcționează, dar verificați raportul.",
        "done_fail": "Există erori (%d). Raportul cu pașaportul tehnic și logul este salvat:\n%s\n"
                     "Trimiteți-l dezvoltatorului — butoanele de mai jos deschid un issue sau un e-mail.",
        "chrome_missing": "Chrome nu a fost găsit. Contragenti are nevoie de el pentru portalul date.gov.md — "
                          "instalați-l de pe google.com/chrome.",
        "chrome_get": "Descarcă Chrome",
        "python_missing": "Comanda python nu funcționează. Contragenti.exe și Demo CRM funcționează fără ea; "
                          "este necesară pentru sdk/python. În PowerShell: python",
        "python_get": "Instalează Python (comanda python)",
        "python_offline": "Python nu a fost găsit; comanda python a fost omisă (offline / --offline).",
        "net_fail": "GitHub nu este accesibil (%s). Actualizarea și descărcarea bazei au fost omise; "
                    "programele funcționează și fără ele.",
        "new_version": "În repozitoriu este versiunea %s (instalată %s). Descărcați noul instalator?",
        "download_msi": "Descarcă versiunea nouă",
        "report_saved": "Raport salvat: %s",
        "clipboard": "Raportul complet este copiat în clipboard — lipiți-l în issue sau în e-mail.",
        "issue_title": "Instalare Contragenti %s: %s",
        "mail_subject": "Contragenti: raport de instalare (%s)",
    },
}


# ────────────────────────────── пути ──────────────────────────────

def app_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def is_frozen():
    return bool(getattr(sys, "frozen", False))


class Paths:
    def __init__(self):
        self.root = app_dir()
        # из исходников (не frozen) Demo CRM лежит в crm_delphi/, в установке — в DemoCRM/
        self.demo_dir = os.path.join(self.root, "DemoCRM")
        if not os.path.isdir(self.demo_dir) and os.path.isdir(os.path.join(self.root, "crm_delphi")):
            self.demo_dir = os.path.join(self.root, "crm_delphi")
        self.demo_exe = os.path.join(self.demo_dir, "ContragentiCRM.exe")
        self.contragenti_exe = os.path.join(self.root, "Contragenti.exe")
        self.contragenti_py = os.path.join(self.root, "company_search.py")
        self.companies_db = os.path.join(self.root, "companies.db")
        self.version_file = os.path.join(self.root, "VERSION")
        self.logs = os.path.join(self.root, "logs")
        try:
            os.makedirs(self.logs, exist_ok=True)
            with open(os.path.join(self.logs, ".w"), "w") as f:
                f.write("")
            os.remove(os.path.join(self.logs, ".w"))
        except OSError:
            self.logs = os.path.join(os.environ.get("LOCALAPPDATA", tempfile.gettempdir()),
                                     "Contragenti", "logs")
            os.makedirs(self.logs, exist_ok=True)
        self.log_file = os.path.join(self.logs, "install.log")

    def installed_version(self):
        try:
            with open(self.version_file, encoding="utf-8") as f:
                return f.read().strip() or "0"
        except OSError:
            return "0"


def ver_tuple(v):
    out = []
    for part in str(v).replace("-", ".").split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out)


# ────────────────────────────── реестр / язык ──────────────────────────────

def reg_read_lang():
    if winreg is None:
        return ""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REG_KEY) as k:
            v, _ = winreg.QueryValueEx(k, "Language")
            return str(v).strip().lower()
    except OSError:
        return ""


def reg_write_lang(code):
    if winreg is None:
        return
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, REG_KEY) as k:
        winreg.SetValueEx(k, "Language", 0, winreg.REG_SZ, code)


def default_lang():
    code = reg_read_lang()
    if code in LANGS:
        return code
    try:
        loc = (locale.getlocale()[0] or "").lower()
    except Exception:  # noqa: BLE001
        loc = ""
    if winreg is not None:
        try:
            ui = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF
            loc = {0x18: "ro", 0x19: "ru", 0x09: "en"}.get(ui, loc)
        except Exception:  # noqa: BLE001
            pass
    for code in LANGS:
        if loc.startswith(code):
            return code
    return "ro"


# ────────────────────────────── паспорт ──────────────────────────────

def find_chrome():
    """Путь и версия Chrome: App Paths в реестре, затем типичные каталоги."""
    candidates = []
    if winreg is not None:
        for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
            try:
                with winreg.OpenKey(hive, r"Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe") as k:
                    v, _ = winreg.QueryValueEx(k, "")
                    candidates.append(v)
            except OSError:
                pass
    for env in ("ProgramFiles", "ProgramFiles(x86)", "LocalAppData"):
        base = os.environ.get(env)
        if base:
            candidates.append(os.path.join(base, "Google", "Chrome", "Application", "chrome.exe"))
    for path in candidates:
        if path and os.path.exists(path):
            version = ""
            try:
                folder = os.path.dirname(path)
                versions = [d for d in os.listdir(folder) if d[:1].isdigit() and "." in d]
                versions.sort(key=ver_tuple)
                if versions:
                    version = versions[-1]
            except OSError:
                pass
            if not version and winreg is not None:
                try:
                    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Google\Chrome\BLBeacon") as k:
                        version, _ = winreg.QueryValueEx(k, "version")
                except OSError:
                    pass
            return path, version
    return "", ""


def find_python():
    """Рабочий интерпретатор: команда python (как в PowerShell), иначе py -3.

    Заглушка Windows «Python was not found» даёт код ≠ 0 и не печатает версию —
    это считается «Python нет». После автоустановки Windows та же команда python
    начинает возвращать номер версии (3.13, 3.14, … — не обязательно 3.12).
    """
    for cmd in (["python", "-c", "import sys;print(sys.version.split()[0])"],
                ["py", "-3", "-c", "import sys;print(sys.version.split()[0])"],
                ["python3", "-c", "import sys;print(sys.version.split()[0])"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=20,
                                 creationflags=_NO_WINDOW, errors="replace")
            v = (out.stdout or "").strip().splitlines()
            v = v[-1].strip() if v else ""
            if out.returncode == 0 and v and v[0].isdigit():
                return cmd[0], v
        except (OSError, subprocess.SubprocessError):
            continue
    return "", ""


def _powershell():
    root = os.environ.get("SystemRoot", r"C:\Windows")
    return os.path.join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


def refresh_env_path():
    """PATH текущего процесса = Machine+User из реестра (после установки Python)."""
    if winreg is None:
        return
    parts = []
    for hive, key in (
        (winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
        (winreg.HKEY_CURRENT_USER, "Environment"),
    ):
        try:
            with winreg.OpenKey(hive, key) as k:
                v, _ = winreg.QueryValueEx(k, "Path")
                if v:
                    parts.append(str(v))
        except OSError:
            continue
    if parts:
        os.environ["PATH"] = os.pathsep.join(parts)


def trigger_windows_python(quiet=False):
    """Как на свежих Windows: в PowerShell команда `python` ставит интерпретатор сама."""
    # Без аргументов App Installer / Store ставит Python. С -c заглушка только пишет
    # «run without arguments to install» — поэтому сначала пробуем -c, иначе просто python.
    script = (
        "$ErrorActionPreference = 'Continue'; "
        "$v = & python -c 'import sys; print(sys.version.split()[0])' 2>&1 | Out-String; "
        "if ($LASTEXITCODE -eq 0 -and $v -match '\\d+\\.\\d+') { "
        "  Write-Output $v.Trim(); exit 0 "
        "}; "
        "Write-Output $v; "
        "Write-Output 'windows-auto-install'; "
        "& python; "
        "exit $LASTEXITCODE"
    )
    kwargs = {"timeout": 600, "errors": "replace", "text": True}
    if quiet:
        kwargs["capture_output"] = True
        kwargs["creationflags"] = _NO_WINDOW
    else:
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
    return subprocess.run(
        [_powershell(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        **kwargs,
    )


def memory_mb():
    try:
        class MemStatus(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        st = MemStatus()
        st.dwLength = ctypes.sizeof(MemStatus)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
        return st.ullTotalPhys // (1024 * 1024), st.ullAvailPhys // (1024 * 1024)
    except Exception:  # noqa: BLE001
        return 0, 0


def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:  # noqa: BLE001
        return False


def file_info(path):
    if not os.path.exists(path):
        return "нет"
    st = os.stat(path)
    return "%d байт, %s" % (st.st_size, datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M"))


def db_rows(path, table):
    if not os.path.exists(path):
        return "нет файла"
    try:
        conn = sqlite3.connect(path)
        try:
            return str(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
        finally:
            conn.close()
    except sqlite3.Error as exc:
        return f"ошибка: {exc}"


def msi_events(limit=15):
    """Последние события Windows Installer из журнала приложений — лог MSI."""
    try:
        out = subprocess.run(
            ["wevtutil", "qe", "Application",
             "/q:*[System[Provider[@Name='MsiInstaller']]]",
             f"/c:{limit}", "/rd:true", "/f:text"],
            capture_output=True, text=True, timeout=20, errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        text = (out.stdout or "").strip()
        return text if text else "(событий MsiInstaller нет)"
    except (OSError, subprocess.SubprocessError) as exc:
        return f"(журнал недоступен: {exc})"


def passport(paths):
    chrome_path, chrome_ver = find_chrome()
    py_cmd, py_ver = find_python()
    total, avail = memory_mb()
    try:
        du = shutil.disk_usage(paths.root)
        disk = "%d МБ свободно из %d МБ" % (du.free // 2**20, du.total // 2**20)
    except OSError:
        disk = "?"
    wv = sys.getwindowsversion() if hasattr(sys, "getwindowsversion") else None
    lines = [
        ("Дата", datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
        ("ОС", platform.platform()),
        ("Сборка Windows", "%d.%d.%d" % (wv.major, wv.minor, wv.build) if wv else "?"),
        ("Архитектура", platform.machine()),
        ("Компьютер / пользователь", "%s / %s" % (os.environ.get("COMPUTERNAME", "?"), os.environ.get("USERNAME", "?"))),
        ("Права администратора", "да" if is_admin() else "нет"),
        ("Локаль", "%s; UI lang code %s" % (locale.getlocale(), reg_read_lang() or "-")),
        ("Память", "%d МБ, свободно %d МБ" % (total, avail)),
        ("Диск установки", disk),
        ("Каталог установки", paths.root),
        ("Версия установки", paths.installed_version()),
        ("Python мастера", "%s (frozen=%s)" % (sys.version.split()[0], is_frozen())),
        ("Contragenti.exe", file_info(paths.contragenti_exe)),
        ("ContragentiCRM.exe", file_info(paths.demo_exe)),
        ("lang.json", file_info(os.path.join(paths.demo_dir, "lang.json"))),
        ("processes.json", file_info(os.path.join(paths.demo_dir, "processes.json"))),
        ("companies.db", "%s (компаний: %s)" % (file_info(paths.companies_db), db_rows(paths.companies_db, "companies"))),
        ("clients.db", "%s (клиентов: %s)" % (file_info(os.path.join(paths.demo_dir, "clients.db")),
                                              db_rows(os.path.join(paths.demo_dir, "clients.db"), "clients"))),
        ("Google Chrome", "%s %s" % (chrome_path or "не найден", chrome_ver)),
        ("Python (команда python)", "%s %s" % (py_cmd or "не найден", py_ver)),
        ("Прокси", "%s" % (os.environ.get("HTTPS_PROXY") or os.environ.get("HTTP_PROXY") or "-")),
    ]
    return lines, {
        "chrome": chrome_path, "chrome_ver": chrome_ver,
        "python": py_cmd, "python_ver": py_ver,
    }


# ────────────────────────────── сеть / GitHub ──────────────────────────────

def http_get(url, timeout=NET_TIMEOUT):
    req = urllib.request.Request(url, headers={"User-Agent": "Contragenti-Setup/1.1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def download_to(url, dst, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "Contragenti-Setup/1.1"})
    tmp = dst + ".part"
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(tmp, "wb") as f:
        shutil.copyfileobj(resp, f)
    os.replace(tmp, dst)
    return os.path.getsize(dst)


def load_release():
    data = http_get(RELEASE_URL)
    return json.loads(data.decode("utf-8-sig"))


def sha256_of(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def merge_companies(seed_db, target_db):
    """Слить стартовую базу в локальную: новые ключи добавляются, существующие
    записи не трогаются (данные пользователя важнее стартовых)."""
    conn = sqlite3.connect(target_db)
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS companies (
                key TEXT PRIMARY KEY, idno TEXT, denumire TEXT, administratori TEXT,
                inregistrare TEXT, forma_juridica TEXT, lichidata TEXT, adresa TEXT,
                details_text TEXT, founders_json TEXT, debts_json TEXT, updated_at TEXT)""")
        have = {r[1] for r in conn.execute("PRAGMA table_info(companies)")}
        for col in ("founders_json", "debts_json"):
            if col not in have:
                conn.execute(f"ALTER TABLE companies ADD COLUMN {col} TEXT")
        before = conn.execute("SELECT COUNT(*) FROM companies").fetchone()[0]
        conn.execute("ATTACH DATABASE ? AS seed", (seed_db,))
        cols = [r[1] for r in conn.execute("PRAGMA seed.table_info(companies)")]
        cols = [c for c in cols if c in have or c in ("key", "idno", "denumire", "administratori",
                                                        "inregistrare", "forma_juridica", "lichidata",
                                                        "adresa", "details_text", "founders_json",
                                                        "debts_json", "updated_at")]
        col_list = ", ".join(cols)
        conn.execute(f"INSERT OR IGNORE INTO companies ({col_list}) SELECT {col_list} FROM seed.companies")
        conn.commit()
        after = conn.execute("SELECT COUNT(*) FROM companies").fetchone()[0]
        conn.execute("DETACH DATABASE seed")
        return before, after
    finally:
        conn.close()


# ────────────────────────────── шаги ──────────────────────────────

class Step:
    def __init__(self, key, status, detail=""):
        self.key = key
        self.status = status    # ok | warn | fail | skip
        self.detail = detail


class Wizard:
    """Логика шагов, независимая от окна: используется и GUI, и --check."""

    def __init__(self, lang, options, log_cb=None, ask_cb=None, offline=False):
        self.lang = lang if lang in LANGS else "ro"
        self.t = TR[self.lang]
        self.opt = options
        self.paths = Paths()
        self.steps = []
        self.passport_lines = []
        self.info = {}
        self.release = None
        self.log_lines = []
        self.log_cb = log_cb
        self.ask_cb = ask_cb          # (text) -> bool; в --check всегда False
        self.offline = offline
        self.quiet = bool(options.get("quiet"))
        self.report_file = ""
        self.new_msi_url = ""
        self._log_fh = open(self.paths.log_file, "a", encoding="utf-8")
        self.log("===== %s (%s) =====" % (self.t["title"], datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
        self.log("cmd: %s" % " ".join(sys.argv))

    # ---- журнал ----
    def log(self, text):
        line = "%s  %s" % (datetime.datetime.now().strftime("%H:%M:%S"), text)
        self.log_lines.append(line)
        try:
            self._log_fh.write(line + "\n")
            self._log_fh.flush()
        except OSError:
            pass
        if self.log_cb:
            try:
                self.log_cb(line)
            except Exception:  # noqa: BLE001 — сбой вывода не должен ронять шаг
                pass

    def step(self, key, status, detail=""):
        self.steps.append(Step(key, status, detail))
        label = {"ok": self.t["ok"], "warn": self.t["warn"], "fail": self.t["fail"], "skip": self.t["skip"]}[status]
        self.log("[%s] %s%s" % (label, self.t[key], (": " + detail) if detail else ""))

    def counts(self):
        fails = sum(1 for s in self.steps if s.status == "fail")
        warns = sum(1 for s in self.steps if s.status == "warn")
        return fails, warns

    # ---- запуск программ ----
    def run_exe(self, args, log_name, timeout=180):
        """GUI-exe (и cx_Freeze Win32GUI, и Delphi) не пишут в pipe — вывод в файл."""
        out_path = os.path.join(self.paths.logs, log_name)
        with open(out_path, "w", encoding="utf-8", errors="replace") as fh:
            proc = subprocess.run(args, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout,
                                  cwd=os.path.dirname(args[0]),
                                  creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            with open(out_path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            text = ""
        return proc.returncode, text

    # ---- шаги ----
    def do_passport(self):
        try:
            self.passport_lines, self.info = passport(self.paths)
            for k, v in self.passport_lines:
                self.log("  %-26s %s" % (k + ":", v))
            self.step("st_passport", "ok", self.passport_lines[1][1])
        except Exception as exc:  # noqa: BLE001
            self.step("st_passport", "warn", str(exc))

    def do_chrome(self):
        if self.info.get("chrome"):
            self.step("st_chrome", "ok", "%s %s" % (self.info["chrome"], self.info.get("chrome_ver", "")))
        else:
            self.step("st_chrome", "warn", self.t["chrome_missing"])

    def do_python(self):
        cmd, ver = find_python()
        if cmd:
            self.info["python"] = cmd
            self.info["python_ver"] = ver
            self.step("st_python", "ok", "%s %s" % (cmd, ver))
            return
        if not self.opt.get("python", True):
            self.step("st_python", "warn", self.t["python_missing"])
            return
        if self.offline:
            self.step("st_python", "warn", self.t["python_offline"])
            return
        try:
            self.log("команда python не работает — запускаем её в PowerShell (Windows ставит сам)")
            proc = trigger_windows_python(quiet=self.quiet)
            tail = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
            self.log("python: код %d %s" % (proc.returncode, tail[:400].replace("\n", " | ")))
            refresh_env_path()
            cmd, ver = find_python()
            if not cmd:
                for _ in range(40):
                    time.sleep(3)
                    refresh_env_path()
                    cmd, ver = find_python()
                    if cmd:
                        break
            if cmd:
                self.info["python"] = cmd
                self.info["python_ver"] = ver
                self.step("st_python", "ok", "после команды python: %s %s" % (cmd, ver))
            else:
                self.step("st_python", "warn", self.t["python_missing"])
        except Exception as exc:  # noqa: BLE001
            self.step("st_python", "warn", "%s %s" % (self.t["python_missing"], exc))

    def do_network(self):
        if self.offline:
            self.step("st_net", "skip", "--offline")
            return False
        try:
            self.release = load_release()
            self.step("st_net", "ok", "release.json: version %s" % self.release.get("version", "?"))
            return True
        except Exception as exc:  # noqa: BLE001
            self.release = None
            self.step("st_net", "warn", self.t["net_fail"] % exc)
            return False

    def do_release(self):
        if not self.release:
            self.step("st_release", "skip")
            return
        remote = str(self.release.get("version", "0"))
        local = self.paths.installed_version()
        msi = self.release.get("msi_url") or ""
        if ver_tuple(remote) > ver_tuple(local) and msi:
            self.new_msi_url = msi
            self.step("st_release", "warn", self.t["new_version"] % (remote, local))
            if self.ask_cb and self.ask_cb(self.t["new_version"] % (remote, local)):
                dst = os.path.join(self.paths.logs, os.path.basename(urllib.parse.urlparse(msi).path) or "Contragenti.msi")
                try:
                    size = download_to(msi, dst, timeout=600)
                    want = (self.release.get("msi_sha256") or "").lower()
                    if want and sha256_of(dst) != want:
                        raise ValueError("sha256 MSI не совпал с release.json — файл не запущен")
                    self.log("MSI: %s (%d байт)" % (dst, size))
                    os.startfile(dst)  # noqa: S606 — установщик запускает сам пользователь
                except Exception as exc:  # noqa: BLE001
                    self.step("st_release", "fail", str(exc))
        elif ver_tuple(remote) > ver_tuple(local):
            self.step("st_release", "warn", "%s > %s, msi_url в release.json пуст — обновляются только компоненты" % (remote, local))
        else:
            self.step("st_release", "ok", "%s (installed %s)" % (remote, local))

    def target_path(self, dst_rel):
        """Путь в установке; из исходников Demo CRM лежит в crm_delphi/, а не в DemoCRM/."""
        dst = os.path.join(self.paths.root, dst_rel.replace("/", os.sep))
        if dst_rel.startswith("DemoCRM/") and not os.path.isdir(os.path.join(self.paths.root, "DemoCRM")):
            dst = os.path.join(self.paths.demo_dir, dst_rel[len("DemoCRM/"):])
        return dst

    def apply_file(self, dst_rel, new_b, is_exe):
        """Кладёт файл поверх установки. Возвращает 'same' | 'updated'."""
        dst = self.target_path(dst_rel)
        if is_exe and (new_b[:2] != b"MZ" or len(new_b) < 100000):
            raise ValueError("не exe (LFS-указатель или обрыв): %d байт" % len(new_b))
        if os.path.exists(dst):
            with open(dst, "rb") as f1:
                old_b = f1.read()
            # текстовые файлы: в установке CRLF (git на Windows), из GitHub — LF
            same = old_b == new_b if is_exe else \
                old_b.replace(b"\r\n", b"\n") == new_b.replace(b"\r\n", b"\n")
            if same:
                self.log("  = %s (без изменений, %d байт)" % (dst_rel, len(new_b)))
                return "same"
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = dst + ".new"
        with open(tmp, "wb") as fh:
            fh.write(new_b)
        if os.path.exists(dst):
            bak = dst + ".bak"
            if os.path.exists(bak):
                os.remove(bak)
            os.replace(dst, bak)
        os.replace(tmp, dst)
        self.log("  + %s (%d байт)" % (dst_rel, len(new_b)))
        return "updated"

    def update_from_zip(self):
        """Один zip-пакет release/Contragenti-update-<версия>.zip вместо
        десятка запросов; sha256 сверяется с release.json."""
        url = self.release.get("update_zip") or ""
        if not url:
            return None
        tmpdir = tempfile.mkdtemp(prefix="contragenti_upd_")
        try:
            zpath = os.path.join(tmpdir, "update.zip")
            size = download_to(url, zpath, timeout=300)
            want = (self.release.get("update_zip_sha256") or "").lower()
            got = sha256_of(zpath)
            if want and got != want:
                raise ValueError("sha256 zip не совпал: %s ≠ %s" % (got[:12], want[:12]))
            self.log("  zip %s: %d байт, sha256 %s" % (os.path.basename(url), size, got[:12]))
            updated, errors, total = [], [], 0
            with zipfile.ZipFile(zpath) as zf:
                for info in zf.infolist():
                    if info.is_dir() or info.filename in ("VERSION", "release.json"):
                        continue
                    total += 1
                    try:
                        res = self.apply_file(info.filename, zf.read(info),
                                              info.filename.lower().endswith(".exe"))
                        if res == "updated":
                            updated.append(info.filename)
                    except Exception as exc:  # noqa: BLE001
                        errors.append("%s: %s" % (info.filename, exc))
                        self.log("  ! %s: %s" % (info.filename, exc))
            return updated, errors, total
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def update_from_components(self):
        comps = self.release.get("components", [])
        updated, errors = [], []
        for comp in comps:
            src, dst_rel = comp.get("src"), comp.get("dst")
            if not src or not dst_rel:
                continue
            try:
                res = self.apply_file(dst_rel, http_get(RAW_BASE + src, timeout=120),
                                      comp.get("kind") == "exe")
                if res == "updated":
                    updated.append(dst_rel)
            except Exception as exc:  # noqa: BLE001
                errors.append("%s: %s" % (dst_rel, exc))
                self.log("  ! %s: %s" % (dst_rel, exc))
        return updated, errors, len(comps)

    def do_update(self):
        if not self.opt.get("update", True):
            self.step("st_update", "skip")
            return
        if not self.release:
            self.step("st_update", "skip", "GitHub")
            return
        result = None
        try:
            result = self.update_from_zip()
        except Exception as exc:  # noqa: BLE001
            self.log("  zip-пакет недоступен (%s) — по отдельным файлам" % exc)
        if result is None:
            result = self.update_from_components()
        updated, errors, total = result
        if errors and not updated:
            self.step("st_update", "fail", "; ".join(errors))
        elif errors:
            self.step("st_update", "warn", "обновлено %d, ошибок %d: %s" % (len(updated), len(errors), "; ".join(errors)))
        else:
            self.step("st_update", "ok", "обновлено %d из %d" % (len(updated), total))

    def do_database(self):
        if not self.opt.get("db", True):
            self.step("st_db", "skip")
            return
        zip_rel = (self.release or {}).get("database", {}).get("zip", "data/companies_seed.zip")
        local_zip = os.path.join(self.paths.root, zip_rel.replace("/", os.sep))
        tmpdir = tempfile.mkdtemp(prefix="contragenti_seed_")
        try:
            zpath = os.path.join(tmpdir, "seed.zip")
            source = ""
            if self.release:
                try:
                    size = download_to(RAW_BASE + zip_rel, zpath)
                    source = "GitHub (%d байт)" % size
                except Exception as exc:  # noqa: BLE001
                    self.log("  zip из GitHub недоступен: %s" % exc)
            if not source and os.path.exists(local_zip):
                shutil.copy(local_zip, zpath)
                source = "локальная копия из установки"
            if not source:
                self.step("st_db", "warn", "стартовая база недоступна ни из GitHub, ни из установки")
                return
            with zipfile.ZipFile(zpath) as zf:
                names = [n for n in zf.namelist() if n.lower().endswith(".db")]
                if not names:
                    raise ValueError("в zip нет .db")
                zf.extract(names[0], tmpdir)
            seed_db = os.path.join(tmpdir, names[0])
            before, after = merge_companies(seed_db, self.paths.companies_db)
            self.step("st_db", "ok", "%s; компаний было %d, стало %d" % (source, before, after))
        except Exception as exc:  # noqa: BLE001
            self.step("st_db", "fail", str(exc))
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def do_config(self):
        try:
            launcher = self.paths.contragenti_exe if os.path.exists(self.paths.contragenti_exe) \
                else self.paths.contragenti_py
            ini = os.path.join(self.paths.demo_dir, "crm.ini")
            os.makedirs(self.paths.demo_dir, exist_ok=True)
            if os.path.exists(ini):
                # уже настроено пользователем — правим только язык, лаунчер не трогаем
                with open(ini, encoding="utf-8-sig") as fh:
                    text = fh.read()
                if "launcher=" not in text:
                    text += "\nlauncher=%s\n" % launcher
                self.log("  crm.ini существует — лаунчер оставлен, язык: %s" % self.lang)
                lines = []
                for line in text.splitlines():
                    if line.strip().startswith("lang="):
                        line = "lang=%s" % self.lang
                    lines.append(line)
                text = "\n".join(lines) + "\n"
            else:
                text = "[contragenti]\nlauncher=%s\nlang=%s\n" % (launcher, self.lang)
            with open(ini, "w", encoding="utf-8") as fh:
                fh.write(text)
            reg_write_lang(self.lang)
            self.step("st_config", "ok", "crm.ini → %s; HKCU\\%s\\Language=%s" % (launcher, REG_KEY, self.lang))
        except Exception as exc:  # noqa: BLE001
            self.step("st_config", "fail", str(exc))

    def do_seed(self):
        if not self.opt.get("seed", True):
            self.step("st_seed", "skip")
            return
        if not os.path.exists(self.paths.demo_exe):
            self.step("st_seed", "fail", "нет %s" % self.paths.demo_exe)
            return
        try:
            code, text = self.run_exe([self.paths.demo_exe, "--seed-demo"], "seed_demo.log")
            tail = " ".join(text.strip().splitlines()[-2:]) if text.strip() else ""
            self.step("st_seed", "ok" if code == 0 else "fail", "код %d %s" % (code, tail[:200]))
        except Exception as exc:  # noqa: BLE001
            self.step("st_seed", "fail", str(exc))

    def do_shortcuts(self):
        if not self.opt.get("shortcuts", True):
            self.step("st_shortcuts", "skip")
            return
        try:
            desk = os.path.join(os.environ.get("USERPROFILE", ""), "Desktop")
            found = [f for f in os.listdir(desk) if f.lower().endswith(".lnk") and
                     ("contragenti" in f.lower() or "demo crm" in f.lower())] if os.path.isdir(desk) else []
            if found:
                self.step("st_shortcuts", "ok", ", ".join(found))
            else:
                self.step("st_shortcuts", "warn", "ярлыков Contragenti на рабочем столе нет (их создаёт MSI)")
        except Exception as exc:  # noqa: BLE001
            self.step("st_shortcuts", "warn", str(exc))

    def do_selftest(self):
        if not self.opt.get("selftest", True):
            self.step("st_selftest", "skip")
            return
        results = []
        ok = True
        if os.path.exists(self.paths.contragenti_exe):
            try:
                code, text = self.run_exe([self.paths.contragenti_exe, "--selftest"], "selftest_contragenti.log")
                passed = code == 0 and "PASS" in text
                ok &= passed
                results.append("Contragenti: %s" % ("PASS" if passed else "FAIL (код %d)" % code))
            except Exception as exc:  # noqa: BLE001
                ok = False
                results.append("Contragenti: %s" % exc)
        else:
            results.append("Contragenti.exe: нет (запуск из исходников)")
        if os.path.exists(self.paths.demo_exe):
            try:
                code, text = self.run_exe([self.paths.demo_exe, "--selftest"], "selftest_democrm.log")
                passed = code == 0 and "True" in text
                ok &= passed
                results.append("Demo CRM: %s" % ("PASS" if passed else "FAIL (код %d)" % code))
            except Exception as exc:  # noqa: BLE001
                ok = False
                results.append("Demo CRM: %s" % exc)
        else:
            ok = False
            results.append("ContragentiCRM.exe: нет")
        self.step("st_selftest", "ok" if ok else "fail", "; ".join(results))

    def run_all(self):
        self.do_passport()
        self.do_chrome()
        self.do_python()
        self.do_network()
        self.do_release()
        self.do_update()
        self.do_database()
        self.do_config()
        self.do_seed()
        self.do_shortcuts()
        self.do_selftest()
        self.report_file = self.write_report()
        fails, warns = self.counts()
        self.log("итог: ошибок %d, замечаний %d" % (fails, warns))
        return fails == 0

    # ---- отчёт ----
    def report_text(self, with_events=True):
        buf = io.StringIO()
        buf.write("Contragenti — отчёт об установке / setup report\n")
        buf.write("=" * 60 + "\n\n")
        buf.write("ТЕХНИЧЕСКИЙ ПАСПОРТ\n")
        for k, v in self.passport_lines:
            buf.write("  %-26s %s\n" % (k + ":", v))
        buf.write("\nШАГИ\n")
        for s in self.steps:
            buf.write("  [%-4s] %s%s\n" % (s.status.upper(), self.t[s.key], (": " + s.detail) if s.detail else ""))
        fails = [s for s in self.steps if s.status == "fail"]
        if fails:
            buf.write("\nОШИБКИ\n")
            for s in fails:
                buf.write("  %s: %s\n" % (self.t[s.key], s.detail))
        buf.write("\nЛОГ УСТАНОВКИ (%s)\n" % self.paths.log_file)
        for line in self.log_lines:
            buf.write("  " + line + "\n")
        if with_events:
            buf.write("\nWINDOWS INSTALLER (последние события)\n")
            buf.write(msi_events())
            buf.write("\n")
        return buf.getvalue()

    def write_report(self):
        name = "install_report_%s.txt" % datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        path = os.path.join(self.paths.logs, name)
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(self.report_text())
            self.log(self.t["report_saved"] % path)
        except OSError as exc:
            self.log("не удалось записать отчёт: %s" % exc)
        return path

    def developer(self):
        dev = (self.release or {}).get("developer", {})
        return {
            "issues": dev.get("github_issues") or f"https://github.com/{REPO}/issues/new",
            "email": dev.get("email") or "ptuhari@gmail.com",
        }

    def issue_url(self):
        fails, warns = self.counts()
        verdict = "ошибок %d, замечаний %d" % (fails, warns)
        title = self.t["issue_title"] % (self.paths.installed_version(), verdict)
        body = self.report_text(with_events=False)
        body = "```\n" + body[:5500] + ("\n...(полный отчёт — в буфере обмена)" if len(body) > 5500 else "") + "\n```"
        return self.developer()["issues"] + "?" + urllib.parse.urlencode({"title": title, "body": body})

    def mailto_url(self):
        subject = self.t["mail_subject"] % self.paths.installed_version()
        body = self.report_text(with_events=False)[:4000]
        return "mailto:%s?%s" % (self.developer()["email"],
                                 urllib.parse.urlencode({"subject": subject, "body": body}).replace("+", "%20"))

    def close(self):
        try:
            self._log_fh.close()
        except OSError:
            pass


# ────────────────────────────── снимок окна ──────────────────────────────

def capture_window(hwnd, path):
    """Снимок собственного окна через PrintWindow: работает и в заблокированном
    сеансе, где ImageGrab даёт чёрный кадр."""
    from ctypes import wintypes
    user32, gdi32 = ctypes.windll.user32, ctypes.windll.gdi32
    for fn in (user32.GetWindowDC, gdi32.CreateCompatibleDC, gdi32.CreateCompatibleBitmap,
               gdi32.SelectObject):
        fn.restype = ctypes.c_void_p
    gdi32.CreateCompatibleDC.argtypes = [ctypes.c_void_p]
    gdi32.CreateCompatibleBitmap.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    gdi32.SelectObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    gdi32.DeleteObject.argtypes = [ctypes.c_void_p]
    gdi32.DeleteDC.argtypes = [ctypes.c_void_p]
    user32.ReleaseDC.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    user32.PrintWindow.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint]
    gdi32.GetDIBits.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint,
                                ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint]

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [("biSize", ctypes.c_uint32), ("biWidth", ctypes.c_int32), ("biHeight", ctypes.c_int32),
                    ("biPlanes", ctypes.c_uint16), ("biBitCount", ctypes.c_uint16),
                    ("biCompression", ctypes.c_uint32), ("biSizeImage", ctypes.c_uint32),
                    ("biXPelsPerMeter", ctypes.c_int32), ("biYPelsPerMeter", ctypes.c_int32),
                    ("biClrUsed", ctypes.c_uint32), ("biClrImportant", ctypes.c_uint32)]

    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    hdc = user32.GetWindowDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    old = gdi32.SelectObject(mdc, bmp)
    try:
        user32.PrintWindow(hwnd, mdc, 2)  # PW_RENDERFULLCONTENT
        bmi = BITMAPINFOHEADER()
        bmi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bmi.biWidth, bmi.biHeight, bmi.biPlanes, bmi.biBitCount = w, -h, 1, 32
        buf = ctypes.create_string_buffer(w * h * 4)
        gdi32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bmi), 0)
        from PIL import Image
        img = Image.frombuffer("RGB", (w, h), buf, "raw", "BGRX", 0, 1)
        img.save(path)
    finally:
        gdi32.SelectObject(mdc, old)
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(mdc)
        user32.ReleaseDC(hwnd, hdc)


# ────────────────────────────── окно ──────────────────────────────

def run_gui(lang, offline, auto=False, shot=""):
    import tkinter as tk
    from tkinter import ttk

    root = tk.Tk()
    root.title("Contragenti Setup")
    root.geometry("760x620")
    root.minsize(640, 520)
    try:
        ico = os.path.join(app_dir(), "app_icon.ico")
        if os.path.exists(ico):
            root.iconbitmap(ico)
    except tk.TclError:
        pass

    state = {"lang": lang, "wizard": None, "running": False}
    t = lambda key: TR[state["lang"]][key]  # noqa: E731

    top = ttk.Frame(root, padding=12)
    top.pack(fill="x")
    title = ttk.Label(top, text=t("title"), font=("Segoe UI", 14, "bold"))
    title.pack(anchor="w")
    intro = ttk.Label(top, text=t("intro"), wraplength=720, justify="left")
    intro.pack(anchor="w", pady=(4, 8))

    lang_row = ttk.Frame(top)
    lang_row.pack(anchor="w")
    lang_lbl = ttk.Label(lang_row, text=t("language"))
    lang_lbl.pack(side="left")
    lang_var = tk.StringVar(value=LANG_NAMES[lang])
    lang_box = ttk.Combobox(lang_row, textvariable=lang_var, state="readonly",
                            values=[LANG_NAMES[c] for c in LANGS], width=12)
    lang_box.pack(side="left", padx=8)

    opts = ttk.Frame(root, padding=(12, 0))
    opts.pack(fill="x")
    vars_ = {k: tk.BooleanVar(value=True) for k in ("python", "update", "db", "seed", "selftest", "shortcuts")}
    checks = {}
    for key in ("python", "update", "db", "seed", "selftest", "shortcuts"):
        cb = ttk.Checkbutton(opts, text=t("opt_" + key), variable=vars_[key])
        cb.pack(anchor="w")
        checks[key] = cb

    btns = ttk.Frame(root, padding=12)
    btns.pack(fill="x")
    run_btn = ttk.Button(btns, text=t("run"))
    run_btn.pack(side="left")
    close_btn = ttk.Button(btns, text=t("close"), command=root.destroy)
    close_btn.pack(side="right")
    start_btn = ttk.Button(btns, text=t("start_apps"))
    chrome_btn = ttk.Button(btns, text=t("chrome_get"), command=lambda: webbrowser.open("https://www.google.com/chrome/"))
    def _run_python_cmd():
        try:
            trigger_windows_python(quiet=False)
        except Exception:  # noqa: BLE001
            pass

    python_btn = ttk.Button(btns, text=t("python_get"), command=_run_python_cmd)
    msi_btn = ttk.Button(btns, text=t("download_msi"))

    prog = ttk.Progressbar(root, mode="determinate", maximum=11)
    prog.pack(fill="x", padx=12)

    log_box = tk.Text(root, height=16, wrap="word", font=("Consolas", 9))
    log_box.pack(fill="both", expand=True, padx=12, pady=8)
    log_box.configure(state="disabled")

    summary = tk.Label(root, text="", justify="left", anchor="w", wraplength=720, font=("Segoe UI", 10, "bold"))
    summary.pack(fill="x", padx=12)

    report_row = ttk.Frame(root, padding=12)
    report_row.pack(fill="x")
    rep_btns = {
        "open_report": ttk.Button(report_row, text=t("open_report")),
        "send_github": ttk.Button(report_row, text=t("send_github")),
        "send_mail": ttk.Button(report_row, text=t("send_mail")),
        "copy": ttk.Button(report_row, text=t("copy")),
        "open_logs": ttk.Button(report_row, text=t("open_logs")),
    }

    # Tk не потокобезопасен: рабочий поток только кладёт события в очередь,
    # а главный поток разбирает её по таймеру.
    import queue
    events = queue.Queue()

    def append_log(line):
        events.put(("log", line))

    def ui_log(line):
        log_box.configure(state="normal")
        log_box.insert("end", line + "\n")
        log_box.see("end")
        log_box.configure(state="disabled")
        if "] " in line and line[:2].isdigit():
            prog.step(1)

    def apply_lang(*_):
        code = next((c for c in LANGS if LANG_NAMES[c] == lang_var.get()), state["lang"])
        state["lang"] = code
        root.title(t("title"))
        title.configure(text=t("title"))
        intro.configure(text=t("intro"))
        lang_lbl.configure(text=t("language"))
        for key, cb in checks.items():
            cb.configure(text=t("opt_" + key))
        run_btn.configure(text=t("run"))
        close_btn.configure(text=t("close"))
        start_btn.configure(text=t("start_apps"))
        chrome_btn.configure(text=t("chrome_get"))
        python_btn.configure(text=t("python_get"))
        msi_btn.configure(text=t("download_msi"))
        for key, b in rep_btns.items():
            b.configure(text=t(key))
        try:
            reg_write_lang(code)   # выбор языка запоминается сразу — как в Demo CRM
        except OSError:
            pass

    lang_box.bind("<<ComboboxSelected>>", apply_lang)

    def ask(text):
        holder = {"r": False}
        ev = threading.Event()
        events.put(("ask", text, holder, ev))
        ev.wait()
        return holder["r"]

    def ui_ask(text, holder, ev):
        from tkinter import messagebox
        try:
            holder["r"] = messagebox.askyesno("Contragenti", text)
        finally:
            ev.set()

    def finish(wiz, ok):
        events.put(("done", wiz, ok))

    def ui_finish(wiz, ok):
        if True:
            state["running"] = False
            run_btn.configure(state="normal")
            fails, warns = wiz.counts()
            if fails:
                summary.configure(text=t("done_fail") % (fails, wiz.report_file), fg="#b02a37")
            elif warns:
                summary.configure(text=t("done_warn") % warns, fg="#9a6700")
            else:
                summary.configure(text=t("done_ok"), fg="#1a7f37")
            for b in rep_btns.values():
                b.pack_forget()
            for key in ("open_report", "send_github", "send_mail", "copy", "open_logs"):
                rep_btns[key].pack(side="left", padx=(0, 6))
            start_btn.pack(side="left", padx=8)
            if not wiz.info.get("chrome"):
                chrome_btn.pack(side="left", padx=4)
            if not wiz.info.get("python"):
                python_btn.pack(side="left", padx=4)
            if wiz.new_msi_url:
                msi_btn.configure(command=lambda: webbrowser.open(wiz.new_msi_url))
                msi_btn.pack(side="left", padx=4)
            prog["value"] = prog["maximum"]
            if shot:
                def _shot():
                    try:
                        root.update_idletasks()
                        hwnd = ctypes.windll.user32.GetAncestor(root.winfo_id(), 2)  # GA_ROOT
                        capture_window(hwnd, shot)
                        wiz.log("снимок окна: %s" % shot)
                    except Exception:  # noqa: BLE001
                        wiz.log("снимок не удался:\n" + traceback.format_exc())
                    root.after(200, root.destroy)
                root.after(900, _shot)

    def poll():
        try:
            while True:
                ev = events.get_nowait()
                if ev[0] == "log":
                    ui_log(ev[1])
                elif ev[0] == "ask":
                    ui_ask(ev[1], ev[2], ev[3])
                elif ev[0] == "done":
                    ui_finish(ev[1], ev[2])
        except queue.Empty:
            pass
        root.after(100, poll)

    root.after(100, poll)

    def worker():
        wiz = Wizard(state["lang"], {k: v.get() for k, v in vars_.items()},
                     log_cb=append_log, ask_cb=(None if auto else ask), offline=offline)
        state["wizard"] = wiz
        try:
            ok = wiz.run_all()
        except Exception:  # noqa: BLE001
            wiz.log("НЕОЖИДАННАЯ ОШИБКА:\n" + traceback.format_exc())
            wiz.step("st_selftest", "fail", "исключение мастера — см. лог")
            wiz.report_file = wiz.write_report()
            ok = False
        finally:
            wiz.close()
        finish(wiz, ok)

    def on_run():
        if state["running"]:
            return
        state["running"] = True
        run_btn.configure(state="disabled")
        prog["value"] = 0
        summary.configure(text="")
        log_box.configure(state="normal")
        log_box.delete("1.0", "end")
        log_box.configure(state="disabled")
        threading.Thread(target=worker, daemon=True).start()

    run_btn.configure(command=on_run)

    def wiz_or_none():
        return state["wizard"]

    def copy_report():
        w = wiz_or_none()
        if not w:
            return
        root.clipboard_clear()
        root.clipboard_append(w.report_text())
        summary.configure(text=t("clipboard"), fg="#1a7f37")

    def send_github():
        w = wiz_or_none()
        if not w:
            return
        copy_report()
        webbrowser.open(w.issue_url())

    def send_mail():
        w = wiz_or_none()
        if not w:
            return
        copy_report()
        webbrowser.open(w.mailto_url())

    def open_report():
        w = wiz_or_none()
        if w and w.report_file and os.path.exists(w.report_file):
            os.startfile(w.report_file)  # noqa: S606

    def open_logs():
        w = wiz_or_none()
        os.startfile((w.paths.logs if w else Paths().logs))  # noqa: S606

    def start_apps():
        p = Paths()
        try:
            if os.path.exists(p.contragenti_exe):
                subprocess.Popen([p.contragenti_exe, "--lang", state["lang"]], cwd=p.root)
            if os.path.exists(p.demo_exe):
                subprocess.Popen([p.demo_exe], cwd=p.demo_dir)
        except OSError as exc:
            summary.configure(text=str(exc), fg="#b02a37")

    rep_btns["open_report"].configure(command=open_report)
    rep_btns["send_github"].configure(command=send_github)
    rep_btns["send_mail"].configure(command=send_mail)
    rep_btns["copy"].configure(command=copy_report)
    rep_btns["open_logs"].configure(command=open_logs)
    start_btn.configure(command=start_apps)

    if auto:
        vars_["seed"].set("--no-seed" not in sys.argv)
        vars_["python"].set("--no-python" not in sys.argv)
        root.after(400, on_run)

    root.mainloop()
    return 0


# ────────────────────────────── main ──────────────────────────────

def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    lang = default_lang()
    offline = "--offline" in argv
    if "--lang" in argv:
        i = argv.index("--lang")
        if i + 1 < len(argv) and argv[i + 1] in LANGS:
            lang = argv[i + 1]
    if "--check" in argv:
        # stdout frozen-exe при перенаправлении в файл — в кодировке консоли
        # (cp1251), а в логе есть «→» и кириллица: переключаем на UTF-8
        for stream in (sys.stdout, sys.stderr):
            try:
                if stream is not None:
                    stream.reconfigure(encoding="utf-8", errors="replace")
            except (AttributeError, ValueError):
                pass
        wiz = Wizard(lang, {"update": "--no-update" not in argv, "db": True,
                            "seed": "--no-seed" not in argv, "selftest": True, "shortcuts": True,
                            "python": "--no-python" not in argv, "quiet": True},
                     log_cb=lambda line: print(line), offline=offline)
        try:
            ok = wiz.run_all()
        finally:
            wiz.close()
        print(wiz.report_text(with_events=False))
        return 0 if ok else 1
    shot = ""
    if "--shot" in argv:
        i = argv.index("--shot")
        if i + 1 < len(argv):
            shot = os.path.abspath(argv[i + 1])
    return run_gui(lang, offline, auto="--auto" in argv, shot=shot)


if __name__ == "__main__":
    sys.exit(main())
