"""
Общий код двух мастеров настройки — Windows (setup_wizard.py) и macOS
(setup_wizard_macos.py): сеть с certifi-фолбэком, чтение release.json,
sha256, слияние стартовой базы компаний по IDNO, сравнение версий, проверка
каталога на запись, справочные функции паспорта. Ни одной платформенной
ветки здесь нет — всё платформенное остаётся в самих мастерах.
"""

import datetime
import json
import os
import shutil
import sqlite3
import urllib.error
import urllib.request

REPO = "PavelTuhari/Contragenti"
RAW_BASE = f"https://raw.githubusercontent.com/{REPO}/main/"
RELEASE_URL = RAW_BASE + "release.json"
NET_TIMEOUT = 12

LANGS = ("ro", "en", "ru")
LANG_NAMES = {"ro": "Română", "en": "English", "ru": "Русский"}


def ver_tuple(v):
    out = []
    for part in str(v).replace("-", ".").split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out)


def dir_writable(path):
    probe = os.path.join(path, "~w%d.tmp" % os.getpid())
    try:
        with open(probe, "w") as f:
            f.write("")
        os.remove(probe)
        return True
    except OSError:
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


# ────────────────────────────── сеть / GitHub ──────────────────────────────

def _ssl_contexts():
    """Хранилище сертификатов на свежей машине может не знать промежуточный
    сертификат objects.githubusercontent.com (CERTIFICATE_VERIFY_FAILED).
    Тогда пробуем набор корней certifi, который лежит в установке. Проверка
    сертификата не отключается никогда."""
    import ssl
    yield None
    try:
        import certifi
        yield ssl.create_default_context(cafile=certifi.where())
    except Exception:  # noqa: BLE001
        return


def _urlopen(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "Contragenti-Setup/1.3"})
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


def http_get(url, timeout=NET_TIMEOUT):
    with _urlopen(url, timeout) as resp:
        return resp.read()


def download_to(url, dst, timeout=60, progress=None):
    """progress(done_bytes, total_bytes) вызывается по мере загрузки."""
    tmp = dst + ".part"
    with _urlopen(url, timeout) as resp, open(tmp, "wb") as f:
        if progress is None:
            shutil.copyfileobj(resp, f)
        else:
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            while True:
                chunk = resp.read(1 << 16)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                progress(done, total)
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
