# -*- coding: utf-8 -*-
"""
Небольшой преобразователь Markdown → HTML без внешних библиотек.

Поддерживает то, чем пользуются документы этого репозитория: заголовки,
абзацы, списки (в том числе вложенные и нумерованные), таблицы GFM,
блоки кода с языком, цитаты, горизонтальные линии, ссылки, картинки,
`код`, **жирный**, *курсив*. Этого достаточно, чтобы собрать книгу той же
командой на любой машине, где есть Python.
"""

import html
import re

_INLINE_CODE = re.compile(r"`([^`]+)`")
_IMAGE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"([^\"]*)\")?\)")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)(?:\s+\"([^\"]*)\")?\)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC = re.compile(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])")
_AUTOLINK = re.compile(r"(?<![\"(=])\b(https?://[^\s<>\")]+)")
_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
_TABLE_SEP = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")
_LIST_ITEM = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
_SLUG_BAD = re.compile(r"[^a-z0-9а-яё\- ]+", re.IGNORECASE)


def slug(text, used=None):
    s = re.sub(r"<[^>]+>", "", text).strip().lower()
    s = _SLUG_BAD.sub("", s).replace(" ", "-")
    s = re.sub(r"-{2,}", "-", s).strip("-") or "section"
    if used is not None:
        base, n = s, 2
        while s in used:
            s = "%s-%d" % (base, n)
            n += 1
        used.add(s)
    return s


def inline(text, link_fix=None, image_fix=None):
    """Разметка внутри строки. Код вынимается первым, чтобы не портить его."""
    holders = []

    def keep_code(m):
        holders.append("<code>%s</code>" % html.escape(m.group(1)))
        return "\x00%d\x00" % (len(holders) - 1)

    text = _INLINE_CODE.sub(keep_code, text)
    text = html.escape(text, quote=False)

    def image(m):
        alt, src, title = m.group(1), m.group(2), m.group(3) or ""
        if image_fix:
            src = image_fix(src)
        cap = ' title="%s"' % html.escape(title) if title else ""
        return '<figure><img src="%s" alt="%s"%s loading="lazy"><figcaption>%s</figcaption></figure>' % (
            html.escape(src), html.escape(alt), cap, html.escape(title or alt))

    text = _IMAGE.sub(image, text)

    def link(m):
        label, href, title = m.group(1), m.group(2), m.group(3) or ""
        if link_fix:
            href = link_fix(href)
        t = ' title="%s"' % html.escape(title) if title else ""
        ext = ' target="_blank" rel="noopener"' if href.startswith("http") else ""
        return '<a href="%s"%s%s>%s</a>' % (html.escape(href), t, ext, label)

    text = _LINK.sub(link, text)
    text = _BOLD.sub(r"<strong>\1</strong>", text)
    text = _ITALIC.sub(r"<em>\1</em>", text)
    text = _AUTOLINK.sub(r'<a href="\1" target="_blank" rel="noopener">\1</a>', text)
    for i, code in enumerate(holders):
        text = text.replace("\x00%d\x00" % i, code)
    return text


class Renderer:
    def __init__(self, link_fix=None, image_fix=None, heading_offset=0, used_slugs=None):
        self.link_fix = link_fix
        self.image_fix = image_fix
        self.heading_offset = heading_offset
        self.used = used_slugs if used_slugs is not None else set()
        self.headings = []          # (уровень, текст, якорь)

    def _inline(self, text):
        return inline(text, self.link_fix, self.image_fix)

    def render(self, text):
        lines = text.replace("\r\n", "\n").split("\n")
        out = []
        i = 0
        while i < len(lines):
            line = lines[i]

            # блок кода
            if line.lstrip().startswith("```"):
                lang = line.strip().strip("`").strip()
                body = []
                i += 1
                while i < len(lines) and not lines[i].lstrip().startswith("```"):
                    body.append(lines[i])
                    i += 1
                i += 1
                cls = ' class="lang-%s"' % html.escape(lang) if lang else ""
                out.append("<pre%s><code>%s</code></pre>" % (cls, html.escape("\n".join(body))))
                continue

            if not line.strip():
                i += 1
                continue

            # заголовок
            m = _HEADING.match(line)
            if m:
                level = min(6, len(m.group(1)) + self.heading_offset)
                body = self._inline(m.group(2).strip())
                anchor = slug(m.group(2), self.used)
                self.headings.append((len(m.group(1)), re.sub(r"<[^>]+>", "", body), anchor))
                out.append('<h%d id="%s">%s</h%d>' % (level, anchor, body, level))
                i += 1
                continue

            # горизонтальная линия
            if re.match(r"^\s*(\*\s*){3,}$|^\s*(-\s*){3,}$|^\s*(_\s*){3,}$", line):
                out.append("<hr>")
                i += 1
                continue

            # таблица
            if "|" in line and i + 1 < len(lines) and _TABLE_SEP.match(lines[i + 1]):
                header = self._cells(line)
                i += 2
                rows = []
                while i < len(lines) and "|" in lines[i] and lines[i].strip():
                    rows.append(self._cells(lines[i]))
                    i += 1
                out.append(self._table(header, rows))
                continue

            # цитата
            if line.lstrip().startswith(">"):
                body = []
                while i < len(lines) and lines[i].lstrip().startswith(">"):
                    body.append(lines[i].lstrip()[1:].lstrip())
                    i += 1
                inner = Renderer(self.link_fix, self.image_fix, self.heading_offset, self.used)
                out.append("<blockquote>%s</blockquote>" % inner.render("\n".join(body)))
                continue

            # список
            if _LIST_ITEM.match(line):
                block, i = self._collect_list(lines, i)
                out.append(block)
                continue

            # абзац
            body = []
            while i < len(lines) and lines[i].strip() and not _HEADING.match(lines[i]) \
                    and not _LIST_ITEM.match(lines[i]) and not lines[i].lstrip().startswith(("```", ">")):
                body.append(lines[i].strip())
                i += 1
            paragraph = self._inline(" ".join(body))
            # одинокая картинка — без обёртки в абзац
            if paragraph.startswith("<figure>") and paragraph.endswith("</figure>"):
                out.append(paragraph)
            else:
                out.append("<p>%s</p>" % paragraph)
        return "\n".join(out)

    @staticmethod
    def _cells(line):
        row = line.strip()
        if row.startswith("|"):
            row = row[1:]
        if row.endswith("|"):
            row = row[:-1]
        return [c.strip() for c in row.split("|")]

    def _table(self, header, rows):
        head = "".join("<th>%s</th>" % self._inline(c) for c in header)
        body = []
        for row in rows:
            cells = "".join("<td>%s</td>" % self._inline(c) for c in row)
            body.append("<tr>%s</tr>" % cells)
        return ('<div class="table-wrap"><table><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>'
                % (head, "".join(body)))

    def _collect_list(self, lines, i):
        """Список с вложенностью по отступу."""
        items = []          # (отступ, маркер, [строки])
        while i < len(lines):
            m = _LIST_ITEM.match(lines[i])
            if m:
                items.append((len(m.group(1)), m.group(2), [m.group(3)]))
                i += 1
                continue
            if lines[i].strip() and items and lines[i].startswith(" " * (items[-1][0] + 2)):
                items[-1][2].append(lines[i].strip())      # продолжение пункта
                i += 1
                continue
            if not lines[i].strip() and i + 1 < len(lines) and _LIST_ITEM.match(lines[i + 1]):
                i += 1
                continue
            break
        return self._build_list(items, 0), i

    def _build_list(self, items, start_indent):
        if not items:
            return ""
        ordered = not items[0][1].startswith(("-", "*", "+"))
        tag = "ol" if ordered else "ul"
        out = ["<%s>" % tag]
        idx = 0
        while idx < len(items):
            indent, _marker, body = items[idx]
            nested = []
            j = idx + 1
            while j < len(items) and items[j][0] > indent:
                nested.append(items[j])
                j += 1
            text = self._inline(" ".join(body))
            inner = self._build_list(nested, indent) if nested else ""
            out.append("<li>%s%s</li>" % (text, inner))
            idx = j
        out.append("</%s>" % tag)
        return "".join(out)


def to_html(text, link_fix=None, image_fix=None, heading_offset=0, used_slugs=None):
    r = Renderer(link_fix, image_fix, heading_offset, used_slugs)
    return r.render(text), r.headings
