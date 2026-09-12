# -*- coding: utf-8 -*-
"""
Запуск имитатора как программы: и службой на сервере, и из окна.

Состояние подхватывается при старте и сохраняется при остановке и по
таймеру — сквозные номера и накопительные суммы переживают перезапуск,
как у настоящей кассы.
"""

import logging
import os
import threading
import time

from .server import build_app, configure
from .state import STATE

LOG = logging.getLogger("fiscalcloud-emulator")


def setup_logging(log_path="", level=logging.INFO):
    LOG.setLevel(level)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")
    if not any(isinstance(h, logging.StreamHandler) for h in LOG.handlers):
        stream = logging.StreamHandler()
        stream.setFormatter(fmt)
        LOG.addHandler(stream)
    if log_path:
        os.makedirs(os.path.dirname(os.path.abspath(log_path)) or ".", exist_ok=True)
        have = any(getattr(h, "baseFilename", "") == os.path.abspath(log_path) for h in LOG.handlers)
        if not have:
            fh = logging.FileHandler(log_path, encoding="utf-8")
            fh.setFormatter(fmt)
            LOG.addHandler(fh)
    return LOG


class Emulator:
    """Сервер имитатора, которым можно управлять из окна и из службы."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.server = None
        self.thread = None
        self._saver = None
        self._stop_saver = threading.Event()
        self._last_save = 0.0
        self._dirty = False

    # ── состояние ──

    @property
    def state_path(self):
        return self.cfg.get("statePath") or ""

    def load_state(self):
        if STATE.load_from(self.state_path):
            LOG.info("состояние восстановлено: %s", self.state_path)
            return True
        return False

    def save_state(self):
        try:
            if STATE.save_to(self.state_path):
                return True
        except OSError as exc:
            LOG.warning("состояние не сохранено: %s", exc)
        return False

    def _on_change(self):
        """Сохранение после изменяющего запроса, но не чаще раза в секунду."""
        now_ts = time.time()
        if now_ts - self._last_save < 1.0:
            self._dirty = True
            return
        self._last_save = now_ts
        self._dirty = False
        self.save_state()

    def _save_loop(self):
        every = max(5, int(self.cfg.get("saveEverySeconds") or 20))
        while not self._stop_saver.wait(every):
            if self._dirty:
                self._dirty = False
                self._last_save = time.time()
            self.save_state()

    # ── сервер ──

    @property
    def running(self):
        return bool(self.server and not self.server.should_exit and self.thread and self.thread.is_alive())

    @property
    def address(self):
        return "http://%s:%s" % (self.cfg.get("host") or "127.0.0.1", self.cfg.get("port") or 50700)

    def start(self, blocking=False):
        import uvicorn
        configure(self.cfg)
        self.load_state()
        app = build_app()
        config = uvicorn.Config(app, host=self.cfg.get("host") or "127.0.0.1",
                                port=int(self.cfg.get("port") or 50700),
                                log_level="warning", access_log=False)
        self.server = uvicorn.Server(config)
        STATE.on_change = self._on_change
        self._stop_saver.clear()
        self._saver = threading.Thread(target=self._save_loop, daemon=True)
        self._saver.start()
        LOG.info("имитатор FiscalCloud слушает %s", self.address)
        if blocking:
            try:
                self.server.run()
            finally:
                self.stop()
            return None
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        for _ in range(100):
            if getattr(self.server, "started", False):
                break
            time.sleep(0.05)
        return self.thread

    def stop(self):
        STATE.on_change = None
        self._stop_saver.set()
        if self.server:
            self.server.should_exit = True
        if self.thread:
            self.thread.join(timeout=5)
        self.save_state()
        LOG.info("имитатор остановлен, состояние сохранено")
        self.server = None
        self.thread = None


def install_signal_handlers(emulator):
    """SIGTERM/SIGINT — остановка со сохранением (для systemctl stop)."""
    import signal

    def handler(signum, _frame):
        LOG.info("сигнал %s — останавливаемся", signum)
        emulator.save_state()
        if emulator.server:
            emulator.server.should_exit = True

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, handler)
        except (ValueError, OSError):
            pass


# ── служба systemd ──

UNIT = """[Unit]
Description=FiscalCloud emulator (SoftLider API) for POS testing
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%(user)s
Environment=FC_EMULATOR_CONFIG=%(config)s
ExecStart=%(python)s -m pos_bridge.fc_emulator serve
WorkingDirectory=%(workdir)s
Restart=on-failure
RestartSec=3
# имитатор ничего не пишет вне своего каталога
ProtectSystem=full
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
"""


def unit_text(python=None, config=None, workdir=None, user=None):
    import getpass
    import sys
    return UNIT % {
        "python": python or sys.executable,
        "config": config or os.environ.get("FC_EMULATOR_CONFIG", "/etc/fiscalcloud-emulator/config.json"),
        "workdir": workdir or os.getcwd(),
        "user": user or getpass.getuser(),
    }
