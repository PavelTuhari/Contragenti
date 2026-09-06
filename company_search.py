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
import time
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

APP_VERSION = "1.3.5"
SEARCH_URL = "https://date.gov.md/open/company-search"
DETAILS_URL = "https://date.gov.md/open/company-details"
# Второй источник: data2b.md — публичный поиск сайта (тот же запрос, который
# делает сама страница). Без ключа, без регистрации и без reCAPTCHA, поэтому
# работает обычным HTTP-запросом и идёт параллельно порталу date.gov.md.
DATA2B_URL = "https://data2b.md/api/companies/"
DATA2B_SITE = "https://data2b.md"
SOURCE_GOV = "date.gov.md"
SOURCE_D2B = "data2b.md"
def _app_dir():
    """Каталог рядом с исполняемым файлом — и для скрипта, и для frozen exe
    (cx_Freeze/PyInstaller кладут __file__ внутрь library.zip, а не рядом с exe)."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def _dir_writable(path):
    probe = os.path.join(path, "~w%d.tmp" % os.getpid())
    try:
        with open(probe, "w") as f:
            f.write("")
        os.remove(probe)
        return True
    except OSError:
        return False


def _data_dir():
    """Каталог данных (companies.db, tms_config.json): рядом с программой, если
    туда можно писать — исходники, портативная копия, установка в профиль;
    иначе (установка в Program Files) — %LOCALAPPDATA%\\Contragenti. При
    первом запуске туда копируется companies.db из установки — стартовая
    база компаний, чтобы утилита сразу была с данными."""
    app = _app_dir()
    # под администратором Program Files доступен на запись, но данные всё равно
    # держим в профиле — иначе у разных пользователей были бы разные базы
    in_pf = any(os.environ.get(e) and os.path.normcase(os.path.abspath(app)).startswith(
        os.path.normcase(os.path.abspath(os.environ[e])) + os.sep)
        for e in ("ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"))
    if _dir_writable(app) and not in_pf:
        return app
    data = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "Contragenti")
    os.makedirs(data, exist_ok=True)
    seed = os.path.join(app, "companies.db")
    if os.path.exists(seed) and not os.path.exists(os.path.join(data, "companies.db")):
        import shutil
        try:
            shutil.copy2(seed, os.path.join(data, "companies.db"))
        except OSError:
            pass
    return data


DATA_DIR = _data_dir()
DB_PATH = os.path.join(DATA_DIR, "companies.db")
DEFAULT_PORT = 9393

COLUMNS = ("idno", "denumire", "administratori", "inregistrare")

# символы галочки выбора в колонке #0 (отправка в una.md)
CHECK_ON = "☑"   # ☑
CHECK_OFF = "☐"  # ☐

# ── бренд экосистемы una.md ──
# Contragenti распространяется как бесплатный инструмент платформы una.md,
# поэтому окно программы несёт её витрину: баннер, окно «Об ERP una.md».
UNA_URL = "https://una.md"
UNA_ACCENT = "#0b6e5f"
UNA_BANNER_BG = "#e3efec"
EXPORT_COLUMNS = (
    "idno", "denumire", "administratori", "inregistrare",
    "forma_juridica", "lichidata", "adresa", "details_text",
    "founders_json", "debts_json", "source", "updated_at",
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
        "d2b_chk": "also data2b.md",
        "src_lbl": "Sources:",
        "src_gov": "date.gov.md",
        "src_d2b": "data2b.md",
        "src_db": "own DB",
        "status_no_data": "{src}: no data for this query.",
        "status_details_none": "Portal has no card for IDNO {idno} (shown from DB).",
        "status_sources_off": "All online sources are off — showing the local DB.",
        "mi_restart": "Restart",
        "status_restart": "Restarting…",
        "st_d2b": "Searching data2b.md…",
        "status_d2b": "data2b.md: {n} of {total} for “{q}”.",
        "status_d2b_none": "data2b.md: nothing found for “{q}”.",
        "d2b_error": "data2b.md unavailable: {err}",
        "f_source": "Source",
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
        "menu_help": "Help", "mi_about": "About / Overview", "mi_selftest": "Run self-test",
        "mi_una": "About una.md ERP", "mi_una_site": "Open una.md website",
        "una_banner": "A free tool from the una.md ERP ecosystem — "
                      "the Moldovan alternative to 1C.",
        "una_banner_btn": "About una.md",
        "una_title": "una.md — ERP for Moldovan business",
        "una_tagline": "A Moldovan ERP platform — an alternative to 1C.",
        "una_p1": "una.md is a business management platform built in Moldova, for "
                  "Moldovan accounting and reporting practice. It is designed as an "
                  "alternative to 1C for companies that want their ERP, their data and "
                  "their support to stay in the country.",
        "una_p2": "Contragenti — the tool you are using now — is a free part of that "
                  "ecosystem. It is a working example of how una.md opens up: any "
                  "program can read from it and write into it.",
        "una_p3": "The counterparty you find here goes straight into the una.md "
                  "directory as three linked blocks: the reference record, the company "
                  "details and its bank accounts. No re-typing, no CSV in between.",
        "una_adv_title": "What this changes in practice",
        "una_a1": "Data stays in your own infrastructure — the database is yours, "
                  "not a foreign cloud.",
        "una_a2": "Built around Moldovan reality: IDNO, state registry date.gov.md, "
                  "MDL bank accounts, local banks directory.",
        "una_a3": "Three interface languages out of the box: Română, Русский, English.",
        "una_a4": "Open integration: local HTTP API and XML, so 1C, a browser or any "
                  "in-house program can talk to it.",
        "una_a5": "Extensible by your own team — the schema and the integration points "
                  "are documented, not sealed.",
        "una_case": "This utility is the short version of the argument: a free program "
                    "that fills your ERP with official registry data in one click. "
                    "That is what an open platform makes possible.",
        "una_btn_site": "Open una.md",
        "una_btn_connect": "Set up connection",
        "about_title": "Contragenti — overview",
        "about_text": (
            "Contragenti {version}\n"
            "A free tool from the una.md ERP ecosystem\n\n"
            "Desktop tool for searching Moldovan legal entities on the date.gov.md "
            "open-data portal, with a local counterparty database.\n\n"
            "Key features:\n"
            "  - Online search by name / manager / IDNO via a real Chrome window\n"
            "  - Company card: basic data, founders, budget debts\n"
            "  - Local SQLite database ({count} companies stored) with offline search\n"
            "  - Export to CSV / Excel / Markdown\n"
            "  - Local HTTP API (port 9393) for integration with 1C and other software\n"
            "  - Direct export of found companies to the una.md ERP "
            "(TMS_UNIVERS / TMS_ORG / TMS_ORG_ACCOUNTS)\n"
            "  - Three interface languages: English / Русский / Română\n\n"
            "Use \"Run self-test\" below to verify the database, translations, "
            "XML export and network subsystems."
        ),
        "selftest_title": "Contragenti — self-test",
        "tms_bar_title": "una.md (ERP):",
        "tms_auto": "Auto-send on search",
        "tms_send": "Send selected to una.md",
        "tms_settings": "una.md settings…",
        "tms_title": "una.md export",
        "tms_none_selected": "No rows are checked. Tick the box in the first column, "
                             "or enable auto-send.",
        "tms_busy": "A previous una.md export is still running.",
        "tms_auto_on": "Auto-send to una.md is ON — new search results are exported automatically.",
        "tms_auto_off": "Auto-send to una.md is OFF — tick rows and press “Send selected”.",
        "tms_progress_run": "una.md: sending {n}/{total}…",
        "tms_progress_done": "una.md: added {ok}, duplicates {dup}, errors {err}",
        "tms_result": "una.md export finished: {total} processed — {ok} added, "
                      "{dup} duplicates, {err} errors.",
        "tms_settings_title": "una.md connection",
        "tms_f_dsn": "DSN (host:port/service):",
        "tms_f_user": "User (schema):",
        "tms_f_pwd": "Password:",
        "tms_f_client": "Oracle Client dir (optional):",
        "tms_f_hub_user": "Shared hub schema (optional):",
        "tms_f_hub_pwd": "Hub schema password:",
        "tms_no_targets": "No schema is configured for writing.",
        "tms_result_multi": "Export finished: {total} processed — {schemas}",
        "tms_warn": "Some schemas are unavailable: {err}",
        "tms_test": "Test", "tms_save": "Save", "tms_cancel": "Cancel",
        "tms_test_ok": "Connected: {ver}",
        "hub_send_now": "Send database to una.md hub",
        "hub_not_set": "Hub address is not configured (hub_url).",
        "hub_sending": "Sending the database to the hub…",
        "hub_sent": "Database sent to the hub, batch {id} — import runs there.",
        "hub_error": "Hub is unreachable: {err}",
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
        "d2b_chk": "плюс data2b.md",
        "src_lbl": "Источники:",
        "src_gov": "date.gov.md",
        "src_d2b": "data2b.md",
        "src_db": "своя БД",
        "status_no_data": "{src}: по этому запросу данных нет.",
        "status_details_none": "На портале нет карточки по IDNO {idno} (показано из БД).",
        "status_sources_off": "Онлайн-источники отключены — показана локальная БД.",
        "mi_restart": "Перезапустить",
        "status_restart": "Перезапуск…",
        "st_d2b": "Ищу на data2b.md…",
        "status_d2b": "data2b.md: {n} из {total} по «{q}».",
        "status_d2b_none": "data2b.md: по «{q}» ничего не найдено.",
        "d2b_error": "data2b.md недоступен: {err}",
        "f_source": "Источник",
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
        "menu_help": "Справка", "mi_about": "О программе", "mi_selftest": "Запустить самопроверку",
        "mi_una": "Об ERP una.md", "mi_una_site": "Открыть сайт una.md",
        "una_banner": "Бесплатный инструмент экосистемы ERP una.md — "
                      "молдавской альтернативы 1С.",
        "una_banner_btn": "Об una.md",
        "una_title": "una.md — ERP для молдавского бизнеса",
        "una_tagline": "Молдавская ERP-платформа — альтернатива 1С.",
        "una_p1": "una.md — платформа управления предприятием, сделанная в Молдове под "
                  "молдавскую практику учёта и отчётности. Это альтернатива 1С для "
                  "компаний, которым важно, чтобы ERP, данные и поддержка оставались "
                  "внутри страны.",
        "una_p2": "Contragenti — программа, которой вы сейчас пользуетесь, — бесплатная "
                  "часть этой экосистемы. Это рабочий пример того, как una.md "
                  "открыта наружу: из неё может читать и в неё может писать любая "
                  "программа.",
        "una_p3": "Найденный здесь контрагент попадает в справочник una.md сразу тремя "
                  "связанными блоками: справочная запись, реквизиты и банковские счета. "
                  "Без перенабора вручную и без промежуточных CSV.",
        "una_adv_title": "Что это меняет на практике",
        "una_a1": "Данные остаются в вашей инфраструктуре — база ваша, а не чужое облако.",
        "una_a2": "Построена вокруг молдавских реалий: IDNO, госреестр date.gov.md, "
                  "счета в MDL, справочник местных банков.",
        "una_a3": "Три языка интерфейса сразу: Română, Русский, English.",
        "una_a4": "Открытая интеграция: локальный HTTP-API и XML — с платформой могут "
                  "говорить 1С, браузер или любая ваша программа.",
        "una_a5": "Расширяется силами вашей команды: схема и точки интеграции "
                  "задокументированы, а не закрыты.",
        "una_case": "Эта утилита — короткая версия аргумента: бесплатная программа, "
                    "которая одним нажатием наполняет ERP данными госреестра. Именно "
                    "это и позволяет открытая платформа.",
        "una_btn_site": "Открыть una.md",
        "una_btn_connect": "Настроить подключение",
        "about_title": "Contragenti — о программе",
        "about_text": (
            "Contragenti {version}\n"
            "Бесплатный инструмент экосистемы ERP una.md\n\n"
            "Настольная утилита для поиска юридических лиц Молдовы на портале "
            "открытых данных date.gov.md, с локальной базой контрагентов.\n\n"
            "Возможности:\n"
            "  - Онлайн-поиск по названию / руководителю / IDNO через реальный Chrome\n"
            "  - Карточка компании: базовые данные, учредители, задолженность перед бюджетом\n"
            "  - Локальная база SQLite (сохранено компаний: {count}) с офлайн-поиском\n"
            "  - Экспорт в CSV / Excel / Markdown\n"
            "  - Локальный HTTP-API (порт 9393) для интеграции с 1С и другими программами\n"
            "  - Прямая отправка найденных компаний в ERP una.md "
            "(TMS_UNIVERS / TMS_ORG / TMS_ORG_ACCOUNTS)\n"
            "  - Три языка интерфейса: English / Русский / Română\n\n"
            "Кнопка «Запустить самопроверку» ниже проверит базу данных, переводы, "
            "экспорт в XML и сетевую подсистему."
        ),
        "selftest_title": "Contragenti — самопроверка",
        "tms_bar_title": "una.md (ERP):",
        "tms_auto": "Авто-отправка при поиске",
        "tms_send": "Отправить выбранные в una.md",
        "tms_settings": "Настройки una.md…",
        "tms_title": "Экспорт в una.md",
        "tms_none_selected": "Ни одна строка не отмечена. Поставьте галочку в первом "
                             "столбце или включите авто-отправку.",
        "tms_busy": "Предыдущая отправка в una.md ещё выполняется.",
        "tms_auto_on": "Авто-отправка в una.md ВКЛючена — новые результаты поиска "
                       "отправляются автоматически.",
        "tms_auto_off": "Авто-отправка в una.md ВЫКЛючена — отметьте строки и нажмите "
                        "«Отправить выбранные».",
        "tms_progress_run": "una.md: отправка {n}/{total}…",
        "tms_progress_done": "una.md: добавлено {ok}, дубликатов {dup}, ошибок {err}",
        "tms_result": "Экспорт в una.md завершён: обработано {total} — добавлено {ok}, "
                      "дубликатов {dup}, ошибок {err}.",
        "tms_settings_title": "Подключение к una.md",
        "tms_f_dsn": "DSN (host:port/service):",
        "tms_f_user": "Пользователь (схема):",
        "tms_f_pwd": "Пароль:",
        "tms_f_client": "Каталог Oracle Client (необязательно):",
        "tms_f_hub_user": "Сводная схема хаба (необязательно):",
        "tms_f_hub_pwd": "Пароль сводной схемы:",
        "tms_no_targets": "Не настроена ни одна схема для записи.",
        "tms_result_multi": "Экспорт завершён: обработано {total} — {schemas}",
        "tms_warn": "Часть схем недоступна: {err}",
        "tms_test": "Проверить", "tms_save": "Сохранить", "tms_cancel": "Отмена",
        "tms_test_ok": "Подключено: {ver}",
        "hub_send_now": "Отправить базу на хаб una.md",
        "hub_not_set": "Адрес хаба не настроен (hub_url).",
        "hub_sending": "Отправка базы на хаб…",
        "hub_sent": "База отправлена на хаб, пакет {id} — импорт идёт там.",
        "hub_error": "Хаб недоступен: {err}",
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
        "d2b_chk": "plus data2b.md",
        "src_lbl": "Surse:",
        "src_gov": "date.gov.md",
        "src_d2b": "data2b.md",
        "src_db": "baza proprie",
        "status_no_data": "{src}: nu sunt date pentru această căutare.",
        "status_details_none": "Portalul nu are fișă pentru IDNO {idno} (afișat din BD).",
        "status_sources_off": "Sursele online sunt oprite — se afișează baza locală.",
        "mi_restart": "Repornește",
        "status_restart": "Repornire…",
        "st_d2b": "Caut pe data2b.md…",
        "status_d2b": "data2b.md: {n} din {total} pentru „{q}”.",
        "status_d2b_none": "data2b.md: nimic găsit pentru „{q}”.",
        "d2b_error": "data2b.md indisponibil: {err}",
        "f_source": "Sursa",
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
        "menu_help": "Ajutor", "mi_about": "Despre program", "mi_selftest": "Rulează auto-testul",
        "mi_una": "Despre ERP una.md", "mi_una_site": "Deschide site-ul una.md",
        "una_banner": "Instrument gratuit din ecosistemul ERP una.md — "
                      "alternativa moldovenească la 1C.",
        "una_banner_btn": "Despre una.md",
        "una_title": "una.md — ERP pentru businessul din Moldova",
        "una_tagline": "Platformă ERP moldovenească — alternativă la 1C.",
        "una_p1": "una.md este o platformă de gestiune a întreprinderii, creată în "
                  "Moldova, pentru practica locală de contabilitate și raportare. Este "
                  "o alternativă la 1C pentru companiile care vor ca ERP-ul, datele și "
                  "suportul să rămână în țară.",
        "una_p2": "Contragenti — programul pe care îl folosiți acum — este o parte "
                  "gratuită a acestui ecosistem. Este un exemplu concret al deschiderii "
                  "una.md: orice program poate citi din ea și scrie în ea.",
        "una_p3": "Contragentul găsit aici ajunge direct în nomenclatorul una.md prin "
                  "trei blocuri legate: înregistrarea de nomenclator, datele de "
                  "identificare și conturile bancare. Fără reintroducere manuală și "
                  "fără fișiere CSV intermediare.",
        "una_adv_title": "Ce schimbă acest lucru în practică",
        "una_a1": "Datele rămân în infrastructura dumneavoastră — baza este a voastră, "
                  "nu un cloud străin.",
        "una_a2": "Construită în jurul realităților moldovenești: IDNO, registrul de stat "
                  "date.gov.md, conturi în MDL, nomenclatorul băncilor locale.",
        "una_a3": "Trei limbi de interfață din start: Română, Русский, English.",
        "una_a4": "Integrare deschisă: API HTTP local și XML — cu platforma pot vorbi "
                  "1C, browserul sau orice program al vostru.",
        "una_a5": "Extensibilă de echipa voastră: schema și punctele de integrare sunt "
                  "documentate, nu închise.",
        "una_case": "Acest utilitar este varianta scurtă a argumentului: un program "
                    "gratuit care umple ERP-ul cu date din registrul de stat printr-un "
                    "singur clic. Exact asta permite o platformă deschisă.",
        "una_btn_site": "Deschide una.md",
        "una_btn_connect": "Configurează conexiunea",
        "about_title": "Contragenti — despre program",
        "about_text": (
            "Contragenti {version}\n"
            "Instrument gratuit din ecosistemul ERP una.md\n\n"
            "Utilitar desktop pentru căutarea persoanelor juridice din Moldova pe "
            "portalul de date deschise date.gov.md, cu bază locală de contragenți.\n\n"
            "Funcționalități:\n"
            "  - Căutare online după denumire / administrator / IDNO printr-o fereastră Chrome reală\n"
            "  - Fișa companiei: date de bază, fondatori, restanțe față de buget\n"
            "  - Bază locală SQLite ({count} companii salvate) cu căutare offline\n"
            "  - Export în CSV / Excel / Markdown\n"
            "  - API HTTP local (port 9393) pentru integrare cu 1C și alte programe\n"
            "  - Export direct al companiilor găsite în ERP una.md "
            "(TMS_UNIVERS / TMS_ORG / TMS_ORG_ACCOUNTS)\n"
            "  - Trei limbi de interfață: English / Русский / Română\n\n"
            "Butonul „Rulează auto-testul” de mai jos verifică baza de date, traducerile, "
            "exportul XML și subsistemul de rețea."
        ),
        "selftest_title": "Contragenti — auto-test",
        "tms_bar_title": "una.md (ERP):",
        "tms_auto": "Trimitere automată la căutare",
        "tms_send": "Trimite selectate în una.md",
        "tms_settings": "Setări una.md…",
        "tms_title": "Export în una.md",
        "tms_none_selected": "Nicio linie bifată. Bifați caseta din prima coloană "
                             "sau activați trimiterea automată.",
        "tms_busy": "Un export una.md anterior încă rulează.",
        "tms_auto_on": "Trimiterea automată în una.md este ACTIVĂ — rezultatele noi "
                       "sunt exportate automat.",
        "tms_auto_off": "Trimiterea automată în una.md este OPRITĂ — bifați liniile și "
                        "apăsați „Trimite selectate”.",
        "tms_progress_run": "una.md: se trimite {n}/{total}…",
        "tms_progress_done": "una.md: adăugate {ok}, duplicate {dup}, erori {err}",
        "tms_result": "Export una.md finalizat: {total} procesate — {ok} adăugate, "
                      "{dup} duplicate, {err} erori.",
        "tms_settings_title": "Conexiune una.md",
        "tms_f_dsn": "DSN (host:port/service):",
        "tms_f_user": "Utilizator (schemă):",
        "tms_f_pwd": "Parolă:",
        "tms_f_client": "Director Oracle Client (opțional):",
        "tms_f_hub_user": "Schema centralizată a hubului (opțional):",
        "tms_f_hub_pwd": "Parola schemei hubului:",
        "tms_no_targets": "Nu este configurată nicio schemă pentru scriere.",
        "tms_result_multi": "Export finalizat: {total} procesate — {schemas}",
        "tms_warn": "O parte din scheme sunt indisponibile: {err}",
        "tms_test": "Testează", "tms_save": "Salvează", "tms_cancel": "Anulează",
        "tms_test_ok": "Conectat: {ver}",
        "hub_send_now": "Trimite baza către hubul una.md",
        "hub_not_set": "Adresa hubului nu este configurată (hub_url).",
        "hub_sending": "Se trimite baza către hub…",
        "hub_sent": "Baza a fost trimisă, pachetul {id} — importul rulează acolo.",
        "hub_error": "Hubul nu este accesibil: {err}",
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


# ──────────────────────── Второй источник: data2b.md ────────────────────────
#
# На date.gov.md встречаются действующие компании, которых портал не отдаёт
# (например IDNO 1007602003320). data2b.md — публичный B2B-справочник Молдовы;
# его страница поиска обращается к открытому адресу /api/companies/?q=…,
# который отвечает без ключа, без регистрации и без капчи. Мы делаем ровно
# тот же простой запрос, что и обычный посетитель сайта.


def data2b_parse(payload):
    """Разбирает ответ поиска data2b.md в записи формата приложения.

    Принимает dict (уже разобранный JSON) или строку/байты с JSON.
    Отсутствующие у источника поля (руководители, дата регистрации) остаются
    пустыми — db_upsert не затирает ими данные, полученные с портала.
    """
    if isinstance(payload, (bytes, bytearray)):
        payload = payload.decode("utf-8", "replace")
    if isinstance(payload, str):
        payload = json.loads(payload)
    rows = []
    for item in (payload or {}).get("results") or []:
        idno = str(item.get("idno") or "").strip()
        name = (item.get("name") or "").strip()
        if not idno and not name:
            continue
        rows.append({
            "idno": idno,
            "denumire": name,
            "administratori": "",
            "inregistrare": "",
            "adresa": " ".join((item.get("address") or "").split()),
            "source": SOURCE_D2B,
        })
    return rows


def data2b_total(payload):
    """Сколько всего совпадений нашёл источник (для строки состояния)."""
    if isinstance(payload, (bytes, bytearray)):
        payload = payload.decode("utf-8", "replace")
    if isinstance(payload, str):
        payload = json.loads(payload)
    try:
        return int((payload or {}).get("count") or 0)
    except (TypeError, ValueError):
        return 0


def data2b_fetch(query, page=1, timeout=20):
    """Один простой поисковый запрос к data2b.md. Возвращает разобранный JSON."""
    import urllib.request
    from urllib.parse import urlencode
    url = DATA2B_URL + "?" + urlencode({"q": query, "page": page})
    req = urllib.request.Request(url, headers={
        "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/140.0 Safari/537.36"),
        "Accept": "application/json",
        "Accept-Language": "ro,ru;q=0.9,en;q=0.8",
        "Referer": DATA2B_SITE + "/ro/",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def data2b_search(query, max_pages=3, timeout=20):
    """Поиск на data2b.md с постраничным добором. Возвращает (rows, total)."""
    query = (query or "").strip()
    if not query:
        return [], 0
    rows, total, seen = [], 0, set()
    for page in range(1, max(1, max_pages) + 1):
        payload = data2b_fetch(query, page=page, timeout=timeout)
        if page == 1:
            total = data2b_total(payload)
        chunk = data2b_parse(payload)
        if not chunk:
            break
        for rec in chunk:
            key = rec["idno"] or "name:" + rec["denumire"]
            if key not in seen:
                seen.add(key)
                rows.append(rec)
        if len(rows) >= total:
            break
    return rows, total


class Data2bWorker(threading.Thread):
    """Параллельный поиск на data2b.md — обычный HTTP, без браузера и капчи."""

    def __init__(self, query, out_queue, tr, max_pages=3):
        super().__init__(daemon=True)
        self.query = query
        self.out = out_queue
        self.tr = tr
        self.max_pages = max_pages

    def run(self):
        try:
            self.out.put(("status", self.tr.get("st_d2b", "data2b.md…")))
            rows, total = data2b_search(self.query, max_pages=self.max_pages)
            self.out.put(("d2b_done", {"rows": rows, "total": total,
                                       "query": self.query}))
        except Exception as exc:  # noqa: BLE001
            self.out.put(("d2b_error", f"{type(exc).__name__}: {exc}"))


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
            source         TEXT,
            updated_at     TEXT
        )
        """
    )
    # миграция: добить недостающие колонки в старой БД
    have = {r[1] for r in conn.execute("PRAGMA table_info(companies)")}
    for col in ("founders_json", "debts_json", "source"):
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
            fields = {k: rec.get(k) for k in COLUMNS}
            # data2b.md даёт ещё адрес и метку источника — они не входят в
            # COLUMNS (колонки таблицы результатов), но нужны в базе
            for extra in ("adresa", "source"):
                if rec.get(extra):
                    fields[extra] = rec[extra]
            db_upsert(conn, fields)
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
            "source": SOURCE_GOV,
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
        f"- **{tr['f_source']}:** {rec.get('source','') or SOURCE_GOV}",
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
        "source": (rec.get("source") or SOURCE_GOV),
        "idno": rec.get("idno", "") or "",
        "updated": rec.get("updated_at", "") or "",
    })
    for tag, key in (
        ("idno", "idno"), ("denumire", "denumire"), ("inregistrare", "inregistrare"),
        ("forma_juridica", "forma_juridica"), ("lichidata", "lichidata"),
        ("adresa", "adresa"), ("administratori", "administratori"),
        ("source", "source"),
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
        ("f_source", "source"),
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
        "body{font-family:-apple-system,Segoe UI,Arial,sans-serif;margin:24px;"
        "color:#222;background:#fff}"
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

    def __init__(self, mode, value, out_queue, tr, headless=False, shots_dir=None):
        super().__init__(daemon=True)
        self.mode = mode
        self.value = value
        self.out = out_queue
        self.tr = tr
        self.headless = headless
        self.shots_dir = shots_dir

    def _status(self, key):
        self.out.put(("status", self.tr.get(key, key)))

    def _shot(self, driver, name):
        """Снимок страницы портала средствами самого браузера (--shots-dir):
        не зависит от рабочего стола и перекрытия окон."""
        if not self.shots_dir:
            return
        try:
            os.makedirs(self.shots_dir, exist_ok=True)
            driver.save_screenshot(os.path.join(self.shots_dir, f"{name}.png"))
        except Exception:  # noqa: BLE001
            pass

    def _make_driver(self):
        options = Options()
        if self.headless:
            options.add_argument("--headless=new")
        options.add_argument("--window-size=1200,900")
        # excludeSwitches=["enable-automation"] убрано: Chrome 152 с этой
        # опцией завершается сразу после старта (SessionNotCreatedException)
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
            if driver is not None:
                self._shot(driver, "sdk_0_portal_timeout")   # что показал портал (капча?)
            self.out.put(("error", self.tr.get("err_timeout", "Timeout")))
        except Exception as exc:  # noqa: BLE001
            self.out.put(("error", f"{type(exc).__name__}: {exc}"))
        finally:
            if driver is not None:
                try:
                    driver.quit()
                except Exception:  # noqa: BLE001
                    pass

    def _dismiss_cookie_banner(self, driver):
        """Закрыть баннер cookie — иначе он перекрывает кнопку отправки формы.

        Выбираем «только необходимые» (btnNecessary): минимум cookie,
        аналитические и рекламные не принимаем.
        """
        for sel in ("#btnNecessary", "#btnAcceptNecessary", ".cookie-btn--outline"):
            try:
                btns = driver.find_elements(By.CSS_SELECTOR, sel)
            except Exception:  # noqa: BLE001
                continue
            for btn in btns:
                try:
                    if btn.is_displayed():
                        driver.execute_script("arguments[0].click();", btn)
                        WebDriverWait(driver, 5).until_not(
                            EC.visibility_of(btn))
                        return True
                except Exception:  # noqa: BLE001
                    continue
        return False

    def _fill_and_submit(self, driver, field_name):
        wait = WebDriverWait(driver, 30)
        self._status("st_form")
        field = wait.until(EC.presence_of_element_located(
            (By.CSS_SELECTOR, f"#requestForm input[name='{field_name}']")))
        field.clear()
        field.send_keys(self.value)
        self._dismiss_cookie_banner(driver)
        self._status("st_submit")
        btn = wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, "#access-service")))
        try:
            btn.click()
        except Exception:  # noqa: BLE001
            # Что-то всё же перекрыло кнопку — жмём напрямую через DOM.
            driver.execute_script("arguments[0].click();", btn)

    def _wait_fragment(self, driver, timeout=120):
        """Ждёт, пока портал отрисует фрагмент ответа.

        Портал отвечает одним из двух способов: содержательным фрагментом
        (таблица результатов или поля карточки) либо коротким сообщением
        «Rezultat căutare persoană juridică — Nu sunt date.» (так он отвечает,
        например, на IDNO 1007602003320). Второй случай раньше не отличался от
        «ещё грузится», и поиск впустую ждал полный таймаут; теперь мы ловим
        его сразу и закрываем браузер.

        Возвращает True, если пришли данные, и False, если портал сообщил,
        что данных нет.
        """
        wait = WebDriverWait(driver, timeout)
        wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "#fragments-accordion")))

        def ready(d):
            if d.find_elements(By.CSS_SELECTOR, "#fragments-accordion .fragment-loading"):
                return False          # ещё крутится спиннер загрузки
            bodies = d.find_elements(By.CSS_SELECTOR, "#fragments-accordion .output-data")
            if not bodies:
                return False
            if d.find_elements(By.CSS_SELECTOR,
                               "#fragments-accordion .output-data table, "
                               "#fragments-accordion .output-data .simple-title"):
                return True           # содержательный ответ
            # текст без таблицы и полей — это сообщение «нет данных»
            return any((b.get_attribute("textContent") or "").strip() for b in bodies)

        wait.until(ready)
        return bool(driver.find_elements(
            By.CSS_SELECTOR, "#fragments-accordion .output-data table, "
                             "#fragments-accordion .output-data .simple-title"))

    def _no_data_text(self, driver):
        """Что именно ответил портал (для строки состояния)."""
        parts = []
        for el in driver.find_elements(By.CSS_SELECTOR, "#fragments-accordion .output-data"):
            parts.append(" ".join((el.get_attribute("textContent") or "").split()))
        return " ".join(p for p in parts if p)[:120]

    def _run_search(self, driver):
        self._status("st_open_search")
        driver.get(SEARCH_URL)
        self._fill_and_submit(driver, "q")
        self._status("st_results")
        if not self._wait_fragment(driver):
            # «Nu sunt date.» — сразу отдаём пустой результат и закрываемся
            self._shot(driver, "sdk_1_portal_no_data")
            self.out.put(("portal_no_data", self._no_data_text(driver)))
            self.out.put(("search_done", []))
            return
        table = driver.find_element(
            By.CSS_SELECTOR, "div[data-fragment-id] table, .table-responsive table")
        try:
            WebDriverWait(driver, 10).until(
                lambda d: len(table.find_elements(By.CSS_SELECTOR, "tbody tr")) > 0)
        except TimeoutException:
            pass
        self._shot(driver, "sdk_1_portal_search_results")
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
        if not self._wait_fragment(driver):
            self._shot(driver, "sdk_2_portal_no_data")
            self.out.put(("portal_no_data", self._no_data_text(driver)))
            self.out.put(("details_none", self.value))
            return
        driver.execute_script(
            "document.querySelectorAll('#fragments-accordion .accordion-collapse')"
            ".forEach(function(e){e.classList.add('show'); e.style.height='auto';"
            "e.style.display='block';});")
        self._shot(driver, "sdk_2_portal_details")

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


# ─────────────────────── интеграция с ERP una.md ───────────────────────

TMS_CONFIG_PATH = os.path.join(DATA_DIR, "tms_config.json")
# Пользовательские настройки GUI (источники поиска и т.п.) — рядом с базой,
# чтобы они сохранялись и при установке в Program Files (см. _data_dir)
SETTINGS_PATH = os.path.join(DATA_DIR, "settings.json")


def settings_load():
    """Настройки интерфейса, запоминаемые между запусками.

    Источники поиска можно включать и отключать независимо: портал
    date.gov.md, справочник data2b.md и собственная база (офлайн).
    """
    cfg = {"src_gov": True, "src_d2b": True, "src_db": True, "headless": False}
    try:
        with open(SETTINGS_PATH, encoding="utf-8") as f:
            saved = json.load(f)
        for key in cfg:
            if key in saved:
                cfg[key] = bool(saved[key])
    except Exception:  # noqa: BLE001
        pass          # файла ещё нет или он повреждён — берём значения по умолчанию
    return cfg


def settings_save(cfg):
    try:
        with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        return True
    except Exception:  # noqa: BLE001
        return False


def tms_load_config():
    """Прочитать параметры подключения к una.md (без пароля в коде)."""
    cfg = {"dsn": "192.168.0.24:1521/clouddev.world", "user": "paralax",
           "password": "", "client_dir": "",
           # сводная схема хаба: пишем в неё тем же подключением, что и в свою
           "hub_schema_user": "", "hub_schema_password": "",
           # хаб сбора баз по HTTP: пустой URL — фоновая отправка выключена
           "hub_url": "", "hub_key": "", "hub_interval": 900}
    try:
        with open(TMS_CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except Exception:  # noqa: BLE001
        pass
    # переменные окружения имеют приоритет над файлом
    for key, env in (("dsn", "TMS_DSN"), ("user", "TMS_USER"),
                     ("password", "TMS_PASSWORD"), ("client_dir", "ORACLE_CLIENT_DIR"),
                     ("hub_url", "HUB_URL"), ("hub_key", "HUB_API_KEY")):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    return cfg


def tms_save_config(cfg):
    with open(TMS_CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


class TmsExportWorker(threading.Thread):
    """Асинхронная отправка организаций в una.md — по одной записи.

    Организация пишется сразу во все настроенные схемы: свою рабочую и
    сводную схему хаба. Каждая схема получает свою транзакцию, поэтому
    недоступность одной не отменяет запись в остальные.

    Внутри схемы запись раскладывается тремя автономными блоками
    (TMS_UNIVERS → TMS_ORG → TMS_ORG26); прогресс и итог кладутся
    в очередь Tk-потока.
    """

    def __init__(self, records, config, out_queue, tr):
        super().__init__(daemon=True)
        self.records = list(records)
        self.config = config
        self.out = out_queue
        self.tr = tr

    def run(self):
        try:
            import tms_multi
        except Exception as exc:  # noqa: BLE001
            self.out.put(("tms_error", f"tms_multi import: {exc}"))
            return

        targets = tms_multi.targets_from_config(self.config)
        if not targets:
            self.out.put(("tms_error", "не задана ни одна схема для записи"))
            return

        mx = tms_multi.MultiExporter(targets).connect()
        if not mx.ready:
            errs = "; ".join(f"{n}: {e}" for n, e in mx.errors.items())
            self.out.put(("tms_error", errs or "не удалось подключиться"))
            return
        if mx.errors:
            # часть схем недоступна — работаем с остальными, но сообщаем
            self.out.put(("tms_warn", "; ".join(
                f"{n}: {e}" for n, e in mx.errors.items())))

        schemas = list(mx.exporters)      # close() очистит список
        done = 0
        try:
            for rec in self.records:
                report = mx.export_one(rec)
                done += 1
                self.out.put(("tms_progress", {
                    "n": done, "total": len(self.records), "report": report}))
        finally:
            mx.close()
        self.out.put(("tms_done", {"total": len(self.records), "schemas": schemas}))


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
        self.settings = settings_load()   # запомненные источники поиска
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
        self._start_hub_uploader()
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
        self.file_menu.add_command(label="", command=self._restart_app)
        self.file_menu.add_separator()
        self.file_menu.add_command(label="", command=self.do_quit)
        self.menubar.add_cascade(menu=self.file_menu, label="")
        self.export_menu = tk.Menu(self.menubar, tearoff=0)
        self.export_menu.add_command(label="", command=self.export_csv_all)
        self.export_menu.add_command(label="", command=self.export_xlsx_all)
        self.export_menu.add_separator()
        self.export_menu.add_command(label="", command=self.export_selected_md)
        self.export_menu.add_command(label="", command=self.export_md_current)
        self.export_menu.add_separator()
        self.export_menu.add_command(label="", command=self.on_hub_send_now)
        self.menubar.add_cascade(menu=self.export_menu, label="")
        self.lang_menu = tk.Menu(self.menubar, tearoff=0)
        for code in LANGS:
            self.lang_menu.add_command(label=LANG_NAMES[code],
                                       command=lambda c=code: self.set_lang(c))
        self.menubar.add_cascade(menu=self.lang_menu, label="")
        self.help_menu = tk.Menu(self.menubar, tearoff=0)
        self.help_menu.add_command(label="", command=self._show_about)
        self.help_menu.add_command(label="", command=self._run_selftest_ui)
        self.help_menu.add_separator()
        self.help_menu.add_command(label="", command=self._show_una)
        self.help_menu.add_command(label="", command=self._open_una_site)
        self.menubar.add_cascade(menu=self.help_menu, label="")
        self.config(menu=self.menubar)

    # ── интерфейс ──

    def _build_ui(self):
        self._build_una_banner()
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
        self._build_tms_bar()

    def _build_una_banner(self):
        """Верхняя полоса бренда: чей это инструмент и куда ведёт ERP."""
        bar = tk.Frame(self, bg=UNA_BANNER_BG)
        bar.pack(fill="x", side="top")
        inner = tk.Frame(bar, bg=UNA_BANNER_BG)
        inner.pack(fill="x", padx=10, pady=5)
        tk.Label(inner, text="una.md", bg=UNA_BANNER_BG, fg=UNA_ACCENT,
                 font=("", 12, "bold")).pack(side="left")
        self.una_banner_lbl = tk.Label(inner, bg=UNA_BANNER_BG, fg="#274b45",
                                       font=("", 9))
        self.una_banner_lbl.pack(side="left", padx=(10, 0))
        self.una_banner_btn = ttk.Button(inner, command=self._show_una)
        self.una_banner_btn.pack(side="right")

    def _build_tms_bar(self):
        """Панель интеграции с una.md: авто-режим, выбор галочками, отправка."""
        bar = ttk.Frame(self, padding=(8, 5))
        bar.pack(fill="x", side="bottom")
        self.tms_title_lbl = ttk.Label(bar, font=("", 9, "bold"))
        self.tms_title_lbl.pack(side="left", padx=(0, 10))

        self.tms_auto_var = tk.BooleanVar(value=False)
        self.tms_auto_chk = ttk.Checkbutton(bar, variable=self.tms_auto_var,
                                            command=self._on_tms_auto_toggle)
        self.tms_auto_chk.pack(side="left", padx=(0, 12))

        self.tms_send_btn = ttk.Button(bar, command=self.on_tms_send_selected,
                                       state="disabled")
        self.tms_send_btn.pack(side="left")
        self.tms_count = tk.StringVar(value="")
        ttk.Label(bar, textvariable=self.tms_count, width=4,
                  foreground="#0b6e5f").pack(side="left", padx=(4, 8))
        self.tms_all_btn = ttk.Button(bar, width=3, command=self._on_tms_check_all)
        self.tms_all_btn.pack(side="left")
        self.tms_none_btn = ttk.Button(bar, width=3, command=self._on_tms_check_none)
        self.tms_none_btn.pack(side="left", padx=(2, 12))

        self.tms_cfg_btn = ttk.Button(bar, command=self._tms_settings_dialog)
        self.tms_cfg_btn.pack(side="right")
        self.tms_progress = tk.StringVar(value="")
        ttk.Label(bar, textvariable=self.tms_progress,
                  foreground="#69808f").pack(side="right", padx=(0, 10))

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
            # Источники поиска: каждый включается и отключается отдельно,
            # состояние запоминается между запусками (settings.json).
            cfg = self.settings
            self.src_gov_var = tk.BooleanVar(value=cfg.get("src_gov", True))
            self.src_d2b_var = tk.BooleanVar(
                value=cfg.get("src_d2b", True)
                and not getattr(self.args, "no_data2b", False))
            self.src_db_var = tk.BooleanVar(value=cfg.get("src_db", True))
            self.headless_var = tk.BooleanVar(value=cfg.get("headless", False))
            self.src_label = ttk.Label(bar)
            self.src_label.grid(row=0, column=4, padx=(10, 2))
            self.chk_gov = ttk.Checkbutton(bar, variable=self.src_gov_var)
            self.chk_gov.grid(row=0, column=5, padx=3)
            self.chk_d2b = ttk.Checkbutton(bar, variable=self.src_d2b_var)
            self.chk_d2b.grid(row=0, column=6, padx=3)
            self.chk_db = ttk.Checkbutton(bar, variable=self.src_db_var)
            self.chk_db.grid(row=0, column=7, padx=3)
            self.chk_headless = ttk.Checkbutton(bar, variable=self.headless_var)
            self.chk_headless.grid(row=0, column=8, padx=(10, 3))
            for var in (self.src_gov_var, self.src_d2b_var,
                        self.src_db_var, self.headless_var):
                var.trace_add("write", lambda *_: self._save_settings())
        else:
            entry.bind("<Return>", lambda e: self.on_db_find())
            self.offline_entry, self.offline_label = entry, lbl
            self.offline_clear_btn, self.offline_find_btn = clr, btn

        tf = ttk.Frame(parent, padding=(8, 0, 8, 8))
        tf.pack(fill="both", expand=True)
        # show="tree headings": колонка #0 хранит галочку выбора для una.md
        tree = ttk.Treeview(tf, columns=COLUMNS, show="tree headings",
                            selectmode="extended")
        tree.column("#0", width=34, minwidth=34, stretch=False, anchor="center")
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
        tree.bind("<Button-1>", lambda e, tv=tree: self._on_tree_click(tv, e))
        tree._idno_map = {}
        tree._recs = {}        # iid → полная запись (для отправки в una.md)
        tree._checked = set()  # iid отмеченных галочкой строк
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
            ("f_source", "source"),
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
        self.menubar.entryconfig(4, label=self.t("menu_help"))
        self.file_menu.entryconfig(0, label=self.t("mi_hide"))
        self.file_menu.entryconfig(1, label=self.t("mi_restart"))
        self.file_menu.entryconfig(3, label=self.t("mi_quit"))
        self.help_menu.entryconfig(0, label=self.t("mi_about"))
        self.help_menu.entryconfig(1, label=self.t("mi_selftest"))
        self.help_menu.entryconfig(3, label=self.t("mi_una"))
        self.help_menu.entryconfig(4, label=self.t("mi_una_site"))
        if hasattr(self, "una_banner_lbl"):
            self.una_banner_lbl.config(text=self.t("una_banner"))
            self.una_banner_btn.config(text=self.t("una_banner_btn"))
        self.export_menu.entryconfig(0, label=self.t("exp_csv_all"))
        self.export_menu.entryconfig(1, label=self.t("exp_xlsx_all"))
        self.export_menu.entryconfig(3, label=self.t("exp_selected_md"))
        self.export_menu.entryconfig(4, label=self.t("exp_current_md"))
        self.export_menu.entryconfig(6, label=self.t("hub_send_now"))
        self.notebook.tab(0, text=self.t("tab_online"))
        self.notebook.tab(1, text=self.t("tab_offline"))
        self.online_label.config(text=self.t("search_label"))
        self.offline_label.config(text=self.t("search_label"))
        self.online_search_btn.config(text=self.t("search_btn"))
        self.offline_find_btn.config(text=self.t("offline_find"))
        for b in (self.online_clear_btn, self.offline_clear_btn):
            b.config(text=self.t("clear_btn"))
        self.chk_headless.config(text=self.t("headless"))
        self.src_label.config(text=self.t("src_lbl"))
        self.chk_gov.config(text=self.t("src_gov"))
        self.chk_d2b.config(text=self.t("src_d2b"))
        self.chk_db.config(text=self.t("src_db"))
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
            tree.heading("#0", text=CHECK_ON)
        if hasattr(self, "tms_title_lbl"):
            self.tms_title_lbl.config(text=self.t("tms_bar_title"))
            self.tms_auto_chk.config(text=self.t("tms_auto"))
            self.tms_send_btn.config(text=self.t("tms_send"))
            self.tms_all_btn.config(text=CHECK_ON)
            self.tms_none_btn.config(text=CHECK_OFF)
            self.tms_cfg_btn.config(text=self.t("tms_settings"))
        if not self.status.get():
            self.status.set(self.t("status_ready"))

    def set_lang(self, code):
        self.lang = code
        self.retranslate()

    # ── интеграция с una.md (ERP) ──

    def _tms_config(self):
        if getattr(self, "_tms_cfg", None) is None:
            self._tms_cfg = tms_load_config()
        return self._tms_cfg

    def _start_hub_uploader(self):
        """Фоновая отправка локальной базы на хаб una.md (если настроен)."""
        self.hub_uploader = None
        cfg = self._tms_config()
        url = (cfg.get("hub_url") or "").strip()
        if not url:
            return
        try:
            import hub_client
        except Exception:  # noqa: BLE001
            return
        self.hub_uploader = hub_client.HubUploader(
            DB_PATH, url=url, api_key=cfg.get("hub_key") or None,
            interval=int(cfg.get("hub_interval") or 900), out_queue=self.queue)
        self.hub_uploader.start()

    def on_hub_send_now(self):
        """Отправить базу на хаб немедленно, не дожидаясь периода."""
        cfg = self._tms_config()
        url = (cfg.get("hub_url") or "").strip()
        if not url:
            messagebox.showinfo(self.t("tms_title"), self.t("hub_not_set"))
            return
        try:
            import hub_client
        except Exception as exc:  # noqa: BLE001
            messagebox.showerror(self.t("tms_title"), str(exc))
            return

        def worker():
            try:
                res = hub_client.upload_once(DB_PATH, url, cfg.get("hub_key") or None)
                self.queue.put(("hub_sent", res))
            except Exception as exc:  # noqa: BLE001
                self.queue.put(("hub_error", str(exc)))

        self.status.set(self.t("hub_sending"))
        threading.Thread(target=worker, daemon=True).start()

    def _on_tms_auto_toggle(self):
        # включение авто-режима не действует задним числом — только на будущие
        # результаты поиска; сообщим пользователю текущий режим в статусе.
        self.status.set(self.t("tms_auto_on") if self.tms_auto_var.get()
                        else self.t("tms_auto_off"))

    def _on_tms_check_all(self):
        self._set_all_checks(self._current_tree(), True)

    def _on_tms_check_none(self):
        self._set_all_checks(self._current_tree(), False)

    def on_tms_send_selected(self):
        """Отправить в una.md записи, отмеченные галочкой в текущей вкладке."""
        tree = self._current_tree()
        recs = [tree._recs[iid] for iid in tree._checked if iid in tree._recs]
        if not recs:
            messagebox.showinfo(self.t("tms_title"), self.t("tms_none_selected"))
            return
        self._tms_send(recs)

    def _tms_send(self, records):
        """Общий запуск асинхронной отправки списка записей в una.md."""
        if getattr(self, "_tms_worker", None) and self._tms_worker.is_alive():
            messagebox.showinfo(self.t("tms_title"), self.t("tms_busy"))
            return
        cfg = self._tms_config()
        if not cfg.get("password"):
            if not self._tms_settings_dialog():
                return
            cfg = self._tms_config()
            if not cfg.get("password"):
                return
        self._tms_stats = {"ok": 0, "dup": 0, "err": 0, "by_schema": {}}
        self.tms_progress.set(self.t("tms_progress_run", n=0, total=len(records)))
        self._tms_worker = TmsExportWorker(records, cfg, self.queue, TR[self.lang])
        self._tms_worker.start()

    def _on_tms_progress(self, payload):
        """Счёт ведём по схемам: одна запись даёт результат в каждой из них."""
        rep = payload["report"]
        st = self._tms_stats
        for name, res in (rep.get("targets") or {}).items():
            per = st["by_schema"].setdefault(name, {"ok": 0, "dup": 0, "err": 0})
            status = res.get("status")
            if status == "ok":
                per["ok"] += 1
                st["ok"] += 1
            elif status == "duplicate":
                per["dup"] += 1
                st["dup"] += 1
            else:
                per["err"] += 1
                st["err"] += 1
        self.tms_progress.set(self.t("tms_progress_run", n=payload["n"],
                                     total=payload["total"]))

    def _on_tms_done(self, payload):
        st = self._tms_stats
        self.tms_progress.set(self.t("tms_progress_done",
                                     ok=st["ok"], dup=st["dup"], err=st["err"]))
        # в статусе — разбивка по схемам: куда именно легло
        parts = [f"{name}: +{v['ok']}/={v['dup']}" + (f"/!{v['err']}" if v["err"] else "")
                 for name, v in st["by_schema"].items()]
        self.status.set(self.t("tms_result_multi", total=payload["total"],
                                schemas=";  ".join(parts) or "—"))

    def _tms_settings_dialog(self):
        """Диалог параметров подключения к una.md. Возвращает True при сохранении."""
        cfg = self._tms_config()
        win = tk.Toplevel(self)
        win.title(self.t("tms_settings_title"))
        win.transient(self)
        win.resizable(False, False)
        win.grab_set()
        frm = ttk.Frame(win, padding=14)
        frm.pack(fill="both", expand=True)
        fields = [("dsn", "tms_f_dsn", False), ("user", "tms_f_user", False),
                  ("password", "tms_f_pwd", True),
                  ("hub_schema_user", "tms_f_hub_user", False),
                  ("hub_schema_password", "tms_f_hub_pwd", True),
                  ("client_dir", "tms_f_client", False)]
        vars_ = {}
        for i, (key, lkey, secret) in enumerate(fields):
            ttk.Label(frm, text=self.t(lkey)).grid(row=i, column=0, sticky="w", pady=4)
            v = tk.StringVar(value=cfg.get(key, ""))
            vars_[key] = v
            ttk.Entry(frm, textvariable=v, width=42,
                      show="•" if secret else "").grid(row=i, column=1, pady=4, padx=(8, 0))
        saved = {"ok": False}

        def do_test():
            """Проверяем все настроенные схемы — и свою, и сводную."""
            self._tms_apply_cfg(vars_)
            try:
                import tms_multi
                targets = tms_multi.targets_from_config(self._tms_cfg)
                if not targets:
                    messagebox.showwarning(self.t("tms_settings_title"),
                                           self.t("tms_no_targets"), parent=win)
                    return
                mx = tms_multi.MultiExporter(targets).connect()
                lines = [f"{name}: {ver[:52]}" for name, ver in mx.ping_all().items()]
                mx.close()
                messagebox.showinfo(self.t("tms_settings_title"),
                                    "\n".join(lines), parent=win)
            except Exception as exc:  # noqa: BLE001
                messagebox.showerror(self.t("tms_settings_title"),
                                     str(exc), parent=win)

        def do_save():
            self._tms_apply_cfg(vars_)
            tms_save_config(self._tms_cfg)
            saved["ok"] = True
            win.destroy()

        btns = ttk.Frame(frm)
        btns.grid(row=len(fields), column=0, columnspan=2, pady=(12, 0), sticky="e")
        ttk.Button(btns, text=self.t("tms_test"), command=do_test).pack(side="left", padx=4)
        ttk.Button(btns, text=self.t("tms_save"), command=do_save).pack(side="left", padx=4)
        ttk.Button(btns, text=self.t("tms_cancel"),
                   command=win.destroy).pack(side="left", padx=4)
        win.wait_window()
        return saved["ok"]

    def _tms_apply_cfg(self, vars_):
        self._tms_cfg = {k: v.get().strip() for k, v in vars_.items()}

    # ── самопрезентация и самопроверка ──

    def _show_about(self):
        """Окно «О программе»: краткая самопрезентация возможностей приложения."""
        win = tk.Toplevel(self)
        win.title(self.t("about_title"))
        win.transient(self)
        win.resizable(False, False)
        txt = tk.Text(win, width=64, height=18, wrap="word", padx=8, pady=8)
        txt.insert("1.0", self.t("about_text", version=APP_VERSION, count=db_count()))
        txt.config(state="disabled")
        txt.pack(padx=12, pady=(12, 6), fill="both", expand=True)
        ttk.Button(win, text=self.t("mi_selftest"),
                   command=self._run_selftest_ui).pack(pady=(0, 12))
        win.grab_set()
        self._about_win = win
        return win

    def _run_selftest_ui(self):
        """Запускает встроенную самопроверку и показывает отчёт пользователю."""
        ok, report = run_selftest()
        (messagebox.showinfo if ok else messagebox.showwarning)(
            self.t("selftest_title"), report)

    # ── витрина ERP una.md ──

    def _open_una_site(self):
        import webbrowser
        webbrowser.open(UNA_URL)

    def _show_una(self):
        """Окно «Об ERP una.md»: чем платформа отличается от 1С и что даёт бизнесу.

        Contragenti — бесплатный инструмент экосистемы una.md, поэтому окно
        доступно из меню «Справка» и из баннера главного окна.
        """
        win = tk.Toplevel(self)
        win.title(self.t("una_title"))
        win.transient(self)
        win.resizable(False, False)

        head = ttk.Frame(win, padding=(16, 14, 16, 6))
        head.pack(fill="x")
        ttk.Label(head, text="una.md", font=("", 20, "bold"),
                  foreground=UNA_ACCENT).pack(anchor="w")
        ttk.Label(head, text=self.t("una_tagline"), font=("", 10),
                  foreground="#555").pack(anchor="w", pady=(2, 0))

        body = ttk.Frame(win, padding=(16, 4, 16, 8))
        body.pack(fill="both", expand=True)
        for key in ("una_p1", "una_p2", "una_p3"):
            ttk.Label(body, text=self.t(key), wraplength=560,
                      justify="left").pack(anchor="w", pady=(0, 8))

        adv = ttk.Labelframe(body, text=self.t("una_adv_title"), padding=10)
        adv.pack(fill="x", pady=(2, 6))
        for key in ("una_a1", "una_a2", "una_a3", "una_a4", "una_a5"):
            row = ttk.Frame(adv)
            row.pack(fill="x", anchor="w", pady=1)
            ttk.Label(row, text="•", foreground=UNA_ACCENT,
                      font=("", 11, "bold")).pack(side="left", padx=(0, 6))
            ttk.Label(row, text=self.t(key), wraplength=520,
                      justify="left").pack(side="left", anchor="w")

        ttk.Label(body, text=self.t("una_case"), wraplength=560, justify="left",
                  foreground="#333").pack(anchor="w", pady=(2, 0))

        btns = ttk.Frame(win, padding=(16, 0, 16, 14))
        btns.pack(fill="x")
        ttk.Button(btns, text=self.t("una_btn_site"),
                   command=self._open_una_site).pack(side="left")
        ttk.Button(btns, text=self.t("una_btn_connect"),
                   command=lambda: (win.destroy(), self._tms_settings_dialog())
                   ).pack(side="left", padx=6)
        ttk.Button(btns, text=self.t("tms_cancel"),
                   command=win.destroy).pack(side="right")
        win.grab_set()
        self._una_win = win
        return win

    # ── общие действия ──

    def _save_settings(self):
        """Запомнить состояние переключателей источников (settings.json)."""
        try:
            self.settings.update({
                "src_gov": bool(self.src_gov_var.get()),
                "src_d2b": bool(self.src_d2b_var.get()),
                "src_db": bool(self.src_db_var.get()),
                "headless": bool(self.headless_var.get()),
            })
            settings_save(self.settings)
        except Exception:  # noqa: BLE001
            pass          # настройки — не критичный ресурс, поиск важнее

    def _restart_app(self):
        """Перезапуск приложения: закрываем сервер и трей, стартуем себя заново.

        Новый процесс запускается тем же интерпретатором с теми же аргументами;
        порт освобождается до старта, иначе новый экземпляр его не займёт.
        """
        import subprocess
        self._save_settings()
        self.status.set(self.t("status_restart"))
        self.update_idletasks()
        self._alive = False
        try:
            if self.httpd:
                self.httpd.shutdown()
                self.httpd.server_close()
        except Exception:  # noqa: BLE001
            pass
        try:
            if self.tray_icon:
                self.tray_icon.stop()
        except Exception:  # noqa: BLE001
            pass
        if getattr(sys, "frozen", False):          # собранный exe
            cmd = [sys.executable] + sys.argv[1:]
        else:
            cmd = [sys.executable, os.path.abspath(__file__)] + sys.argv[1:]
        try:
            subprocess.Popen(cmd, cwd=os.getcwd(), close_fds=True)
        except Exception as exc:  # noqa: BLE001
            self._alive = True
            self.status.set(f"restart failed: {exc}")
            return
        self.destroy()

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
        use_gov = bool(self.src_gov_var.get())
        use_d2b = bool(self.src_d2b_var.get())
        self._gov_rows = None
        self._d2b_rows = None
        if not (use_gov or use_d2b):
            # оба онлайн-источника отключены — работаем по локальной базе
            records = db_query(query)
            self._populate(self.tree_online, records)
            self.status.set(self.t("status_sources_off"))
            return
        self._busy(True)
        self.status.set(self.t("status_search"))
        # Включённые источники опрашиваются параллельно: портал date.gov.md
        # (браузер, капча) и data2b.md (обычный HTTP). Кнопки разблокируются,
        # когда завершится последний из них.
        self._search_pending = 0
        if use_gov:
            self._search_pending += 1
            self.worker = BrowserWorker("search", query, self.queue, TR[self.lang],
                                        headless=self.headless_var.get(),
                                        shots_dir=getattr(self.args, "shots_dir", None))
            self.worker.start()
        if use_d2b:
            self._search_pending += 1
            self.d2b_worker = Data2bWorker(query, self.queue, TR[self.lang])
            self.d2b_worker.start()

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
                                    headless=self.headless_var.get(),
                                        shots_dir=getattr(self.args, "shots_dir", None))
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
                elif kind == "portal_no_data":
                    # портал ответил «Nu sunt date.» — сообщаем и не ждём таймаут
                    self.status.set(self.t("status_no_data", src=SOURCE_GOV))
                elif kind == "details_none":
                    self._on_details_none(payload)
                elif kind == "d2b_done":
                    self._on_d2b_done(payload)
                elif kind == "d2b_error":
                    # второй источник необязателен: не мешаем основному поиску
                    self._search_task_finished()
                    self.status.set(self.t("d2b_error", err=str(payload)[:90]))
                elif kind == "details_done":
                    self._on_details_done(payload)
                elif kind == "error":
                    self._busy(False)
                    self.status.set(self.t("status_error"))
                    if getattr(self, "_oneshot", False):
                        # one-shot (SDK): никаких модальных окон — ошибку в stderr,
                        # вызывающая программа увидит отсутствие XML и код выхода 3
                        sys.stderr.write(f"pick error: {payload}\n")
                        sys.stderr.flush()
                        self._oneshot = False
                        self._exit_code = 3
                        self.after(200, self.do_quit)
                    else:
                        messagebox.showerror(self.t("status_error"), payload)
                elif kind == "tms_progress":
                    self._on_tms_progress(payload)
                elif kind == "tms_done":
                    self._on_tms_done(payload)
                elif kind == "tms_error":
                    self.tms_progress.set("")
                    messagebox.showerror(self.t("tms_title"), payload)
                elif kind == "tms_warn":
                    self.status.set(self.t("tms_warn", err=str(payload)[:90]))
                elif kind == "hub_sent":
                    self.status.set(self.t("hub_sent", id=payload.get("batch_id", "?")))
                elif kind == "hub_error":
                    self.status.set(self.t("hub_error", err=str(payload)[:80]))
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

    def _search_task_finished(self):
        """Один из параллельных источников завершился; кнопки — когда оба."""
        self._search_pending = max(0, getattr(self, "_search_pending", 1) - 1)
        if self._search_pending == 0:
            self._busy(False)

    def _merge_rows(self, *groups):
        """Объединяет выдачи источников, дедуплицируя по IDNO (портал первым)."""
        merged, seen = [], set()
        for group in groups:
            for rec in group or []:
                key = (rec.get("idno") or "").strip() or "name:" + (rec.get("denumire") or "")
                if key in seen:
                    continue
                seen.add(key)
                merged.append(rec)
        return merged

    def _maybe_auto_pick(self, rows):
        """--pick --auto-pick: интеграционный тест SDK — вернуть первую найденную
        карточку без участия пользователя (детали дозагрузятся в resolve_pick)."""
        if not (getattr(self, "_oneshot", False)
                and getattr(self.args, "auto_pick", False) and rows):
            return
        if getattr(self, "_auto_pick_started", False):
            return
        first = (rows[0].get("idno") or "").strip()
        if first:
            self._auto_pick_started = True
            self.status.set(f"auto-pick → {first}")
            self.after(400, lambda: self._self_shot("sdk_3_contragenti_results"))
            self._auto_pick_when_idle(first)

    def _on_search_done(self, rows):
        for rec in rows:
            rec.setdefault("source", SOURCE_GOV)
        self._gov_rows = rows
        self._search_task_finished()
        db_save_search_rows(rows)
        self._refresh_title()
        if self.src_db_var.get():
            records = db_query(self.last_query)
            self._populate(self.tree_online, records)
            self.status.set(self.t("status_from_db", q=self.last_query,
                                    n=len(records), r=len(rows)))
        else:
            shown = self._merge_rows(rows, getattr(self, "_d2b_rows", None))
            self._populate(self.tree_online, shown)
            self.status.set(self.t("status_online", n=len(rows)))
        # авто-режим una.md: сразу отправить свежие результаты поиска
        if getattr(self, "tms_auto_var", None) and self.tms_auto_var.get() and rows:
            self._tms_send(rows)
        self._maybe_auto_pick(rows)

    def _on_d2b_done(self, payload):
        """Результат параллельного поиска на data2b.md."""
        rows = payload.get("rows") or []
        total = payload.get("total") or len(rows)
        query = payload.get("query") or self.last_query
        self._d2b_rows = rows
        self._search_task_finished()
        if rows:
            db_save_search_rows(rows)
            self._refresh_title()
        if self.src_db_var.get():
            self._populate(self.tree_online, db_query(query))
        else:
            self._populate(self.tree_online,
                           self._merge_rows(getattr(self, "_gov_rows", None), rows))
        self.status.set(self.t("status_d2b", n=len(rows), total=total, q=query)
                        if rows else self.t("status_d2b_none", q=query))
        # Портал уже ответил и ничего не дал (компании там нет) — в режиме SDK
        # отдаём то, что нашёл второй источник.
        if not (getattr(self, "_gov_rows", None) or []):
            self._maybe_auto_pick(rows)

    def _self_shot(self, name):
        """Снимок собственного окна (--shots-dir) через PrintWindow изнутри процесса."""
        shots_dir = getattr(self.args, "shots_dir", None)
        if not shots_dir:
            return
        try:
            os.makedirs(shots_dir, exist_ok=True)
            self.update_idletasks()
            capture_window_win32(self, os.path.join(shots_dir, f"{name}.png"))
        except Exception:  # noqa: BLE001
            pass

    def _auto_pick_when_idle(self, idno):
        """Ждём, пока поток поиска закроет Chrome: иначе resolve_pick решит,
        что воркер занят, и вернёт карточку без деталей (адрес, форма, долги)."""
        if self._worker_active():
            self.after(300, lambda: self._auto_pick_when_idle(idno))
        else:
            self.resolve_pick(idno)

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

    def _on_details_none(self, idno):
        """Портал не отдал карточку по этому IDNO (например 1007602003320).

        Ничего не ждём: показываем то, что уже есть в базе (например запись,
        найденную на data2b.md), и, если шёл возврат контрагента, завершаем его
        с имеющимися данными — вызывающая программа не должна зависать.
        """
        self._busy(False)
        rec = db_get(idno) or self.current_rec or {"idno": idno}
        self._show_detail(rec)
        self.status.set(self.t("status_details_none", idno=idno))
        if self.pick_after_details == idno:
            self.pick_after_details = None
            self._finish_pick(idno)

    # ── таблица / карточка ──

    def _populate(self, tree, records):
        for iid in tree.get_children():
            tree.delete(iid)
        tree._idno_map.clear()
        tree._recs.clear()
        tree._checked.clear()
        for rec in records:
            values = (rec.get("idno", "") or "", rec.get("denumire", "") or "",
                      rec.get("administratori", "") or "", rec.get("inregistrare", "") or "")
            iid = tree.insert("", "end", text=CHECK_OFF, values=values)
            tree._recs[iid] = rec
            if rec.get("idno"):
                tree._idno_map[iid] = rec["idno"]

    def _on_tree_click(self, tree, event):
        """Клик по колонке-галочке (#0) переключает отметку строки."""
        if tree.identify_region(event.x, event.y) != "tree":
            return
        iid = tree.identify_row(event.y)
        if not iid:
            return
        self._toggle_check(tree, iid)
        return "break"

    def _toggle_check(self, tree, iid):
        if iid in tree._checked:
            tree._checked.discard(iid)
            tree.item(iid, text=CHECK_OFF)
        else:
            tree._checked.add(iid)
            tree.item(iid, text=CHECK_ON)
        self._update_tms_count()

    def _current_tree(self):
        return self.tree_online if self.notebook.index("current") == 0 else self.tree_offline

    def _set_all_checks(self, tree, on):
        tree._checked.clear()
        for iid in tree.get_children():
            tree.item(iid, text=CHECK_ON if on else CHECK_OFF)
            if on:
                tree._checked.add(iid)
        self._update_tms_count()

    def _update_tms_count(self):
        if hasattr(self, "tms_send_btn"):
            n = len(self._current_tree()._checked)
            self.tms_send_btn.config(state=("normal" if n else "disabled"))
            self.tms_count.set(str(n) if n else "")

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
        q = (payload.get("q") or "").strip()
        # --auto-pick: сначала локальная база-кэш (полная карточка уже есть) —
        # портал не трогаем зря; на портал идём только если компании нет в кэше
        if self._oneshot and getattr(self.args, "auto_pick", False) and q:
            cached = [r for r in db_query(q) if r.get("details_text")]
            if cached:
                if payload.get("lang") in LANGS:
                    self.set_lang(payload["lang"])
                self._raise_window()
                self.online_entry.delete(0, "end")
                self.online_entry.insert(0, q)
                self.notebook.select(0)
                self._populate(self.tree_online, cached)
                self._show_return_button(True)
                idno = cached[0]["idno"]
                self._show_detail(cached[0])       # карточка видна на снимке возврата
                self.status.set(f"auto-pick (cache) → {idno}")
                self.after(500, lambda: self._self_shot("sdk_3_contragenti_results"))
                self.after(900, lambda: self.resolve_pick(idno))
                return
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
                                        headless=self.headless_var.get(),
                                        shots_dir=getattr(self.args, "shots_dir", None))
            self.worker.start()
        else:
            self._finish_pick(idno)

    def _finish_pick(self, idno):
        rec = db_get(idno) or self.current_rec or {"idno": idno}
        xml = build_card_xml(rec)
        self._self_shot("sdk_4_contragenti_card_return")
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


def run_selftest():
    """Автоматическая самопроверка ключевых подсистем без реального браузера.

    Возвращает (ok: bool, report: str) — пригодно и для CLI (--selftest),
    и для вызова из GUI (меню «Справка → Запустить самопроверку»).
    """
    checks = []

    def add(name, fn):
        try:
            fn()
            checks.append((name, True, ""))
        except Exception as exc:  # noqa: BLE001
            checks.append((name, False, str(exc)))

    def check_db():
        db_init()
        conn = db_connect()
        try:
            conn.execute("SELECT COUNT(*) FROM companies").fetchone()
        finally:
            conn.close()

    def check_i18n():
        for code in LANGS:
            assert TR[code].get("title"), f"missing 'title' for {code}"

    def check_xml_export():
        rec = {"idno": "0000000000000", "denumire": "SELFTEST S.R.L.", "updated_at": ""}
        xml = build_card_xml(rec)
        assert "<counterparty" in xml and "SELFTEST" in xml

    def check_network():
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", 0))
        finally:
            s.close()

    def check_html_parsers():
        html = "<table><tr><td>x</td><td>y</td></tr></table>"
        parse_tables(html)

    def check_tms():
        # интеграция с una.md: модуль импортируется и маппинг работает
        import tms_export
        m = tms_export.map_company({"denumire": "SELFTEST SRL", "idno": "0000000000000"})
        assert m["univers"]["DENUMIREA"] == "SELFTEST SRL"
        assert tms_export.iban_bank_prefix("MD24AG000225100013104168") == "AG"

    def check_data2b():
        # разбор ответа второго источника — на реальном образце выдачи сайта
        sample = {"count": 1, "results": [{
            "registered": None, "id": "1007602003320",
            "slug": "institutie-publica-colegiul-de-muzica-si-pedagogie-din-balti",
            "name": "INSTITUȚIE PUBLICĂ COLEGIUL DE MUZICĂ ȘI PEDAGOGIE DIN BĂLȚI",
            "idno": "1007602003320", "address": "MUN.BALTI Ciprian Porumbescu 18 ",
            "has_web_contacts": True, "has_phone_contacts": True}]}
        rows = data2b_parse(sample)
        assert len(rows) == 1, f"expected 1 row, got {len(rows)}"
        rec = rows[0]
        assert rec["idno"] == "1007602003320", rec["idno"]
        assert "COLEGIUL" in rec["denumire"], rec["denumire"]
        assert rec["adresa"] == "MUN.BALTI Ciprian Porumbescu 18", repr(rec["adresa"])
        assert rec["source"] == SOURCE_D2B, rec["source"]
        assert data2b_total(sample) == 1
        # тот же разбор из строки JSON и устойчивость к пустой выдаче
        assert data2b_parse(json.dumps(sample))[0]["idno"] == "1007602003320"
        assert data2b_parse({"count": 0, "results": []}) == []
        assert data2b_search("") == ([], 0)
        # источник попадает в XML карточки
        xml = build_card_xml({"idno": "1007602003320", "denumire": "X",
                              "source": SOURCE_D2B})
        assert f'source="{SOURCE_D2B}"' in xml, xml[:200]

    def check_settings():
        # запоминаемые источники поиска: запись → чтение → восстановление файла
        global SETTINGS_PATH
        keep = SETTINGS_PATH
        import tempfile
        SETTINGS_PATH = os.path.join(tempfile.mkdtemp(), "settings.json")
        try:
            defaults = settings_load()          # файла нет — значения по умолчанию
            assert defaults == {"src_gov": True, "src_d2b": True,
                                "src_db": True, "headless": False}, defaults
            assert settings_save({"src_gov": False, "src_d2b": True,
                                  "src_db": False, "headless": True})
            got = settings_load()
            assert got["src_gov"] is False and got["src_db"] is False, got
            assert got["src_d2b"] is True and got["headless"] is True, got
            with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
                f.write("{ broken")           # повреждённый файл не должен ронять
            assert settings_load()["src_gov"] is True
        finally:
            SETTINGS_PATH = keep

    add("database (SQLite)", check_db)
    add("i18n (en/ru/ro)", check_i18n)
    add("xml export", check_xml_export)
    add("network socket", check_network)
    add("html parsers", check_html_parsers)
    add("una.md mapping", check_tms)
    add("data2b.md search parsing", check_data2b)
    add("settings (search sources)", check_settings)

    ok = all(c[1] for c in checks)
    lines = ["Contragenti self-test: " + ("PASS" if ok else "FAIL"), ""]
    for name, passed, err in checks:
        lines.append(f"[{'OK' if passed else 'FAIL'}] {name}" + (f": {err}" if err else ""))
    return ok, "\n".join(lines)


def capture_window_win32(widget, path):
    """Снимок окна Tk через WinAPI PrintWindow.

    В отличие от захвата экрана (PIL.ImageGrab / CopyFromScreen), просит само
    окно отрисовать себя в память — поэтому работает и там, где рабочий стол
    недоступен: в отключённых RDP-сессиях, у служб, в CI и на headless-машинах.
    """
    import ctypes
    from ctypes import wintypes
    from PIL import Image

    user32 = ctypes.windll.user32
    gdi32 = ctypes.windll.gdi32
    PW_RENDERFULLCONTENT = 0x00000002

    # winfo_id() даёт дочерний Tk-холст; нужно окно верхнего уровня с рамкой
    hwnd = user32.GetParent(widget.winfo_id()) or widget.winfo_id()

    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if w <= 0 or h <= 0:
        raise RuntimeError("window has no size")

    hdc = user32.GetWindowDC(hwnd)
    memdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(memdc, bmp)
    try:
        if not user32.PrintWindow(hwnd, memdc, PW_RENDERFULLCONTENT):
            raise RuntimeError("PrintWindow failed")

        class BITMAPINFOHEADER(ctypes.Structure):
            _fields_ = [
                ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
                ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
                ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                ("biClrImportant", wintypes.DWORD),
            ]

        bi = BITMAPINFOHEADER()
        bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bi.biWidth = w
        bi.biHeight = -h  # отрицательная высота = строки сверху вниз
        bi.biPlanes = 1
        bi.biBitCount = 32
        bi.biCompression = 0  # BI_RGB

        buf = ctypes.create_string_buffer(w * h * 4)
        if not gdi32.GetDIBits(memdc, bmp, 0, h, buf, ctypes.byref(bi), 0):
            raise RuntimeError("GetDIBits failed")
        img = Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", 0, 1).convert("RGB")
    finally:
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(memdc)
        user32.ReleaseDC(hwnd, hdc)

    img.save(path)
    return img


# Предел размера окна демо. На виртуальном/отключённом рабочем столе система
# может сообщать размер экрана больше, чем область, которую драйвер реально
# отрисовывает; всё за её границей попадает в снимок пустым.
DEMO_MAX_W = int(os.environ.get("CONTRAGENTI_DEMO_W", "620"))
DEMO_MAX_H = int(os.environ.get("CONTRAGENTI_DEMO_H", "435"))


def run_demo(outdir, lang="ru"):
    """Самопрезентация: без участия пользователя открывает окна интерфейса
    с демонстрационными данными и сохраняет их скриншоты в outdir.
    """
    os.makedirs(outdir, exist_ok=True)

    db_init()
    # Если база пуста (первый запуск / чистая установка), кладём образец
    # реальной карточки с портала, чтобы демонстрация была наглядной.
    demo_idno = "1003600116460"
    if not db_get(demo_idno):
        conn = db_connect()
        try:
            db_upsert(conn, {
                "idno": demo_idno,
                "denumire": "CENTRUL DE ELABORARE ŞI IMPLEMENTARE A SISTEMELOR "
                            "INFORMAŢIONALE DE MANAGEMENT UNISIM-SOFT S.R.L.",
                "administratori": "TUHARI PAVEL [Administrator]",
                "inregistrare": "30.03.2001",
                "forma_juridica": "Societate cu răspundere limitată",
                "lichidata": "Nu",
                "adresa": "mun. Chişinău, sec. Buiucani, str. Alba-Iulia, 75/B",
                "founders_json": json.dumps(
                    [{"name": "TUHARI PAVEL", "share": "100,00"}], ensure_ascii=False),
                "debts_json": json.dumps([
                    {"nr": "1", "type": "Bugetul de stat și local", "sum": "0,00"},
                    {"nr": "2", "type": "Bugetul de stat", "sum": "0,98"},
                    {"nr": "3", "type": "Bugetul asigurărilor sociale de stat", "sum": "0,00"},
                ], ensure_ascii=False),
            })
            conn.commit()
        finally:
            conn.close()

    args = argparse.Namespace(port=9491, host="127.0.0.1", lang=lang, q=None,
                               pick=False, out=None, no_server=True, no_tray=True)
    app = App(args)
    # Окно не может быть больше рабочего стола (Windows обрезает его по
    # размеру экрана), а на маленьком экране содержимое не помещается в кадр.
    # Поэтому уменьшаем масштаб интерфейса Tk так, чтобы вся раскладка влезла.
    # Окно должно целиком помещаться в рабочий стол: за пределами экрана
    # содержимое не отрисовывается и в кадр попадает пустая область.
    app.update()
    scr_w, scr_h = app.winfo_screenwidth(), app.winfo_screenheight()
    if sys.platform == "win32":
        # Tk иногда сообщает размер виртуального рабочего стола, а реально
        # отрисовывается только область физического экрана — берём её.
        try:
            import ctypes
            scr_w = ctypes.windll.user32.GetSystemMetrics(0) or scr_w
            scr_h = ctypes.windll.user32.GetSystemMetrics(1) or scr_h
        except Exception:  # noqa: BLE001
            pass
    win_w = min(1120, scr_w - 24, DEMO_MAX_W)
    win_h = min(780, scr_h - 56, DEMO_MAX_H)
    app.minsize(200, 200)  # штатный minsize окна не даёт ужать его под кадр
    app.geometry(f"{win_w}x{win_h}")
    app.update()
    # Колонки таблицы подгоняем под фактическую ширину окна.
    weights = {"idno": 0.20, "denumire": 0.46, "administratori": 0.22,
               "inregistrare": 0.12}
    for tree in (app.tree_online, app.tree_offline):
        for col in COLUMNS:
            tree.column(col, width=max(60, int((win_w - 24) * weights.get(col, 0.2))))
    app.update()

    def shot(name, widget=None):
        target = widget or app
        app.update()
        target.deiconify()
        target.lift()
        for _ in range(10):
            app.update()
            time.sleep(0.05)
        path = os.path.join(outdir, name)
        # Основной способ — PrintWindow: работает без доступа к рабочему столу.
        try:
            capture_window_win32(target, path)
            print(f"  {name}: ok")
            return
        except Exception as exc:  # noqa: BLE001
            win32_err = exc
        # Резерв — обычный захват экрана (не-Windows или нестандартные случаи).
        try:
            from PIL import ImageGrab
            x, y = target.winfo_rootx(), target.winfo_rooty()
            w, h = target.winfo_width(), target.winfo_height()
            ImageGrab.grab(bbox=(x, y, x + w, y + h)).save(path)
            print(f"  {name}: ok (screen grab)")
        except Exception as exc:  # noqa: BLE001
            print(f"  {name}: skipped (PrintWindow: {win32_err}; grab: {exc})")

    def select_row(idno):
        for iid in app.tree_offline.get_children():
            if app.tree_offline._idno_map.get(iid) == idno:
                app.tree_offline.selection_set(iid)
                app.tree_offline.focus(iid)
                app.tree_offline.see(iid)
                app._on_row_select(app.tree_offline)
                return True
        return False

    app.notebook.select(0)
    shot("01_online.png")

    app.notebook.select(1)
    app.on_db_find()
    shot("02_db_list.png")

    select_row(demo_idno)
    shot("03_card.png")

    # Вторая карточка — показывает несколько учредителей с долями.
    app.offline_entry.delete(0, "end")
    app.offline_entry.insert(0, "ALFA-VIS")
    app.on_db_find()
    if not select_row("1017600018242"):
        kids = app.tree_offline.get_children()
        if kids:
            app.tree_offline.selection_set(kids[0])
            app._on_row_select(app.tree_offline)
    shot("04_card_search.png")

    about_win = app._show_about()
    shot("05_about.png", widget=about_win)

    ok, report = run_selftest()
    print(report)
    report_win = tk.Toplevel(app)
    report_win.title(app.t("selftest_title"))
    report_win.transient(app)
    report_txt = tk.Text(report_win, width=60, height=10, wrap="word", padx=8, pady=8)
    report_txt.insert("1.0", report)
    report_txt.config(state="disabled")
    report_txt.pack(padx=12, pady=12, fill="both", expand=True)
    shot("06_selftest.png", widget=report_win)
    report_win.destroy()
    about_win.destroy()

    app.destroy()
    print(f"Demo screenshots saved to: {outdir}")
    return ok


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Contragenti — date.gov.md company search")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="HTTP API port")
    ap.add_argument("--host", default="127.0.0.1", help="HTTP API host")
    ap.add_argument("--lang", default="ru", choices=LANGS, help="UI language")
    ap.add_argument("--q", default=None, help="initial search filter")
    ap.add_argument("--pick", action="store_true",
                    help="one-shot: wait for selection, output XML to --out/stdout, quit")
    ap.add_argument("--out", default=None, help="file to write returned XML (with --pick)")
    ap.add_argument("--auto-pick", action="store_true",
                    help="with --pick: return the first search result automatically "
                         "(for SDK integration tests)")
    ap.add_argument("--shots-dir", default=None,
                    help="with --pick: save portal/browser and own-window screenshots "
                         "(sdk_*.png) to this directory for the caller's test report")
    ap.add_argument("--no-data2b", action="store_true",
                    help="do not search data2b.md in parallel with date.gov.md")
    ap.add_argument("--no-server", action="store_true", help="do not start HTTP API")
    ap.add_argument("--no-tray", action="store_true", help="do not create tray icon")
    ap.add_argument("--selftest", action="store_true",
                    help="run internal self-test (db/i18n/xml/network) and exit")
    ap.add_argument("--demo", action="store_true",
                    help="run unattended self-presentation demo, save screenshots, and exit")
    ap.add_argument("--demo-dir", default="demo_screenshots",
                    help="output folder for --demo screenshots")
    return ap.parse_args(argv)


if __name__ == "__main__":
    cli_args = parse_args()
    if cli_args.selftest:
        _ok, _report = run_selftest()
        print(_report)
        sys.exit(0 if _ok else 1)
    if cli_args.demo:
        sys.exit(0 if run_demo(cli_args.demo_dir, cli_args.lang) else 1)
    App(cli_args).mainloop()
