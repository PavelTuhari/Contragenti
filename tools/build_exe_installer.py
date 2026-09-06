"""Собирает dist/Contragenti-<версия>-setup.exe (тонкий) и
dist/Contragenti-<версия>-app.zip (полная сборка, публикуется отдельно).

    python setup.py build_exe            # или bdist_msi — нужна build/exe.win-amd64-3.12
    python tools/build_exe_installer.py  # app.zip из сборки + PyInstaller --onefile

Раньше payload.zip (вся сборка cx_Freeze, ~50 МБ) был встроен в exe через
PyInstaller --add-data, из-за чего временная папка _MEI... не успевала
раскрыться и удалиться на выходе («Failed to remove temporary directory»).
Теперь setup.exe — только окно/загрузчик: он скачивает app.zip из
release.json во время установки (см. installer_exe.py), поэтому сам exe
маленький (tkinter/tcl-tk + certifi), а app.zip публикуется в release/ и
скачивается отдельно. Устанавливать без интернета (кроме
--offline-payload) нельзя — для офлайна используется Contragenti-<версия>-win64.msi.

Установщик Windows Installer не использует, поэтому политики, запрещающие
MSI («The system administrator has set policies to prevent this
installation», 1625), на него не действуют.
"""
import glob
import os
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable


def version():
    with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
        return f.read().strip()


def build_dir():
    dirs = sorted(glob.glob(os.path.join(ROOT, "build", "exe.win-*")))
    if not dirs:
        raise SystemExit("нет build/exe.win-*: сначала python setup.py build_exe")
    return dirs[-1]


def make_app_zip(src, out):
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, _, files in os.walk(src):
            for f in files:
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, src))
                n += 1
    return n


def certifi_cacert():
    import certifi
    return certifi.where()


def main():
    ver = version()
    src = build_dir()
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    app_zip = os.path.join(ROOT, "dist", "Contragenti-%s-app.zip" % ver)
    n = make_app_zip(src, app_zip)
    print("app.zip: %d файлов, %d байт" % (n, os.path.getsize(app_zip)))

    work = os.path.join(ROOT, "build", "pyi")
    os.makedirs(work, exist_ok=True)
    cacert = certifi_cacert()
    name = "Contragenti-%s-setup" % ver
    # без --uac-admin: права администратора установщик запрашивает сам только
    # когда они нужны (Program Files), а при отказе ставит в профиль
    cmd = [PY, "-m", "PyInstaller", "--onefile", "--noconsole", "--clean", "-y",
           "--name", name, "--icon", os.path.join(ROOT, "app_icon.ico"),
           "--add-data", cacert + os.pathsep + ".",
           "--add-data", os.path.join(ROOT, "app_icon.ico") + os.pathsep + ".",
           "--distpath", os.path.join(ROOT, "dist"), "--workpath", work,
           "--specpath", work, os.path.join(ROOT, "installer_exe.py")]
    subprocess.run(cmd, check=True, cwd=ROOT)
    out = os.path.join(ROOT, "dist", name + ".exe")
    print("ok:", out, os.path.getsize(out), "байт")
    print("ok:", app_zip, os.path.getsize(app_zip), "байт")


if __name__ == "__main__":
    main()
