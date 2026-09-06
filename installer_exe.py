"""
Contragenti-setup.exe — тонкий установщик без Windows Installer.

Зачем тонкий: MSI на части компьютеров не запускается — «The system
administrator has set policies to prevent this installation» (код 1625:
политика DisableUserInstalls / запрет MSI из интернета и т.п.). Этот exe с
Windows Installer не связан. А сам файл должен быть маленьким — раньше он
целиком носил в себе Python, Selenium, PIL, Demo CRM (~50 МБ внутри
PyInstaller-onefile), из-за чего временная папка _MEI... не успевала
раскрыться и удалиться на выходе («Failed to remove temporary directory»,
классический баг PyInstaller onefile + большой встроенный ресурс). Теперь
внутри exe нет ни программы, ни Python — только окно на tkinter и загрузчик.
При запуске он читает release.json из репозитория (версия, ссылка и sha256
полного пакета `Contragenti-<версия>-app.zip`), скачивает и проверяет его,
распаковывает в целевой каталог, создаёт ярлыки и запись в «Программы и
компоненты», запускает мастер настройки. Всегда ставит ту версию, что
сейчас лежит в репозитории, — сам exe от версии не зависит, и переиздавать
его при каждом релизе не обязательно (но пересобираем вместе с остальным,
чтобы номер в имени файла совпадал с тем, что реально будет установлено).

Собирается tools/build_exe_installer.py: PyInstaller --onefile, без
встроенной программы — только иконка и корни сертификатов certifi (запасной
путь при CERTIFICATE_VERIFY_FAILED на старых образах Windows).

Режимы:
    Contragenti-setup.exe                 окно (каталог, ярлыки, язык)
    Contragenti-setup.exe /S              тихо в Program Files (админ) или профиль
    Contragenti-setup.exe /S /D=C:\\Dir     тихо в указанный каталог
    Contragenti-setup.exe --extract-only C:\\Dir
                                           портативно: только распаковать,
                                           без ярлыков и реестра
    --no-shortcuts  --no-wizard  --lang ro|en|ru  --offline-payload FILE.zip
                                           (для тестов/офлайн: не качать,
                                           взять готовый app.zip с диска)
Установка без интернета не работает (кроме --offline-payload) — для этого
используйте Contragenti-<версия>-win64.msi, он несёт всё в себе.
Удаление: «Программы и компоненты» → Contragenti (запускает
"ContragentiSetup.exe" --uninstall) или тот же мастер с ключом --uninstall.
"""

import ctypes
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import zipfile

try:
    import winreg
except ImportError:
    winreg = None

APP = "Contragenti"
PUBLISHER = "Pavel Tuhari"
UNINST_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Contragenti"
RELEASE_URL = "https://raw.githubusercontent.com/PavelTuhari/Contragenti/main/release.json"
LANGS = ("ro", "en", "ru")
LANG_NAMES = {"ro": "Română", "en": "English", "ru": "Русский"}
TR = {
    "ru": {
        "title": "Установка Contragenti",
        "intro": "Мастер скачает актуальную сборку из github.com/PavelTuhari/Contragenti "
                 "(нужен интернет) и распакует её в каталог ниже, без прав администратора и "
                 "без Windows Installer. После установки откроется мастер настройки.",
        "dir": "Каталог:", "browse": "Обзор…", "language": "Язык:",
        "opt_desktop": "Ярлыки на рабочем столе (Contragenti, Demo CRM)",
        "opt_menu": "Папка в меню «Пуск» и запись в «Программы и компоненты»",
        "opt_wizard": "После установки запустить мастер настройки",
        "install": "Установить", "close": "Закрыть", "done": "Установлено (версия %s) в %s",
        "err": "Ошибка: %s", "busy": "Закройте Contragenti и Demo CRM и повторите: %s",
        "elevating": "Для установки в %s нужны права администратора — подтвердите запрос Windows…",
        "fallback": "Без прав администратора — установка в профиль пользователя: %s",
        "fetching": "Проверка последней версии…",
        "downloading": "Загрузка… %d%% (%.1f из %.1f МБ)",
        "verifying": "Проверка контрольной суммы…",
        "extracting": "Распаковка… %d%%", "shortcuts": "Ярлыки и реестр…", "wizard": "Запуск мастера настройки…",
        "no_net": "Нет связи с GitHub: %s\nБез интернета используйте Contragenti-<версия>-win64.msi — "
                  "он содержит всё необходимое и не требует загрузки во время установки.",
        "bad_sum": "Файл скачан повреждённым (не совпала контрольная сумма) — попробуйте ещё раз.",
    },
    "en": {
        "title": "Contragenti Setup",
        "intro": "The wizard downloads the current build from github.com/PavelTuhari/Contragenti "
                 "(internet required) and unpacks it into the folder below, without administrator "
                 "rights and without Windows Installer. The setup wizard opens afterwards.",
        "dir": "Folder:", "browse": "Browse…", "language": "Language:",
        "opt_desktop": "Desktop shortcuts (Contragenti, Demo CRM)",
        "opt_menu": "Start menu folder and “Programs and Features” entry",
        "opt_wizard": "Run the setup wizard after installation",
        "install": "Install", "close": "Close", "done": "Installed (version %s) to %s",
        "err": "Error: %s", "busy": "Close Contragenti and Demo CRM and retry: %s",
        "elevating": "Installing to %s needs administrator rights — confirm the Windows prompt…",
        "fallback": "No administrator rights — installing into the user profile: %s",
        "fetching": "Checking the latest version…",
        "downloading": "Downloading… %d%% (%.1f of %.1f MB)",
        "verifying": "Verifying checksum…",
        "extracting": "Extracting… %d%%", "shortcuts": "Shortcuts and registry…", "wizard": "Starting the setup wizard…",
        "no_net": "Can't reach GitHub: %s\nWithout internet use Contragenti-<version>-win64.msi — "
                  "it bundles everything and needs no download during setup.",
        "bad_sum": "The download is corrupted (checksum mismatch) — try again.",
    },
    "ro": {
        "title": "Instalare Contragenti",
        "intro": "Asistentul descarcă sursa actuală de pe github.com/PavelTuhari/Contragenti "
                 "(necesită internet) și o dezarhivează în dosarul de mai jos, fără drepturi de "
                 "administrator și fără Windows Installer. Apoi se deschide asistentul de configurare.",
        "dir": "Dosar:", "browse": "Răsfoiește…", "language": "Limba:",
        "opt_desktop": "Scurtături pe desktop (Contragenti, Demo CRM)",
        "opt_menu": "Dosar în meniul Start și înregistrare în „Programe și caracteristici”",
        "opt_wizard": "După instalare pornește asistentul de configurare",
        "install": "Instalează", "close": "Închide", "done": "Instalat (versiunea %s) în %s",
        "err": "Eroare: %s", "busy": "Închideți Contragenti și Demo CRM și reîncercați: %s",
        "elevating": "Instalarea în %s necesită drepturi de administrator — confirmați cererea Windows…",
        "fallback": "Fără drepturi de administrator — instalare în profilul utilizatorului: %s",
        "fetching": "Se verifică ultima versiune…",
        "downloading": "Se descarcă… %d%% (%.1f din %.1f MB)",
        "verifying": "Se verifică suma de control…",
        "extracting": "Dezarhivare… %d%%", "shortcuts": "Scurtături și registru…", "wizard": "Pornirea asistentului…",
        "no_net": "Nu se poate contacta GitHub: %s\nFără internet folosiți Contragenti-<versiune>-win64.msi — "
                  "conține tot ce e necesar și nu are nevoie de descărcare la instalare.",
        "bad_sum": "Fișierul descărcat este corupt (suma de control nu se potrivește) — încercați din nou.",
    },
}


# ────────────────────────────── rețea ──────────────────────────────

def _res_path(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def _ssl_contexts():
    """Хранилище сертификатов Windows на свежем сервере может не знать
    промежуточный сертификат github(usercontent).com (CERTIFICATE_VERIFY_FAILED).
    Тогда пробуем набор корней certifi, встроенный в exe. Проверка
    сертификата не отключается никогда — тот же приём, что в setup_wizard.py."""
    yield None
    try:
        yield ssl.create_default_context(cafile=_res_path("cacert.pem"))
    except Exception:  # noqa: BLE001
        return


def _urlopen(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "Contragenti-Setup/1.4"})
    last = None
    for ctx in _ssl_contexts():
        try:
            if ctx is None:
                return urllib.request.urlopen(req, timeout=timeout)
            return urllib.request.urlopen(req, timeout=timeout, context=ctx)
        except urllib.error.URLError as exc:
            last = exc
            if "CERTIFICATE_VERIFY_FAILED" not in str(exc):
                raise
    raise last


def http_get(url, timeout=15):
    with _urlopen(url, timeout) as resp:
        return resp.read()


def download_to(url, dst, timeout=30, progress=None, total_hint=0):
    """progress(done_bytes, total_bytes) вызывается по мере загрузки."""
    tmp = dst + ".part"
    with _urlopen(url, timeout) as resp:
        total = int(resp.headers.get("Content-Length") or total_hint or 0)
        done = 0
        with open(tmp, "wb") as f:
            while True:
                chunk = resp.read(1 << 16)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                if progress:
                    progress(done, total)
    os.replace(tmp, dst)
    return os.path.getsize(dst)


def fetch_manifest():
    return json.loads(http_get(RELEASE_URL, timeout=15).decode("utf-8-sig"))


def sha256_of(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ────────────────────────────── установка ──────────────────────────────

def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:  # noqa: BLE001
        return False


def program_files_dir():
    return os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), APP)


def user_dir():
    return os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), APP)


def default_dir():
    """По умолчанию — Program Files для всех пользователей; права
    администратора запрашиваются (UAC) в момент установки, при отказе —
    профиль текущего пользователя."""
    return program_files_dir()


def dir_writable(path):
    """Можно ли писать в каталог (создаётся при необходимости)."""
    try:
        os.makedirs(path, exist_ok=True)
        probe = os.path.join(path, "~w%d.tmp" % os.getpid())
        with open(probe, "w") as f:
            f.write("")
        os.remove(probe)
        return True
    except OSError:
        return False


def relaunch_elevated(args):
    """Перезапуск установщика с правами администратора (UAC). True — запущен."""
    try:
        params = " ".join('"%s"' % a for a in args)
        if not getattr(sys, "frozen", False):
            params = '"%s" %s' % (os.path.abspath(__file__), params)
        return ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params, None, 1) > 32
    except Exception:  # noqa: BLE001
        return False


def default_lang():
    if winreg is not None:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\DemoCRM") as k:
                v, _ = winreg.QueryValueEx(k, "Language")
                if str(v).lower() in LANGS:
                    return str(v).lower()
        except OSError:
            pass
        try:
            ui = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF
            return {0x18: "ro", 0x19: "ru"}.get(ui, "en")
        except Exception:  # noqa: BLE001
            pass
    return "ro"


def _ps(script):
    root = os.environ.get("SystemRoot", r"C:\Windows")
    exe = os.path.join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    return subprocess.run([exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                          capture_output=True, text=True, timeout=120, errors="replace",
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def make_shortcut(lnk, target, args="", workdir="", icon=""):
    q = lambda s: s.replace("'", "''")  # noqa: E731
    script = (
        "$w = New-Object -ComObject WScript.Shell; "
        "$s = $w.CreateShortcut('%s'); $s.TargetPath = '%s'; $s.Arguments = '%s'; "
        "$s.WorkingDirectory = '%s'; %s $s.Save()"
        % (q(lnk), q(target), q(args), q(workdir),
           ("$s.IconLocation = '%s,0';" % q(icon)) if icon else "")
    )
    os.makedirs(os.path.dirname(lnk), exist_ok=True)
    return _ps(script).returncode == 0


def all_users_install(target_dir):
    """Установка в Program Files (или любой каталог вне профиля) с правами
    администратора — ярлыки и запись в реестре общие для всех."""
    return is_admin() and not target_dir.lower().startswith(
        os.environ.get("LOCALAPPDATA", "~~").lower())


def desktop_dir(common=False):
    if common:
        return os.path.join(os.environ.get("PUBLIC", r"C:\Users\Public"), "Desktop")
    return os.path.join(os.environ.get("USERPROFILE", ""), "Desktop")


def start_menu_dir(common=False):
    base = os.environ.get("ProgramData", r"C:\ProgramData") if common else os.environ.get("APPDATA", "")
    return os.path.join(base, "Microsoft", "Windows", "Start Menu", "Programs", APP)


def dir_size_kb(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total // 1024


def stop_running(target_dir):
    """Программы из каталога установки надо закрыть, иначе файлы не заменить."""
    for name in ("Contragenti.exe", "ContragentiCRM.exe", "Demo CRM.exe", "ContragentiSetup.exe"):
        _ps("Get-Process | Where-Object { $_.Path -like '%s\\*' -and $_.Name -eq '%s' } | "
            "Stop-Process -Force -ErrorAction SilentlyContinue"
            % (target_dir.replace("'", "''"), os.path.splitext(name)[0].replace("'", "''")))


def extract(zip_path, target_dir, progress=None):
    """Распаковывает уже скачанный (и проверенный по sha256) zip — обычный
    файл во временном каталоге, а не внутри _MEIPASS: раньше PyInstaller
    onefile не успевал удалить свою временную папку, пока внутри неё лежал
    открытый 50-мегабайтный архив («Failed to remove temporary directory»)."""
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        total = len(names)
        for i, name in enumerate(names):
            z.extract(name, target_dir)
            if progress and (i % 50 == 0 or i == total - 1):
                progress(int((i + 1) * 100 / total))


def register(target_dir, ver, lang, desktop=True, menu=True):
    wiz = os.path.join(target_dir, "ContragentiSetup.exe")
    ico = os.path.join(target_dir, "app_icon.ico")
    common = all_users_install(target_dir)
    if desktop:
        make_shortcut(os.path.join(desktop_dir(common), "Contragenti.lnk"),
                      os.path.join(target_dir, "Contragenti.exe"), "--lang " + lang, target_dir, ico)
        make_shortcut(os.path.join(desktop_dir(common), "Demo CRM (SDK Contragenti).lnk"),
                      os.path.join(target_dir, "Demo CRM.exe"), "", target_dir, ico)
    if menu:
        sm = start_menu_dir(common)
        make_shortcut(os.path.join(sm, "Contragenti.lnk"),
                      os.path.join(target_dir, "Contragenti.exe"), "--lang " + lang, target_dir, ico)
        make_shortcut(os.path.join(sm, "Demo CRM (SDK Contragenti).lnk"),
                      os.path.join(target_dir, "Demo CRM.exe"), "", target_dir, ico)
        make_shortcut(os.path.join(sm, "Contragenti — настройка и обновление.lnk"), wiz, "", target_dir, ico)
        make_shortcut(os.path.join(sm, "Удалить Contragenti.lnk"), wiz, "--uninstall", target_dir, ico)
        if winreg is not None:
            hive = winreg.HKEY_LOCAL_MACHINE if common else winreg.HKEY_CURRENT_USER
            with winreg.CreateKey(hive, UNINST_KEY) as k:
                for name, val in (
                    ("DisplayName", APP), ("DisplayVersion", ver), ("Publisher", PUBLISHER),
                    ("InstallLocation", target_dir), ("DisplayIcon", ico),
                    ("UninstallString", '"%s" --uninstall' % wiz),
                    ("QuietUninstallString", '"%s" --uninstall --silent' % wiz),
                    ("URLInfoAbout", "https://github.com/PavelTuhari/Contragenti"),
                ):
                    winreg.SetValueEx(k, name, 0, winreg.REG_SZ, val)
                winreg.SetValueEx(k, "NoModify", 0, winreg.REG_DWORD, 1)
                winreg.SetValueEx(k, "NoRepair", 0, winreg.REG_DWORD, 1)
                winreg.SetValueEx(k, "EstimatedSize", 0, winreg.REG_DWORD, dir_size_kb(target_dir))


def install(target_dir, lang, desktop=True, menu=True, run_wizard=True, log=None, progress=None,
            offline_payload=""):
    """progress(phase, done, total) — phase: 'fetch' | 'download' | 'verify' | 'extract'."""
    log = log or (lambda s: None)

    def p(phase, done=0, total=0):
        if progress:
            progress(phase, done, total)

    tmpdir = tempfile.mkdtemp(prefix="contragenti_setup_")
    try:
        if offline_payload:
            zip_path, ver = offline_payload, "?"
        else:
            p("fetch")
            manifest = fetch_manifest()
            ver = str(manifest.get("version", "?"))
            url = manifest.get("app_zip_url")
            if not url:
                raise RuntimeError("release.json: нет app_zip_url")
            want_sha = (manifest.get("app_zip_sha256") or "").lower()
            size_hint = int(manifest.get("app_zip_size") or 0)
            zip_path = os.path.join(tmpdir, "app.zip")
            log("скачивание %s (%s)" % (url, ver))
            download_to(url, zip_path, timeout=120,
                       progress=lambda d, t: p("download", d, t or size_hint), total_hint=size_hint)
            log("скачано: %d байт" % os.path.getsize(zip_path))
            if want_sha:
                p("verify")
                got = sha256_of(zip_path)
                if got != want_sha:
                    raise ValueError("sha256 не совпал: %s != %s" % (got[:12], want_sha[:12]))
                log("sha256 совпал: %s" % got[:16])

        os.makedirs(target_dir, exist_ok=True)
        stop_running(target_dir)
        extract(zip_path, target_dir, progress=lambda pct: p("extract", pct, 100))
        log("распаковано %s в %s" % (ver, target_dir))
        if desktop or menu:
            register(target_dir, ver, lang, desktop, menu)
            log("shortcuts/registry done")
        if run_wizard:
            wiz = os.path.join(target_dir, "ContragentiSetup.exe")
            if os.path.exists(wiz):
                subprocess.Popen([wiz, "--lang", lang], cwd=target_dir)
                log("wizard started")
        return ver
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ────────────────────────────── окно ──────────────────────────────

def run_gui(lang, target, offline_payload=""):
    import tkinter as tk
    from tkinter import ttk, filedialog

    root = tk.Tk()
    t = lambda k: TR[lang][k]  # noqa: E731
    root.title(t("title"))
    root.geometry("640x420")
    root.resizable(False, False)
    ico = _res_path("app_icon.ico")
    try:
        if os.path.exists(ico):
            root.iconbitmap(ico)
    except tk.TclError:
        pass

    frm = ttk.Frame(root, padding=14)
    frm.pack(fill="both", expand=True)
    title = ttk.Label(frm, text=t("title"), font=("Segoe UI", 14, "bold"))
    title.pack(anchor="w")
    intro = ttk.Label(frm, text=t("intro"), wraplength=600, justify="left")
    intro.pack(anchor="w", pady=(4, 10))

    row = ttk.Frame(frm)
    row.pack(fill="x")
    lang_lbl = ttk.Label(row, text=t("language"))
    lang_lbl.pack(side="left")
    lang_var = tk.StringVar(value=LANG_NAMES[lang])
    lang_box = ttk.Combobox(row, textvariable=lang_var, state="readonly", width=12,
                            values=[LANG_NAMES[c] for c in LANGS])
    lang_box.pack(side="left", padx=8)

    row2 = ttk.Frame(frm)
    row2.pack(fill="x", pady=(10, 4))
    dir_lbl = ttk.Label(row2, text=t("dir"))
    dir_lbl.pack(side="left")
    dir_var = tk.StringVar(value=target)
    dir_entry = ttk.Entry(row2, textvariable=dir_var, width=60)
    dir_entry.pack(side="left", padx=8, fill="x", expand=True)
    browse = ttk.Button(row2, text=t("browse"),
                        command=lambda: dir_var.set(filedialog.askdirectory(initialdir=dir_var.get()) or dir_var.get()))
    browse.pack(side="left")

    v_desktop, v_menu, v_wiz = tk.BooleanVar(value=True), tk.BooleanVar(value=True), tk.BooleanVar(value=True)
    cb1 = ttk.Checkbutton(frm, text=t("opt_desktop"), variable=v_desktop)
    cb2 = ttk.Checkbutton(frm, text=t("opt_menu"), variable=v_menu)
    cb3 = ttk.Checkbutton(frm, text=t("opt_wizard"), variable=v_wiz)
    for cb in (cb1, cb2, cb3):
        cb.pack(anchor="w", pady=2)

    prog = ttk.Progressbar(frm, mode="determinate", maximum=100)
    prog.pack(fill="x", pady=(12, 4))
    status = ttk.Label(frm, text="", wraplength=600)
    status.pack(anchor="w")

    btns = ttk.Frame(frm)
    btns.pack(fill="x", pady=(12, 0))
    inst_btn = ttk.Button(btns, text=t("install"))
    inst_btn.pack(side="left")
    close_btn = ttk.Button(btns, text=t("close"), command=root.destroy)
    close_btn.pack(side="right")

    state = {"lang": lang, "busy": False}

    def apply_lang(*_):
        state["lang"] = next((c for c in LANGS if LANG_NAMES[c] == lang_var.get()), lang)
        tt = TR[state["lang"]]
        root.title(tt["title"])
        title.configure(text=tt["title"]); intro.configure(text=tt["intro"])
        lang_lbl.configure(text=tt["language"]); dir_lbl.configure(text=tt["dir"])
        browse.configure(text=tt["browse"]); cb1.configure(text=tt["opt_desktop"])
        cb2.configure(text=tt["opt_menu"]); cb3.configure(text=tt["opt_wizard"])
        inst_btn.configure(text=tt["install"]); close_btn.configure(text=tt["close"])
    lang_box.bind("<<ComboboxSelected>>", apply_lang)

    def ui(fn, *a):
        root.after(0, lambda: fn(*a))

    def on_progress(phase, done, total):
        tt = TR[state["lang"]]
        if phase == "fetch":
            ui(lambda: (prog.configure(value=0), status.configure(text=tt["fetching"])))
        elif phase == "download":
            pct = int(done * 60 / total) if total else 0
            ui(lambda: (prog.configure(value=pct),
                        status.configure(text=tt["downloading"] % (pct, done / 1e6, (total or done) / 1e6))))
        elif phase == "verify":
            ui(lambda: (prog.configure(value=62), status.configure(text=tt["verifying"])))
        elif phase == "extract":
            pct = 65 + int(done * 35 / 100)
            ui(lambda: (prog.configure(value=pct), status.configure(text=tt["extracting"] % done)))

    def work():
        tt = TR[state["lang"]]
        target_dir = dir_var.get().strip()
        try:
            if not dir_writable(target_dir) and not is_admin():
                # нужны права администратора: UAC; при отказе — в профиль
                ui(lambda: status.configure(text=tt["elevating"] % target_dir))
                args = ["--dir", target_dir, "--lang", state["lang"]]
                if not v_desktop.get() and not v_menu.get():
                    args.append("--no-shortcuts")
                if not v_wiz.get():
                    args.append("--no-wizard")
                if relaunch_elevated(args + ["--elevated"]):
                    ui(root.destroy)
                    return
                target_dir = user_dir()
                ui(lambda: (dir_var.set(target_dir), status.configure(text=tt["fallback"] % target_dir)))
            ver = install(target_dir, state["lang"], v_desktop.get(), v_menu.get(), v_wiz.get(),
                         progress=on_progress, offline_payload=offline_payload)
            ui(lambda: (prog.configure(value=100), status.configure(text=tt["done"] % (ver, dir_var.get().strip())),
                        close_btn.configure(state="normal")))
        except PermissionError as exc:
            ui(lambda: status.configure(text=tt["busy"] % exc))
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            ui(lambda: status.configure(text=tt["no_net"] % exc))
        except ValueError as exc:
            ui(lambda: status.configure(text=tt["bad_sum"] + " (%s)" % exc))
        except Exception as exc:  # noqa: BLE001
            ui(lambda: status.configure(text=tt["err"] % exc))
        finally:
            state["busy"] = False
            ui(lambda: inst_btn.configure(state="normal"))

    def on_install():
        if state["busy"]:
            return
        state["busy"] = True
        inst_btn.configure(state="disabled")
        threading.Thread(target=work, daemon=True).start()

    inst_btn.configure(command=on_install)
    root.mainloop()
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    lang = default_lang()
    target = default_dir()
    silent = "/S" in argv or "--silent" in argv
    offline_payload = ""
    if "--offline-payload" in argv:
        i = argv.index("--offline-payload")
        if i + 1 < len(argv):
            offline_payload = argv[i + 1]
    for a in argv:
        if a.upper().startswith("/D="):
            target = a[3:].strip('"')
    if "--dir" in argv:
        i = argv.index("--dir")
        if i + 1 < len(argv):
            target = argv[i + 1]
    if "--lang" in argv:
        i = argv.index("--lang")
        if i + 1 < len(argv) and argv[i + 1] in LANGS:
            lang = argv[i + 1]
    if "--extract-only" in argv:
        i = argv.index("--extract-only")
        dst = argv[i + 1] if i + 1 < len(argv) else target
        install(dst, lang, desktop=False, menu=False, run_wizard=False, offline_payload=offline_payload)
        return 0
    if silent or "--elevated" in argv:
        if not dir_writable(target) and not is_admin():
            # тихая установка в Program Files без прав: пробуем UAC, иначе — профиль
            if "--no-elevate" not in argv and relaunch_elevated(argv + ["--elevated"]):
                return 0
            target = user_dir()
        install(target, lang, desktop="--no-shortcuts" not in argv, menu="--no-shortcuts" not in argv,
                run_wizard="--no-wizard" not in argv, log=print, offline_payload=offline_payload)
        return 0
    return run_gui(lang, target, offline_payload=offline_payload)


if __name__ == "__main__":
    sys.exit(main())
