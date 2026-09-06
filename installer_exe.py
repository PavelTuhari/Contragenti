"""
Contragenti-<версия>-setup.exe — установщик без Windows Installer.

Зачем: MSI на части компьютеров не запускается — «The system administrator
has set policies to prevent this installation» (код 1625: политика
DisableUserInstalls / запрет MSI из интернета и т.п.). Этот exe с Windows
Installer не связан: он просто распаковывает программу в каталог
пользователя, создаёт ярлыки и запись в «Программы и компоненты»
(HKCU, без прав администратора) и запускает мастер настройки.

Собирается tools/build_exe_installer.py: PyInstaller --onefile, внутри —
payload.zip с готовой сборкой cx_Freeze (build/exe.win-amd64-3.12).

Режимы:
    Contragenti-1.3.0-setup.exe                 окно (каталог, ярлыки, язык)
    Contragenti-1.3.0-setup.exe /S              тихо в %LOCALAPPDATA%\\Contragenti
    Contragenti-1.3.0-setup.exe /S /D=C:\\Dir     тихо в указанный каталог
    Contragenti-1.3.0-setup.exe --extract-only C:\\Dir
                                                 портативно: только распаковать,
                                                 без ярлыков и реестра
    --no-shortcuts  --no-wizard  --lang ro|en|ru
Удаление: «Программы и компоненты» → Contragenti (запускает
"Contragenti Setup.exe" --uninstall) или тот же мастер с ключом --uninstall.
"""

import ctypes
import os
import subprocess
import sys
import threading
import zipfile

try:
    import winreg
except ImportError:
    winreg = None

APP = "Contragenti"
PUBLISHER = "Pavel Tuhari"
UNINST_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Contragenti"
LANGS = ("ro", "en", "ru")
LANG_NAMES = {"ro": "Română", "en": "English", "ru": "Русский"}
TR = {
    "ru": {
        "title": "Установка Contragenti",
        "intro": "Программа будет распакована в каталог ниже, без прав администратора и без "
                 "Windows Installer. После установки откроется мастер настройки.",
        "dir": "Каталог:", "browse": "Обзор…", "language": "Язык:",
        "opt_desktop": "Ярлыки на рабочем столе (Contragenti, Demo CRM)",
        "opt_menu": "Папка в меню «Пуск» и запись в «Программы и компоненты»",
        "opt_wizard": "После установки запустить мастер настройки",
        "install": "Установить", "close": "Закрыть", "done": "Установлено в %s",
        "err": "Ошибка: %s", "busy": "Закройте Contragenti и Demo CRM и повторите: %s",
        "extracting": "Распаковка… %d%%", "shortcuts": "Ярлыки и реестр…", "wizard": "Запуск мастера настройки…",
    },
    "en": {
        "title": "Contragenti Setup",
        "intro": "The program will be unpacked into the folder below, without administrator rights and "
                 "without Windows Installer. The setup wizard opens afterwards.",
        "dir": "Folder:", "browse": "Browse…", "language": "Language:",
        "opt_desktop": "Desktop shortcuts (Contragenti, Demo CRM)",
        "opt_menu": "Start menu folder and “Programs and Features” entry",
        "opt_wizard": "Run the setup wizard after installation",
        "install": "Install", "close": "Close", "done": "Installed to %s",
        "err": "Error: %s", "busy": "Close Contragenti and Demo CRM and retry: %s",
        "extracting": "Extracting… %d%%", "shortcuts": "Shortcuts and registry…", "wizard": "Starting the setup wizard…",
    },
    "ro": {
        "title": "Instalare Contragenti",
        "intro": "Programul va fi dezarhivat în dosarul de mai jos, fără drepturi de administrator și "
                 "fără Windows Installer. Apoi se deschide asistentul de configurare.",
        "dir": "Dosar:", "browse": "Răsfoiește…", "language": "Limba:",
        "opt_desktop": "Scurtături pe desktop (Contragenti, Demo CRM)",
        "opt_menu": "Dosar în meniul Start și înregistrare în „Programe și caracteristici”",
        "opt_wizard": "După instalare pornește asistentul de configurare",
        "install": "Instalează", "close": "Închide", "done": "Instalat în %s",
        "err": "Eroare: %s", "busy": "Închideți Contragenti și Demo CRM și reîncercați: %s",
        "extracting": "Dezarhivare… %d%%", "shortcuts": "Scurtături și registru…", "wizard": "Pornirea asistentului…",
    },
}


def payload_path():
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, "payload.zip")


def payload_version():
    try:
        with zipfile.ZipFile(payload_path()) as z:
            return z.read("VERSION").decode("utf-8-sig").strip()
    except (OSError, KeyError, zipfile.BadZipFile):
        return "0"


def default_dir():
    return os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), APP)


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


def desktop_dir():
    return os.path.join(os.environ.get("USERPROFILE", ""), "Desktop")


def start_menu_dir():
    return os.path.join(os.environ.get("APPDATA", ""), "Microsoft", "Windows", "Start Menu", "Programs", APP)


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
    """Программы из каталога установки надо закрыть, иначе exe не заменить."""
    for name in ("Contragenti.exe", "ContragentiCRM.exe", "Demo CRM.exe", "Contragenti Setup.exe"):
        _ps("Get-Process | Where-Object { $_.Path -like '%s\\*' -and $_.Name -eq '%s' } | "
            "Stop-Process -Force -ErrorAction SilentlyContinue"
            % (target_dir.replace("'", "''"), os.path.splitext(name)[0].replace("'", "''")))


def extract(target_dir, progress=None):
    with zipfile.ZipFile(payload_path()) as z:
        names = z.namelist()
        total = len(names)
        for i, name in enumerate(names):
            z.extract(name, target_dir)
            if progress and (i % 50 == 0 or i == total - 1):
                progress(int((i + 1) * 100 / total))


def register(target_dir, ver, lang, desktop=True, menu=True):
    wiz = os.path.join(target_dir, "Contragenti Setup.exe")
    ico = os.path.join(target_dir, "app_icon.ico")
    if desktop:
        make_shortcut(os.path.join(desktop_dir(), "Contragenti.lnk"),
                      os.path.join(target_dir, "Contragenti.exe"), "--lang " + lang, target_dir, ico)
        make_shortcut(os.path.join(desktop_dir(), "Demo CRM (SDK Contragenti).lnk"),
                      os.path.join(target_dir, "Demo CRM.exe"), "", target_dir, ico)
    if menu:
        sm = start_menu_dir()
        make_shortcut(os.path.join(sm, "Contragenti.lnk"),
                      os.path.join(target_dir, "Contragenti.exe"), "--lang " + lang, target_dir, ico)
        make_shortcut(os.path.join(sm, "Demo CRM (SDK Contragenti).lnk"),
                      os.path.join(target_dir, "Demo CRM.exe"), "", target_dir, ico)
        make_shortcut(os.path.join(sm, "Contragenti — настройка и обновление.lnk"), wiz, "", target_dir, ico)
        make_shortcut(os.path.join(sm, "Удалить Contragenti.lnk"), wiz, "--uninstall", target_dir, ico)
        if winreg is not None:
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, UNINST_KEY) as k:
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


def install(target_dir, lang, desktop=True, menu=True, run_wizard=True, log=None, progress=None):
    log = log or (lambda s: None)
    ver = payload_version()
    os.makedirs(target_dir, exist_ok=True)
    stop_running(target_dir)
    extract(target_dir, progress)
    log("extracted %s to %s" % (ver, target_dir))
    if desktop or menu:
        register(target_dir, ver, lang, desktop, menu)
        log("shortcuts/registry done")
    if run_wizard:
        wiz = os.path.join(target_dir, "Contragenti Setup.exe")
        if os.path.exists(wiz):
            subprocess.Popen([wiz, "--lang", lang], cwd=target_dir)
            log("wizard started")
    return ver


# ────────────────────────────── окно ──────────────────────────────

def run_gui(lang, target):
    import tkinter as tk
    from tkinter import ttk, filedialog

    root = tk.Tk()
    t = lambda k: TR[lang][k]  # noqa: E731
    root.title("%s %s" % (t("title"), payload_version()))
    root.geometry("640x420")
    root.resizable(False, False)
    ico = os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__))), "app_icon.ico")
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
        root.title("%s %s" % (tt["title"], payload_version()))
        title.configure(text=tt["title"]); intro.configure(text=tt["intro"])
        lang_lbl.configure(text=tt["language"]); dir_lbl.configure(text=tt["dir"])
        browse.configure(text=tt["browse"]); cb1.configure(text=tt["opt_desktop"])
        cb2.configure(text=tt["opt_menu"]); cb3.configure(text=tt["opt_wizard"])
        inst_btn.configure(text=tt["install"]); close_btn.configure(text=tt["close"])
    lang_box.bind("<<ComboboxSelected>>", apply_lang)

    def ui(fn, *a):
        root.after(0, lambda: fn(*a))

    def work():
        tt = TR[state["lang"]]
        try:
            install(dir_var.get().strip(), state["lang"], v_desktop.get(), v_menu.get(), v_wiz.get(),
                    progress=lambda p: ui(lambda p=p: (prog.configure(value=p),
                                                       status.configure(text=tt["extracting"] % p))))
            ui(lambda: (prog.configure(value=100), status.configure(text=tt["done"] % dir_var.get().strip()),
                        close_btn.configure(state="normal")))
        except PermissionError as exc:
            ui(lambda: status.configure(text=tt["busy"] % exc))
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
        install(dst, lang, desktop=False, menu=False, run_wizard=False)
        return 0
    if silent:
        install(target, lang, desktop="--no-shortcuts" not in argv, menu="--no-shortcuts" not in argv,
                run_wizard="--no-wizard" not in argv)
        return 0
    return run_gui(lang, target)


if __name__ == "__main__":
    sys.exit(main())
