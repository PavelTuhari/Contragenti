# -*- coding: utf-8 -*-
"""
Сбор иллюстраций для книги.

Часть снимков уже лежит в репозитории (прогоны самотестов Demo CRM на
Windows и macOS, снимки Contragenti), часть делается прямо сейчас:
страницы API прослойки снимает headless-Chrome, окно имитатора кассы —
`screencapture` по координатам самого окна.

Снимки уменьшаются до ширины книги: 105 кадров ретины весят десятки
мегабайт, а в книге нужна читаемая картинка, а не пиксель в пиксель.
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WIDTH = 1400


def _resize(src, dst, width=WIDTH):
    """Уменьшить по ширине (sips на macOS), иначе просто скопировать."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if sys.platform == "darwin" and shutil.which("sips"):
        r = subprocess.run(["sips", "--resampleWidth", str(width), src, "--out", dst],
                           capture_output=True, text=True)
        if r.returncode == 0 and os.path.exists(dst):
            return True
    shutil.copyfile(src, dst)
    return True


def copy_set(pairs, src_dir, out_dir, prefix, width=WIDTH):
    """pairs: [(имя файла, подпись)] → [(путь в книге, подпись)]."""
    done = []
    for name, caption in pairs:
        src = os.path.join(src_dir, name)
        if not os.path.exists(src):
            continue
        dst_name = "%s_%s" % (prefix, name)
        _resize(src, os.path.join(out_dir, dst_name), width)
        done.append((dst_name, caption))
    return done


# ── снимки, которые делаются сейчас ──

def chrome_shot(url, dst, size="1400,1000", wait_ms=1200):
    if not os.path.exists(CHROME):
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    cmd = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
           "--virtual-time-budget=%d" % wait_ms, "--window-size=%s" % size,
           "--screenshot=%s" % dst, url]
    subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    return os.path.exists(dst)


def emulator_window_shot(dst, port=50719):
    """Снимок окна имитатора кассы: программа сама называет свои координаты."""
    if sys.platform != "darwin":
        return False
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shot_gui.py")
    r = subprocess.run([sys.executable, script, dst, str(port)],
                       capture_output=True, text=True, cwd=ROOT, timeout=120)
    if r.returncode != 0:
        print("   окно имитатора снять не удалось: %s" % (r.stderr or "").strip()[-200:])
    return os.path.exists(dst)
