# -*- coding: utf-8 -*-
"""
Запись организаций сразу в несколько схем una.md.

У каждого предприятия своя схема в общей базе (ARTIMA, DULCINELLA, …), а
PARALAX выступает сводным справочником хаба. Найденный контрагент нужен и
там, и там, поэтому экспорт умеет работать по списку целей.

Цели независимы: сбой или недоступность одной не отменяет запись в другие —
каждая схема получает свою транзакцию и свой результат в отчёте.

    targets = [
        {"name": "своя схема", "user": "ARTIMA", "password": "...", "dsn": "..."},
        {"name": "хаб",        "user": "paralax", "password": "...", "dsn": "..."},
    ]
    with MultiExporter(targets) as mx:
        report = mx.export_one(rec)
"""

import tms_export


class MultiExporter:
    """Экспорт одной записи в несколько схем одновременно."""

    def __init__(self, targets):
        """targets — список словарей с ключами name/user/password/dsn/client_dir."""
        self.targets = [t for t in targets if t.get("password")]
        self.exporters = {}      # name → TmsExporter
        self.errors = {}         # name → текст ошибки подключения

    def connect(self):
        for t in self.targets:
            name = t.get("name") or t.get("user") or "?"
            try:
                self.exporters[name] = tms_export.TmsExporter(t).connect()
            except Exception as exc:  # noqa: BLE001
                # недоступность одной схемы не должна ронять остальные
                self.errors[name] = str(exc).splitlines()[0]
        return self

    def close(self):
        for exp in self.exporters.values():
            exp.close()
        self.exporters.clear()

    def __enter__(self):
        return self.connect()

    def __exit__(self, *a):
        self.close()

    @property
    def ready(self):
        return list(self.exporters)

    def ping_all(self):
        out = {}
        for name, exp in self.exporters.items():
            try:
                out[name] = exp.ping()
            except Exception as exc:  # noqa: BLE001
                out[name] = f"ошибка: {str(exc).splitlines()[0]}"
        for name, err in self.errors.items():
            out[name] = f"нет подключения: {err}"
        return out

    def export_one(self, rec, dry_run=False):
        """Отправить запись во все доступные схемы. Вернуть отчёт по каждой."""
        report = {"targets": {}, "ok": 0, "duplicate": 0, "error": 0}
        for name, err in self.errors.items():
            report["targets"][name] = {"status": "unreachable", "error": err}
            report["error"] += 1
        for name, exp in self.exporters.items():
            try:
                res = exp.export_one(rec, dry_run=dry_run)
            except Exception as exc:  # noqa: BLE001
                report["targets"][name] = {"status": "error", "error": str(exc)}
                report["error"] += 1
                continue
            report["targets"][name] = res
            if res["status"] in ("ok", "dry_run"):
                report["ok"] += 1
            elif res["status"] == "duplicate":
                report["duplicate"] += 1
            else:
                report["error"] += 1
        return report

    def export_many(self, records, dry_run=False, progress=None):
        """Пакетная отправка. progress(i, total, report) — необязательный колбэк."""
        results = []
        for i, rec in enumerate(records, 1):
            rep = self.export_one(rec, dry_run=dry_run)
            results.append(rep)
            if progress:
                progress(i, len(records), rep)
        return results


def targets_from_config(cfg):
    """Собрать список целей из конфига приложения.

    Основная цель — та, что задана в tms_config (обычно своя схема).
    Дополнительные перечисляются в ключе "extra_targets".
    """
    targets = []
    if cfg.get("password"):
        targets.append({
            "name": cfg.get("target_name") or cfg.get("user") or "основная",
            "user": cfg.get("user"), "password": cfg.get("password"),
            "dsn": cfg.get("dsn"), "client_dir": cfg.get("client_dir", ""),
        })
    # сводная схема хаба — вторая цель того же экспорта
    if cfg.get("hub_schema_user") and cfg.get("hub_schema_password"):
        targets.append({
            "name": cfg["hub_schema_user"],
            "user": cfg["hub_schema_user"], "password": cfg["hub_schema_password"],
            "dsn": cfg.get("hub_schema_dsn") or cfg.get("dsn"),
            "client_dir": cfg.get("client_dir", ""),
        })
    for extra in cfg.get("extra_targets") or []:
        if not extra.get("password"):
            continue
        targets.append({
            "name": extra.get("name") or extra.get("user"),
            "user": extra.get("user"), "password": extra.get("password"),
            "dsn": extra.get("dsn") or cfg.get("dsn"),
            "client_dir": extra.get("client_dir") or cfg.get("client_dir", ""),
        })
    return targets
