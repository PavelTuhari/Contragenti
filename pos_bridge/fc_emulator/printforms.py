# -*- coding: utf-8 -*-
"""
Печатные формы документа в четырёх видах, как их отдаёт FiscalCloud при
`printOnServer = false`: Json (строки формы), Html, Pdf и Image (base64).

Html и Pdf собираются из тех же строк, что и Json, поэтому три вида всегда
показывают один документ. Image — валидный PNG заданной ширины; шрифты
имитатор не растрирует, поэтому изображение пустое (это единственное, чем
печатная форма имитатора отличается от формы устройства).
"""

import base64
import zlib

# виды строк печатной формы (enum PrintFormRow.type в описании API)
TEXT, IMAGE, QRCODE, SEPARATOR, EMPTY, PAGE_BREAK, DRAWER = (
    "Text", "Image", "QRCode", "Separator", "EmptyRow", "PageBreak", "OpenCashDrawer")


def row(kind, text="", **extra):
    r = {"type": kind}
    if text:
        r["text"] = text
    r.update(extra)
    return r


def money(v):
    return "%.2f" % float(v or 0)


def receipt_rows(doc, device, title="BON FISCAL"):
    """Строки печатной формы чека — из самого документа, без выдумок."""
    rows = [
        row(TEXT, device.get("organizationName") or "", align="Center", bold=True),
        row(TEXT, "IDNO %s" % (device.get("idnx") or ""), align="Center"),
        row(TEXT, device.get("address") or "", align="Center"),
        row(TEXT, "%s %s" % (device.get("model") or "", device.get("serialNumber") or ""), align="Center"),
        row(SEPARATOR),
        row(TEXT, title, align="Center", bold=True),
        row(TEXT, "Nr. %s   %s" % (doc.get("numberPresentation") or "", doc.get("dateTimePresentation") or "")),
        row(SEPARATOR),
    ]
    for it in doc.get("items") or []:
        rows.append(row(TEXT, it.get("name") or ""))
        rows.append(row(TEXT, "  %g x %s = %s %s" % (
            it.get("quantity") or 0, money(it.get("price")), money(it.get("finalAmount")),
            it.get("taxGroupCode") or "")))
    if doc.get("items"):
        rows.append(row(SEPARATOR))
    if doc.get("totalAmountModifications"):
        rows.append(row(TEXT, "Reducere: %s" % money(doc.get("totalAmountModifications"))))
    rows.append(row(TEXT, "TOTAL: %s MDL" % money(doc.get("totalAmount")), bold=True))
    for p in doc.get("payments") or []:
        rows.append(row(TEXT, "%s: %s" % (p.get("typeName") or "", money(p.get("amount")))))
        if p.get("bankTerminalRRN"):
            rows.append(row(TEXT, "  RRN %s" % p["bankTerminalRRN"]))
    if doc.get("totalChange"):
        rows.append(row(TEXT, "Rest: %s" % money(doc.get("totalChange"))))
    if doc.get("mevId"):
        rows.append(row(SEPARATOR))
        rows.append(row(TEXT, "SIA MEV: %s" % doc["mevId"], align="Center"))
        rows.append(row(QRCODE, doc["mevId"]))
    if doc.get("additionalFooterText"):
        rows.append(row(TEXT, doc["additionalFooterText"], align="Center"))
    rows.append(row(EMPTY))
    return rows


def report_rows(doc, device):
    title = "RAPORT Z" if doc.get("type") == "ZReport" else "RAPORT X"
    rows = [
        row(TEXT, device.get("organizationName") or "", align="Center", bold=True),
        row(TEXT, title, align="Center", bold=True),
        row(TEXT, "Nr. %s   %s" % (doc.get("numberPresentation") or "", doc.get("dateTimePresentation") or "")),
        row(SEPARATOR),
        row(TEXT, "Bonuri: %s" % (doc.get("receiptCount") or 0)),
        row(TEXT, "Total: %s MDL" % money(doc.get("totalAmount"))),
        row(TEXT, "TVA: %s MDL" % money(doc.get("totalTaxAmount"))),
    ]
    for t in doc.get("taxItems") or []:
        rows.append(row(TEXT, "  %s %s: baza %s, TVA %s" % (
            t.get("taxGroupCode"), t.get("taxRatePresentation") or "", money(t.get("amount")), money(t.get("taxAmount")))))
    for p in doc.get("payments") or []:
        rows.append(row(TEXT, "%s: %s" % (p.get("typeName") or "", money(p.get("amount")))))
    rows += [
        row(SEPARATOR),
        row(TEXT, "Numerar in casa: %s" % money(doc.get("finalBalance"))),
        row(TEXT, "Total general: %s" % money(doc.get("grandTotalAmount"))),
        row(EMPTY),
    ]
    return rows


def text_rows(rows):
    """Плоский текст из строк формы — основа Html и Pdf."""
    out = []
    for r in rows:
        kind = r.get("type")
        if kind == SEPARATOR:
            out.append("-" * 40)
        elif kind == EMPTY:
            out.append("")
        elif kind == PAGE_BREAK:
            out.append("\f")
        elif kind in (TEXT, QRCODE):
            out.append(r.get("text") or "")
    return out


def to_html(rows, title="Bon"):
    body = []
    for r in rows:
        kind = r.get("type")
        if kind == SEPARATOR:
            body.append("<hr>")
        elif kind == EMPTY:
            body.append("<br>")
        elif kind == QRCODE:
            body.append('<div class="qr">%s</div>' % _esc(r.get("text") or ""))
        elif kind == TEXT:
            style = []
            if r.get("bold"):
                style.append("font-weight:bold")
            if r.get("align") == "Center":
                style.append("text-align:center")
            body.append('<div style="%s">%s</div>' % (";".join(style), _esc(r.get("text") or "")))
    return ("<!doctype html><meta charset=\"utf-8\"><title>%s</title>"
            "<style>body{font:12px/1.35 monospace;width:320px;margin:8px}"
            ".qr{font-size:10px;color:#666;word-break:break-all}hr{border:0;border-top:1px dashed #999}</style>"
            "%s" % (_esc(title), "".join(body)))


def _esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def to_pdf(rows, settings=None):
    """Минимальный корректный PDF на одну страницу (Helvetica, WinAnsi)."""
    s = settings or {}
    font_size = int(s.get("fontSize") or 9)
    margin_x = int(s.get("horizontalMargin") or 12)
    margin_y = int(s.get("verticalMargin") or 12)
    width = int(s.get("contentWidth") or 240) + margin_x * 2
    lines = text_rows(rows)
    height = margin_y * 2 + max(1, len(lines)) * (font_size + 2)

    def esc(t):
        t = t.encode("cp1252", "replace").decode("cp1252")
        return t.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")

    content = ["BT", "/F1 %d Tf" % font_size, "%d %d Td" % (margin_x, height - margin_y - font_size),
               "%d TL" % (font_size + 2)]
    for line in lines:
        content.append("(%s) Tj T*" % esc(line))
    content.append("ET")
    stream = "\n".join(content).encode("latin-1", "replace")

    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Resources << /Font << /F1 4 0 R >> >> "
         "/Contents 5 0 R >>" % (width, height)).encode("latin-1"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref_at = len(out)
    out += b"xref\n0 %d\n" % (len(objs) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref_at)
    return bytes(out)


def to_png(rows, settings=None):
    """Валидный PNG заданной ширины; шрифты имитатор не растрирует."""
    s = settings or {}
    width = int(s.get("width") or s.get("contentWidth") or 384)
    line_h = int(s.get("fontSize") or 9) + 3
    height = max(1, int(s.get("verticalMargin") or 8) * 2 + max(1, len(text_rows(rows))) * line_h)
    raw = b"".join(b"\x00" + b"\xff" * (width * 3) for _ in range(height))

    def chunk(tag, data):
        return (len(data).to_bytes(4, "big") + tag + data
                + (zlib.crc32(tag + data) & 0xFFFFFFFF).to_bytes(4, "big"))

    ihdr = width.to_bytes(4, "big") + height.to_bytes(4, "big") + bytes([8, 2, 0, 0, 0])
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def render(rows, media_type, pdf_settings=None, image_settings=None, title="Bon"):
    """(printFormMediaType, printFormContent) — как в ответе FiscalCloud."""
    kind = (media_type or "Json")
    if kind == "Html":
        return "Html", to_html(rows, title)
    if kind == "Pdf":
        return "Pdf", base64.b64encode(to_pdf(rows, pdf_settings)).decode("ascii")
    if kind == "Image":
        return "Image", base64.b64encode(to_png(rows, image_settings)).decode("ascii")
    return "Json", rows
