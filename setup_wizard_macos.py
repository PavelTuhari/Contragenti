"""
Мастер настройки после установки Contragenti (macOS) — аналог setup_wizard.py.

Запускается тонким установщиком contragenti-macos-install.sh и postinstall-
скриптом .pkg; позже доступен как «Contragenti Setup.app» в каталоге
установки. Шаги те же, что у Windows-мастера (ключи st_*), общие функции —
в setup_common.py:

  1. технический паспорт (sw_vers, uname -m, память, диск, Chrome, Python,
     версии файлов, счётчики строк в базах);
  2. Google Chrome — /Applications/Google Chrome.app/Contents/Info.plist;
  3. Python — нужен только для sdk/python: python3 уже есть (Xcode CLT /
     Homebrew) → brew install python@3.12 → официальный pkg с python.org
     с проверкой подписи (pkgutil --check-signature, издатель Python
     Software Foundation), тихая установка installer -pkg;
  4. доступ к GitHub (release.json), новая версия — предложить скачать
     .pkg или обновить бандлы на месте (macos_app_zip_url);
  5. обновление компонентов: components (файлы поверх установки) плюс
     macos_components — Demo CRM обновляется целиком zip-ом бандла;
  6. стартовая база компаний date.gov.md — слияние по IDNO;
  7. crm.ini (launcher, lang) в ~/Library/Application Support/Contragenti/DemoCRM,
     язык в UserDefaults: defaults write md.una.contragenti.democrm Language;
  8. демо-данные Demo CRM (--seed-demo), ярлыки (симлинки в ~/Applications),
     самопроверка обеих программ (--selftest).

Режимы:
    "Contragenti Setup"              окно мастера (по умолчанию)
    ... --check                      без окна: все шаги, лог, код возврата
    ... --lang ro|en|ru --offline --no-python --no-seed --no-update
    ... --uninstall [--silent] [--purge-data]
    ... --auto --shot файл.png       окно, шаги сами, снимок окна, выход

Лог: ~/Library/Logs/Contragenti/install.log; отчёт install_report_<дата>.txt.
"""

import datetime
import io
import json
import locale
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
import webbrowser
import zipfile

from setup_common import (LANGS, LANG_NAMES, RAW_BASE, REPO, db_rows, dir_writable,  # noqa: F401
                          download_to, file_info, http_get, load_release, merge_companies,
                          sha256_of, ver_tuple)

DEFAULTS_DOMAIN = "md.una.contragenti.democrm"
CHROME_APP = "/Applications/Google Chrome.app"
PYTHON_ORG_PKG = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg"

# ────────────────────────────── i18n ──────────────────────────────

TR = {
    "ru": {
        "title": "Contragenti — настройка после установки (macOS)",
        "intro": "Мастер настроит Mac так, чтобы Contragenti, Demo CRM и SDK заработали сразу. "
                 "Отметьте нужные шаги и нажмите «Выполнить».",
        "language": "Язык:",
        "opt_python": "Если нет python3 — установить (Homebrew, иначе pkg с python.org)",
        "opt_update": "Обновить компоненты из GitHub (Demo CRM, переводы, описания процессов)",
        "opt_db": "Загрузить стартовую базу компаний date.gov.md (zip из GitHub)",
        "opt_seed": "Заполнить Demo CRM демонстрационными данными",
        "opt_selftest": "Выполнить самопроверку Contragenti и Demo CRM",
        "opt_shortcuts": "Проверить ярлыки (симлинки в ~/Applications)",
        "run": "Выполнить", "close": "Закрыть", "open_report": "Открыть отчёт",
        "send_github": "Сообщить на GitHub", "send_mail": "Отправить на e-mail",
        "open_logs": "Папка логов", "copy": "Скопировать отчёт",
        "start_apps": "Запустить Contragenti и Demo CRM",
        "st_passport": "Технический паспорт системы", "st_chrome": "Google Chrome", "st_python": "Python",
        "st_net": "Доступ к GitHub", "st_release": "Новая версия в репозитории",
        "st_update": "Обновление компонентов", "st_db": "Стартовая база компаний",
        "st_config": "Настройка Demo CRM и UserDefaults", "st_seed": "Демонстрационные данные Demo CRM",
        "st_shortcuts": "Ярлыки", "st_selftest": "Самопроверка",
        "ok": "OK", "warn": "ВНИМАНИЕ", "fail": "ОШИБКА", "skip": "пропущено",
        "done_ok": "Готово: все шаги выполнены. Contragenti и Demo CRM готовы к работе.",
        "done_warn": "Готово с замечаниями (%d). Программы работают, но посмотрите отчёт.",
        "done_fail": "Есть ошибки (%d). Отчёт с техническим паспортом и логом сохранён:\n%s\n"
                     "Отправьте его разработчику — кнопки ниже откроют заготовку issue или письма.",
        "chrome_missing": "Chrome не найден в /Applications. Он нужен Contragenti для портала "
                          "date.gov.md — установите с google.com/chrome.",
        "chrome_get": "Скачать Chrome",
        "python_missing": "python3 не найден. Contragenti.app и Demo CRM работают без него; нужен для sdk/python.",
        "python_get": "Установить Python 3.12",
        "python_offline": "python3 не найден, установка пропущена (нет сети / --offline / --no-python).",
        "python_installed": "Python установлен: %s %s (через %s).",
        "python_installing": "Ставим Python… это может занять несколько минут.",
        "net_fail": "GitHub недоступен (%s). Обновление и загрузка базы пропущены; программы работают и без них.",
        "new_version": "В репозитории версия %s (установлена %s). Обновить установку на месте?",
        "download_pkg": "Скачать новую версию (.pkg)",
        "report_saved": "Отчёт сохранён: %s",
        "clipboard": "Полный отчёт скопирован в буфер обмена — вставьте его в issue или письмо.",
        "issue_title": "Установка Contragenti на macOS %s: %s",
        "mail_subject": "Contragenti: отчёт об установке на macOS (%s)",
    },
    "en": {
        "title": "Contragenti — post-install setup (macOS)",
        "intro": "This wizard configures the Mac so that Contragenti, Demo CRM and the SDK work right away. "
                 "Tick the steps you need and press Run.",
        "language": "Language:",
        "opt_python": "If python3 is missing, install it (Homebrew, otherwise the python.org pkg)",
        "opt_update": "Update components from GitHub (Demo CRM, translations, process descriptions)",
        "opt_db": "Download the starter company database from date.gov.md (zip from GitHub)",
        "opt_seed": "Fill Demo CRM with demo data",
        "opt_selftest": "Run self-tests of Contragenti and Demo CRM",
        "opt_shortcuts": "Check shortcuts (symlinks in ~/Applications)",
        "run": "Run", "close": "Close", "open_report": "Open report",
        "send_github": "Report on GitHub", "send_mail": "Send by e-mail",
        "open_logs": "Logs folder", "copy": "Copy report",
        "start_apps": "Start Contragenti and Demo CRM",
        "st_passport": "System passport", "st_chrome": "Google Chrome", "st_python": "Python",
        "st_net": "GitHub access", "st_release": "New version in the repository",
        "st_update": "Component update", "st_db": "Starter company database",
        "st_config": "Demo CRM and UserDefaults setup", "st_seed": "Demo CRM demo data",
        "st_shortcuts": "Shortcuts", "st_selftest": "Self-test",
        "ok": "OK", "warn": "WARNING", "fail": "ERROR", "skip": "skipped",
        "done_ok": "Done: all steps completed. Contragenti and Demo CRM are ready.",
        "done_warn": "Done with warnings (%d). The programs work, but please check the report.",
        "done_fail": "There are errors (%d). A report with the system passport and log is saved:\n%s\n"
                     "Send it to the developer — the buttons below open an issue or e-mail draft.",
        "chrome_missing": "Chrome not found in /Applications. Contragenti needs it for the date.gov.md "
                          "portal — install it from google.com/chrome.",
        "chrome_get": "Get Chrome",
        "python_missing": "python3 not found. Contragenti.app and Demo CRM work without it; needed for sdk/python.",
        "python_get": "Install Python 3.12",
        "python_offline": "python3 not found; installation skipped (offline / --offline / --no-python).",
        "python_installed": "Python installed: %s %s (via %s).",
        "python_installing": "Installing Python… this can take a few minutes.",
        "net_fail": "GitHub is unreachable (%s). Update and database download skipped; the programs work without them.",
        "new_version": "The repository has version %s (installed %s). Update the installation in place?",
        "download_pkg": "Download new version (.pkg)",
        "report_saved": "Report saved: %s",
        "clipboard": "The full report is copied to the clipboard — paste it into the issue or e-mail.",
        "issue_title": "Contragenti macOS install %s: %s",
        "mail_subject": "Contragenti: macOS installation report (%s)",
    },
    "ro": {
        "title": "Contragenti — configurare după instalare (macOS)",
        "intro": "Asistentul configurează Mac-ul astfel încât Contragenti, Demo CRM și SDK să funcționeze imediat. "
                 "Bifați pașii necesari și apăsați „Execută”.",
        "language": "Limba:",
        "opt_python": "Dacă lipsește python3 — instalează (Homebrew, altfel pkg de pe python.org)",
        "opt_update": "Actualizează componentele din GitHub (Demo CRM, traduceri, descrieri de procese)",
        "opt_db": "Descarcă baza inițială de companii date.gov.md (zip din GitHub)",
        "opt_seed": "Completează Demo CRM cu date demonstrative",
        "opt_selftest": "Execută autoverificarea Contragenti și Demo CRM",
        "opt_shortcuts": "Verifică scurtăturile (symlink-uri în ~/Applications)",
        "run": "Execută", "close": "Închide", "open_report": "Deschide raportul",
        "send_github": "Raportează pe GitHub", "send_mail": "Trimite prin e-mail",
        "open_logs": "Dosarul cu loguri", "copy": "Copiază raportul",
        "start_apps": "Pornește Contragenti și Demo CRM",
        "st_passport": "Pașaportul tehnic al sistemului", "st_chrome": "Google Chrome", "st_python": "Python",
        "st_net": "Acces la GitHub", "st_release": "Versiune nouă în repozitoriu",
        "st_update": "Actualizarea componentelor", "st_db": "Baza inițială de companii",
        "st_config": "Configurare Demo CRM și UserDefaults", "st_seed": "Date demonstrative Demo CRM",
        "st_shortcuts": "Scurtături", "st_selftest": "Autoverificare",
        "ok": "OK", "warn": "ATENȚIE", "fail": "EROARE", "skip": "omis",
        "done_ok": "Gata: toți pașii au fost executați. Contragenti și Demo CRM sunt pregătite.",
        "done_warn": "Gata, cu observații (%d). Programele funcționează, dar verificați raportul.",
        "done_fail": "Există erori (%d). Raportul cu pașaportul tehnic și logul este salvat:\n%s\n"
                     "Trimiteți-l dezvoltatorului — butoanele de mai jos deschid un issue sau un e-mail.",
        "chrome_missing": "Chrome nu a fost găsit în /Applications. Contragenti are nevoie de el pentru "
                          "portalul date.gov.md — instalați-l de pe google.com/chrome.",
        "chrome_get": "Descarcă Chrome",
        "python_missing": "python3 nu a fost găsit. Contragenti.app și Demo CRM funcționează fără el; necesar pentru sdk/python.",
        "python_get": "Instalează Python 3.12",
        "python_offline": "python3 nu a fost găsit; instalarea a fost omisă (offline / --offline / --no-python).",
        "python_installed": "Python instalat: %s %s (prin %s).",
        "python_installing": "Se instalează Python… poate dura câteva minute.",
        "net_fail": "GitHub nu este accesibil (%s). Actualizarea și descărcarea bazei au fost omise; programele funcționează și fără ele.",
        "new_version": "În repozitoriu este versiunea %s (instalată %s). Actualizați instalarea pe loc?",
        "download_pkg": "Descarcă versiunea nouă (.pkg)",
        "report_saved": "Raport salvat: %s",
        "clipboard": "Raportul complet este copiat în clipboard — lipiți-l în issue sau în e-mail.",
        "issue_title": "Instalare Contragenti pe macOS %s: %s",
        "mail_subject": "Contragenti: raport de instalare pe macOS (%s)",
    },
}


# ────────────────────────────── пути ──────────────────────────────

def is_frozen():
    return bool(getattr(sys, "frozen", False))


def app_dir():
    """Каталог установки: для «Contragenti Setup.app» — родитель бандла, для
    скрипта — каталог файла (клон репозитория)."""
    if is_frozen():
        exe_dir = os.path.dirname(os.path.abspath(sys.executable))
        if exe_dir.endswith("/Contents/MacOS"):
            return os.path.dirname(os.path.dirname(os.path.dirname(exe_dir)))
        return exe_dir
    return os.path.dirname(os.path.abspath(__file__))


def in_applications(path):
    p = os.path.abspath(path)
    home_apps = os.path.join(os.path.expanduser("~"), "Applications")
    return p == "/Applications" or p.startswith("/Applications/") or \
        p == home_apps or p.startswith(home_apps + "/")


class Paths:
    def __init__(self):
        self.root = app_dir()
        self.home = os.path.expanduser("~")
        self.support = os.path.join(self.home, "Library", "Application Support", "Contragenti")
        self.logs = os.path.join(self.home, "Library", "Logs", "Contragenti")
        # из исходников Demo CRM лежит в crm_macos/build/…, в установке — рядом с бандлом
        self.contragenti_app = os.path.join(self.root, "Contragenti.app")
        self.contragenti_bin = os.path.join(self.contragenti_app, "Contents", "MacOS", "Contragenti")
        self.contragenti_py = os.path.join(self.root, "company_search.py")
        self.setup_app = os.path.join(self.root, "Contragenti Setup.app")
        self.demo_app = os.path.join(self.root, "Demo CRM.app")
        if not os.path.isdir(self.demo_app):
            built = os.path.join(self.root, "crm_macos", "build", "DerivedData", "Build", "Products", "Release", "Demo CRM.app")
            if os.path.isdir(built):
                self.demo_app = built
        self.demo_bin = os.path.join(self.demo_app, "Contents", "MacOS", "Demo CRM")
        self.demo_dir = os.path.join(self.root, "DemoCRM")
        if not os.path.isdir(self.demo_dir) and os.path.isdir(os.path.join(self.root, "crm_delphi")):
            self.demo_dir = os.path.join(self.root, "crm_delphi")
        self.version_file = os.path.join(self.root, "VERSION")
        # из клона репозитория утилиту запускает python из .venv (selenium, tkinter)
        self.venv_python = next((p for p in (os.path.join(self.root, ".venv", "bin", "python"),
                                             os.path.join(self.root, "venv", "bin", "python"))
                                 if os.path.exists(p)), "")
        # данные — по тому же правилу, что у самих программ: рядом с установкой,
        # если туда можно писать и это не /Applications; иначе — в профиле
        self.root_writable = dir_writable(self.root) and not in_applications(self.root)
        self.data = self.root if self.root_writable else self.support
        self.demo_data = self.demo_dir if (self.root_writable and dir_writable(self.demo_dir)) \
            else os.path.join(self.support, "DemoCRM")
        os.makedirs(self.data, exist_ok=True)
        os.makedirs(self.demo_data, exist_ok=True)
        os.makedirs(self.logs, exist_ok=True)
        self.companies_db = os.path.join(self.data, "companies.db")
        for src, dst in ((os.path.join(self.root, "companies.db"), self.companies_db),
                         (os.path.join(self.demo_dir, "clients.db"), os.path.join(self.demo_data, "clients.db"))):
            if os.path.exists(src) and not os.path.exists(dst) and os.path.dirname(src) != os.path.dirname(dst):
                try:
                    shutil.copy2(src, dst)
                except OSError:
                    pass
        self.log_file = os.path.join(self.logs, "install.log")

    def installed_version(self):
        try:
            with open(self.version_file, encoding="utf-8") as f:
                return f.read().strip() or "0"
        except OSError:
            return "0"

    def launcher(self):
        if os.path.exists(self.contragenti_bin):
            return self.contragenti_bin
        return self.contragenti_py


# ────────────────────────────── UserDefaults / язык ──────────────────────────────

def defaults_read_lang():
    try:
        out = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, "Language"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip().lower() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def defaults_write_lang(code):
    subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, "Language", code],
                   capture_output=True, text=True, timeout=10)


def default_lang():
    code = defaults_read_lang()
    if code in LANGS:
        return code
    try:
        loc = (locale.getlocale()[0] or "").lower()
    except Exception:  # noqa: BLE001
        loc = ""
    try:
        out = subprocess.run(["defaults", "read", "-g", "AppleLocale"], capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            loc = out.stdout.strip().lower()
    except (OSError, subprocess.SubprocessError):
        pass
    for code in LANGS:
        if loc.startswith(code):
            return code
    return "ro"


# ────────────────────────────── паспорт ──────────────────────────────

def _sh(args, timeout=15):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return out.returncode, (out.stdout or "").strip(), (out.stderr or "").strip()
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, "", str(exc)


def find_chrome():
    plist = os.path.join(CHROME_APP, "Contents", "Info.plist")
    if not os.path.exists(plist):
        return "", ""
    try:
        with open(plist, "rb") as fh:
            ver = plistlib.load(fh).get("CFBundleShortVersionString", "")
    except Exception:  # noqa: BLE001
        ver = ""
    return CHROME_APP, ver


def find_python():
    """python3, который отвечает версией 3.x (Xcode CLT, Homebrew, python.org)."""
    for cmd in ("python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"):
        path = shutil.which(cmd) if not cmd.startswith("/") else (cmd if os.path.exists(cmd) else "")
        if not path:
            continue
        rc, out, _ = _sh([path, "-c", "import sys; print(sys.version.split()[0])"], timeout=20)
        if rc == 0 and out.startswith("3."):
            return path, out
    return "", ""


def memory_mb():
    rc, out, _ = _sh(["sysctl", "-n", "hw.memsize"])
    try:
        return int(out) // (1024 * 1024) if rc == 0 else 0
    except ValueError:
        return 0


def macos_version():
    rc, out, _ = _sh(["sw_vers", "-productVersion"])
    rc2, build, _ = _sh(["sw_vers", "-buildVersion"])
    return (out if rc == 0 else platform.mac_ver()[0]), (build if rc2 == 0 else "")


def passport(paths):
    chrome_path, chrome_ver = find_chrome()
    py_cmd, py_ver = find_python()
    ver, build = macos_version()
    try:
        du = shutil.disk_usage(paths.root)
        disk = "%d МБ свободно из %d МБ" % (du.free // 2**20, du.total // 2**20)
    except OSError:
        disk = "?"
    rc, arch, _ = _sh(["uname", "-m"])
    brew = shutil.which("brew") or ""
    lines = [
        ("Дата", datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
        ("ОС", "macOS %s (%s)" % (ver, build)),
        ("Архитектура", arch or platform.machine()),
        ("Компьютер / пользователь", "%s / %s" % (platform.node(), os.environ.get("USER", "?"))),
        ("Homebrew", brew or "нет"),
        ("Локаль", "%s; Language в UserDefaults: %s" % (locale.getlocale(), defaults_read_lang() or "-")),
        ("Память", "%d МБ" % memory_mb()),
        ("Диск установки", disk),
        ("Каталог установки", paths.root),
        ("Версия установки", paths.installed_version()),
        ("Python мастера", "%s (frozen=%s)" % (sys.version.split()[0], is_frozen())),
        ("Contragenti.app", file_info(paths.contragenti_bin)),
        ("Demo CRM.app", file_info(paths.demo_bin)),
        ("lang.json", file_info(os.path.join(paths.demo_dir, "lang.json"))),
        ("processes.json", file_info(os.path.join(paths.demo_dir, "processes.json"))),
        ("companies.db", "%s (компаний: %s)" % (file_info(paths.companies_db), db_rows(paths.companies_db, "companies"))),
        ("clients.db", "%s (клиентов: %s)" % (file_info(os.path.join(paths.demo_data, "clients.db")),
                                              db_rows(os.path.join(paths.demo_data, "clients.db"), "clients"))),
        ("Каталог данных", "%s%s" % (paths.data, "" if paths.root_writable else
                                     " (каталог программы — /Applications или только чтение)")),
        ("Google Chrome", "%s %s" % (chrome_path or "не найден", chrome_ver)),
        ("Python (python3)", "%s %s" % (py_cmd or "не найден", py_ver)),
        ("Прокси", "%s" % (os.environ.get("HTTPS_PROXY") or os.environ.get("HTTP_PROXY") or "-")),
    ]
    return lines, {"chrome": chrome_path, "chrome_ver": chrome_ver, "python": py_cmd, "python_ver": py_ver,
                   "brew": brew}


def installer_log_tail(limit=30):
    """Последние строки журнала installer (.pkg) — аналог событий Windows Installer."""
    rc, out, err = _sh(["log", "show", "--predicate", 'process == "installer"', "--last", "1h",
                        "--style", "compact"], timeout=40)
    if rc != 0 or not out:
        return "(событий installer нет: %s)" % (err[:120] if err else "пусто")
    return "\n".join(out.splitlines()[-limit:])


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
        self.ask_cb = ask_cb
        self.offline = offline
        self.report_file = ""
        self.new_pkg_url = ""
        self._log_fh = open(self.paths.log_file, "a", encoding="utf-8")
        self.log("===== %s (%s) =====" % (self.t["title"], datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
        self.log("cmd: %s" % " ".join(sys.argv))

    def log(self, text):
        line = "%s  %s" % (datetime.datetime.now().strftime("%H:%M:%S"), text)
        self.log_lines.append(line)
        try:
            if self._log_fh.closed:
                self._log_fh = open(self.paths.log_file, "a", encoding="utf-8")
            self._log_fh.write(line + "\n")
            self._log_fh.flush()
        except (OSError, ValueError):
            pass
        if self.log_cb:
            try:
                self.log_cb(line)
            except Exception:  # noqa: BLE001
                pass

    def step(self, key, status, detail=""):
        self.steps.append(Step(key, status, detail))
        label = {"ok": self.t["ok"], "warn": self.t["warn"], "fail": self.t["fail"], "skip": self.t["skip"]}[status]
        self.log("[%s] %s%s" % (label, self.t[key], (": " + detail) if detail else ""))

    def counts(self):
        fails = sum(1 for s in self.steps if s.status == "fail")
        warns = sum(1 for s in self.steps if s.status == "warn")
        return fails, warns

    def run_bin(self, args, log_name, timeout=180):
        out_path = os.path.join(self.paths.logs, log_name)
        with open(out_path, "w", encoding="utf-8", errors="replace") as fh:
            proc = subprocess.run(args, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout,
                                  cwd=os.path.dirname(args[0]) if os.path.isabs(args[0]) else None)
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

    def install_python(self, interactive=False):
        """brew install python@3.12 → pkg с python.org (подпись PSF, тихая установка)."""
        brew = self.info.get("brew") or shutil.which("brew")
        if brew:
            self.log("  brew install python@3.12 …")
            rc, out, err = _sh([brew, "install", "python@3.12"], timeout=1800)
            self.log("  brew: код %d %s" % (rc, (err or out)[-300:]))
            cmd, ver = find_python()
            if cmd:
                return cmd, ver, "Homebrew"
        tmpdir = tempfile.mkdtemp(prefix="contragenti_py_")
        try:
            pkg = os.path.join(tmpdir, "python.pkg")
            self.log("  скачиваю %s" % PYTHON_ORG_PKG)
            download_to(PYTHON_ORG_PKG, pkg, timeout=600)
            rc, out, err = _sh(["pkgutil", "--check-signature", pkg], timeout=60)
            if rc != 0 or "Python Software Foundation" not in out:
                return "", "", "подпись pkg не подтверждена (%s)" % (err or out)[:200]
            self.log("  подпись Python Software Foundation подтверждена")
            # без sudo: в домашний каталог; installer -target CurrentUserHomeDirectory
            rc, out, err = _sh(["installer", "-pkg", pkg, "-target", "CurrentUserHomeDirectory"], timeout=900)
            if rc != 0:
                return "", "", "installer: код %d %s" % (rc, (err or out)[:200])
            cmd, ver = find_python()
            if cmd:
                return cmd, ver, "python.org"
            return "", "", "после установки python3 не найден"
        except Exception as exc:  # noqa: BLE001
            return "", "", str(exc)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def do_python(self):
        if self.info.get("python"):
            self.step("st_python", "ok", "%s %s" % (self.info["python"], self.info.get("python_ver", "")))
            return
        if not self.opt.get("python", True) or self.offline:
            self.step("st_python", "warn", self.t["python_offline"])
            return
        try:
            cmd, ver, how = self.install_python()
            if cmd:
                self.info["python"], self.info["python_ver"] = cmd, ver
                self.step("st_python", "ok", self.t["python_installed"] % (cmd, ver, how))
            else:
                self.step("st_python", "warn", "%s %s" % (self.t["python_missing"], how))
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

    def stop_apps(self):
        for pat in ("Contragenti.app/Contents/MacOS/Contragenti", "Demo CRM.app/Contents/MacOS/Demo CRM"):
            _sh(["pkill", "-f", pat])

    def update_bundles_in_place(self):
        """Скачать macos_app_zip, сверить sha256, заменить содержимое каталога
        установки (кроме баз и crm.ini — они и так в профиле)."""
        url = self.release.get("macos_app_zip_url") or ""
        if not url:
            raise ValueError("macos_app_zip_url в release.json пуст")
        tmpdir = tempfile.mkdtemp(prefix="contragenti_upd_")
        try:
            zpath = os.path.join(tmpdir, "app.zip")
            size = download_to(url, zpath, timeout=900)
            want = (self.release.get("macos_app_zip_sha256") or "").lower()
            got = sha256_of(zpath)
            if want and got != want:
                raise ValueError("sha256 zip не совпал: %s ≠ %s" % (got[:12], want[:12]))
            self.log("  zip %s: %d байт, sha256 %s" % (os.path.basename(url), size, got[:12]))
            self.stop_apps()
            # распаковка через ditto сохраняет права и подписи бандлов
            rc, out, err = _sh(["ditto", "-x", "-k", zpath, tmpdir], timeout=600)
            if rc != 0:
                raise ValueError("ditto: " + (err or out)[:200])
            src_root = os.path.join(tmpdir, "Contragenti")
            if not os.path.isdir(src_root):
                src_root = tmpdir
            keep = {"companies.db", "crm.ini", "settings.json", "tms_config.json"}
            for name in os.listdir(src_root):
                if name in keep:
                    continue
                src, dst = os.path.join(src_root, name), os.path.join(self.paths.root, name)
                if os.path.isdir(dst) and not os.path.islink(dst):
                    shutil.rmtree(dst, ignore_errors=True)
                elif os.path.exists(dst):
                    os.remove(dst)
                shutil.move(src, dst)
                self.log("  + %s" % name)
            for app in (self.paths.contragenti_app, self.paths.setup_app, self.paths.demo_app):
                if os.path.isdir(app):
                    _sh(["xattr", "-dr", "com.apple.quarantine", app])
            return True
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def do_release(self):
        if not self.release:
            self.step("st_release", "skip")
            return
        remote = str(self.release.get("version", "0"))
        local = self.paths.installed_version()
        pkg = self.release.get("macos_pkg_url") or ""
        if ver_tuple(remote) > ver_tuple(local) and (pkg or self.release.get("macos_app_zip_url")):
            self.new_pkg_url = pkg
            self.step("st_release", "warn", self.t["new_version"] % (remote, local))
            if self.ask_cb and self.ask_cb(self.t["new_version"] % (remote, local)):
                try:
                    if is_frozen() and self.release.get("macos_app_zip_url"):
                        self.update_bundles_in_place()
                        self.log("  обновлено на месте до %s — перезапустите мастер" % remote)
                    elif pkg:
                        dst = os.path.join(self.paths.logs, os.path.basename(urllib.parse.urlparse(pkg).path))
                        size = download_to(pkg, dst, timeout=900)
                        want = (self.release.get("macos_pkg_sha256") or "").lower()
                        if want and sha256_of(dst) != want:
                            raise ValueError("sha256 .pkg не совпал с release.json — файл не запущен")
                        self.log("pkg: %s (%d байт)" % (dst, size))
                        subprocess.Popen(["open", dst])
                except Exception as exc:  # noqa: BLE001
                    self.step("st_release", "fail", str(exc))
        elif ver_tuple(remote) > ver_tuple(local):
            self.step("st_release", "warn", "%s > %s, macos_pkg_url в release.json пуст" % (remote, local))
        else:
            self.step("st_release", "ok", "%s (installed %s)" % (remote, local))

    def target_path(self, dst_rel):
        dst = os.path.join(self.paths.root, dst_rel)
        if dst_rel.startswith("DemoCRM/") and not os.path.isdir(os.path.join(self.paths.root, "DemoCRM")):
            dst = os.path.join(self.paths.demo_dir, dst_rel[len("DemoCRM/"):])
        return dst

    def apply_file(self, dst_rel, new_b):
        """Файл поверх установки: 'same' | 'updated' | 'dry' (из исходников не заменяем)."""
        dst = self.target_path(dst_rel)
        if not is_frozen():
            differs = True
            if os.path.exists(dst):
                with open(dst, "rb") as f1:
                    differs = f1.read().replace(b"\r\n", b"\n") != new_b.replace(b"\r\n", b"\n")
            self.log("  %s %s (из исходников: %s)" % ("~" if differs else "=", dst_rel,
                     "отличается, не заменяю" if differs else "без изменений"))
            return "dry"
        if os.path.exists(dst):
            with open(dst, "rb") as f1:
                if f1.read().replace(b"\r\n", b"\n") == new_b.replace(b"\r\n", b"\n"):
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

    def update_democrm_bundle(self):
        """Demo CRM.app не обновляется пофайлово — заменяется целиком zip-ом бандла."""
        url = self.release.get("macos_democrm_zip_url") or ""
        if not url or not is_frozen():
            return None
        tmpdir = tempfile.mkdtemp(prefix="contragenti_crm_")
        try:
            zpath = os.path.join(tmpdir, "democrm.zip")
            download_to(url, zpath, timeout=600)
            want = (self.release.get("macos_democrm_zip_sha256") or "").lower()
            got = sha256_of(zpath)
            if want and got != want:
                raise ValueError("sha256 democrm.zip не совпал")
            rc, out, err = _sh(["ditto", "-x", "-k", zpath, tmpdir], timeout=300)
            if rc != 0:
                raise ValueError("ditto: " + (err or out)[:200])
            src = os.path.join(tmpdir, "Demo CRM.app")
            if not os.path.isdir(src):
                raise ValueError("в zip нет Demo CRM.app")
            _sh(["pkill", "-f", "Demo CRM.app/Contents/MacOS/Demo CRM"])
            dst = os.path.join(self.paths.root, "Demo CRM.app")
            if os.path.isdir(dst):
                shutil.rmtree(dst, ignore_errors=True)
            shutil.move(src, dst)
            _sh(["xattr", "-dr", "com.apple.quarantine", dst])
            self.log("  + Demo CRM.app (бандл заменён целиком, sha256 %s)" % got[:12])
            return "updated"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def do_update(self):
        if not self.opt.get("update", True):
            self.step("st_update", "skip")
            return
        if not self.release:
            self.step("st_update", "skip", "GitHub")
            return
        if is_frozen() and not dir_writable(self.paths.root):
            self.step("st_update", "warn", "каталог %s доступен только на чтение — обновите через .pkg" % self.paths.root)
            return
        if ver_tuple(str(self.release.get("version", "0"))) < ver_tuple(self.paths.installed_version()):
            self.step("st_update", "skip", "в репозитории %s, установлена %s — новее" % (
                self.release.get("version"), self.paths.installed_version()))
            return
        updated, errors, total = [], [], 0
        comps = list(self.release.get("components", [])) + list(self.release.get("macos_components", []))
        for comp in comps:
            src, dst_rel = comp.get("src"), comp.get("dst")
            if not src or not dst_rel or comp.get("kind") == "exe":
                continue        # ContragentiCRM.exe на Mac не нужен
            if dst_rel.endswith(".app") or comp.get("kind") == "app":
                continue        # бандлы — отдельно
            total += 1
            try:
                if self.apply_file(dst_rel, http_get(RAW_BASE + src, timeout=120)) == "updated":
                    updated.append(dst_rel)
            except Exception as exc:  # noqa: BLE001
                errors.append("%s: %s" % (dst_rel, exc))
                self.log("  ! %s: %s" % (dst_rel, exc))
        try:
            if self.update_democrm_bundle() == "updated":
                updated.append("Demo CRM.app")
            total += 1
        except Exception as exc:  # noqa: BLE001
            errors.append("Demo CRM.app: %s" % exc)
            self.log("  ! Demo CRM.app: %s" % exc)
        if errors and not updated:
            self.step("st_update", "fail", "; ".join(errors))
        elif errors:
            self.step("st_update", "warn", "обновлено %d, ошибок %d: %s" % (len(updated), len(errors), "; ".join(errors)))
        elif not is_frozen():
            self.step("st_update", "ok", "запуск из исходников: %d файлов сверено, ничего не заменялось" % total)
        else:
            self.step("st_update", "ok", "обновлено %d из %d" % (len(updated), total))

    def do_database(self):
        if not self.opt.get("db", True):
            self.step("st_db", "skip")
            return
        zip_rel = (self.release or {}).get("database", {}).get("zip", "data/companies_seed.zip")
        local_zip = os.path.join(self.paths.root, zip_rel)
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
            before, after = merge_companies(os.path.join(tmpdir, names[0]), self.paths.companies_db)
            self.step("st_db", "ok", "%s; компаний было %d, стало %d" % (source, before, after))
        except Exception as exc:  # noqa: BLE001
            self.step("st_db", "fail", str(exc))
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def do_config(self):
        try:
            launcher = self.paths.launcher()
            ini = os.path.join(self.paths.demo_data, "crm.ini")
            if os.path.exists(ini):
                with open(ini, encoding="utf-8-sig") as fh:
                    text = fh.read()
                if "launcher=" not in text:
                    text += "\nlauncher=%s\n" % launcher
                self.log("  crm.ini существует — лаунчер оставлен, язык: %s" % self.lang)
                text = "\n".join("lang=%s" % self.lang if line.strip().startswith("lang=") else line
                                 for line in text.splitlines()) + "\n"
            else:
                text = "[contragenti]\nlauncher=%s\nlang=%s\n[erp]\nurl=http://127.0.0.1:9000\nkey=\nclient_id=demo-crm\n" % (
                    launcher, self.lang)
            with open(ini, "w", encoding="utf-8") as fh:
                fh.write(text)
            defaults_write_lang(self.lang)
            self.step("st_config", "ok", "crm.ini → %s; defaults %s Language=%s; логи %s" % (
                launcher, DEFAULTS_DOMAIN, self.lang, self.paths.logs))
        except Exception as exc:  # noqa: BLE001
            self.step("st_config", "fail", str(exc))

    def do_seed(self):
        if not self.opt.get("seed", True):
            self.step("st_seed", "skip")
            return
        if not os.path.exists(self.paths.demo_bin):
            self.step("st_seed", "fail", "нет %s" % self.paths.demo_bin)
            return
        try:
            code, text = self.run_bin([self.paths.demo_bin, "--seed-demo"], "seed_demo.log")
            tail = " ".join(text.strip().splitlines()[-2:]) if text.strip() else ""
            self.step("st_seed", "ok" if code == 0 else "fail", "код %d %s" % (code, tail[:200]))
        except Exception as exc:  # noqa: BLE001
            self.step("st_seed", "fail", str(exc))

    def do_shortcuts(self):
        if not self.opt.get("shortcuts", True):
            self.step("st_shortcuts", "skip")
            return
        try:
            found, made = [], []
            if in_applications(self.paths.root):
                found.append("установка в %s — Launchpad видит бандлы сам" % self.paths.root)
            else:
                apps = os.path.join(self.paths.home, "Applications")
                os.makedirs(apps, exist_ok=True)
                for name in ("Contragenti.app", "Demo CRM.app", "Contragenti Setup.app"):
                    src = os.path.join(self.paths.root, name)
                    link = os.path.join(apps, name)
                    if not os.path.isdir(src):
                        continue
                    if os.path.islink(link) and os.readlink(link) == src:
                        found.append(name)
                    elif not os.path.exists(link) and not os.path.islink(link):
                        os.symlink(src, link)
                        made.append(name)
                    else:
                        found.append(name + " (свой)")
            self.step("st_shortcuts", "ok" if (found or made) else "warn",
                      "; ".join((["созданы: " + ", ".join(made)] if made else []) + found) or "бандлов нет")
        except Exception as exc:  # noqa: BLE001
            self.step("st_shortcuts", "warn", str(exc))

    def do_selftest(self):
        if not self.opt.get("selftest", True):
            self.step("st_selftest", "skip")
            return
        results, ok = [], True
        if os.path.exists(self.paths.contragenti_bin):
            try:
                code, text = self.run_bin([self.paths.contragenti_bin, "--selftest"], "selftest_contragenti.log")
                passed = code == 0 and "PASS" in text
                ok &= passed
                results.append("Contragenti: %s" % ("PASS" if passed else "FAIL (код %d)" % code))
            except Exception as exc:  # noqa: BLE001
                ok = False
                results.append("Contragenti: %s" % exc)
        elif os.path.exists(self.paths.contragenti_py) and (self.paths.venv_python or self.info.get("python")):
            try:
                py = self.paths.venv_python or self.info["python"]
                code, text = self.run_bin([py, self.paths.contragenti_py, "--selftest"], "selftest_contragenti.log")
                passed = code == 0 and "PASS" in text
                ok &= passed
                results.append("company_search.py: %s" % ("PASS" if passed else "FAIL (код %d)" % code))
            except Exception as exc:  # noqa: BLE001
                ok = False
                results.append("company_search.py: %s" % exc)
        else:
            results.append("Contragenti.app: нет")
        if os.path.exists(self.paths.demo_bin):
            try:
                code, text = self.run_bin([self.paths.demo_bin, "--selftest"], "selftest_democrm.log")
                passed = code == 0 and "True" in text
                ok &= passed
                results.append("Demo CRM: %s" % ("PASS" if passed else "FAIL (код %d)" % code))
            except Exception as exc:  # noqa: BLE001
                ok = False
                results.append("Demo CRM: %s" % exc)
        else:
            ok = False
            results.append("Demo CRM.app: нет")
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

    # ---- отчёт (формат setup_wizard.py) ----
    def report_text(self, with_events=True):
        buf = io.StringIO()
        buf.write("Contragenti — отчёт об установке / setup report (macOS)\n")
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
        if with_events and in_applications(self.paths.root):
            buf.write("\nINSTALLER (.pkg, последние события)\n")
            buf.write(installer_log_tail())
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
        return {"issues": dev.get("github_issues") or f"https://github.com/{REPO}/issues/new",
                "email": dev.get("email") or "ptuhari@gmail.com"}

    def issue_url(self):
        fails, warns = self.counts()
        title = self.t["issue_title"] % (self.paths.installed_version(), "ошибок %d, замечаний %d" % (fails, warns))
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


# ────────────────────────────── окно ──────────────────────────────

def capture_window(root, path):
    """Снимок окна мастера: screencapture по прямоугольнику окна (нужно право
    «Запись экрана»; без него кадр будет пустым, но мастер не упадёт)."""
    root.update_idletasks()
    x, y = root.winfo_rootx(), root.winfo_rooty()
    w, h = root.winfo_width(), root.winfo_height()
    rc, out, err = _sh(["screencapture", "-x", "-R", "%d,%d,%d,%d" % (x, y - 28, w, h + 28), path], timeout=30)
    if rc != 0:
        raise RuntimeError("screencapture: " + (err or out))


def run_gui(lang, offline, auto=False, shot="", argv=()):
    import queue
    import tkinter as tk
    from tkinter import ttk

    root = tk.Tk()
    root.title("Contragenti Setup")
    root.geometry("800x700")
    root.minsize(640, 560)

    state = {"lang": lang, "wizard": None, "running": False, "python_busy": False}
    t = lambda key: TR[state["lang"]][key]  # noqa: E731

    top = ttk.Frame(root, padding=12)
    top.pack(fill="x")
    title = ttk.Label(top, text=t("title"), font=("Helvetica", 15, "bold"))
    title.pack(anchor="w")
    intro = ttk.Label(top, text=t("intro"), wraplength=740, justify="left")
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
    keys = ("python", "update", "db", "seed", "selftest", "shortcuts")
    vars_ = {k: tk.BooleanVar(value=True) for k in keys}
    checks = {}
    for key in keys:
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
    pkg_btn = ttk.Button(btns, text=t("download_pkg"))
    events = queue.Queue()

    def _run_python_cmd():
        wiz = state.get("wizard")
        if wiz is None or state["python_busy"]:
            return
        state["python_busy"] = True
        python_btn.configure(state="disabled")
        summary.configure(text=t("python_installing"), fg="#9a6700")

        def _work():
            try:
                cmd, ver, how = wiz.install_python(interactive=True)
                if cmd:
                    wiz.info["python"], wiz.info["python_ver"] = cmd, ver
                    wiz.log(t("python_installed") % (cmd, ver, how))
                    events.put(("python_done", True))
                else:
                    wiz.log(how)
                    events.put(("python_done", False))
            except Exception as exc:  # noqa: BLE001
                wiz.log("Python: %s" % exc)
                events.put(("python_done", False))
        threading.Thread(target=_work, daemon=True).start()

    python_btn = ttk.Button(btns, text=t("python_get"), command=_run_python_cmd)

    prog = ttk.Progressbar(root, mode="determinate", maximum=11)
    prog.pack(fill="x", padx=12)
    log_box = tk.Text(root, height=16, wrap="word", font=("Menlo", 11))
    log_box.pack(fill="both", expand=True, padx=12, pady=8)
    log_box.configure(state="disabled")
    summary = tk.Label(root, text="", justify="left", anchor="w", wraplength=740, font=("Helvetica", 12, "bold"))
    summary.pack(fill="x", padx=12)
    report_row = ttk.Frame(root, padding=12)
    report_row.pack(fill="x")
    rep_btns = {k: ttk.Button(report_row, text=t(k)) for k in ("open_report", "send_github", "send_mail", "copy", "open_logs")}

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
        pkg_btn.configure(text=t("download_pkg"))
        for key, b in rep_btns.items():
            b.configure(text=t(key))
        defaults_write_lang(code)

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

    def ui_finish(wiz, ok):
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
            python_btn.configure(state="normal")
            python_btn.pack(side="left", padx=4)
        if wiz.new_pkg_url:
            pkg_btn.configure(command=lambda: webbrowser.open(wiz.new_pkg_url))
            pkg_btn.pack(side="left", padx=4)
        prog["value"] = prog["maximum"]
        if shot:
            def _shot():
                try:
                    capture_window(root, shot)
                    wiz.log("снимок окна: %s" % shot)
                except Exception:  # noqa: BLE001
                    wiz.log("снимок не удался:\n" + traceback.format_exc())
                finally:
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
                elif ev[0] == "python_done":
                    state["python_busy"] = False
                    if ev[1]:
                        python_btn.pack_forget()
                        summary.configure(text=t("done_ok"), fg="#1a7f37")
                    else:
                        python_btn.configure(state="normal")
                        summary.configure(text=t("python_missing"), fg="#b02a37")
        except queue.Empty:
            pass
        root.after(100, poll)

    root.after(100, poll)

    def worker():
        wiz = Wizard(state["lang"], {k: v.get() for k, v in vars_.items()},
                     log_cb=lambda line: events.put(("log", line)), ask_cb=(None if auto else ask), offline=offline)
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
        events.put(("done", wiz, ok))

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

    def copy_report():
        w = state["wizard"]
        if w:
            root.clipboard_clear()
            root.clipboard_append(w.report_text())
            summary.configure(text=t("clipboard"), fg="#1a7f37")

    def send_github():
        if state["wizard"]:
            copy_report()
            webbrowser.open(state["wizard"].issue_url())

    def send_mail():
        if state["wizard"]:
            copy_report()
            webbrowser.open(state["wizard"].mailto_url())

    def open_report():
        w = state["wizard"]
        if w and w.report_file and os.path.exists(w.report_file):
            subprocess.Popen(["open", w.report_file])

    def open_logs():
        w = state["wizard"]
        subprocess.Popen(["open", w.paths.logs if w else Paths().logs])

    def start_apps():
        p = Paths()
        try:
            if os.path.isdir(p.contragenti_app):
                subprocess.Popen(["open", "-a", p.contragenti_app, "--args", "--lang", state["lang"]])
            elif os.path.exists(p.contragenti_py):
                subprocess.Popen([p.venv_python or sys.executable, p.contragenti_py, "--lang", state["lang"]], cwd=p.root)
            if os.path.isdir(p.demo_app):
                subprocess.Popen(["open", "-a", p.demo_app])
        except OSError as exc:
            summary.configure(text=str(exc), fg="#b02a37")

    rep_btns["open_report"].configure(command=open_report)
    rep_btns["send_github"].configure(command=send_github)
    rep_btns["send_mail"].configure(command=send_mail)
    rep_btns["copy"].configure(command=copy_report)
    rep_btns["open_logs"].configure(command=open_logs)
    start_btn.configure(command=start_apps)

    if auto:
        vars_["seed"].set("--no-seed" not in argv)
        vars_["python"].set("--no-python" not in argv)
        vars_["update"].set("--no-update" not in argv)
        root.after(400, on_run)
    root.lift()
    root.mainloop()
    return 0


# ────────────────────────────── удаление ──────────────────────────────

def uninstall_app(silent, purge_data):
    """Удаляет каталог установки, симлинки в ~/Applications и LaunchAgents;
    данные в ~/Library/Application Support/Contragenti — только с --purge-data
    (в окне — по вопросу)."""
    p = Paths()
    root = p.root
    if not silent:
        import tkinter as tk
        from tkinter import messagebox
        r = tk.Tk()
        r.withdraw()
        ok = messagebox.askyesno("Contragenti", "Удалить Contragenti из %s?" % root)
        if ok and not purge_data:
            purge_data = messagebox.askyesno("Contragenti", "Удалить и данные (companies.db, clients.db) из\n%s ?" % p.support)
        r.destroy()
        if not ok:
            return 1
    for pat in ("Contragenti.app/Contents/MacOS/Contragenti", "Demo CRM.app/Contents/MacOS/Demo CRM"):
        _sh(["pkill", "-f", pat])
    apps = os.path.join(p.home, "Applications")
    for name in ("Contragenti.app", "Demo CRM.app", "Contragenti Setup.app"):
        link = os.path.join(apps, name)
        if os.path.islink(link):
            os.remove(link)
    for la in ("md.una.contragenti.plist", "md.una.contragenti.democrm.plist"):
        path = os.path.join(p.home, "Library", "LaunchAgents", la)
        if os.path.exists(path):
            _sh(["launchctl", "unload", path])
            os.remove(path)
    if purge_data:
        shutil.rmtree(p.support, ignore_errors=True)
        _sh(["defaults", "delete", DEFAULTS_DOMAIN])
    # каталог установки удаляется после выхода этого процесса (он сам внутри)
    if root.startswith("/Applications/") and not dir_writable(root):
        script = "sleep 2; osascript -e 'do shell script \"rm -rf \\\"%s\\\"\" with administrator privileges'" % root
    else:
        script = "sleep 2; rm -rf \"%s\"" % root
    subprocess.Popen(["/bin/sh", "-c", script])
    return 0


# ────────────────────────────── main ──────────────────────────────

def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--uninstall" in argv:
        return uninstall_app("--silent" in argv, "--purge-data" in argv)
    lang = default_lang()
    offline = "--offline" in argv
    if "--lang" in argv:
        i = argv.index("--lang")
        if i + 1 < len(argv) and argv[i + 1] in LANGS:
            lang = argv[i + 1]
    if "--check" in argv:
        wiz = Wizard(lang, {"update": "--no-update" not in argv, "db": True,
                            "seed": "--no-seed" not in argv, "selftest": True, "shortcuts": True,
                            "python": "--no-python" not in argv},
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
    return run_gui(lang, offline, auto="--auto" in argv, shot=shot, argv=argv)


if __name__ == "__main__":
    sys.exit(main())
