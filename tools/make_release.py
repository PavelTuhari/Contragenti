"""Собирает release/: zip-пакет обновления, копии MSI/setup.exe/app.zip,
обновляет release.json.

    python tools/make_release.py            zip + MSI/exe/app.zip (если новее в dist/) + release.json
    python tools/make_release.py --zip-only только zip и release.json (вызов из build.bat
                                            и pre-commit: после каждой перекомпиляции
                                            и любого коммита пакет актуален)
    python tools/make_release.py --macos    только артефакты macOS из dist/macos/
                                            (tools/build_macos.sh) и их поля в release.json;
                                            Windows-поля не трогаются

Zip-пакет `release/Contragenti-update-<версия>.zip` — то, что мастер настройки
(«ContragentiSetup.exe») скачивает и раскладывает поверх установки без
переустановки MSI: Demo CRM (exe, lang.json, processes.json, sample_card.xml,
README_ru.md), инструкции, SDK, стартовая база компаний, setup_wizard.py.
Пути внутри zip = пути в каталоге установки.

`release/Contragenti-<версия>-app.zip` — вся сборка cx_Freeze
(build/exe.win-amd64-3.12): его качает тонкий `Contragenti-<версия>-setup.exe`
во время установки (сам этот exe программу и Python не содержит).

Zip собирается детерминированно (фиксированные даты записей, сортировка),
поэтому при неизменном содержимом файл байт-в-байт тот же и коммит не
раздувается. release.json получает url, размер и sha256 каждого файла —
загрузчик сверяет sha256 после скачивания.
"""
import hashlib
import json
import os
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = "https://github.com/PavelTuhari/Contragenti/raw/main/"
REL_DIR = os.path.join(ROOT, "release")

# (путь в репозитории, путь в установке)
FILES = [
    ("crm_delphi/ContragentiCRM.exe", "DemoCRM/ContragentiCRM.exe"),
    ("crm_delphi/lang.json", "DemoCRM/lang.json"),
    ("crm_delphi/processes.json", "DemoCRM/processes.json"),
    ("crm_delphi/sample_card.xml", "DemoCRM/sample_card.xml"),
    ("crm_delphi/README_ru.md", "DemoCRM/README_ru.md"),
    ("INTEGRATION.md", "INTEGRATION.md"),
    ("INSTALL_WINDOWS_ru.md", "INSTALL_WINDOWS_ru.md"),
    ("INSTALL_MSI_ru.md", "INSTALL_MSI_ru.md"),
    ("INSTALL_RO.md", "INSTALL_RO.md"),
    ("API_ru.md", "API_ru.md"),
    ("GUIDE_ru.md", "GUIDE_ru.md"),
    ("README.md", "README.md"),
    ("sdk/README.md", "sdk/README.md"),
    ("sdk/python/contragenti_sdk.py", "sdk/python/contragenti_sdk.py"),
    ("sdk/cpp/contragenti_sdk.h", "sdk/cpp/contragenti_sdk.h"),
    ("sdk/cpp/example.cpp", "sdk/cpp/example.cpp"),
    ("data/companies_seed.zip", "data/companies_seed.zip"),
    ("setup_wizard.py", "setup_wizard.py"),
    ("setup_common.py", "setup_common.py"),
    ("VERSION", "VERSION"),
]

# артефакты macOS (tools/build_macos.sh): (шаблон имени в dist/macos, суффикс для очистки, ключ release.json)
MACOS_ARTIFACTS = [
    ("Contragenti-%s-macos.pkg", "-macos.pkg", "macos_pkg"),
    ("Contragenti-%s-macos-app.zip", "-macos-app.zip", "macos_app_zip"),
    ("Contragenti-%s-macos-democrm.zip", "-macos-democrm.zip", "macos_democrm_zip"),
]


def version():
    with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
        return f.read().strip()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_zip(ver):
    os.makedirs(REL_DIR, exist_ok=True)
    out = os.path.join(REL_DIR, f"Contragenti-update-{ver}.zip")
    tmp = out + ".part"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for src, dst in sorted(FILES, key=lambda p: p[1]):
            path = os.path.join(ROOT, src.replace("/", os.sep))
            if not os.path.exists(path):
                print("  ! нет файла:", src)
                continue
            with open(path, "rb") as f:
                data = f.read()
            # exe и zip внутри — как есть; тексты нормализуем к LF, чтобы
            # zip не зависел от autocrlf на машине сборки
            if not dst.lower().endswith((".exe", ".zip", ".db")):
                data = data.replace(b"\r\n", b"\n")
            info = zipfile.ZipInfo(dst, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
    # если содержимое не изменилось — оставляем старый файл (тот же байт-в-байт)
    if os.path.exists(out) and sha256(out) == sha256(tmp):
        os.remove(tmp)
    else:
        os.replace(tmp, out)
    # старые версии пакета — убрать, в репозитории живёт только текущий
    for name in os.listdir(REL_DIR):
        if name.startswith("Contragenti-update-") and name.endswith(".zip") and name != os.path.basename(out):
            os.remove(os.path.join(REL_DIR, name))
    return out


def copy_artifact(ver, pattern, ext, sub=""):
    """Копирует dist/<sub>/<pattern> в release/, старые версии того же типа удаляет."""
    src = os.path.join(ROOT, "dist", sub, pattern % ver)
    dst = os.path.join(REL_DIR, pattern % ver)
    if os.path.exists(src) and (not os.path.exists(dst) or sha256(src) != sha256(dst)):
        shutil.copy2(src, dst)
        print("  скопирован:", dst)
    for name in os.listdir(REL_DIR):
        if name.endswith(ext) and name != os.path.basename(dst):
            os.remove(os.path.join(REL_DIR, name))
    return dst if os.path.exists(dst) else ""


def copy_msi(ver):
    return copy_artifact(ver, "Contragenti-%s-win64.msi", ".msi")


def copy_exe(ver):
    return copy_artifact(ver, "Contragenti-%s-setup.exe", "-setup.exe")


def copy_app_zip(ver):
    return copy_artifact(ver, "Contragenti-%s-app.zip", "-app.zip")


def copy_macos_artifacts(ver):
    """dist/macos/* → release/; возвращает {ключ: путь} для update_manifest_macos."""
    out = {}
    for pattern, ext, key in MACOS_ARTIFACTS:
        path = copy_artifact(ver, pattern, ext, sub="macos")
        if path:
            out[key] = path
    return out


def update_manifest_macos(ver, paths):
    """Только macos_*-поля; msi_*/exe_*/app_zip_* и components не трогаются —
    сборка на Windows про эти поля не знает и тоже их не затирает."""
    path = os.path.join(ROOT, "release.json")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    rel = json.loads(text)
    rel["version"] = ver
    for key, fpath in paths.items():
        rel[key + "_url"] = RAW + "release/" + os.path.basename(fpath)
        rel[key + "_size"] = os.path.getsize(fpath)
        rel[key + "_sha256"] = sha256(fpath)
    rel["macos_install_sh"] = RAW + "release/contragenti-macos-install.sh"
    rel["macos_arch"] = os.uname().machine if hasattr(os, "uname") else "arm64"
    # файлы, которые мастер macOS кладёт поверх установки без переустановки;
    # Demo CRM.app обновляется целиком через macos_democrm_zip_url
    rel["macos_components"] = [
        {"src": "setup_wizard_macos.py", "dst": "setup_wizard_macos.py"},
        {"src": "setup_common.py", "dst": "setup_common.py"},
        {"src": "INSTALL_MACOS_ru.md", "dst": "INSTALL_MACOS_ru.md"},
        {"src": "INSTALL_MACOS_RO.md", "dst": "INSTALL_MACOS_RO.md"},
        {"src": "crm_macos/README_ru.md", "dst": "DemoCRM/README_macos_ru.md"},
    ]
    new_text = json.dumps(rel, ensure_ascii=False, indent=2) + "\n"
    if new_text != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_text)
        print("  release.json обновлён (macos_*)")


def update_manifest(ver, zip_path, msi_path, exe_path="", app_zip_path=""):
    path = os.path.join(ROOT, "release.json")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    rel = json.loads(text)
    rel["version"] = ver
    rel["update_zip"] = RAW + "release/" + os.path.basename(zip_path)
    rel["update_zip_size"] = os.path.getsize(zip_path)
    rel["update_zip_sha256"] = sha256(zip_path)
    if msi_path:
        rel["msi_url"] = RAW + "release/" + os.path.basename(msi_path)
        rel["msi_size"] = os.path.getsize(msi_path)
        rel["msi_sha256"] = sha256(msi_path)
    if exe_path:
        # setup.exe без Windows Installer — мастер предпочитает его MSI
        rel["exe_url"] = RAW + "release/" + os.path.basename(exe_path)
        rel["exe_size"] = os.path.getsize(exe_path)
        rel["exe_sha256"] = sha256(exe_path)
    if app_zip_path:
        # полная сборка (build/exe.win-*), которую setup.exe докачивает при установке
        rel["app_zip_url"] = RAW + "release/" + os.path.basename(app_zip_path)
        rel["app_zip_size"] = os.path.getsize(app_zip_path)
        rel["app_zip_sha256"] = sha256(app_zip_path)
    new_text = json.dumps(rel, ensure_ascii=False, indent=2) + "\n"
    if new_text != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_text)
        print("  release.json обновлён")


def main(argv):
    ver = version()
    if "--macos" in argv:
        paths = copy_macos_artifacts(ver)
        for k, p in paths.items():
            print("  %s: %s %d байт" % (k, os.path.basename(p), os.path.getsize(p)))
        update_manifest_macos(ver, paths)
        return 0
    zip_path = build_zip(ver)
    print("  zip:", zip_path, os.path.getsize(zip_path), "байт")
    msi_path, exe_path, app_zip_path = "", "", ""
    if "--zip-only" in argv:
        names = os.listdir(REL_DIR) if os.path.isdir(REL_DIR) else []
        msi = [n for n in names if n.endswith(".msi")]
        exe = [n for n in names if n.endswith("-setup.exe")]
        app_zip = [n for n in names if n.endswith("-app.zip")]
        msi_path = os.path.join(REL_DIR, msi[0]) if msi else ""
        exe_path = os.path.join(REL_DIR, exe[0]) if exe else ""
        app_zip_path = os.path.join(REL_DIR, app_zip[0]) if app_zip else ""
    else:
        msi_path = copy_msi(ver)
        exe_path = copy_exe(ver)
        app_zip_path = copy_app_zip(ver)
    update_manifest(ver, zip_path, msi_path, exe_path, app_zip_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
