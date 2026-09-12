# -*- coding: utf-8 -*-
"""
Окно имитатора FiscalCloud.

Показывает то же, что видно у кассы: реквизиты устройства, состояние смены,
выданные документы с печатной формой и журнал обращений кассового
приложения. Отсюда же можно снять X- и Z-отчёт, переключить «Bon de plata»
и доступность сервера налоговой — то есть проверить поведение кассы в
условиях, которые на живом оборудовании не воспроизведёшь.

Окно не обязательно: на сервере программа работает без него
(`python -m pos_bridge.fc_emulator serve`).
"""

import queue
import threading

try:
    import tkinter as tk
    from tkinter import ttk
except ImportError:  # noqa: BLE001 — на сервере tkinter не нужен
    tk = None
    ttk = None

from . import printforms as pf
from . import settings as cfg_mod
from .server import make_report
from .service import Emulator, setup_logging
from .state import PAYMENT_TYPES, STATE, TAX_GROUPS, human

KIND_TITLES = {
    "receipt": "Фискальный чек",
    "return": "Возврат",
    "alternative": "Bon de plata",
    "nonfiscal": "Нефискальный",
    "report": "Отчёт",
    "cashoperation": "Касса",
}


def available():
    return tk is not None


class EmulatorWindow:
    def __init__(self, cfg=None):
        self.cfg = cfg or cfg_mod.load()
        setup_logging(self.cfg.get("logPath") or "")
        self.emulator = Emulator(self.cfg)
        self.messages = queue.Queue()
        self.root = tk.Tk()
        self.root.title("Имитатор FiscalCloud · касса Sunmi / SoftLider")
        self.root.geometry("1080x720")
        self.root.minsize(940, 600)
        self._docs_index = {}
        self._build()
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.refresh()
        self.root.after(200, self._pump)

    # ── интерфейс ──

    def _build(self):
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass

        top = ttk.Frame(self.root, padding=(10, 8))
        top.pack(fill="x")
        ttk.Label(top, text="Адрес").pack(side="left")
        self.host_var = tk.StringVar(value=self.cfg.get("host") or "127.0.0.1")
        ttk.Entry(top, textvariable=self.host_var, width=14).pack(side="left", padx=(6, 2))
        ttk.Label(top, text=":").pack(side="left")
        self.port_var = tk.StringVar(value=str(self.cfg.get("port") or 50700))
        ttk.Entry(top, textvariable=self.port_var, width=7).pack(side="left", padx=(2, 10))
        self.btn_start = ttk.Button(top, text="Запустить", command=self.on_start)
        self.btn_start.pack(side="left")
        self.btn_stop = ttk.Button(top, text="Остановить", command=self.on_stop, state="disabled")
        self.btn_stop.pack(side="left", padx=6)
        self.status = ttk.Label(top, text="остановлен", foreground="#a00")
        self.status.pack(side="left", padx=12)
        ttk.Button(top, text="X-отчёт", command=lambda: self.on_report("XReport")).pack(side="right")
        ttk.Button(top, text="Z-отчёт (закрыть день)",
                   command=lambda: self.on_report("ZReport")).pack(side="right", padx=6)

        body = ttk.Frame(self.root, padding=(10, 0))
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=0, minsize=320)
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=3)
        body.rowconfigure(1, weight=2)

        # ── слева: устройство и поведение ──
        left = ttk.Frame(body)
        left.grid(row=0, column=0, rowspan=2, sticky="nsew", padx=(0, 10), pady=(6, 8))

        dev = ttk.LabelFrame(left, text="Устройство", padding=8)
        dev.pack(fill="x")
        self.dev_vars = {}
        fields = [("organizationName", "Организация"), ("idnx", "IDNO"), ("address", "Адрес"),
                  ("serialNumber", "Серийный №"), ("model", "Модель")]
        for i, (key, title) in enumerate(fields):
            ttk.Label(dev, text=title).grid(row=i, column=0, sticky="w", pady=1)
            var = tk.StringVar(value=str((self.cfg.get("device") or {}).get(key, "")))
            ttk.Entry(dev, textvariable=var, width=28).grid(row=i, column=1, sticky="ew", pady=1)
            self.dev_vars[key] = var
        dev.columnconfigure(1, weight=1)

        keys = ttk.LabelFrame(left, text="Ключи кассового приложения", padding=8)
        keys.pack(fill="x", pady=(8, 0))
        self.key_var = tk.StringVar(value=self.cfg.get("apiKey", ""))
        self.secret_var = tk.StringVar(value=self.cfg.get("apiSecret", ""))
        ttk.Label(keys, text="Api-Key").grid(row=0, column=0, sticky="w")
        ttk.Entry(keys, textvariable=self.key_var, width=28).grid(row=0, column=1, sticky="ew")
        ttk.Label(keys, text="Api-Secret").grid(row=1, column=0, sticky="w")
        ttk.Entry(keys, textvariable=self.secret_var, width=28, show="•").grid(row=1, column=1, sticky="ew")
        keys.columnconfigure(1, weight=1)

        mode = ttk.LabelFrame(left, text="Поведение кассы", padding=8)
        mode.pack(fill="x", pady=(8, 0))
        self.alt_var = tk.BooleanVar(value=bool(self.cfg.get("useAlternativeReceipts")))
        self.online_var = tk.BooleanVar(value=bool(self.cfg.get("taxAuthorityOnline", True)))
        ttk.Checkbutton(mode, text="Разрешены «Bon de plata»", variable=self.alt_var,
                        command=self.on_mode).pack(anchor="w")
        ttk.Checkbutton(mode, text="Сервер налоговой доступен", variable=self.online_var,
                        command=self.on_mode).pack(anchor="w")
        ttk.Label(mode, text="Снимите вторую галочку, чтобы продажа в режиме\n"
                             "FiscalThenAlternativeReceipt ушла в «Bon de plata».",
                  foreground="#666", justify="left").pack(anchor="w", pady=(4, 0))

        tax = ttk.LabelFrame(left, text="Группы НДС и виды оплат", padding=8)
        tax.pack(fill="x", pady=(8, 0))
        self.tax_label = ttk.Label(tax, text="", justify="left")
        self.tax_label.pack(anchor="w")

        actions = ttk.Frame(left)
        actions.pack(fill="x", pady=(10, 0))
        ttk.Button(actions, text="Сохранить настройки", command=self.on_save_settings).pack(side="left")
        ttk.Button(actions, text="Сбросить состояние", command=self.on_reset).pack(side="left", padx=6)

        self.hint = ttk.Label(left, text="", foreground="#046", wraplength=300, justify="left")
        self.hint.pack(fill="x", pady=(10, 0))

        # ── справа сверху: смена и документы ──
        right = ttk.Frame(body)
        right.grid(row=0, column=1, sticky="nsew", pady=(6, 4))
        right.rowconfigure(1, weight=1)
        right.columnconfigure(0, weight=1)

        self.shift_label = ttk.Label(right, text="", justify="left")
        self.shift_label.grid(row=0, column=0, sticky="w", pady=(0, 6))

        panes = ttk.Panedwindow(right, orient="horizontal")
        panes.grid(row=1, column=0, sticky="nsew")
        docs_frame = ttk.Frame(panes)
        self.docs = ttk.Treeview(docs_frame, columns=("kind", "number", "time", "total"),
                                 show="headings", height=12)
        for col, title, width in (("kind", "Документ", 130), ("number", "№", 80),
                                  ("time", "Время", 150), ("total", "Сумма", 90)):
            self.docs.heading(col, text=title)
            self.docs.column(col, width=width, anchor="w" if col in ("kind", "time") else "e")
        scroll = ttk.Scrollbar(docs_frame, orient="vertical", command=self.docs.yview)
        self.docs.configure(yscrollcommand=scroll.set)
        self.docs.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.docs.bind("<<TreeviewSelect>>", self.on_pick_doc)
        panes.add(docs_frame, weight=3)

        form_frame = ttk.Frame(panes)
        ttk.Label(form_frame, text="Печатная форма").pack(anchor="w")
        self.form = tk.Text(form_frame, width=42, height=12, wrap="none",
                            font=("Menlo", 10) if tk else None)
        self.form.pack(fill="both", expand=True)
        panes.add(form_frame, weight=2)

        # ── справа снизу: журнал ──
        low = ttk.Frame(body)
        low.grid(row=1, column=1, sticky="nsew", pady=(4, 8))
        low.rowconfigure(1, weight=1)
        low.columnconfigure(0, weight=1)
        ttk.Label(low, text="Журнал обращений кассового приложения").grid(row=0, column=0, sticky="w")
        self.journal = ttk.Treeview(low, columns=("time", "method", "path", "status"),
                                    show="headings", height=7)
        for col, title, width in (("time", "Время", 150), ("method", "Метод", 70),
                                  ("path", "Точка", 420), ("status", "Код", 60)):
            self.journal.heading(col, text=title)
            self.journal.column(col, width=width, anchor="w" if col != "status" else "center")
        jscroll = ttk.Scrollbar(low, orient="vertical", command=self.journal.yview)
        self.journal.configure(yscrollcommand=jscroll.set)
        self.journal.grid(row=1, column=0, sticky="nsew")
        jscroll.grid(row=1, column=1, sticky="ns")

    # ── действия ──

    def say(self, text):
        self.hint.configure(text=text)

    def collect_settings(self):
        self.cfg["host"] = self.host_var.get().strip() or "127.0.0.1"
        try:
            self.cfg["port"] = int(self.port_var.get().strip() or 50700)
        except ValueError:
            self.cfg["port"] = 50700
            self.port_var.set("50700")
        self.cfg["apiKey"] = self.key_var.get().strip()
        self.cfg["apiSecret"] = self.secret_var.get().strip()
        self.cfg.setdefault("device", {})
        for key, var in self.dev_vars.items():
            self.cfg["device"][key] = var.get().strip()
        self.cfg["useAlternativeReceipts"] = bool(self.alt_var.get())
        self.cfg["taxAuthorityOnline"] = bool(self.online_var.get())
        return self.cfg

    def on_start(self):
        if self.emulator.running:
            return
        self.emulator.cfg = self.collect_settings()
        try:
            self.emulator.start()
        except OSError as exc:
            self.say("Не удалось занять порт: %s" % exc)
            return
        self.btn_start.configure(state="disabled")
        self.btn_stop.configure(state="normal")
        self.say("Касса отвечает на %s. Описание API — %s/openapi.json"
                 % (self.emulator.address, self.emulator.address))
        self.refresh()

    def on_stop(self):
        self.emulator.stop()
        self.btn_start.configure(state="normal")
        self.btn_stop.configure(state="disabled")
        self.say("Остановлен, состояние сохранено: %s" % self.emulator.state_path)
        self.refresh()

    def on_mode(self):
        STATE.use_alternative_receipts = bool(self.alt_var.get())
        STATE.tax_authority_online = bool(self.online_var.get())
        self.say("Сервер налоговой: %s; «Bon de plata»: %s"
                 % ("доступен" if STATE.tax_authority_online else "недоступен",
                    "разрешены" if STATE.use_alternative_receipts else "запрещены"))

    def on_save_settings(self):
        path = cfg_mod.save(self.collect_settings())
        self.say("Настройки сохранены: %s\nОни вступят в силу при следующем запуске сервера." % path)

    def on_report(self, kind):
        doc = make_report(kind)
        self.emulator.save_state()
        self.say("Снят %s №%s на сумму %s MDL"
                 % ("Z-отчёт" if kind == "ZReport" else "X-отчёт",
                    doc["numberPresentation"], pf.money(doc["totalAmount"])))
        self.refresh()

    def on_reset(self):
        STATE.reset()
        self.emulator.save_state()
        self.say("Состояние сброшено: номера с единицы, смена открыта заново.")
        self.refresh()

    def on_pick_doc(self, _event=None):
        sel = self.docs.selection()
        if not sel:
            return
        kind, doc_id = self._docs_index.get(sel[0], (None, None))
        doc = STATE.find(kind, doc_id) if kind else None
        if not doc:
            return
        rows = (pf.report_rows(doc, STATE.device()) if kind == "report"
                else pf.receipt_rows(doc, STATE.device(), KIND_TITLES.get(kind, "BON")))
        self.form.delete("1.0", "end")
        self.form.insert("1.0", "\n".join(pf.text_rows(rows)))

    def on_close(self):
        if self.emulator.running:
            self.emulator.stop()
        self.root.destroy()

    # ── обновление ──

    def refresh(self):
        running = self.emulator.running
        self.status.configure(text="работает · %s" % self.emulator.address if running else "остановлен",
                              foreground="#070" if running else "#a00")
        self.btn_start.configure(state="disabled" if running else "normal")
        self.btn_stop.configure(state="normal" if running else "disabled")

        sh = STATE.shift
        self.shift_label.configure(text=(
            "Смена открыта %s · чеков %d на %s MDL · наличные в ящике %s MDL\n"
            "Сквозные номера: чеки %d, возвраты %d, отчёты %d · накопительно %s MDL"
            % (human(sh.opened_at), sh.receipt_count, pf.money(sh.total), pf.money(sh.balance),
               STATE.numbers.get("receipt", 0), STATE.numbers.get("return", 0),
               STATE.numbers.get("report", 0), pf.money(STATE.grand_total + sh.total))))

        self.tax_label.configure(text=(
            "НДС: " + ", ".join("%s %g%%" % (g["code"], g["rate"]) for g in TAX_GROUPS)
            + "\nОплаты: " + ", ".join("%d %s" % (p["code"], p["name"]) for p in PAYMENT_TYPES)))

        rows = []
        for kind, docs in STATE.documents.items():
            for d in docs:
                rows.append((d.get("dateTime") or "", kind, d))
        rows.sort(key=lambda r: r[0], reverse=True)
        self.docs.delete(*self.docs.get_children())
        self._docs_index = {}
        for _dt, kind, d in rows[:300]:
            amount = d.get("totalAmount", d.get("amount", 0))
            item = self.docs.insert("", "end", values=(
                KIND_TITLES.get(kind, kind), d.get("numberPresentation") or "",
                d.get("dateTimePresentation") or "", pf.money(amount)))
            self._docs_index[item] = (kind, d.get("id"))

        self.journal.delete(*self.journal.get_children())
        for entry in reversed(STATE.requests[-200:]):
            self.journal.insert("", "end", values=(entry["time"], entry["method"],
                                                   entry["path"], entry["status"]))

    def _pump(self):
        try:
            self.refresh()
        finally:
            self.root.after(1500, self._pump)

    def run(self, autostart=True):
        if autostart:
            self.on_start()
        self.root.mainloop()


def run(cfg=None, autostart=True):
    if not available():
        raise RuntimeError("нет tkinter: на сервере запускайте без окна — "
                           "python -m pos_bridge.fc_emulator serve")
    EmulatorWindow(cfg).run(autostart=autostart)
