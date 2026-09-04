#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Goods Catalog — пополнение единой базы товаров по штрих-коду.

Партнёрское приложение общего каталога: оператор сканирует штрих-код,
и если товара ещё нет в базе — заводит карточку, а если есть — сразу видит
существующую. Сама база служит первоисточником: штрих-код в ней уникален,
и первый, кто отсканировал новый товар, наполняет каталог для всех.

Сценарий одного окна:
  * поле штрих-кода (сканер вводит код и жмёт Enter — обрабатывается как ввод);
  * найден  → карточка товара из базы;
  * не найден → форма новой карточки (название, единица, цена, НДС) и
                кнопка «Добавить в каталог»;
  * история отсканированного хранится локально (SQLite), поиск по ней офлайн.

Запуск:  python goods_scanner.py [--lang ru] [--selftest] [--demo --demo-dir DIR]
"""

import argparse
import os
import queue
import sqlite3
import sys
import threading
import time

import tkinter as tk
from tkinter import ttk, messagebox

APP_VERSION = "1.0"


def _app_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


LOCAL_DB = os.path.join(_app_dir(), "goods_local.db")
CONFIG_PATH = os.path.join(_app_dir(), "goods_config.json")

LANGS = ("en", "ru", "ro")
LANG_NAMES = {"en": "English", "ru": "Русский", "ro": "Română"}

UM_CHOICES = ("buc", "kg", "l", "m", "pac")
TVA_CHOICES = ("A", "B", "N", "C")

# ── бренд единого каталога ──
BRAND = "Goods Catalog"
ACCENT = "#0b6e5f"
BANNER_BG = "#e3efec"

TR = {
    "en": {
        "title": "Goods Catalog — barcode intake",
        "banner": "One shared goods catalog — every barcode adds to it, the "
                  "database is the source of truth.",
        "scan_label": "Barcode:", "scan_hint": "Scan or type a barcode and press Enter",
        "lookup": "Look up", "clear": "Clear",
        "found": "In catalog", "not_found": "New barcode — fill the card and add it",
        "card_title": "Product card",
        "f_barcode": "Barcode", "f_name": "Name", "f_um": "Unit",
        "f_price": "Price", "f_tva": "VAT", "f_code": "Code",
        "add_btn": "Add to catalog", "history": "Recently scanned",
        "col_time": "Time", "col_barcode": "Barcode", "col_name": "Name", "col_status": "Status",
        "st_found": "found", "st_added": "added", "st_dup": "already there",
        "status_ready": "Ready. Scan a barcode.",
        "status_looking": "Looking up {bc}…",
        "status_found": "In catalog: {name}  (code {cod})",
        "status_new": "New barcode {bc} — enter the name and add it.",
        "status_added": "Added to catalog: {name}  (code {cod})",
        "status_dup": "Already in catalog: {name}  (code {cod})",
        "status_error": "Error",
        "msg_no_name": "Enter the product name.",
        "msg_bad_bc": "Not a valid barcode: {bc}",
        "menu_file": "File", "mi_quit": "Quit",
        "menu_lang": "Language", "menu_help": "Help",
        "mi_about": "About", "mi_selftest": "Run self-test", "mi_conn": "Connection…",
        "conn_title": "Catalog connection",
        "c_dsn": "DSN (host:port/service):", "c_user": "User (schema):",
        "c_pwd": "Password:", "c_client": "Oracle Client dir (optional):",
        "c_test": "Test", "c_save": "Save", "c_cancel": "Cancel",
        "c_ok": "Connected: {ver}", "c_noconn": "Connection is not configured.",
        "about": ("Goods Catalog {version}\n\n"
                  "Shared product catalog filled by barcode. The database is the "
                  "single source of truth: a barcode is unique in it, and the "
                  "first partner to scan a new item adds it for everyone.\n\n"
                  "  - Scan → look up → card or new-card form\n"
                  "  - Dedup by barcode across both catalog stores\n"
                  "  - Local history of scans (SQLite), offline lookup\n"
                  "  - Three languages: English / Русский / Română\n\n"
                  "Locally kept scans: {count}."),
        "selftest_title": "Goods Catalog — self-test",
    },
    "ru": {
        "title": "Каталог товаров — приём по штрих-коду",
        "banner": "Единый каталог товаров — каждый штрих-код пополняет его, "
                  "база служит первоисточником.",
        "scan_label": "Штрих-код:", "scan_hint": "Отсканируйте или введите штрих-код и нажмите Enter",
        "lookup": "Найти", "clear": "Очистить",
        "found": "Есть в каталоге", "not_found": "Новый штрих-код — заполните карточку и добавьте",
        "card_title": "Карточка товара",
        "f_barcode": "Штрих-код", "f_name": "Название", "f_um": "Единица",
        "f_price": "Цена", "f_tva": "НДС", "f_code": "Код",
        "add_btn": "Добавить в каталог", "history": "Недавно отсканировано",
        "col_time": "Время", "col_barcode": "Штрих-код", "col_name": "Название", "col_status": "Статус",
        "st_found": "найдено", "st_added": "добавлено", "st_dup": "уже было",
        "status_ready": "Готово. Отсканируйте штрих-код.",
        "status_looking": "Поиск {bc}…",
        "status_found": "Есть в каталоге: {name}  (код {cod})",
        "status_new": "Новый штрих-код {bc} — введите название и добавьте.",
        "status_added": "Добавлено в каталог: {name}  (код {cod})",
        "status_dup": "Уже в каталоге: {name}  (код {cod})",
        "status_error": "Ошибка",
        "msg_no_name": "Введите название товара.",
        "msg_bad_bc": "Некорректный штрих-код: {bc}",
        "menu_file": "Файл", "mi_quit": "Выход",
        "menu_lang": "Язык", "menu_help": "Справка",
        "mi_about": "О программе", "mi_selftest": "Запустить самопроверку", "mi_conn": "Подключение…",
        "conn_title": "Подключение к каталогу",
        "c_dsn": "DSN (host:port/service):", "c_user": "Пользователь (схема):",
        "c_pwd": "Пароль:", "c_client": "Каталог Oracle Client (необязательно):",
        "c_test": "Проверить", "c_save": "Сохранить", "c_cancel": "Отмена",
        "c_ok": "Подключено: {ver}", "c_noconn": "Подключение не настроено.",
        "about": ("Каталог товаров {version}\n\n"
                  "Единый каталог товаров, наполняемый по штрих-коду. База служит "
                  "первоисточником: штрих-код в ней уникален, и первый партнёр, "
                  "отсканировавший новый товар, заводит его для всех.\n\n"
                  "  - Скан → поиск → карточка или форма новой карточки\n"
                  "  - Дедупликация по штрих-коду в обоих хранилищах\n"
                  "  - Локальная история сканирований (SQLite), офлайн-поиск\n"
                  "  - Три языка: English / Русский / Română\n\n"
                  "Сохранено сканирований локально: {count}."),
        "selftest_title": "Каталог товаров — самопроверка",
    },
    "ro": {
        "title": "Catalog de mărfuri — recepție după cod de bare",
        "banner": "Un catalog unic de mărfuri — fiecare cod de bare îl "
                  "completează, baza este sursa primară.",
        "scan_label": "Cod de bare:", "scan_hint": "Scanați sau introduceți codul și apăsați Enter",
        "lookup": "Caută", "clear": "Șterge",
        "found": "În catalog", "not_found": "Cod nou — completați fișa și adăugați",
        "card_title": "Fișa produsului",
        "f_barcode": "Cod de bare", "f_name": "Denumire", "f_um": "Unitate",
        "f_price": "Preț", "f_tva": "TVA", "f_code": "Cod",
        "add_btn": "Adaugă în catalog", "history": "Scanate recent",
        "col_time": "Ora", "col_barcode": "Cod de bare", "col_name": "Denumire", "col_status": "Stare",
        "st_found": "găsit", "st_added": "adăugat", "st_dup": "deja există",
        "status_ready": "Gata. Scanați un cod de bare.",
        "status_looking": "Se caută {bc}…",
        "status_found": "În catalog: {name}  (cod {cod})",
        "status_new": "Cod nou {bc} — introduceți denumirea și adăugați.",
        "status_added": "Adăugat în catalog: {name}  (cod {cod})",
        "status_dup": "Deja în catalog: {name}  (cod {cod})",
        "status_error": "Eroare",
        "msg_no_name": "Introduceți denumirea produsului.",
        "msg_bad_bc": "Cod de bare invalid: {bc}",
        "menu_file": "Fișier", "mi_quit": "Ieșire",
        "menu_lang": "Limbă", "menu_help": "Ajutor",
        "mi_about": "Despre program", "mi_selftest": "Rulează auto-testul", "mi_conn": "Conexiune…",
        "conn_title": "Conexiune la catalog",
        "c_dsn": "DSN (host:port/service):", "c_user": "Utilizator (schemă):",
        "c_pwd": "Parolă:", "c_client": "Director Oracle Client (opțional):",
        "c_test": "Testează", "c_save": "Salvează", "c_cancel": "Anulează",
        "c_ok": "Conectat: {ver}", "c_noconn": "Conexiunea nu este configurată.",
        "about": ("Catalog de mărfuri {version}\n\n"
                  "Catalog comun de mărfuri completat după codul de bare. Baza "
                  "este sursa primară: codul de bare este unic în ea, iar primul "
                  "partener care scanează un produs nou îl adaugă pentru toți.\n\n"
                  "  - Scanare → căutare → fișă sau formular de fișă nouă\n"
                  "  - Deduplicare după cod în ambele depozite\n"
                  "  - Istoric local al scanărilor (SQLite), căutare offline\n"
                  "  - Trei limbi: English / Русский / Română\n\n"
                  "Scanări păstrate local: {count}."),
        "selftest_title": "Catalog de mărfuri — auto-test",
    },
}


# ─────────────────────── локальная история ───────────────────────

def local_init():
    conn = sqlite3.connect(LOCAL_DB)
    conn.execute("""CREATE TABLE IF NOT EXISTS scans (
        barcode TEXT PRIMARY KEY, denumire TEXT, um TEXT, cod INTEGER,
        status TEXT, ts TEXT)""")
    conn.commit()
    conn.close()


def local_save(barcode, denumire, um, cod, status):
    conn = sqlite3.connect(LOCAL_DB)
    conn.execute("INSERT OR REPLACE INTO scans (barcode, denumire, um, cod, status, ts) "
                 "VALUES (?,?,?,?,?, datetime('now','localtime'))",
                 (barcode, denumire, um, cod, status))
    conn.commit()
    conn.close()


def local_recent(limit=100):
    conn = sqlite3.connect(LOCAL_DB)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM scans ORDER BY ts DESC LIMIT ?", (limit,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def local_get(barcode):
    conn = sqlite3.connect(LOCAL_DB)
    conn.row_factory = sqlite3.Row
    row = conn.execute("SELECT * FROM scans WHERE barcode=?", (barcode,)).fetchone()
    conn.close()
    return dict(row) if row else None


def local_count():
    conn = sqlite3.connect(LOCAL_DB)
    n = conn.execute("SELECT COUNT(*) FROM scans").fetchone()[0]
    conn.close()
    return n


# ─────────────────────── конфиг ───────────────────────

def load_config():
    import json
    cfg = {"dsn": "192.168.0.24:1521/clouddev.world", "user": "BONUS2019",
           "password": "", "client_dir": ""}
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except Exception:  # noqa: BLE001
        pass
    for k, env in (("dsn", "GOODS_DSN"), ("user", "GOODS_USER"),
                   ("password", "GOODS_PASSWORD"), ("client_dir", "ORACLE_CLIENT_DIR")):
        if os.environ.get(env):
            cfg[k] = os.environ[env]
    return cfg


def save_config(cfg):
    import json
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


# ─────────────────────── фоновые операции ───────────────────────

class LookupWorker(threading.Thread):
    """Поиск товара по штрих-коду в общей базе (в отдельном потоке)."""

    def __init__(self, barcode, config, out_queue):
        super().__init__(daemon=True)
        self.barcode = barcode
        self.config = config
        self.out = out_queue

    def run(self):
        try:
            import goods_export
            exp = goods_export.GoodsExporter(self.config).connect()
        except Exception as exc:  # noqa: BLE001
            self.out.put(("lookup_error", str(exc)))
            return
        try:
            found = exp.find_by_barcode(self.barcode)
        except Exception as exc:  # noqa: BLE001
            self.out.put(("lookup_error", str(exc)))
            return
        finally:
            exp.close()
        self.out.put(("lookup_done", {"barcode": self.barcode, "found": found}))


class AddWorker(threading.Thread):
    """Добавление новой карточки товара в общий каталог."""

    def __init__(self, rec, config, out_queue):
        super().__init__(daemon=True)
        self.rec = rec
        self.config = config
        self.out = out_queue

    def run(self):
        try:
            import goods_export
            exp = goods_export.GoodsExporter(self.config).connect()
        except Exception as exc:  # noqa: BLE001
            self.out.put(("add_error", str(exc)))
            return
        try:
            report = exp.export_one(self.rec)
        except Exception as exc:  # noqa: BLE001
            self.out.put(("add_error", str(exc)))
            return
        finally:
            exp.close()
        self.out.put(("add_done", report))


# ─────────────────────── самопроверка ───────────────────────

def run_selftest():
    checks = []

    def add(name, fn):
        try:
            fn()
            checks.append((name, True, ""))
        except Exception as exc:  # noqa: BLE001
            checks.append((name, False, str(exc)))

    def check_local():
        local_init()
        local_count()

    def check_i18n():
        for code in LANGS:
            assert TR[code].get("title")

    def check_barcode():
        import goods_export
        assert goods_export.normalize_barcode(" 480 51 ") == "48051"
        assert not goods_export.valid_barcode("12")
        assert goods_export.valid_barcode("4820026412108")

    def check_map():
        import goods_export
        m = goods_export.map_product({"barcode": "4820026412108", "denumire": "X"})
        assert m["univers"]["TIP"] == "P"

    add("local history (SQLite)", check_local)
    add("i18n (en/ru/ro)", check_i18n)
    add("barcode normalize", check_barcode)
    add("product mapping", check_map)

    ok = all(c[1] for c in checks)
    lines = ["Goods Catalog self-test: " + ("PASS" if ok else "FAIL"), ""]
    for name, passed, err in checks:
        lines.append(f"[{'OK' if passed else 'FAIL'}] {name}" + (f": {err}" if err else ""))
    return ok, "\n".join(lines)


# ─────────────────────── интерфейс ───────────────────────

class App(tk.Tk):
    def __init__(self, args=None):
        super().__init__()
        self.args = args
        self.lang = getattr(args, "lang", "ru") if args else "ru"
        self.queue = queue.Queue()
        self.config_data = load_config()
        self.current_barcode = None
        local_init()

        self.title(self.t("title"))
        self.geometry("880x620")
        self.minsize(680, 520)
        self._build_menu()
        self._build_ui()
        self.retranslate()
        self._refresh_history()
        self.after(120, self._poll_queue)
        self.after(200, lambda: self.bc_entry.focus_set())

    def t(self, key, **kw):
        s = TR[self.lang].get(key, key)
        return s.format(**kw) if kw else s

    # ── меню ──

    def _build_menu(self):
        self.menubar = tk.Menu(self)
        self.file_menu = tk.Menu(self.menubar, tearoff=0)
        self.file_menu.add_command(label="", command=self.destroy)
        self.menubar.add_cascade(menu=self.file_menu, label="")
        self.lang_menu = tk.Menu(self.menubar, tearoff=0)
        for code in LANGS:
            self.lang_menu.add_command(label=LANG_NAMES[code],
                                       command=lambda c=code: self.set_lang(c))
        self.menubar.add_cascade(menu=self.lang_menu, label="")
        self.help_menu = tk.Menu(self.menubar, tearoff=0)
        self.help_menu.add_command(label="", command=self._show_conn)
        self.help_menu.add_command(label="", command=self._show_about)
        self.help_menu.add_command(label="", command=self._run_selftest_ui)
        self.menubar.add_cascade(menu=self.help_menu, label="")
        self.config(menu=self.menubar)

    # ── компоновка ──

    def _build_ui(self):
        banner = tk.Frame(self, bg=BANNER_BG)
        banner.pack(fill="x", side="top")
        inner = tk.Frame(banner, bg=BANNER_BG)
        inner.pack(fill="x", padx=10, pady=5)
        tk.Label(inner, text=BRAND, bg=BANNER_BG, fg=ACCENT,
                 font=("", 12, "bold")).pack(side="left")
        self.banner_lbl = tk.Label(inner, bg=BANNER_BG, fg="#274b45", font=("", 9))
        self.banner_lbl.pack(side="left", padx=(10, 0))

        # строка штрих-кода
        top = ttk.Frame(self, padding=(12, 12, 12, 6))
        top.pack(fill="x")
        self.scan_lbl = ttk.Label(top, font=("", 10, "bold"))
        self.scan_lbl.grid(row=0, column=0, sticky="w")
        self.bc_var = tk.StringVar()
        self.bc_entry = ttk.Entry(top, textvariable=self.bc_var, width=26,
                                  font=("Consolas", 14))
        self.bc_entry.grid(row=0, column=1, sticky="w", padx=(8, 6))
        self.bc_entry.bind("<Return>", lambda e: self.on_lookup())
        self.lookup_btn = ttk.Button(top, command=self.on_lookup)
        self.lookup_btn.grid(row=0, column=2, padx=(0, 4))
        self.clear_btn = ttk.Button(top, command=self._on_clear, width=10)
        self.clear_btn.grid(row=0, column=3)
        self.scan_hint = ttk.Label(top, foreground="#888", font=("", 9))
        self.scan_hint.grid(row=1, column=1, columnspan=3, sticky="w", pady=(2, 0))

        # карточка товара / форма новой
        self.card = ttk.Labelframe(self, padding=12)
        self.card.pack(fill="x", padx=12, pady=(6, 6))
        self.state_lbl = ttk.Label(self.card, font=("", 10, "bold"))
        self.state_lbl.grid(row=0, column=0, columnspan=4, sticky="w", pady=(0, 8))

        self.fields = {}
        self.field_labels = {}
        rows = [("f_name", "name", 42), ("f_um", "um", 10),
                ("f_price", "price", 12), ("f_tva", "tva", 8)]
        for i, (lkey, fkey, w) in enumerate(rows):
            lab = ttk.Label(self.card)
            lab.grid(row=1 + i, column=0, sticky="w", pady=3, padx=(0, 8))
            self.field_labels[lkey] = lab
            if fkey == "um":
                var = tk.StringVar(value=UM_CHOICES[0])
                widget = ttk.Combobox(self.card, textvariable=var, values=UM_CHOICES,
                                      width=w, state="readonly")
            elif fkey == "tva":
                var = tk.StringVar(value=TVA_CHOICES[0])
                widget = ttk.Combobox(self.card, textvariable=var, values=TVA_CHOICES,
                                      width=w, state="readonly")
            else:
                var = tk.StringVar()
                widget = ttk.Entry(self.card, textvariable=var, width=w)
            widget.grid(row=1 + i, column=1, sticky="w", pady=3)
            self.fields[fkey] = (var, widget)
        self.card.columnconfigure(1, weight=1)

        self.add_btn = ttk.Button(self.card, command=self.on_add)
        self.add_btn.grid(row=5, column=0, columnspan=2, sticky="w", pady=(10, 0))

        # история
        hist = ttk.Labelframe(self, padding=(8, 6))
        hist.pack(fill="both", expand=True, padx=12, pady=(0, 8))
        self.hist_lbl = hist
        cols = ("ts", "barcode", "name", "status")
        self.tree = ttk.Treeview(hist, columns=cols, show="headings", height=8)
        widths = {"ts": 130, "barcode": 130, "name": 380, "status": 90}
        for c in cols:
            self.tree.column(c, width=widths[c], anchor="w")
        vsb = ttk.Scrollbar(hist, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")
        self.tree.bind("<<TreeviewSelect>>", self._on_hist_select)

        self.status = tk.StringVar()
        ttk.Label(self, textvariable=self.status, relief="sunken", anchor="w",
                  padding=(6, 3)).pack(fill="x", side="bottom")

    # ── переводы ──

    def retranslate(self):
        self.title(self.t("title"))
        self.menubar.entryconfig(1, label=self.t("menu_file"))
        self.menubar.entryconfig(2, label=self.t("menu_lang"))
        self.menubar.entryconfig(3, label=self.t("menu_help"))
        self.file_menu.entryconfig(0, label=self.t("mi_quit"))
        self.help_menu.entryconfig(0, label=self.t("mi_conn"))
        self.help_menu.entryconfig(1, label=self.t("mi_about"))
        self.help_menu.entryconfig(2, label=self.t("mi_selftest"))
        self.banner_lbl.config(text=self.t("banner"))
        self.scan_lbl.config(text=self.t("scan_label"))
        self.scan_hint.config(text=self.t("scan_hint"))
        self.lookup_btn.config(text=self.t("lookup"))
        self.clear_btn.config(text=self.t("clear"))
        self.card.config(text=self.t("card_title"))
        self.add_btn.config(text=self.t("add_btn"))
        for lkey, lab in self.field_labels.items():
            lab.config(text=self.t(lkey) + ":")
        self.hist_lbl.config(text=self.t("history"))
        for c, key in zip(("ts", "barcode", "name", "status"),
                          ("col_time", "col_barcode", "col_name", "col_status")):
            self.tree.heading(c, text=self.t(key))
        if not self.status.get():
            self.status.set(self.t("status_ready"))

    def set_lang(self, code):
        self.lang = code
        self.retranslate()

    # ── действия ──

    def _on_clear(self):
        self.bc_var.set("")
        self._reset_card()
        self.bc_entry.focus_set()

    def _reset_card(self):
        self.state_lbl.config(text="")
        for fkey, (var, _w) in self.fields.items():
            if fkey == "um":
                var.set(UM_CHOICES[0])
            elif fkey == "tva":
                var.set(TVA_CHOICES[0])
            else:
                var.set("")
        self.add_btn.state(["disabled"])

    def on_lookup(self):
        import goods_export
        raw = self.bc_var.get()
        bc = goods_export.normalize_barcode(raw)
        if not goods_export.valid_barcode(bc):
            messagebox.showwarning(self.t("title"), self.t("msg_bad_bc", bc=raw))
            return
        self.current_barcode = bc
        self.bc_var.set(bc)
        # офлайн: сначала локальная история
        cached = local_get(bc)
        if cached and cached.get("cod"):
            self._show_found(bc, {"cod": cached["cod"], "denumire": cached["denumire"]})
        self.status.set(self.t("status_looking", bc=bc))
        if not self.config_data.get("password"):
            if not self._show_conn():
                return
        LookupWorker(bc, self.config_data, self.queue).start()

    def on_add(self):
        name = self.fields["name"][0].get().strip()
        if not name:
            messagebox.showinfo(self.t("title"), self.t("msg_no_name"))
            return
        rec = {"barcode": self.current_barcode, "denumire": name,
               "um": self.fields["um"][0].get(),
               "pret": self.fields["price"][0].get().strip() or None,
               "codtva": self.fields["tva"][0].get()}
        self.add_btn.state(["disabled"])
        AddWorker(rec, self.config_data, self.queue).start()

    def _show_found(self, barcode, found):
        self.state_lbl.config(text="✓ " + self.t("found"), foreground=ACCENT)
        self.fields["name"][0].set(found.get("denumire") or "")
        self.fields["name"][1].state(["readonly"])
        self.add_btn.state(["disabled"])
        self.status.set(self.t("status_found", name=found.get("denumire") or "?",
                                cod=found.get("cod")))
        local_save(barcode, found.get("denumire"), None, found.get("cod"), "found")
        self._refresh_history()

    def _show_new(self, barcode):
        self.state_lbl.config(text="＋ " + self.t("not_found"), foreground="#a63a2b")
        self.fields["name"][1].state(["!readonly"])
        self.fields["name"][0].set("")
        self.add_btn.state(["!disabled"])
        self.status.set(self.t("status_new", bc=barcode))
        self.fields["name"][1].focus_set()

    def _poll_queue(self):
        try:
            while True:
                kind, payload = self.queue.get_nowait()
                if kind == "lookup_done":
                    found = payload["found"]
                    if found and found.get("cod"):
                        self._show_found(payload["barcode"], found)
                    else:
                        self._show_new(payload["barcode"])
                elif kind == "lookup_error":
                    self.status.set(self.t("status_error"))
                    messagebox.showerror(self.t("status_error"), str(payload))
                elif kind == "add_done":
                    self._on_add_done(payload)
                elif kind == "add_error":
                    self.add_btn.state(["!disabled"])
                    self.status.set(self.t("status_error"))
                    messagebox.showerror(self.t("status_error"), str(payload))
        except queue.Empty:
            pass
        self.after(120, self._poll_queue)

    def _on_add_done(self, rep):
        name = rep.get("denumire") or "?"
        um = self.fields["um"][0].get()
        if rep["status"] == "ok":
            self.status.set(self.t("status_added", name=name, cod=rep["cod"]))
            local_save(rep["barcode"], name, um, rep["cod"], "added")
            self.state_lbl.config(text="✓ " + self.t("found"), foreground=ACCENT)
        elif rep["status"] == "duplicate":
            self.status.set(self.t("status_dup", name=name, cod=rep["cod"]))
            local_save(rep["barcode"], name, um, rep["cod"], "dup")
        else:
            self.add_btn.state(["!disabled"])
            self.status.set(self.t("status_error"))
            messagebox.showerror(self.t("status_error"), rep.get("error", "?"))
            return
        self._refresh_history()
        self.bc_var.set("")
        self._reset_card()
        self.bc_entry.focus_set()

    def _refresh_history(self):
        for iid in self.tree.get_children():
            self.tree.delete(iid)
        st_map = {"found": self.t("st_found"), "added": self.t("st_added"),
                  "dup": self.t("st_dup")}
        for rec in local_recent(100):
            self.tree.insert("", "end", values=(
                rec.get("ts", ""), rec.get("barcode", ""),
                rec.get("denumire") or "", st_map.get(rec.get("status"), rec.get("status"))))

    def _on_hist_select(self, event):
        sel = self.tree.selection()
        if sel:
            vals = self.tree.item(sel[0], "values")
            if len(vals) >= 2:
                self.bc_var.set(vals[1])

    # ── окна ──

    def _show_conn(self):
        cfg = self.config_data
        win = tk.Toplevel(self)
        win.title(self.t("conn_title"))
        win.transient(self)
        win.resizable(False, False)
        win.grab_set()
        frm = ttk.Frame(win, padding=14)
        frm.pack(fill="both", expand=True)
        fields = [("dsn", "c_dsn", False), ("user", "c_user", False),
                  ("password", "c_pwd", True), ("client_dir", "c_client", False)]
        vars_ = {}
        for i, (key, lkey, secret) in enumerate(fields):
            ttk.Label(frm, text=self.t(lkey)).grid(row=i, column=0, sticky="w", pady=4)
            v = tk.StringVar(value=cfg.get(key, ""))
            vars_[key] = v
            ttk.Entry(frm, textvariable=v, width=40,
                      show="•" if secret else "").grid(row=i, column=1, pady=4, padx=(8, 0))
        saved = {"ok": False}

        def apply():
            self.config_data = {k: v.get().strip() for k, v in vars_.items()}

        def do_test():
            apply()
            try:
                import goods_export
                exp = goods_export.GoodsExporter(self.config_data).connect()
                ver = exp.ping()
                exp.close()
                messagebox.showinfo(self.t("conn_title"), self.t("c_ok", ver=ver), parent=win)
            except Exception as exc:  # noqa: BLE001
                messagebox.showerror(self.t("conn_title"), str(exc), parent=win)

        def do_save():
            apply()
            save_config(self.config_data)
            saved["ok"] = True
            win.destroy()

        btns = ttk.Frame(frm)
        btns.grid(row=len(fields), column=0, columnspan=2, pady=(12, 0), sticky="e")
        ttk.Button(btns, text=self.t("c_test"), command=do_test).pack(side="left", padx=4)
        ttk.Button(btns, text=self.t("c_save"), command=do_save).pack(side="left", padx=4)
        ttk.Button(btns, text=self.t("c_cancel"), command=win.destroy).pack(side="left", padx=4)
        win.wait_window()
        return saved["ok"]

    def _show_about(self):
        win = tk.Toplevel(self)
        win.title(self.t("mi_about"))
        win.transient(self)
        win.resizable(False, False)
        txt = tk.Text(win, width=62, height=16, wrap="word", padx=8, pady=8)
        txt.insert("1.0", self.t("about", version=APP_VERSION, count=local_count()))
        txt.config(state="disabled")
        txt.pack(padx=12, pady=12, fill="both", expand=True)
        win.grab_set()
        return win

    def _run_selftest_ui(self):
        ok, report = run_selftest()
        (messagebox.showinfo if ok else messagebox.showwarning)(
            self.t("selftest_title"), report)


# ─────────────────────── демо (скриншоты) ───────────────────────

def run_demo(outdir, lang="ru"):
    os.makedirs(outdir, exist_ok=True)
    # заполним историю образцами, чтобы демо было наглядным
    local_init()
    for bc, name, st in [
        ("0000080040460", "Ton in suc propriu 80g Rio Mare", "found"),
        ("5449000000996", "Coca-Cola 1L", "added"),
        ("0026102005156", "Bol Arcade 23cm", "found"),
        ("4770175046987", "Ciocolata Milka 90g", "dup")]:
        local_save(bc, name, "buc", 5000, st)

    args = argparse.Namespace(lang=lang)
    app = App(args)
    app.update()
    scr_w = scr_h = None
    try:
        import ctypes
        scr_w = ctypes.windll.user32.GetSystemMetrics(0)
        scr_h = ctypes.windll.user32.GetSystemMetrics(1)
    except Exception:  # noqa: BLE001
        pass
    app.minsize(200, 200)
    app.geometry(f"{min(760, (scr_w or 800)-24)}x{min(560, (scr_h or 600)-56)}")
    app.update()

    def shot(name, widget=None):
        target = widget or app
        app.update(); target.deiconify(); target.lift()
        for _ in range(10):
            app.update(); time.sleep(0.05)
        try:
            from company_search import capture_window_win32
            capture_window_win32(target, os.path.join(outdir, name))
            print("  ", name, "ok")
        except Exception as exc:  # noqa: BLE001
            print("  ", name, "skipped:", exc)

    app._refresh_history()
    app.bc_var.set("5449000000996")
    app._show_new("5449000000996")
    app.fields["name"][0].set("Coca-Cola 1L")
    app.update()
    shot("01_scan.png")

    about = app._show_about()
    shot("02_about.png", widget=about)
    about.destroy()
    app.destroy()
    print("saved to", outdir)
    return True


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Goods Catalog — barcode intake")
    ap.add_argument("--lang", default="ru", choices=LANGS)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--demo-dir", default="goods_demo")
    return ap.parse_args(argv)


if __name__ == "__main__":
    a = parse_args()
    if a.selftest:
        _ok, _rep = run_selftest()
        print(_rep)
        sys.exit(0 if _ok else 1)
    if a.demo:
        sys.exit(0 if run_demo(a.demo_dir, a.lang) else 1)
    App(a).mainloop()
