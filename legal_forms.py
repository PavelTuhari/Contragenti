# -*- coding: utf-8 -*-
"""
Нормализация наименований молдавских юридических лиц.

Портал date.gov.md отдаёт название вместе с организационно-правовой формой
одной строкой и в разном написании. Модуль разбирает такую строку на три
независимых признака:

    tip     — тип предприятия  (ICS, IM, II, OCN, OMF, REP, …)
    forma   — юридическая форма (SRL, SA, CP, CI, GT, …)
    nume    — собственно название

Признаки независимы: «ICS … SRL» — это одновременно предприятие с иностранным
капиталом и общество с ограниченной ответственностью, поэтому один
нормализованный код здесь недостаточен.
"""

import re
import unicodedata


def _fold(text):
    """Убрать диакритику и привести к верхнему регистру для сопоставления."""
    s = unicodedata.normalize("NFD", text or "")
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    # румынские ş/ţ с запятой ниже не всегда разлагаются
    s = (s.replace("ș", "s").replace("ş", "s")
           .replace("ț", "t").replace("ţ", "t")
           .replace("Ș", "S").replace("Ş", "S")
           .replace("Ț", "T").replace("Ţ", "T"))
    return re.sub(r"\s+", " ", s).strip().upper()


# ── тип предприятия: длинные варианты идут первыми ──
TIP_PATTERNS = [
    ("ICS", r"INTREPRINDERE(?:A)? CU CAPITAL STRAIN"),
    ("ICS", r"INTREPRINDERE(?:A)? CU CAPITAL STRAINE"),
    ("IM",  r"INTREPRINDERE(?:A)? MIXTA"),
    ("II",  r"INTREPRINDERE(?:A)? INDIVIDUALA"),
    ("IP",  r"INTREPRINDERE(?:A)? PARTICULARA"),
    ("IS",  r"INTREPRINDERE(?:A)? DE STAT"),
    ("OCN", r"ORGANIZATIA DE CREDITARE NEBANCARA"),
    ("OMF", r"ORGANIZATIA DE MICROFINANTARE"),
    ("REP", r"REPREZENTANTA (?:DIN MOLDOVA )?(?:A |AL )?(?:FIRMEI |COMPANIEI |SOCIETATII )?"),
    ("REP", r"REPREZENTANTA"),
    ("SUC", r"SUCURSALA"),
    ("FIL", r"FILIALA"),
]

# ── юридическая форма ──
FORMA_PATTERNS = [
    ("SRL", r"SOCIETATE(?:A)? COMERCIALA CU RASPUNDERE LIMITATA"),
    ("SRL", r"SOCIETATE(?:A)? CU RASPUNDERE LIMITATA"),
    ("SA",  r"SOCIETATE(?:A)? PE ACTIUNI"),
    ("SC",  r"SOCIETATE(?:A)? COMERCIALA"),
    ("CP",  r"COOPERATIVA DE PRODUCTIE"),
    ("CI",  r"COOPERATIVA DE INTREPRINZATOR(?:I)?"),
    ("CA",  r"COOPERATIVA AGRICOLA DE PRODUCTIE"),
    ("CA",  r"COOPERATIVA AGRICOLA"),
    ("COOP", r"COOPERATIVA"),
    ("GT",  r"GOSPODARIA TARANEASCA"),
    ("GT",  r"GOSPODARIE TARANEASCA"),
    ("II",  r"INTREPRINZATOR INDIVIDUAL"),
    ("FIRM", r"FIRMA(?: COMERCIALA)?(?: DE PRODUCERE)?"),
    ("AG",  r"AGENTIA"),
    ("LOMB", r"LOMBARD"),
    ("CSV", r"CASA DE SCHIMB VALUTAR"),
    ("CC",  r"CASA DE COMERT"),
    ("IT",  r"INTOVARASIREA POMICOLA"),
    ("IT",  r"INTOVARASIREA"),
]

# Короткие суффиксы/аббревиатуры в самом названии.
# Завершающая точка входит в совпадение (иначе от «S.R.L.» остаётся сирота «.»),
# поэтому вместо \b на конце — просмотр вперёд.
SUFFIX_PATTERNS = [
    ("SRL", r"\bS\.?\s?R\.?\s?L\.?(?![A-Z0-9])"),
    ("SA",  r"\bS\.?\s?A\.?(?![A-Z0-9])"),
    ("II",  r"\bI\.?\s?I\.?(?![A-Z0-9])"),
    ("IM",  r"\bI\.?\s?M\.?(?![A-Z0-9])"),
]


def _tidy(text):
    """Убрать следы вырезанных фрагментов: осиротевшую пунктуацию и пробелы."""
    s = re.sub(r"\s+", " ", text or "").strip()
    s = re.sub(r"\s+([,;.])", r"\1", s)      # пробел перед знаком
    s = re.sub(r"(?<!\w)[.,;]+(?=\s|$)", " ", s)   # знак, не относящийся к слову
    s = re.sub(r"\(\s*\)", " ", s)           # пустые скобки
    s = re.sub(r"\s+", " ", s)
    return s.strip(" .,;-«»\"'")


def _strip_pattern(folded, original, pattern):
    """Удалить из строки участок, найденный по шаблону (в folded-координатах)."""
    m = re.search(pattern, folded)
    if not m:
        return None, folded, original
    # folded и original совпадают по длине посимвольно (диакритика заменяется 1:1),
    # кроме схлопнутых пробелов — поэтому вырезаем по folded и чистим original
    frag_orig = original[m.start():m.end()] if len(original) == len(folded) else None
    new_folded = (folded[:m.start()] + " " + folded[m.end():]).strip()
    new_folded = re.sub(r"\s+", " ", new_folded)
    if frag_orig is not None:
        new_original = (original[:m.start()] + " " + original[m.end():]).strip()
    else:
        # длины разошлись — восстанавливаем по folded-варианту
        new_original = new_folded
    new_original = re.sub(r"\s+", " ", new_original)
    return True, new_folded, new_original


def parse_name(raw):
    """Разобрать наименование на (tip, forma, nume).

    Возвращает dict: tip, forma, nume, short, original.
    """
    original = re.sub(r"\s+", " ", (raw or "").strip())
    if not original:
        return {"tip": None, "forma": None, "nume": "", "short": "", "original": ""}

    folded = _fold(original)
    work_f, work_o = folded, original

    tip = None
    for code, pat in TIP_PATTERNS:
        hit, work_f, work_o = _strip_pattern(work_f, work_o, pat)
        if hit:
            tip = code
            break

    forma = None
    for code, pat in FORMA_PATTERNS:
        hit, work_f, work_o = _strip_pattern(work_f, work_o, pat)
        if hit:
            forma = code
            break

    # аббревиатура-суффикс уточняет форму (или задаёт её, если слов не было)
    for code, pat in SUFFIX_PATTERNS:
        m = re.search(pat, work_f)
        if not m:
            continue
        # не срезаем, если это единственное содержимое названия
        candidate = re.sub(pat, " ", work_f).strip(" .,-«»\"'")
        if not candidate:
            continue
        if forma is None or forma in ("SC", "FIRM"):
            forma = code
        _, work_f, work_o = _strip_pattern(work_f, work_o, pat)
        break

    nume = _tidy(work_o)
    if not nume:                      # название целиком состояло из формы
        nume = original

    short = " ".join(p for p in (tip, nume, forma) if p).strip()
    return {"tip": tip, "forma": forma, "nume": nume,
            "short": short, "original": original}


if __name__ == "__main__":       # быстрая ручная проверка
    samples = [
        "Societatea cu Raspundere Limitata FAST INTERTRANS",
        "SOCIETATEA COMERCIALA NATURALCON S.R.L.",
        "Societatea pe Actiuni ACCENT ELECTRONIC",
        "Intreprinderea cu Capital Strain INSTALATII GRUP S.R.L.",
        "INTREPRINDEREA CU CAPITAL STRAIN ZALMOXIS GRUP SRL",
        "Intreprinderea Mixta WESER-GOLD S.R.L.",
        "Intreprinderea Individuala CARPEN-GOLD",
        "Organizatia de Microfinantare BC CREDIT S.R.L.",
        "Reprezentanta din Moldova a companiei DT CONSULT MM S.R.L.",
        "Cooperativa de Intreprinzator BURLACU-FRUCT",
        "Gospodaria Taraneasca ANISIM DINA DUMITRU",
        "Casa de Schimb Valutar NORTH EXCHANGE S.R.L.",
        "Societatea cu Răspundere Limitată ALFA-VIS COM",
    ]
    for s in samples:
        r = parse_name(s)
        print(f"{r['tip'] or '-':<5}{r['forma'] or '-':<6}{r['nume'][:44]:<46}| {r['short'][:52]}")
