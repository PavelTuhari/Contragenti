"""Собирает dist/Contragenti-<версия>-setup.exe — установщик без Windows Installer.

    python setup.py build_exe            # или bdist_msi — нужна build/exe.win-amd64-3.12
    python tools/build_exe_installer.py  # payload.zip из сборки + PyInstaller --onefile

Внутри exe — installer_exe.py (окно/тихий режим) и payload.zip со всей
сборкой cx_Freeze. Сам установщик Windows Installer не использует, поэтому
политики, запрещающие MSI («The system administrator has set policies to
prevent this installation», 1625), на него не действуют.
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


def make_payload(src, out):
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, _, files in os.walk(src):
            for f in files:
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, src))
                n += 1
    return n


def main():
    ver = version()
    src = build_dir()
    work = os.path.join(ROOT, "build", "pyi")
    os.makedirs(work, exist_ok=True)
    payload = os.path.join(work, "payload.zip")
    n = make_payload(src, payload)
    print("payload: %d файлов, %d байт" % (n, os.path.getsize(payload)))
    name = "Contragenti-%s-setup" % ver
    # без --uac-admin: права администратора установщик запрашивает сам только
    # когда они нужны (Program Files), а при отказе ставит в профиль
    cmd = [PY, "-m", "PyInstaller", "--onefile", "--noconsole", "--clean", "-y",
           "--name", name, "--icon", os.path.join(ROOT, "app_icon.ico"),
           "--add-data", payload + os.pathsep + ".",
           "--add-data", os.path.join(ROOT, "app_icon.ico") + os.pathsep + ".",
           "--distpath", os.path.join(ROOT, "dist"), "--workpath", work,
           "--specpath", work, os.path.join(ROOT, "installer_exe.py")]
    subprocess.run(cmd, check=True, cwd=ROOT)
    out = os.path.join(ROOT, "dist", name + ".exe")
    print("ok:", out, os.path.getsize(out), "байт")


if __name__ == "__main__":
    main()
