"""Пересобирает data/companies_seed.zip из локальной companies.db.

Внутри zip — чистая копия базы (через sqlite backup, без журнала). Её
скачивает мастер настройки после установки (setup_wizard.py) по ссылке из
release.json и сливает с локальной companies.db по ключу IDNO.
"""
import os
import sqlite3
import zipfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "companies.db")
tmp = os.path.join(root, "data", "companies.db")
out = os.path.join(root, "data", "companies_seed.zip")

os.makedirs(os.path.dirname(out), exist_ok=True)
c = sqlite3.connect(src)
b = sqlite3.connect(tmp)
c.backup(b)
b.close()
c.close()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(tmp, "companies.db")
os.remove(tmp)
rows = sqlite3.connect(src).execute("SELECT COUNT(*) FROM companies").fetchone()[0]
print("ok:", out, os.path.getsize(out), "bytes,", rows, "companies")
