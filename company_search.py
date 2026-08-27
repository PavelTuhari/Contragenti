#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Contragenti — поиск и карточка персона юридика на date.gov.md.

GUI-утилита с локальным HTTP-API для интеграции (1С, браузер, нативные
приложения). Полное описание — в DOCUMENTATION_ru.md и API_ru.md.

Кратко:
  * Онлайн-поиск компаний (open/company-search) и карточка (open/company-details)
    через реальный браузер (Selenium + Chrome), т.к. страницы за невидимой reCAPTCHA.
  * Все результаты сохраняются в SQLite (companies.db), upsert по IDNO.
  * Master-detail интерфейс, офлайн-вкладка «Только БД», 3 языка (en/ru/ro).
  * Экспорт: вся БД → CSV/Excel; компания → структурированный Markdown
    (учредители и долги отдельными таблицами); массовый экспорт выбранных → .md.
  * Локальный веб-сервер (по умолчанию порт 9393) + иконка в трее:
    внешняя программа шлёт фильтр, по которому не нашла контрагента, — утилита
    открывается с этим поиском на нужном языке; после выбора возвращает XML
    полной карточки контрагента.

Запуск:  python company_search.py [--port 9393] [--lang ru] [--q "фильтр"]
                                  [--pick --out card.xml] [--no-server] [--no-tray]
"""

import os
import sys
import csv
import json
import queue
import sqlite3
import argparse
import threading
import datetime
from html.parser import HTMLParser
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import xml.etree.ElementTree as ET
import xml.sax.saxutils as saxutils

import tkinter as tk
from tkinter import ttk, messagebox, filedialog

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException

import openpyxl

APP_VERSION = "1.0"
SEARCH_URL = "https://date.gov.md/open/company-search"
DETAILS_URL = "https://date.gov.md/open/company-details"
DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "companies.db")
DEFAULT_PORT = 9393

COLUMNS = ("idno", "denumire", "administratori", "inregistrare")
EXPORT_COLUMNS = (
    "idno", "denumire", "administratori", "inregistrare",
    "forma_juridica", "lichidata", "adresa", "details_text",
    "founders_json", "debts_json", "updated_at",
)


# ────────────────────────────── i18n ──────────────────────────────

LANGS = ("en", "ru", "ro")
LANG_NAMES = {"en": "English", "ru": "Русский", "ro": "Română"}

TR = {
    "en": {
        "title": "Company search — date.gov.md",
        "search_label": "Search criterion:",
        "search_btn": "Search",
        "clear_btn": "×",
        "show_from_db": "Show from DB",
        "headless": "Headless browser",
        "tab_online": "Online search",
        "tab_offline": "DB only (offline)",
        "offline_find": "Find in DB",
        "col_idno": "IDNO/Fiscal code",
        "col_denumire": "Name",
        "col_administratori": "Administrators",
        "col_inregistrare": "Registration",
        "detail_title": "Company card",
        "f_denumire": "Name", "f_idno": "IDNO", "f_reg": "Registration date",
        "f_forma": "Legal form", "f_lichidata": "Liquidated",
        "f_adresa": "Legal address", "f_admin": "Administrators", "f_updated": "Updated",
        "founders": "Founders", "debts": "State budget arrears",
        "h_name": "Name", "h_share": "Share (%)",
        "h_nr": "No.", "h_type": "Budget type", "h_sum": "Sum (MDL)",
        "details_btn": "Get data by IDNO",
        "export_md": "Export MD",
        "xml_btn": "XML card",
        "return_btn": "↩ Return counterparty",
        "res_selected": "Selected counterparty",
        "res_full_xml": "Full XML",
        "menu_file": "File", "mi_hide": "Hide window", "mi_quit": "Quit",
        "menu_export": "Export", "menu_lang": "Language",
        "exp_csv_all": "All DB → CSV…", "exp_xlsx_all": "All DB → Excel…",
        "exp_selected_md": "Selected → MD (folder)…", "exp_current_md": "Current → MD…",
        "no_details": "No details in DB. Click “Get data by IDNO”.",
        "status_ready": "Ready. Enter a company name / person / IDNO.",
        "status_search": "Searching…",
        "status_online": "Online: {n} rows (saved to DB).",
        "status_from_db": "From DB for “{q}”: {n} (online received: {r}).",
        "status_db_all": "All DB records: {n}.",
        "status_db_query": "DB “{q}”: {n} records.",
        "status_details": "Details for IDNO {idno} received and saved.",
        "status_error": "Error.",
        "status_server": "API server: http://{host}:{port}  |  DB: {n}",
        "status_pick": "External request for “{q}”: pick a row, then press “Return counterparty”.",
        "status_returned": "Card XML returned to the caller (IDNO {idno}).",
        "status_exported_n": "Exported {n} file(s) to {path}",
        "msg_empty": "Enter a search criterion.",
        "msg_no_idno": "Select a row with IDNO or enter a 13-digit IDNO.",
        "msg_bad_idno": "“{v}” does not look like an IDNO (13 digits).",
        "msg_no_company": "No company selected.",
        "msg_no_selection": "Select one or more rows.",
        "exported": "Exported: {path}",
        "st_browser": "Starting browser…",
        "st_open_search": "Opening search page…",
        "st_open_details": "Opening company card…",
        "st_form": "Waiting for the form…",
        "st_submit": "Submitting request (captcha)…",
        "st_results": "Waiting for results… (solve captcha in the browser if asked)",
        "st_data": "Waiting for data… (solve captcha in the browser if asked)",
        "err_timeout": "Timed out. Captcha may be required, IDNO invalid, or nothing found.",
    },
    "ru": {
        "title": "Поиск компаний — date.gov.md",
        "search_label": "Критерий поиска:",
        "search_btn": "Поиск",
        "clear_btn": "×",
        "show_from_db": "Показывать из БД",
        "headless": "Скрытый браузер",
        "tab_online": "Онлайн-поиск",
        "tab_offline": "Только БД (офлайн)",
        "offline_find": "Найти в БД",
        "col_idno": "IDNO/Cod Fiscal",
        "col_denumire": "Denumire",
        "col_administratori": "Administratori",
        "col_inregistrare": "Înregistrare",
        "detail_title": "Карточка компании",
        "f_denumire": "Название", "f_idno": "IDNO", "f_reg": "Дата регистрации",
        "f_forma": "Форма", "f_lichidata": "Ликвидирована",
        "f_adresa": "Юр. адрес", "f_admin": "Руководители", "f_updated": "Обновлено",
        "founders": "Учредители", "debts": "Задолженность перед бюджетом",
        "h_name": "Имя", "h_share": "Доля (%)",
        "h_nr": "№", "h_type": "Тип бюджета", "h_sum": "Сумма (MDL)",
        "details_btn": "Данные по IDNO",
        "export_md": "Экспорт MD",
        "xml_btn": "XML карточки",
        "return_btn": "↩ Вернуть контрагента",
        "res_selected": "Выбранный контрагент",
        "res_full_xml": "Полный XML",
        "menu_file": "Файл", "mi_hide": "Скрыть окно", "mi_quit": "Выход",
        "menu_export": "Экспорт", "menu_lang": "Язык",
        "exp_csv_all": "Вся БД → CSV…", "exp_xlsx_all": "Вся БД → Excel…",
        "exp_selected_md": "Выбранные → MD (папка)…", "exp_current_md": "Текущую → MD…",
        "no_details": "В БД нет деталей. Нажмите «Данные по IDNO».",
        "status_ready": "Готово. Введите название компании / имя / IDNO.",
        "status_search": "Поиск…",
        "status_online": "Онлайн: {n} записей (сохранено в БД).",
        "status_from_db": "Из БД по «{q}»: {n} (получено онлайн: {r}).",
        "status_db_all": "Все записи БД: {n}.",
        "status_db_query": "БД «{q}»: {n} записей.",
        "status_details": "Детали IDNO {idno} получены и сохранены.",
        "status_error": "Ошибка.",
        "status_server": "API-сервер: http://{host}:{port}  |  БД: {n}",
        "status_pick": "Внешний запрос по «{q}»: выберите строку и нажмите «Вернуть контрагента».",
        "status_returned": "XML карточки возвращён вызвавшей программе (IDNO {idno}).",
        "status_exported_n": "Экспортировано файлов: {n} в {path}",
        "msg_empty": "Введите критерий поиска.",
        "msg_no_idno": "Выберите строку с IDNO или введите 13-значный IDNO.",
        "msg_bad_idno": "«{v}» не похож на IDNO (13 цифр).",
        "msg_no_company": "Компания не выбрана.",
        "msg_no_selection": "Выберите одну или несколько строк.",
        "exported": "Экспортировано: {path}",
        "st_browser": "Запуск браузера…",
        "st_open_search": "Открываю страницу поиска…",
        "st_open_details": "Открываю карточку компании…",
        "st_form": "Жду форму…",
        "st_submit": "Отправляю запрос (капча)…",
        "st_results": "Жду результаты… (при необходимости решите капчу в окне браузера)",
        "st_data": "Жду данные… (при необходимости решите капчу в окне браузера)",
        "err_timeout": "Истекло время ожидания. Возможно нужна капча, неверный IDNO или ничего не найдено.",
    },
    "ro": {
        "title": "Căutare companii — date.gov.md",
        "search_label": "Criteriu de căutare:",
        "search_btn": "Caută",
        "clear_btn": "×",
        "show_from_db": "Arată din BD",
        "headless": "Browser ascuns",
        "tab_online": "Căutare online",
        "tab_offline": "Doar BD (offline)",
        "offline_find": "Caută în BD",
        "col_idno": "IDNO/Cod Fiscal",
        "col_denumire": "Denumire",
        "col_administratori": "Administratori",
        "col_inregistrare": "Înregistrare",
        "detail_title": "Fișa companiei",
        "f_denumire": "Denumire", "f_idno": "IDNO", "f_reg": "Data înregistrării",
        "f_forma": "Forma juridică", "f_lichidata": "Lichidată",
        "f_adresa": "Adresa juridică", "f_admin": "Administratori", "f_updated": "Actualizat",
        "founders": "Fondatori", "debts": "Restanțe față de buget",
        "h_name": "Nume", "h_share": "Cota (%)",
        "h_nr": "Nr.", "h_type": "Tipul bugetului", "h_sum": "Suma (MDL)",
        "details_btn": "Date după IDNO",
        "export_md": "Export MD",
        "xml_btn": "XML fișă",
        "return_btn": "↩ Returnează contrapartida",
        "res_selected": "Contrapartidă selectată",
        "res_full_xml": "XML complet",
        "menu_file": "Fișier", "mi_hide": "Ascunde fereastra", "mi_quit": "Ieșire",
        "menu_export": "Export", "menu_lang": "Limbă",
        "exp_csv_all": "Toată BD → CSV…", "exp_xlsx_all": "Toată BD → Excel…",
        "exp_selected_md": "Selectate → MD (folder)…", "exp_current_md": "Curentă → MD…",
        "no_details": "BD nu are detalii. Apasă „Date după IDNO”.",
        "status_ready": "Gata. Introdu denumirea / persoana / IDNO.",
        "status_search": "Se caută…",
        "status_online": "Online: {n} rânduri (salvat în BD).",
        "status_from_db": "Din BD pentru „{q}”: {n} (online: {r}).",
        "status_db_all": "Toate înregistrările BD: {n}.",
        "status_db_query": "BD „{q}”: {n} înregistrări.",
        "status_details": "Detaliile IDNO {idno} primite și salvate.",
        "status_error": "Eroare.",
        "status_server": "Server API: http://{host}:{port}  |  BD: {n}",
        "status_pick": "Cerere externă pentru „{q}”: alege un rând și apasă „Returnează contrapartida”.",
        "status_returned": "XML-ul fișei a fost returnat aplicației (IDNO {idno}).",
        "status_exported_n": "Exportate fișiere: {n} în {path}",
        "msg_empty": "Introdu un criteriu de căutare.",
        "msg_no_idno": "Selectează un rând cu IDNO sau introdu un IDNO de 13 cifre.",
        "msg_bad_idno": "„{v}” nu pare un IDNO (13 cifre).",
        "msg_no_company": "Nicio companie selectată.",
        "msg_no_selection": "Selectează unul sau mai multe rânduri.",
        "exported": "Exportat: {path}",
        "st_browser": "Pornesc browserul…",
        "st_open_search": "Deschid pagina de căutare…",
        "st_open_details": "Deschid fișa companiei…",
        "st_form": "Aștept formularul…",
        "st_submit": "Trimit cererea (captcha)…",
        "st_results": "Aștept rezultatele… (rezolvă captcha în browser dacă apare)",
        "st_data": "Aștept datele… (rezolvă captcha în browser dacă apare)",
        "err_timeout": "Timp expirat. Poate e nevoie de captcha, IDNO invalid sau nimic găsit.",
    },
}


# ────────────────────────────── Парсеры HTML ──────────────────────────────


class ResultTableParser(HTMLParser):
    """Строки HTML-таблицы результатов поиска."""

    def __init__(self):
        super().__init__()
        self.in_body = self.in_row = self.in_cell = False
        self.rows = []
        self.current_row = None
        self.current_cell = ""

    def handle_starttag(self, tag, attrs):
        if tag == "tbody":
            self.in_body = True
        elif tag == "tr" and self.in_body:
            self.in_row = True
            self.current_row = []
        elif tag == "td" and self.in_row:
            self.in_cell = True
            self.current_cell = ""

    def handle_endtag(self, tag):
        if tag == "tbody":
            self.in_body = False
        elif tag == "tr" and self.in_row:
            self.in_row = False
            if self.current_row is not None:
                self.rows.append(self.current_row)
            self.current_row = None
        elif tag == "td" and self.in_cell:
            self.in_cell = False
            self.current_row.append(" ".join(self.current_cell.split()))

    def handle_data(self, data):
        if self.in_cell:
            self.current_cell += data


def parse_results(html):
    p = ResultTableParser()
    p.feed(html)
    out = []
    for row in p.rows:
        cells = list(row) + ["", "", "", ""]
        out.append({"idno": cells[0], "denumire": cells[1],
                    "administratori": cells[2], "inregistrare": cells[3]})
    return out


class DetailBasicParser(HTMLParser):
    """Простые «label: value» из фрагмента «Date de bază»."""

    def __init__(self):
        super().__init__()
        self.result = {}
        self.in_title = self.capturing = False
        self.cur_label = None
        self.cur_value = ""

    def _flush(self):
        if self.cur_label is not None and self.capturing:
            label = " ".join(self.cur_label.split()).rstrip(":").strip()
            value = " ".join(self.cur_value.split()).strip()
            if label and label not in self.result:
                self.result[label] = value
        self.capturing = False
        self.cur_label = None
        self.cur_value = ""

    def handle_starttag(self, tag, attrs):
        cls = dict(attrs).get("class") or ""
        if tag == "span" and "simple-title" in cls:
            self._flush()
            self.in_title = True
            self.cur_label = ""
        elif self.capturing and tag in ("ul", "table"):
            self._flush()

    def handle_endtag(self, tag):
        if tag == "span" and self.in_title:
            self.in_title = False
            self.capturing = True
            self.cur_value = ""
        elif tag == "li" and self.capturing:
            self._flush()

    def handle_data(self, data):
        if self.in_title:
            self.cur_label += data
        elif self.capturing:
            self.cur_value += data


def parse_detail_basic(html):
    p = DetailBasicParser()
    p.feed(html)
    return p.result


class TablesParser(HTMLParser):
    """Все таблицы страницы: [{'headers': [...], 'rows': [[...], ...]}]."""

    def __init__(self):
        super().__init__()
        self.tables = []
        self.cur = None
        self.in_thead = False
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self.cur = {"headers": [], "rows": []}
        elif self.cur is not None:
            if tag == "thead":
                self.in_thead = True
            elif tag == "tr":
                self.row = []
            elif tag in ("td", "th"):
                self.cell = ""

    def handle_endtag(self, tag):
        if self.cur is None:
            return
        if tag == "th" and self.cell is not None:
            self.cur["headers"].append(" ".join(self.cell.split()))
            self.cell = None
        elif tag == "td" and self.cell is not None:
            self.row.append(" ".join(self.cell.split()))
            self.cell = None
        elif tag == "tr":
            if self.row and not self.in_thead:
                self.cur["rows"].append(self.row)
            self.row = None
        elif tag == "thead":
            self.in_thead = False
        elif tag == "table":
            self.tables.append(self.cur)
            self.cur = None

    def handle_data(self, data):
        if self.cell is not None:
            self.cell += data


def parse_tables(html):
    p = TablesParser()
    p.feed(html)
    return p.tables


def classify_tables(tables):
    """Классифицирует таблицы карточки на учредителей и долги по заголовкам."""
    founders, debts = [], []
    for t in tables:
        hj = " ".join(t.get("headers", [])).lower()
        if "cota" in hj or "доля" in hj or "share" in hj:
            for r in t["rows"]:
                if r:
                    founders.append({"name": r[0], "share": r[-1] if len(r) > 1 else ""})
        elif "suma" in hj or "buget" in hj or "sum" in hj:
            for r in t["rows"]:
                if len(r) >= 3:
                    debts.append({"nr": r[0], "type": r[1], "sum": r[2]})
                elif r:
                    debts.append({"nr": "", "type": r[0], "sum": r[-1]})
    return founders, debts


# ────────────────────────────── Слой SQLite ──────────────────────────────


def db_connect():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def db_init():
    conn = db_connect()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS companies (
            key            TEXT PRIMARY KEY,
            idno           TEXT,
            denumire       TEXT,
            administratori TEXT,
            inregistrare   TEXT,
            forma_juridica TEXT,
            lichidata      TEXT,
            adresa         TEXT,
            details_text   TEXT,
            founders_json  TEXT,
            debts_json     TEXT,
            updated_at     TEXT
        )
        """
    )
    # миграция: добить недостающие колонки в старой БД
    have = {r[1] for r in conn.execute("PRAGMA table_info(companies)")}
    for col in ("founders_json", "debts_json"):
        if col not in have:
            conn.execute(f"ALTER TABLE companies ADD COLUMN {col} TEXT")
    conn.commit()
    conn.close()


def _now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def _make_key(idno, denumire):
    idno = (idno or "").strip()
    if idno:
        return idno
    denumire = (denumire or "").strip()
    return "name:" + denumire if denumire else None


def db_upsert(conn, fields):
    key = _make_key(fields.get("idno"), fields.get("denumire"))
    if not key:
        return
    data = {k: v for k, v in fields.items() if v not in (None, "")}
    data["key"] = key
    data["updated_at"] = _now()
    exists = conn.execute("SELECT 1 FROM companies WHERE key = ?", (key,)).fetchone()
    if exists:
        cols = [c for c in data if c != "key"]
        if cols:
            conn.execute(
                f"UPDATE companies SET {', '.join(c + ' = ?' for c in cols)} WHERE key = ?",
                [data[c] for c in cols] + [key])
    else:
        cols = list(data)
        conn.execute(
            f"INSERT INTO companies ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
            [data[c] for c in cols])


def db_save_search_rows(rows):
    conn = db_connect()
    try:
        for rec in rows:
            db_upsert(conn, {k: rec.get(k) for k in COLUMNS})
        conn.commit()
    finally:
        conn.close()


def db_save_details(data):
    basic = data.get("basic", {})
    conn = db_connect()
    try:
        db_upsert(conn, {
            "idno": data.get("idno") or basic.get("IDNO/Cod Fiscal"),
            "denumire": basic.get("Denumire"),
            "inregistrare": basic.get("Data înregistrării"),
            "forma_juridica": basic.get("Forma juridică"),
            "lichidata": basic.get("Lichidată"),
            "adresa": basic.get("Adresa juridică"),
            "details_text": data.get("text"),
            "founders_json": json.dumps(data.get("founders", []), ensure_ascii=False),
            "debts_json": json.dumps(data.get("debts", []), ensure_ascii=False),
        })
        conn.commit()
    finally:
        conn.close()


def db_query(text):
    text = (text or "").strip()
    conn = db_connect()
    try:
        if not text:
            cur = conn.execute("SELECT * FROM companies ORDER BY denumire")
        else:
            like = f"%{text}%"
            cur = conn.execute(
                "SELECT * FROM companies "
                "WHERE idno LIKE ? OR denumire LIKE ? OR administratori LIKE ? "
                "ORDER BY denumire", (like, like, like))
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def db_get(idno):
    conn = db_connect()
    try:
        r = conn.execute("SELECT * FROM companies WHERE idno = ?", (idno,)).fetchone()
        return dict(r) if r else None
    finally:
        conn.close()


def db_all():
    return db_query("")


def db_count():
    conn = db_connect()
    try:
        return conn.execute("SELECT COUNT(*) FROM companies").fetchone()[0]
    finally:
        conn.close()


# ────────────────────────────── Экспорт ──────────────────────────────


def _load_json(rec, key):
    try:
        return json.loads(rec.get(key) or "[]")
    except Exception:  # noqa: BLE001
        return []


def export_csv(path):
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(EXPORT_COLUMNS)
        for r in db_all():
            w.writerow([r.get(c, "") or "" for c in EXPORT_COLUMNS])


def export_xlsx(path):
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "companies"
    ws.append(list(EXPORT_COLUMNS))
    for r in db_all():
        ws.append([r.get(c, "") or "" for c in EXPORT_COLUMNS])
    wb.save(path)


def company_markdown(rec, lang="ru"):
    """Структурированный Markdown одной компании (учредители/долги — таблицами)."""
    tr = TR.get(lang, TR["ru"])
    founders = _load_json(rec, "founders_json")
    debts = _load_json(rec, "debts_json")
    name = rec.get("denumire") or rec.get("idno") or "company"
    lines = [
        f"# {name}", "",
        f"- **{tr['f_idno']}:** {rec.get('idno','') or ''}",
        f"- **{tr['f_reg']}:** {rec.get('inregistrare','') or ''}",
        f"- **{tr['f_forma']}:** {rec.get('forma_juridica','') or ''}",
        f"- **{tr['f_lichidata']}:** {rec.get('lichidata','') or ''}",
        f"- **{tr['f_adresa']}:** {rec.get('adresa','') or ''}",
        f"- **{tr['f_admin']}:** {rec.get('administratori','') or ''}",
        f"- **{tr['f_updated']}:** {rec.get('updated_at','') or ''}",
        "",
    ]
    if founders:
        lines += [f"## {tr['founders']}", "",
                  f"| {tr['h_name']} | {tr['h_share']} |", "| --- | ---: |"]
        for fdr in founders:
            lines.append(f"| {fdr.get('name','')} | {fdr.get('share','')} |")
        lines.append("")
    if debts:
        lines += [f"## {tr['debts']}", "",
                  f"| {tr['h_nr']} | {tr['h_type']} | {tr['h_sum']} |",
                  "| ---: | --- | ---: |"]
        for d in debts:
            lines.append(f"| {d.get('nr','')} | {d.get('type','')} | {d.get('sum','')} |")
        lines.append("")
    details = rec.get("details_text")
    if details:
        lines += ["## " + tr["detail_title"], "", "```", details, "```", ""]
    return "\n".join(lines)


def export_company_md(path, rec, lang="ru"):
    with open(path, "w", encoding="utf-8") as f:
        f.write(company_markdown(rec, lang))


def _safe_filename(rec):
    base = rec.get("idno") or rec.get("denumire") or "company"
    safe = "".join(ch for ch in base if ch.isalnum() or ch in "-_ ").strip()[:60]
    return safe or "company"


# ────────────────────────────── XML карточки ──────────────────────────────


def build_card_xml(rec):
    """XML полной карточки контрагента для внешних систем (1С и т.п.)."""
    root = ET.Element("counterparty", {
        "source": "date.gov.md",
        "idno": rec.get("idno", "") or "",
        "updated": rec.get("updated_at", "") or "",
    })
    for tag, key in (
        ("idno", "idno"), ("denumire", "denumire"), ("inregistrare", "inregistrare"),
        ("forma_juridica", "forma_juridica"), ("lichidata", "lichidata"),
        ("adresa", "adresa"), ("administratori", "administratori"),
    ):
        ET.SubElement(root, tag).text = rec.get(key, "") or ""
    founders_el = ET.SubElement(root, "founders")
    for fdr in _load_json(rec, "founders_json"):
        ET.SubElement(founders_el, "founder", {
            "name": fdr.get("name", ""), "share": fdr.get("share", "")})
    debts_el = ET.SubElement(root, "debts", {"currency": "MDL"})
    for d in _load_json(rec, "debts_json"):
        ET.SubElement(debts_el, "debt", {
            "nr": str(d.get("nr", "")), "type": d.get("type", ""),
            "sum": d.get("sum", "")})
    if rec.get("details_text"):
        ET.SubElement(root, "details_text").text = rec["details_text"]
    try:
        ET.indent(root, space="  ")
    except Exception:  # noqa: BLE001
        pass
    body = ET.tostring(root, encoding="unicode")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + body


def build_card_html(rec, xml, lang="ru"):
    """HTML-страница результата для браузера: основные поля + полный XML."""
    tr = TR.get(lang, TR["ru"])
    esc = saxutils.escape
    fields = [
        ("f_idno", "idno"), ("f_denumire", "denumire"), ("f_reg", "inregistrare"),
        ("f_forma", "forma_juridica"), ("f_lichidata", "lichidata"),
        ("f_adresa", "adresa"), ("f_admin", "administratori"),
    ]
    field_rows = "".join(
        "<tr><th>%s</th><td>%s</td></tr>" % (esc(tr[k]), esc(rec.get(fk, "") or ""))
        for k, fk in fields)
    parts = []
    founders = _load_json(rec, "founders_json")
    if founders:
        rows = "".join("<tr><td>%s</td><td class=r>%s</td></tr>" % (
            esc(f.get("name", "")), esc(f.get("share", ""))) for f in founders)
        parts.append("<h3>%s</h3><table><tr><th>%s</th><th>%s</th></tr>%s</table>" % (
            esc(tr["founders"]), esc(tr["h_name"]), esc(tr["h_share"]), rows))
    debts = _load_json(rec, "debts_json")
    if debts:
        rows = "".join("<tr><td class=r>%s</td><td>%s</td><td class=r>%s</td></tr>" % (
            esc(str(d.get("nr", ""))), esc(d.get("type", "")), esc(d.get("sum", "")))
            for d in debts)
        parts.append("<h3>%s</h3><table><tr><th>%s</th><th>%s</th><th>%s</th></tr>%s</table>" % (
            esc(tr["debts"]), esc(tr["h_nr"]), esc(tr["h_type"]), esc(tr["h_sum"]), rows))
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<title>%s</title><style>"
        "body{font-family:-apple-system,Segoe UI,Arial,sans-serif;margin:24px;color:#222}"
        "h2{margin:0 0 4px} .ok{color:#0a7d28;font-weight:600;margin-bottom:12px}"
        "table{border-collapse:collapse;margin:8px 0;max-width:900px;width:100%%}"
        "th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}"
        "th{background:#f2f4f7;white-space:nowrap} td.r,th.r{text-align:right}"
        "pre{background:#0f172a;color:#e2e8f0;padding:12px;border-radius:6px;"
        "overflow:auto;max-width:900px;white-space:pre-wrap}"
        "</style></head><body>"
        "<h2>%s</h2><div class=ok>IDNO: %s</div>"
        "<table>%s</table>%s"
        "<h3>%s</h3><pre>%s</pre>"
        "</body></html>"
    ) % (
        esc(tr["res_selected"]), esc(tr["res_selected"]),
        esc(rec.get("idno", "") or ""), field_rows, "".join(parts),
        esc(tr["res_full_xml"]), esc(xml),
    )


# ────────────────────────────── Браузер (Selenium) ──────────────────────────────


class BrowserWorker(threading.Thread):
    """Онлайн-запрос через Chrome в отдельном потоке."""

    def __init__(self, mode, value, out_queue, tr, headless=False):
        super().__init__(daemon=True)
        self.mode = mode
        self.value = value
        self.out = out_queue
        self.tr = tr
        self.headless = headless

    def _status(self, key):
        self.out.put(("status", self.tr.get(key, key)))

    def _make_driver(self):
        options = Options()
        if self.headless:
            options.add_argument("--headless=new")
        options.add_argument("--window-size=1200,900")
        options.add_experimental_option("excludeSwitches", ["enable-automation"])
        driver = webdriver.Chrome(options=options)
        driver.set_page_load_timeout(60)
        return driver

    def run(self):
        driver = None
        try:
            self._status("st_browser")
            driver = self._make_driver()
            if self.mode == "search":
                self._run_search(driver)
            else:
                self._run_details(driver)
        except TimeoutException:
            self.out.put(("error", self.tr.get("err_timeout", "Timeout")))
        except Exception as exc:  # noqa: BLE001
            self.out.put(("error", f"{type(exc).__name__}: {exc}"))
        finally:
            if driver is not None:
                try:
                    driver.quit()
                except Exception:  # noqa: BLE001
                    pass

    def _fill_and_submit(self, driver, field_name):
        wait = WebDriverWait(driver, 30)
        self._status("st_form")
        field = wait.until(EC.presence_of_element_located(
            (By.CSS_SELECTOR, f"#requestForm input[name='{field_name}']")))
        field.clear()
        field.send_keys(self.value)
        self._status("st_submit")
        wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, "#access-service"))).click()

    def _run_search(self, driver):
        self._status("st_open_search")
        driver.get(SEARCH_URL)
        self._fill_and_submit(driver, "q")
        self._status("st_results")
        result_wait = WebDriverWait(driver, 120)
        table = result_wait.until(EC.presence_of_element_located(
            (By.CSS_SELECTOR, "div[data-fragment-id] table, .table-responsive table")))
        try:
            WebDriverWait(driver, 10).until(
                lambda d: len(table.find_elements(By.CSS_SELECTOR, "tbody tr")) > 0)
        except TimeoutException:
            pass
        self.out.put(("search_done", parse_results(table.get_attribute("outerHTML"))))

    def _run_details(self, driver):
        self._status("st_open_details")
        driver.get(DETAILS_URL)
        self._fill_and_submit(driver, "idno")
        self._status("st_data")
        result_wait = WebDriverWait(driver, 120)
        accordion = result_wait.until(EC.presence_of_element_located(
            (By.CSS_SELECTOR, "#fragments-accordion")))
        result_wait.until(lambda d: len(
            accordion.find_elements(By.CSS_SELECTOR, ".accordion-item")) > 0)
        result_wait.until(lambda d:
            len(accordion.find_elements(By.CSS_SELECTOR, ".fragment-loading")) == 0
            and len(accordion.find_elements(
                By.CSS_SELECTOR, ".output-data .simple-title, .output-data table")) > 0)
        driver.execute_script(
            "document.querySelectorAll('#fragments-accordion .accordion-collapse')"
            ".forEach(function(e){e.classList.add('show'); e.style.height='auto';"
            "e.style.display='block';});")

        fragments, text_parts = [], []
        for item in accordion.find_elements(By.CSS_SELECTOR, ".accordion-item"):
            try:
                title = item.find_element(By.CSS_SELECTOR, ".accordion-button").text.strip()
            except Exception:  # noqa: BLE001
                title = ""
            try:
                body_el = item.find_element(By.CSS_SELECTOR, ".accordion-body")
                body = driver.execute_script(
                    "return arguments[0].innerText || arguments[0].textContent;", body_el)
                body = (body or "").strip()
            except Exception:  # noqa: BLE001
                body = ""
            fragments.append((title, body))
            text_parts.append(f"=== {title} ===\n{body}")

        html = accordion.get_attribute("outerHTML")
        basic = parse_detail_basic(html)
        founders, debts = classify_tables(parse_tables(html))
        self.out.put(("details_done", {
            "idno": self.value, "fragments": fragments, "basic": basic,
            "text": "\n\n".join(text_parts), "founders": founders, "debts": debts,
        }))


# ────────────────────────────── HTTP API ──────────────────────────────


class ApiHandler(BaseHTTPRequestHandler):
    app = None  # ссылка на App, устанавливается при старте сервера

    def log_message(self, *args):  # тихий лог
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, base, fields):
        """RU: 302 обратно в вызывающую систему с данными в query-строке.
        EN: 302 back to the calling system with the data in the query string."""
        from urllib.parse import urlencode, urlsplit, urlunsplit, parse_qsl
        parts = urlsplit(base)
        qs = dict(parse_qsl(parts.query, keep_blank_values=True))
        qs.update({k: v for k, v in fields.items() if v not in (None, "")})
        url = urlunsplit((parts.scheme, parts.netloc, parts.path,
                          urlencode(qs, doseq=False), parts.fragment))
        body = ("<!doctype html><meta charset=utf-8>"
                f"<meta http-equiv=refresh content='0;url={url}'>"
                f"<p>Se revine în sistemul apelant… <a href='{url}'>continuă</a></p>")
        data = body.encode("utf-8")
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        path = u.path.rstrip("/") or "/"
        q = (qs.get("q", [""])[0]).strip()
        idno = (qs.get("idno", [""])[0]).strip()
        lang = (qs.get("lang", ["ru"])[0]).strip()
        if lang not in LANGS:
            lang = "ru"
        fmt = (qs.get("format", ["xml"])[0]).strip().lower()

        if path == "/health":
            self._send(200, json.dumps(
                {"status": "ok", "version": APP_VERSION, "db_count": db_count()}))
        elif path == "/search":
            recs = db_query(q)
            if fmt == "json":
                self._send(200, json.dumps(recs, ensure_ascii=False))
            else:
                items = "".join(
                    "<item idno=%s>%s</item>" % (
                        saxutils.quoteattr(r.get("idno", "") or ""),
                        saxutils.escape(r.get("denumire", "") or ""))
                    for r in recs)
                self._send(200, '<?xml version="1.0" encoding="UTF-8"?>\n<results>'
                           + items + "</results>", "application/xml; charset=utf-8")
        elif path == "/card":
            rec = db_get(idno) if idno else None
            if not rec:
                self._send(404, json.dumps({"error": "not found", "idno": idno}))
            elif fmt == "json":
                self._send(200, json.dumps(rec, ensure_ascii=False))
            else:
                self._send(200, build_card_xml(rec), "application/xml; charset=utf-8")
        elif path == "/open":
            self.app.submit_open(q, lang)
            self._send(202, json.dumps({"status": "opened", "q": q, "lang": lang}))
        elif path == "/pick":
            try:
                timeout = float(qs.get("timeout", ["300"])[0])
            except ValueError:
                timeout = 300.0
            fmt_raw = qs.get("format", [None])[0]
            fmt_raw = fmt_raw.lower() if fmt_raw else None
            accept = self.headers.get("Accept", "")
            # RU: return_to — АДРЕС ВЫЗЫВАЮЩЕЙ СИСТЕМЫ. Если он задан, после
            #     выбора пользователя браузер УХОДИТ ОБРАТНО в эту систему с
            #     данными в query-строке, а не остаётся на странице утилиты.
            #     Демонстрационная карточка (format=html) — отдельный режим.
            # EN: with return_to the browser is redirected BACK to the calling
            #     system carrying the data; the HTML card stays a separate mode.
            return_to = (qs.get("return_to", [""])[0] or "").strip()
            if return_to and not return_to.lower().startswith(("http://", "https://")):
                return_to = ""
            state = (qs.get("state", [""])[0] or "")[:120]
            wants_html = (fmt_raw == "html"
                          or (fmt_raw is None and not return_to
                              and "text/html" in accept))
            holder = self.app.submit_pick(q, lang, timeout)
            if holder is None:
                if return_to:
                    self._redirect(return_to, {"status": "timeout", "state": state})
                else:
                    self._send(504, json.dumps({"error": "timeout"}))
            elif holder.get("cancelled"):
                if return_to:
                    self._redirect(return_to, {"status": "cancelled", "state": state})
                else:
                    self._send(204, "")
            else:
                xml = holder.get("xml", "")
                rec = holder.get("rec", {})
                if return_to:
                    fields = {"status": "ok", "state": state,
                              "idno": rec.get("idno", ""),
                              "denumire": rec.get("denumire", "") or rec.get("name", ""),
                              "adresa": rec.get("adresa", ""),
                              "inregistrare": rec.get("inregistrare", ""),
                              "forma_juridica": rec.get("forma_juridica", ""),
                              "lichidata": rec.get("lichidata", ""),
                              "administratori": rec.get("administratori", "")}
                    self._redirect(return_to, fields)
                elif wants_html:
                    self._send(200, build_card_html(rec, xml, lang),
                               "text/html; charset=utf-8")
                else:
                    self._send(200, xml, "application/xml; charset=utf-8")
        elif path == "/":
            self._send(200, self._help_html(), "text/html; charset=utf-8")
        else:
            self._send(404, json.dumps({"error": "unknown endpoint"}))

    def _help_html(self):
        host = self.headers.get("Host", "127.0.0.1:%d" % DEFAULT_PORT)
        return (
            "<!doctype html><meta charset=utf-8><title>Contragenti API</title>"
            "<h2>Contragenti — локальный API</h2><ul>"
            f"<li><code>GET /health</code></li>"
            f"<li><code>GET /search?q=ТЕКСТ&amp;format=json|xml</code> — поиск в БД</li>"
            f"<li><code>GET /card?idno=IDNO&amp;format=xml|json</code> — карточка из БД</li>"
            f"<li><code>GET /open?q=ТЕКСТ&amp;lang=ru|ro|en</code> — открыть окно с поиском</li>"
            f"<li><code>GET /pick?q=ТЕКСТ&amp;lang=ru&amp;timeout=300</code> — выбрать "
            f"контрагента, вернуть XML карточки</li></ul>"
            f"<p>Пример: <a href='/pick?q=UNISIM&amp;lang=ru'>/pick?q=UNISIM&amp;lang=ru</a></p>")


# ────────────────────────────── GUI ──────────────────────────────


class App(tk.Tk):
    def __init__(self, args=None):
        super().__init__()
        self.args = args or argparse.Namespace(
            port=DEFAULT_PORT, host="127.0.0.1", lang="ru", q=None,
            pick=False, out=None, no_server=False, no_tray=False)
        self.lang = self.args.lang if self.args.lang in LANGS else "ru"
        db_init()
        self.queue = queue.Queue()
        self.worker = None
        self.last_query = ""
        self.current_idno = ""
        self.current_rec = None
        self.pending_pick = None      # {'event','holder'} для HTTP /pick
        self.pick_after_details = None
        self.httpd = None
        self.tray_icon = None

        self.geometry("1120x780")
        self.minsize(860, 580)
        self._build_menu()
        self._build_ui()
        self.retranslate()
        self._show_all_db()
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(120, self._poll_queue)

        if not self.args.no_server:
            self._start_server()
        if not self.args.no_tray:
            self._start_tray()
        # стартовый запрос из командной строки
        if self.args.q:
            if self.args.pick:
                self._begin_pick({"q": self.args.q, "lang": self.lang,
                                  "event": None, "holder": {}, "oneshot": True})
            else:
                self._begin_open({"q": self.args.q, "lang": self.lang})

    def t(self, key, **kw):
        s = TR[self.lang].get(key, key)
        return s.format(**kw) if kw else s

    # ── меню ──

    def _build_menu(self):
        self.menubar = tk.Menu(self)
        self.file_menu = tk.Menu(self.menubar, tearoff=0)
        self.file_menu.add_command(label="", command=self._hide_window)
        self.file_menu.add_command(label="", command=self.do_quit)
        self.menubar.add_cascade(menu=self.file_menu, label="")
        self.export_menu = tk.Menu(self.menubar, tearoff=0)
        self.export_menu.add_command(label="", command=self.export_csv_all)
        self.export_menu.add_command(label="", command=self.export_xlsx_all)
        self.export_menu.add_separator()
        self.export_menu.add_command(label="", command=self.export_selected_md)
        self.export_menu.add_command(label="", command=self.export_md_current)
        self.menubar.add_cascade(menu=self.export_menu, label="")
        self.lang_menu = tk.Menu(self.menubar, tearoff=0)
        for code in LANGS:
            self.lang_menu.add_command(label=LANG_NAMES[code],
                                       command=lambda c=code: self.set_lang(c))
        self.menubar.add_cascade(menu=self.lang_menu, label="")
        self.config(menu=self.menubar)

    # ── интерфейс ──

    def _build_ui(self):
        paned = ttk.Panedwindow(self, orient="vertical")
        paned.pack(fill="both", expand=True)

        self.notebook = ttk.Notebook(paned)
        paned.add(self.notebook, weight=3)
        self.tab_online = ttk.Frame(self.notebook)
        self.tab_offline = ttk.Frame(self.notebook)
        self.notebook.add(self.tab_online)
        self.notebook.add(self.tab_offline)
        self.tree_online = self._build_search_tab(self.tab_online, online=True)
        self.tree_offline = self._build_search_tab(self.tab_offline, online=False)

        self.detail = ttk.Labelframe(paned, padding=8)
        paned.add(self.detail, weight=2)
        self._build_detail(self.detail)

        self.status = tk.StringVar()
        ttk.Label(self, textvariable=self.status, relief="sunken", anchor="w",
                  padding=(6, 3)).pack(fill="x", side="bottom")

    def _build_search_tab(self, parent, online):
        bar = ttk.Frame(parent, padding=(8, 8, 8, 4))
        bar.pack(fill="x")
        lbl = ttk.Label(bar)
        lbl.grid(row=0, column=0, sticky="w")
        entry = ttk.Entry(bar, width=36)
        entry.grid(row=0, column=1, sticky="ew", padx=(8, 0))
        clr = ttk.Button(bar, width=3, command=lambda: self._on_clear(online))
        clr.grid(row=0, column=2, padx=(2, 6))
        btn = ttk.Button(bar, command=(self.on_search if online else self.on_db_find))
        btn.grid(row=0, column=3, padx=(0, 6))
        bar.columnconfigure(1, weight=1)

        if online:
            entry.bind("<Return>", lambda e: self.on_search())
            self.online_entry, self.online_label = entry, lbl
            self.online_clear_btn, self.online_search_btn = clr, btn
            self.show_from_db_var = tk.BooleanVar(value=True)
            self.headless_var = tk.BooleanVar(value=False)
            self.chk_db = ttk.Checkbutton(bar, variable=self.show_from_db_var)
            self.chk_db.grid(row=0, column=4, padx=6)
            self.chk_headless = ttk.Checkbutton(bar, variable=self.headless_var)
            self.chk_headless.grid(row=0, column=5, padx=6)
        else:
            entry.bind("<Return>", lambda e: self.on_db_find())
            self.offline_entry, self.offline_label = entry, lbl
            self.offline_clear_btn, self.offline_find_btn = clr, btn

        tf = ttk.Frame(parent, padding=(8, 0, 8, 8))
        tf.pack(fill="both", expand=True)
        tree = ttk.Treeview(tf, columns=COLUMNS, show="headings", selectmode="extended")
        widths = {"idno": 150, "denumire": 430, "administratori": 280, "inregistrare": 100}
        for col in COLUMNS:
            tree.column(col, width=widths[col], anchor="w")
        vsb = ttk.Scrollbar(tf, orient="vertical", command=tree.yview)
        hsb = ttk.Scrollbar(tf, orient="horizontal", command=tree.xview)
        tree.configure(yscrollcommand=vsb.set, xscrollcommand=hsb.set)
        tree.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")
        hsb.grid(row=1, column=0, sticky="ew")
        tf.rowconfigure(0, weight=1)
        tf.columnconfigure(0, weight=1)
        tree.bind("<<TreeviewSelect>>", lambda e, tv=tree: self._on_row_select(tv))
        tree._idno_map = {}
        return tree

    def _build_detail(self, parent):
        actions = ttk.Frame(parent)
        actions.pack(fill="x")
        self.detail_idno_var = tk.StringVar()
        ttk.Entry(actions, width=16, textvariable=self.detail_idno_var).pack(side="left")
        self.details_btn = ttk.Button(actions, command=self.on_details)
        self.details_btn.pack(side="left", padx=6)
        self.export_md_btn = ttk.Button(actions, command=self.export_md_current)
        self.export_md_btn.pack(side="left")
        self.xml_btn = ttk.Button(actions, command=self.on_xml)
        self.xml_btn.pack(side="left", padx=6)
        # заметная кнопка возврата контрагента — видна только при внешнем /pick
        self.return_btn = ttk.Button(actions, command=self.on_return_pick)
        self.return_actions = actions  # куда паковать при показе

        grid = ttk.Frame(parent, padding=(0, 8, 0, 6))
        grid.pack(fill="x")
        self.field_vars = {}
        self.field_labels = {}
        dl = ttk.Label(grid, font=("", 9, "bold"))
        dl.grid(row=0, column=0, sticky="w")
        self.field_labels["f_denumire"] = dl
        self.field_vars["denumire"] = tk.StringVar()
        ttk.Label(grid, textvariable=self.field_vars["denumire"], font=("", 10, "bold"),
                  wraplength=1040).grid(row=0, column=1, columnspan=5, sticky="w")
        pairs = [
            ("f_idno", "idno"), ("f_reg", "inregistrare"), ("f_forma", "forma_juridica"),
            ("f_lichidata", "lichidata"), ("f_adresa", "adresa"), ("f_admin", "administratori"),
        ]
        for i, (lkey, fkey) in enumerate(pairs):
            r, c = 1 + i // 3, (i % 3) * 2
            lab = ttk.Label(grid, foreground="#555")
            lab.grid(row=r, column=c, sticky="nw", padx=(0, 4), pady=2)
            self.field_labels[lkey] = lab
            var = tk.StringVar()
            self.field_vars[fkey] = var
            ttk.Label(grid, textvariable=var, wraplength=300).grid(
                row=r, column=c + 1, sticky="nw", padx=(0, 14), pady=2)
        for c in (1, 3, 5):
            grid.columnconfigure(c, weight=1)

        tf = ttk.Frame(parent)
        tf.pack(fill="both", expand=True)
        self.detail_text = tk.Text(tf, wrap="word", height=8)
        dvsb = ttk.Scrollbar(tf, orient="vertical", command=self.detail_text.yview)
        self.detail_text.configure(yscrollcommand=dvsb.set, state="disabled")
        self.detail_text.pack(side="left", fill="both", expand=True)
        dvsb.pack(side="right", fill="y")

    # ── перевод интерфейса ──

    def retranslate(self):
        self._refresh_title()
        self.menubar.entryconfig(1, label=self.t("menu_file"))
        self.menubar.entryconfig(2, label=self.t("menu_export"))
        self.menubar.entryconfig(3, label=self.t("menu_lang"))
        self.file_menu.entryconfig(0, label=self.t("mi_hide"))
        self.file_menu.entryconfig(1, label=self.t("mi_quit"))
        self.export_menu.entryconfig(0, label=self.t("exp_csv_all"))
        self.export_menu.entryconfig(1, label=self.t("exp_xlsx_all"))
        self.export_menu.entryconfig(3, label=self.t("exp_selected_md"))
        self.export_menu.entryconfig(4, label=self.t("exp_current_md"))
        self.notebook.tab(0, text=self.t("tab_online"))
        self.notebook.tab(1, text=self.t("tab_offline"))
        self.online_label.config(text=self.t("search_label"))
        self.offline_label.config(text=self.t("search_label"))
        self.online_search_btn.config(text=self.t("search_btn"))
        self.offline_find_btn.config(text=self.t("offline_find"))
        for b in (self.online_clear_btn, self.offline_clear_btn):
            b.config(text=self.t("clear_btn"))
        self.chk_db.config(text=self.t("show_from_db"))
        self.chk_headless.config(text=self.t("headless"))
        self.detail.config(text=self.t("detail_title"))
        self.details_btn.config(text=self.t("details_btn"))
        self.export_md_btn.config(text=self.t("export_md"))
        self.xml_btn.config(text=self.t("xml_btn"))
        self.return_btn.config(text=self.t("return_btn"))
        for lkey, widget in self.field_labels.items():
            widget.config(text=self.t(lkey) + ":")
        for tree in (self.tree_online, self.tree_offline):
            for col in COLUMNS:
                tree.heading(col, text=self.t("col_" + col))
        if not self.status.get():
            self.status.set(self.t("status_ready"))

    def set_lang(self, code):
        self.lang = code
        self.retranslate()

    # ── общие действия ──

    def _busy(self, busy):
        state = "disabled" if busy else "normal"
        self.online_search_btn.config(state=state)
        self.details_btn.config(state=state)

    def _worker_active(self):
        return self.worker is not None and self.worker.is_alive()

    def _on_clear(self, online):
        (self.online_entry if online else self.offline_entry).delete(0, "end")
        self._show_all_db()

    def on_search(self):
        query = self.online_entry.get().strip()
        if not query:
            self._show_all_db()
            return
        if self._worker_active():
            return
        self.last_query = query
        self._busy(True)
        self.status.set(self.t("status_search"))
        self.worker = BrowserWorker("search", query, self.queue, TR[self.lang],
                                    headless=self.headless_var.get())
        self.worker.start()

    def on_db_find(self):
        query = self.offline_entry.get().strip()
        records = db_query(query)
        self._populate(self.tree_offline, records)
        self.status.set(self.t("status_db_query", q=query, n=len(records)) if query
                        else self.t("status_db_all", n=len(records)))

    def on_details(self):
        idno = (self.detail_idno_var.get() or self.current_idno).strip()
        if not idno:
            messagebox.showinfo(self.t("detail_title"), self.t("msg_no_idno"))
            return
        if not (idno.isdigit() and len(idno) == 13):
            messagebox.showwarning(self.t("detail_title"), self.t("msg_bad_idno", v=idno))
            return
        if self._worker_active():
            return
        self._busy(True)
        self.worker = BrowserWorker("details", idno, self.queue, TR[self.lang],
                                    headless=self.headless_var.get())
        self.worker.start()

    def on_xml(self):
        """Кнопка XML: при активном /pick или one-shot возвращает карточку
        вызвавшей программе, иначе копирует XML текущей карточки в буфер обмена."""
        idno = (self.detail_idno_var.get() or self.current_idno).strip()
        if not idno and not self.current_rec:
            messagebox.showinfo(self.t("detail_title"), self.t("msg_no_company"))
            return
        if self.pending_pick or getattr(self, "_oneshot", False):
            self.resolve_pick(idno)
        else:
            rec = db_get(idno) or self.current_rec or {}
            self.clipboard_clear()
            self.clipboard_append(build_card_xml(rec))
            self.status.set(f"XML → clipboard (IDNO {idno}).")

    def on_return_pick(self):
        """Кнопка «Вернуть контрагента»: возвращает выбранную карточку туда,
        откуда пришёл внешний запрос (/pick или one-shot)."""
        idno = (self.detail_idno_var.get() or self.current_idno).strip()
        if not idno and not self.current_rec:
            messagebox.showinfo(self.t("detail_title"), self.t("msg_no_company"))
            return
        self.resolve_pick(idno)

    def _show_return_button(self, show):
        if show:
            self.return_btn.pack(side="left", padx=6)
        else:
            self.return_btn.pack_forget()

    # ── события потока ──

    def _poll_queue(self):
        try:
            while True:
                kind, payload = self.queue.get_nowait()
                if kind == "status":
                    self.status.set(payload)
                elif kind == "search_done":
                    self._on_search_done(payload)
                elif kind == "details_done":
                    self._on_details_done(payload)
                elif kind == "error":
                    self._busy(False)
                    self.status.set(self.t("status_error"))
                    messagebox.showerror(self.t("status_error"), payload)
                elif kind == "pick":
                    self._begin_pick(payload)
                elif kind == "open":
                    self._begin_open(payload)
                elif kind == "ui":
                    if payload == "raise":
                        self._raise_window()
                    elif payload == "quit":
                        self.do_quit()
        except queue.Empty:
            pass
        if getattr(self, "_alive", True):
            self.after(120, self._poll_queue)

    def _on_search_done(self, rows):
        self._busy(False)
        db_save_search_rows(rows)
        self._refresh_title()
        if self.show_from_db_var.get():
            records = db_query(self.last_query)
            self._populate(self.tree_online, records)
            self.status.set(self.t("status_from_db", q=self.last_query,
                                    n=len(records), r=len(rows)))
        else:
            self._populate(self.tree_online, rows)
            self.status.set(self.t("status_online", n=len(rows)))

    def _on_details_done(self, data):
        self._busy(False)
        db_save_details(data)
        self._refresh_title()
        idno = data.get("idno") or data.get("basic", {}).get("IDNO/Cod Fiscal", "")
        rec = db_get(idno) or {}
        self._show_detail(rec)
        self.status.set(self.t("status_details", idno=idno))
        if self.pick_after_details == idno:
            self.pick_after_details = None
            self._finish_pick(idno)

    # ── таблица / карточка ──

    def _populate(self, tree, records):
        for iid in tree.get_children():
            tree.delete(iid)
        tree._idno_map.clear()
        for rec in records:
            values = (rec.get("idno", "") or "", rec.get("denumire", "") or "",
                      rec.get("administratori", "") or "", rec.get("inregistrare", "") or "")
            iid = tree.insert("", "end", values=values)
            if rec.get("idno"):
                tree._idno_map[iid] = rec["idno"]

    def _show_all_db(self):
        records = db_all()
        self._populate(self.tree_online, records)
        self._populate(self.tree_offline, records)
        self.status.set(self.t("status_db_all", n=len(records)))

    def _on_row_select(self, tree):
        iid = tree.focus()
        if not iid:
            sel = tree.selection()
            if not sel:
                return
            iid = sel[0]
        vals = tree.item(iid, "values")
        idno = tree._idno_map.get(iid, "")
        rec = db_get(idno) if idno else None
        if not rec:
            rec = {"idno": vals[0], "denumire": vals[1],
                   "administratori": vals[2], "inregistrare": vals[3]}
        self._show_detail(rec)

    def _show_detail(self, rec):
        self.current_rec = rec
        self.current_idno = rec.get("idno", "") or ""
        self.detail_idno_var.set(self.current_idno)
        for fkey, var in self.field_vars.items():
            var.set(rec.get(fkey, "") or "")
        self.detail_text.config(state="normal")
        self.detail_text.delete("1.0", "end")
        details = rec.get("details_text")
        self.detail_text.insert("1.0", details if details else self.t("no_details"))
        self.detail_text.config(state="disabled")

    def _active_tree(self):
        return self.tree_online if self.notebook.index("current") == 0 else self.tree_offline

    # ── /pick, /open ──

    def submit_open(self, q, lang):
        self.queue.put(("open", {"q": q, "lang": lang}))

    def submit_pick(self, q, lang, timeout):
        ev = threading.Event()
        holder = {}
        self.queue.put(("pick", {"q": q, "lang": lang, "event": ev, "holder": holder}))
        if ev.wait(timeout):
            return holder          # {'xml','rec'} или {'cancelled':True}
        return None                # таймаут

    def _raise_window(self):
        try:
            self.deiconify()
            self.lift()
            self.attributes("-topmost", True)
            self.after(400, lambda: self.attributes("-topmost", False))
            self.focus_force()
        except Exception:  # noqa: BLE001
            pass

    def _begin_open(self, payload):
        if payload.get("lang") in LANGS:
            self.set_lang(payload["lang"])
        self._raise_window()
        q = payload.get("q", "") or ""
        self.online_entry.delete(0, "end")
        self.online_entry.insert(0, q)
        self.notebook.select(0)
        if q:
            self.on_search()

    def _begin_pick(self, payload):
        self._oneshot = payload.get("oneshot", False)
        if payload.get("event") is not None:
            self.pending_pick = {"event": payload["event"], "holder": payload["holder"]}
        self._begin_open(payload)
        self._show_return_button(True)
        self.status.set(self.t("status_pick", q=payload.get("q", "")))

    def resolve_pick(self, idno):
        """Готовит карточку для возврата: при отсутствии деталей — дозагружает,
        затем завершает /pick или one-shot."""
        rec = db_get(idno)
        if rec and rec.get("details_text"):
            self._finish_pick(idno)
        elif idno.isdigit() and len(idno) == 13 and not self._worker_active():
            self.pick_after_details = idno
            self._busy(True)
            self.worker = BrowserWorker("details", idno, self.queue, TR[self.lang],
                                        headless=self.headless_var.get())
            self.worker.start()
        else:
            self._finish_pick(idno)

    def _finish_pick(self, idno):
        rec = db_get(idno) or self.current_rec or {"idno": idno}
        xml = build_card_xml(rec)
        if self.pending_pick:
            self.pending_pick["holder"]["xml"] = xml
            self.pending_pick["holder"]["rec"] = rec
            self.pending_pick["event"].set()
            self.pending_pick = None
        self._show_return_button(False)
        self.status.set(self.t("status_returned", idno=idno))
        if getattr(self, "_oneshot", False):
            out = getattr(self.args, "out", None)
            if out:
                with open(out, "w", encoding="utf-8") as f:
                    f.write(xml)
            else:
                sys.stdout.write(xml + "\n")
                sys.stdout.flush()
            self._oneshot = False
            self.after(300, self.do_quit)

    # ── экспорт ──

    def _ask_save(self, ext, ftypes, initial):
        return filedialog.asksaveasfilename(defaultextension=ext, filetypes=ftypes,
                                            initialfile=initial)

    def export_csv_all(self):
        path = self._ask_save(".csv", [("CSV", "*.csv")], "companies.csv")
        if path:
            export_csv(path)
            self.status.set(self.t("exported", path=path))

    def export_xlsx_all(self):
        path = self._ask_save(".xlsx", [("Excel", "*.xlsx")], "companies.xlsx")
        if path:
            export_xlsx(path)
            self.status.set(self.t("exported", path=path))

    def export_md_current(self):
        if not self.current_rec:
            messagebox.showinfo(self.t("detail_title"), self.t("msg_no_company"))
            return
        rec = db_get(self.current_idno) or self.current_rec
        path = self._ask_save(".md", [("Markdown", "*.md")], _safe_filename(rec) + ".md")
        if path:
            export_company_md(path, rec, self.lang)
            self.status.set(self.t("exported", path=path))

    def export_selected_md(self):
        tree = self._active_tree()
        sel = tree.selection()
        if not sel:
            messagebox.showinfo(self.t("menu_export"), self.t("msg_no_selection"))
            return
        folder = filedialog.askdirectory()
        if not folder:
            return
        n = 0
        for iid in sel:
            idno = tree._idno_map.get(iid, "")
            rec = db_get(idno) if idno else None
            if not rec:
                vals = tree.item(iid, "values")
                rec = {"idno": vals[0], "denumire": vals[1],
                       "administratori": vals[2], "inregistrare": vals[3]}
            fname = _safe_filename(rec) + ".md"
            export_company_md(os.path.join(folder, fname), rec, self.lang)
            n += 1
        self.status.set(self.t("status_exported_n", n=n, path=folder))

    # ── сервер / трей / жизненный цикл ──

    def _start_server(self):
        try:
            ApiHandler.app = self
            self.httpd = ThreadingHTTPServer((self.args.host, self.args.port), ApiHandler)
            threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
            self.status.set(self.t("status_server", host=self.args.host,
                                    port=self.args.port, n=db_count()))
        except Exception as exc:  # noqa: BLE001
            self.status.set(f"HTTP server error: {exc}")

    def _start_tray(self):
        try:
            import pystray
            from PIL import Image, ImageDraw
        except Exception:  # noqa: BLE001
            return
        try:
            img = Image.new("RGB", (64, 64), (20, 80, 150))
            d = ImageDraw.Draw(img)
            d.rectangle([16, 16, 48, 48], fill=(255, 255, 255))
            # ВАЖНО: колбэки трея выполняются в другом потоке — нельзя трогать Tk
            # напрямую (self.after/виджеты). Кладём команду в потокобезопасную
            # очередь, её выполнит Tk-поток в _poll_queue.
            menu = pystray.Menu(
                pystray.MenuItem("Open / Открыть", lambda i, it: self.queue.put(("ui", "raise"))),
                pystray.MenuItem("Quit / Выход", lambda i, it: self.queue.put(("ui", "quit"))),
            )
            self.tray_icon = pystray.Icon("contragenti", img, "Contragenti", menu)
            self.tray_icon.run_detached()
        except Exception:  # noqa: BLE001
            self.tray_icon = None  # трей недоступен (например, macOS без main-thread)

    def _hide_window(self):
        self.withdraw()

    def _on_close(self):
        # если работает сервер/трей — прячем окно, иначе выходим
        if self.httpd is not None:
            self._hide_window()
        else:
            self.do_quit()

    def do_quit(self):
        self._alive = False
        if self.pending_pick:
            self.pending_pick["holder"]["cancelled"] = True
            self.pending_pick["event"].set()
            self.pending_pick = None
        self._show_return_button(False)
        try:
            if self.httpd:
                self.httpd.shutdown()
        except Exception:  # noqa: BLE001
            pass
        try:
            if self.tray_icon:
                self.tray_icon.stop()
        except Exception:  # noqa: BLE001
            pass
        self.destroy()

    def _refresh_title(self):
        self.title(self.t("title") + f"   ({self.t('f_updated')}: {db_count()})")


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Contragenti — date.gov.md company search")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="HTTP API port")
    ap.add_argument("--host", default="127.0.0.1", help="HTTP API host")
    ap.add_argument("--lang", default="ru", choices=LANGS, help="UI language")
    ap.add_argument("--q", default=None, help="initial search filter")
    ap.add_argument("--pick", action="store_true",
                    help="one-shot: wait for selection, output XML to --out/stdout, quit")
    ap.add_argument("--out", default=None, help="file to write returned XML (with --pick)")
    ap.add_argument("--no-server", action="store_true", help="do not start HTTP API")
    ap.add_argument("--no-tray", action="store_true", help="do not create tray icon")
    return ap.parse_args(argv)


if __name__ == "__main__":
    App(parse_args()).mainloop()
