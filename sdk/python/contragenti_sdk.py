"""SDK-обёртка вызова Contragenti из другого Python-приложения.

Полный контракт (флаги CLI, формат XML, куда класть поля) — в
../../INTEGRATION.md. Единственная зависимость — стандартная библиотека.

Пример:
    from contragenti_sdk import pick_counterparty

    card = pick_counterparty(q="UNISIM", lang="ru")
    if card is None:
        print("пользователь отменил выбор")
    else:
        print(card["idno"], card["denumire"])
        for f in card["founders"]:
            print("  founder:", f["name"], f["share"])
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field


class ContragentiTimeout(Exception):
    """Пользователь не успел выбрать контрагента за отведённое время."""


class ContragentiError(Exception):
    """Contragenti завершился с ошибкой (см. .stderr)."""

    def __init__(self, message: str, stderr: str = ""):
        super().__init__(message)
        self.stderr = stderr


@dataclass
class Founder:
    name: str
    share: str


@dataclass
class Debt:
    nr: str
    type: str
    sum: str


@dataclass
class CounterpartyCard:
    idno: str
    denumire: str
    inregistrare: str = ""
    forma_juridica: str = ""
    lichidata: str = ""
    adresa: str = ""
    administratori: str = ""
    details_text: str = ""
    founders: list = field(default_factory=list)   # list[Founder]
    debts: list = field(default_factory=list)       # list[Debt]
    debts_currency: str = ""

    def __getitem__(self, key):
        # удобный доступ как к словарю: card["idno"] тоже работает
        return getattr(self, key)


def _resolve_launcher(launcher: str | None) -> list:
    """Определяет команду запуска: готовый Contragenti.exe/бинарник,
    либо запуск исходника через python того же интерпретатора, что и текущий
    процесс (или через venv рядом со скриптом, если он есть)."""
    if launcher is None:
        # по умолчанию — company_search.py в корне репозитория
        here = os.path.dirname(os.path.abspath(__file__))
        launcher = os.path.normpath(os.path.join(here, "..", "..", "company_search.py"))

    if launcher.lower().endswith(".py"):
        venv_py = os.path.join(os.path.dirname(launcher), ".venv", "Scripts", "python.exe")
        py = venv_py if os.path.exists(venv_py) else sys.executable
        return [py, launcher]
    return [launcher]


def pick_counterparty(
    q: str = "",
    lang: str = "ru",
    launcher: str | None = None,
    timeout_sec: int = 300,
    extra_args: list | None = None,
) -> CounterpartyCard | None:
    """Запускает Contragenti в режиме одноразового выбора и возвращает карточку.

    Args:
        q: стартовый фильтр поиска (название, IDNO или руководитель).
        lang: язык окна — "ru" / "ro" / "en".
        launcher: путь к Contragenti.exe или к company_search.py; если не
            задан — берётся company_search.py из корня репозитория.
        timeout_sec: сколько ждать выбора пользователем.
        extra_args: дополнительные флаги CLI (например ["--auto-pick"]).

    Returns:
        CounterpartyCard, если пользователь выбрал контрагента, иначе None
        (окно закрыто без выбора).

    Raises:
        ContragentiTimeout: истёк timeout_sec.
        ContragentiError: процесс завершился с ошибкой.
    """
    cmd = _resolve_launcher(launcher)
    with tempfile.TemporaryDirectory(prefix="contragenti_pick_") as tmp:
        out_file = os.path.join(tmp, "card.xml")
        cmd += ["--pick", "--out", out_file, "--lang", lang,
                "--no-server", "--no-tray"]
        if q:
            cmd += ["--q", q]
        if extra_args:
            cmd += extra_args

        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout_sec + 5,
            )
        except subprocess.TimeoutExpired as exc:
            raise ContragentiTimeout(
                f"Contragenti не завершился за {timeout_sec + 5} с"
            ) from exc

        if proc.returncode != 0:
            raise ContragentiError(
                f"Contragenti завершился с кодом {proc.returncode}", proc.stderr
            )

        if not os.path.exists(out_file):
            return None  # пользователь закрыл окно без выбора

        return parse_card_xml(open(out_file, encoding="utf-8").read())


def parse_card_xml(xml_text: str) -> CounterpartyCard:
    """Разбирает XML-карточку (из файла --out или из HTTP-ответа /pick)."""
    root = ET.fromstring(xml_text)

    def text(tag: str) -> str:
        node = root.find(tag)
        return (node.text or "").strip() if node is not None else ""

    founders = [
        Founder(name=f.get("name", ""), share=f.get("share", ""))
        for f in root.findall("./founders/founder")
    ]
    debts_node = root.find("./debts")
    debts = [
        Debt(nr=d.get("nr", ""), type=d.get("type", ""), sum=d.get("sum", ""))
        for d in root.findall("./debts/debt")
    ]

    return CounterpartyCard(
        idno=text("idno") or root.get("idno", ""),
        denumire=text("denumire"),
        inregistrare=text("inregistrare"),
        forma_juridica=text("forma_juridica"),
        lichidata=text("lichidata"),
        adresa=text("adresa"),
        administratori=text("administratori"),
        details_text=text("details_text"),
        founders=founders,
        debts=debts,
        debts_currency=(debts_node.get("currency", "") if debts_node is not None else ""),
    )


if __name__ == "__main__":
    # мини-самопроверка без запуска Contragenti: только разбор XML
    sample = """<?xml version="1.0" encoding="UTF-8"?>
    <counterparty source="date.gov.md" idno="1003600116460">
      <idno>1003600116460</idno>
      <denumire>CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.</denumire>
      <forma_juridica>Societate cu raspundere limitata</forma_juridica>
      <adresa>mun. Chisinau, str. Alba-Iulia 75/B</adresa>
      <administratori>TUHARI PAVEL [Administrator]</administratori>
      <founders><founder name="TUHARI PAVEL" share="100,00"/></founders>
      <debts currency="MDL"><debt nr="1" type="Bugetul de stat" sum="0,98"/></debts>
    </counterparty>"""
    card = parse_card_xml(sample)
    assert card.idno == "1003600116460"
    assert card.denumire.startswith("CENTRUL")
    assert len(card.founders) == 1 and card.founders[0].name == "TUHARI PAVEL"
    assert len(card.debts) == 1 and card.debts[0].sum == "0,98"
    print("OK: parse_card_xml self-test passed")
