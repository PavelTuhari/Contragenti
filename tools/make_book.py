# -*- coding: utf-8 -*-
"""
Сборка книги о комплексе: docs/book/index.html.

    python tools/make_book.py --shots     собрать иллюстрации в docs/book/img
    python tools/make_book.py --checks    прогнать проверки и сохранить их вывод
    python tools/make_book.py --build     собрать книгу из md-документов
    python tools/make_book.py --all       и то, и другое

Книга — одна страница: оглавление сбоку, части по порядку, внутри каждой
части связка от автора, галерея снимков и целиком те же md-документы, что
лежат в репозитории. Тексты не пересказываются: книга собирается из них,
поэтому не расходится с исходниками.
"""

import argparse
import datetime
import html
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "book"))
sys.path.insert(0, ROOT)

import plan                       # noqa: E402
from diagram import DIAGRAM       # noqa: E402
import shots as shotlib           # noqa: E402
from markdown_lite import slug, to_html   # noqa: E402

BOOK_DIR = os.path.join(ROOT, "docs", "book")
IMG_DIR = os.path.join(BOOK_DIR, "img")
MANIFEST = os.path.join(IMG_DIR, "manifest.json")
TITLE = "Контрагенти: реестр, CRM, ERP и касса"
SUBTITLE = "Комплекс систем от карточки организации до фискального чека"


# ── иллюстрации ──

def gather_shots():
    os.makedirs(IMG_DIR, exist_ok=True)
    manifest = {}

    # Demo CRM для macOS — свежий прогон GUI-самотеста
    mac_src = os.path.join("/tmp", "book_guitest")
    app = os.path.join(ROOT, "crm_macos", "build", "DerivedData", "Build", "Products",
                       "Release", "Demo CRM.app", "Contents", "MacOS", "Demo CRM")
    if os.path.exists(app):
        shutil.rmtree(mac_src, ignore_errors=True)
        print("-- прогон GUI-самотеста Demo CRM (macOS) ради свежих снимков")
        subprocess.run([app, "--gui-test", mac_src], capture_output=True, text=True, timeout=900)
    if not os.path.isdir(mac_src):
        mac_src = "/tmp/guitest"
    manifest["crm-macos"] = shotlib.copy_set(plan.CRM_MACOS, mac_src, IMG_DIR, "mac")
    print("   macOS: %d снимков" % len(manifest["crm-macos"]))

    # Demo CRM для Windows — прогон уже лежит в репозитории
    manifest["crm-windows"] = shotlib.copy_set(
        plan.CRM_WINDOWS, os.path.join(ROOT, "crm_delphi", "shots_gui"), IMG_DIR, "win")
    print("   Windows: %d снимков" % len(manifest["crm-windows"]))

    # Contragenti
    manifest["contragenti"] = shotlib.copy_set(
        plan.CONTRAGENTI, os.path.join(ROOT, "docs", "screenshots"), IMG_DIR, "cg")
    print("   Contragenti: %d снимков" % len(manifest["contragenti"]))

    # страницы прослойки и описание имитатора — снимает headless-Chrome
    pages = [("http://127.0.0.1:50800/api-docs", "pos_api_docs.png"),
             ("http://127.0.0.1:50800/api-playground", "pos_api_playground.png"),
             ("http://127.0.0.1:50700/openapi.json", "fc_openapi.png")]
    made = []
    for url, name in pages:
        dst = os.path.join("/tmp", name)
        if shotlib.chrome_shot(url, dst):
            made.append((name, dict(plan.POS_PAGES).get(name, name)))
            shotlib._resize(dst, os.path.join(IMG_DIR, "pos_" + name))
    manifest["pos"] = [("pos_" + n, c) for n, c in made]
    print("   страницы API: %d снимков%s" % (len(made), "" if made else " — прослойка не запущена"))

    # окно имитатора кассы
    dst = "/tmp/fc_gui.png"
    if shotlib.emulator_window_shot(dst):
        shotlib._resize(dst, os.path.join(IMG_DIR, "fc_fc_gui.png"))
        manifest["fcgui"] = [("fc_fc_gui.png", plan.FC_GUI[0][1])]
    else:
        manifest["fcgui"] = []
    print("   окно имитатора: %d снимков" % len(manifest["fcgui"]))

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    total = sum(len(v) for v in manifest.values())
    size = sum(os.path.getsize(os.path.join(IMG_DIR, n)) for v in manifest.values() for n, _ in v)
    print("Иллюстраций: %d, %.1f МБ → %s" % (total, size / 1048576.0, IMG_DIR))
    return manifest


CHECKS = [
    ("Demo CRM · разбор XML и SQLite", ["--selftest"], "crm_selftest.txt", "crm"),
    ("Demo CRM · DML всех сущностей", ["--dml-test"], "crm_dml.txt", "crm"),
    ("Прослойка кассы · сквозная проверка", ["-m", "pos_bridge", "selftest"], "pos_selftest.txt", "py"),
    ("Имитатор кассы · сверка с описанием FiscalCloud",
     ["-m", "pos_bridge", "fc-conformance"], "fc_conformance.txt", "py"),
    ("Каталог из MySQL", ["-m", "pos_bridge", "check-mysql"], "mysql.txt", "py"),
]


def gather_checks():
    """Запустить проверки и сохранить их вывод рядом с книгой."""
    out_dir = os.path.join(BOOK_DIR, "logs")
    os.makedirs(out_dir, exist_ok=True)
    app = os.path.join(ROOT, "crm_macos", "build", "DerivedData", "Build", "Products",
                       "Release", "Demo CRM.app", "Contents", "MacOS", "Demo CRM")
    python = os.path.join(ROOT, ".venv", "bin", "python")
    if not os.path.exists(python):
        python = sys.executable
    done = []
    for title, argv, name, kind in CHECKS:
        if kind == "crm":
            if not os.path.exists(app):
                continue
            cmd = [app] + argv
        else:
            cmd = [python] + argv
        print("-- прогон: %s" % title)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=900, cwd=ROOT)
            text = (r.stdout or "") + (r.stderr or "")
            code = r.returncode
        except Exception as exc:  # noqa: BLE001
            text, code = str(exc), -1
        shown = " ".join(["Demo\u00a0CRM" if c == app else os.path.basename(c) for c in cmd])
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            f.write(text.strip() + "\n")
        done.append({"title": title, "file": name, "code": code, "cmd": shown})
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(done, f, ensure_ascii=False, indent=1)
    print("Прогонов сохранено: %d" % len(done))
    return done


def load_checks():
    path = os.path.join(BOOK_DIR, "logs", "manifest.json")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ── книга ──

CSS = """
:root{--ink:#1d2330;--muted:#6b7280;--line:#e3e7ee;--bg:#fbfcfe;--paper:#fff;
      --accent:#1a6fd4;--accent-soft:#eaf2fd;--code-bg:#f6f8fb;--side:300px}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
     font:16px/1.62 "Georgia","Iowan Old Style",serif;-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
code,pre,kbd{font-family:"SF Mono",Menlo,Consolas,monospace}
#layout{display:flex;align-items:flex-start}
#toc{width:var(--side);flex:0 0 var(--side);position:sticky;top:0;height:100vh;overflow:auto;
     background:var(--paper);border-right:1px solid var(--line);padding:22px 18px 40px}
#toc h2{font:600 13px/1.3 system-ui,sans-serif;text-transform:uppercase;letter-spacing:.08em;
        color:var(--muted);margin:0 0 12px}
#toc ol{list-style:none;margin:0;padding:0;font:14px/1.45 system-ui,sans-serif}
#toc li{margin:2px 0}
#toc a{display:block;padding:5px 8px;border-radius:6px;color:var(--ink)}
#toc a:hover{background:var(--accent-soft);text-decoration:none}
#toc a.sub{padding-left:22px;font-size:13px;color:var(--muted)}
#toc a.active{background:var(--accent-soft);color:var(--accent);font-weight:600}
main{flex:1;min-width:0;padding:0 0 80px}
.wrap{max-width:860px;margin:0 auto;padding:0 28px}
.cover{background:linear-gradient(160deg,#12305c,#1a6fd4 60%,#3f9ae0);color:#fff;
       padding:74px 28px 60px;margin-bottom:36px}
.cover .wrap{padding:0 28px}
.cover h1{font-size:42px;line-height:1.12;margin:0 0 14px;letter-spacing:-.01em}
.cover p.sub{font-size:19px;opacity:.92;margin:0 0 26px}
.cover .meta{font:14px/1.6 system-ui,sans-serif;opacity:.85}
.cover .badges{margin-top:22px;display:flex;flex-wrap:wrap;gap:8px}
.cover .badges span{background:rgba(255,255,255,.16);border:1px solid rgba(255,255,255,.3);
                    border-radius:999px;padding:4px 12px;font:13px system-ui,sans-serif}
h1,h2,h3,h4,h5,h6{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.25;
                  margin:1.8em 0 .6em;scroll-margin-top:12px}
h2{font-size:27px;border-bottom:1px solid var(--line);padding-bottom:.28em}
h3{font-size:21px}h4{font-size:17px}h5,h6{font-size:15px;color:var(--muted)}
.part{margin:56px 0 0;padding-top:8px}
.part>h2{font-size:32px;border:0;color:var(--accent);margin-bottom:.2em}
.lead{font-size:17.5px;color:#39404d;border-left:3px solid var(--accent);padding-left:18px;margin:18px 0 26px}
.doc{background:var(--paper);border:1px solid var(--line);border-radius:12px;
     padding:6px 26px 22px;margin:22px 0}
.doc>.doc-head{font:600 12px/1.4 system-ui,sans-serif;text-transform:uppercase;letter-spacing:.08em;
               color:var(--muted);padding:14px 0 0;border-bottom:1px solid var(--line);margin-bottom:6px}
.doc>.doc-head .src{float:right;text-transform:none;letter-spacing:0;font-weight:400}
pre{background:var(--code-bg);border:1px solid var(--line);border-radius:8px;padding:12px 14px;
    overflow:auto;font-size:13px;line-height:1.5}
p code,li code,td code{background:var(--code-bg);border:1px solid var(--line);border-radius:4px;
                       padding:1px 5px;font-size:.88em}
blockquote{margin:1em 0;padding:.2em 1em;border-left:3px solid var(--line);color:#41506a;background:#f7f9fc}
.table-wrap{overflow-x:auto;margin:1em 0}
table{border-collapse:collapse;width:100%;font:14px/1.45 system-ui,sans-serif}
th,td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top}
th{background:#f2f5fa;font-weight:600}
tr:nth-child(even) td{background:#fafbfd}
hr{border:0;border-top:1px solid var(--line);margin:2em 0}
figure{margin:1.2em 0}
figure img{max-width:100%;height:auto;border:1px solid var(--line);border-radius:8px;display:block}
.doc figure img{width:auto}
.doc figure img[src*="shields.io"],.doc figure img[src*="badge"]{border:0;border-radius:0}
.gallery img{width:100%}
figcaption{font:13px/1.45 system-ui,sans-serif;color:var(--muted);margin-top:6px}
.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px;margin:22px 0}
.gallery figure{margin:0}
.gallery img{cursor:zoom-in;transition:box-shadow .15s}
.gallery img:hover{box-shadow:0 6px 22px rgba(20,40,80,.16)}
#lightbox{position:fixed;inset:0;background:rgba(12,18,30,.92);display:none;align-items:center;
          justify-content:center;z-index:50;padding:24px;cursor:zoom-out}
#lightbox img{max-width:100%;max-height:92vh;border-radius:8px;box-shadow:0 10px 50px rgba(0,0,0,.5)}
#lightbox p{position:absolute;bottom:14px;left:0;right:0;text-align:center;color:#dfe6f2;
            font:14px system-ui,sans-serif;margin:0}
.doc.check pre{background:#10151f;color:#d7e2f3;border-color:#1d2736;font-size:12.5px}
.doc.check .doc-head .src{color:#8794aa}
.scheme{margin:26px 0}
.book-foot{margin-top:60px;padding-top:18px;border-top:1px solid var(--line);
           font:14px/1.6 system-ui,sans-serif;color:var(--muted)}
.toggle{display:none}
@media (max-width:960px){
  #toc{position:fixed;left:0;top:0;z-index:40;transform:translateX(-100%);transition:transform .2s}
  #toc.open{transform:none;box-shadow:0 0 40px rgba(0,0,0,.25)}
  .toggle{display:block;position:fixed;right:14px;bottom:14px;z-index:45;background:var(--accent);
          color:#fff;border:0;border-radius:999px;padding:12px 18px;font:15px system-ui,sans-serif;
          box-shadow:0 6px 20px rgba(20,60,120,.35)}
  .cover h1{font-size:31px}
}
@media print{
  #toc,.toggle,#lightbox{display:none}
  body{background:#fff;font-size:11pt}
  .doc{border:0;padding:0}
  .cover{background:#fff;color:#000;padding:0 0 20px}
  .cover .badges span{border-color:#999;background:none}
  .part{page-break-before:always}
  pre,figure,table{page-break-inside:avoid}
}
"""

JS = """
(function(){
  var box=document.getElementById('lightbox'), img=box.querySelector('img'), cap=box.querySelector('p');
  document.querySelectorAll('.gallery img').forEach(function(el){
    el.addEventListener('click',function(){
      img.src=el.src; cap.textContent=el.alt||''; box.style.display='flex';
    });
  });
  box.addEventListener('click',function(){box.style.display='none';img.src='';});
  document.addEventListener('keydown',function(e){if(e.key==='Escape'){box.style.display='none';}});
  var btn=document.querySelector('.toggle'), toc=document.getElementById('toc');
  if(btn){btn.addEventListener('click',function(){toc.classList.toggle('open');});}
  toc.addEventListener('click',function(e){if(e.target.tagName==='A'){toc.classList.remove('open');}});
  var links={}, targets=[];
  toc.querySelectorAll('a').forEach(function(a){
    var id=a.getAttribute('href').slice(1); links[id]=a;
    var t=document.getElementById(id); if(t){targets.push(t);}
  });
  var current=null;
  function onScroll(){
    var best=null;
    targets.forEach(function(t){
      if(t.getBoundingClientRect().top<140){best=t;}
    });
    if(best&&best.id!==current){
      if(current&&links[current]){links[current].classList.remove('active');}
      current=best.id;
      if(links[current]){links[current].classList.add('active');}
    }
  }
  document.addEventListener('scroll',onScroll,{passive:true}); onScroll();
})();
"""


def rel_to_book(md_path, href):
    """Ссылка из документа — в адрес, работающий из docs/book/index.html."""
    if href.startswith(("http://", "https://", "mailto:", "#")):
        return href
    base = os.path.dirname(md_path)
    target = os.path.normpath(os.path.join(base, href.split("#")[0])) if base else href.split("#")[0]
    anchor = "#" + href.split("#", 1)[1] if "#" in href else ""
    # ссылка на другой документ книги — ведём на его раздел
    if target.endswith(".md"):
        return "#doc-" + slug(target)
    return os.path.relpath(os.path.join(ROOT, target), BOOK_DIR) + anchor


def build(manifest, checks=None):
    os.makedirs(BOOK_DIR, exist_ok=True)
    checks = checks if checks is not None else load_checks()
    used = set()
    toc = []
    parts = []
    doc_count = 0

    for ch in plan.CHAPTERS:
        used.add(ch["id"])
        body = ['<section class="part" id="%s">' % ch["id"],
                "<h2>%s</h2>" % html.escape(ch["title"])]
        lead_html, _ = to_html(ch["lead"].strip(), used_slugs=used)
        body.append('<div class="lead">%s</div>' % lead_html)
        sub = []
        if ch.get("diagram"):
            body.append(DIAGRAM)
        if ch.get("checks"):
            for item in checks:
                log = os.path.join(BOOK_DIR, "logs", item["file"])
                try:
                    with open(log, encoding="utf-8") as f:
                        text = f.read().strip()
                except OSError:
                    continue
                if len(text) > 9000:
                    head = text[:4200].rsplit("\n", 1)[0]
                    tail = text[-3000:].split("\n", 1)[-1]
                    text = head + "\n…\n" + tail
                mark = "код возврата %d" % item["code"]
                anchor = slug("check-" + item["file"], used)
                body.append('<article class="doc check" id="%s">' % anchor)
                body.append('<div class="doc-head">%s<span class="src">%s · %s</span></div>'
                            % (html.escape(item["title"]), html.escape(item["cmd"]), mark))
                body.append("<pre><code>%s</code></pre>" % html.escape(text))
                body.append("</article>")
                sub.append((anchor, item["title"]))

        for group in ch.get("shots") or []:
            items = manifest.get(group) or []
            if not items:
                continue
            body.append('<div class="gallery">')
            for name, caption in items:
                body.append('<figure><img src="img/%s" alt="%s" loading="lazy">'
                            "<figcaption>%s</figcaption></figure>"
                            % (html.escape(name), html.escape(caption), html.escape(caption)))
            body.append("</div>")

        for md_path, label in ch["docs"]:
            full = os.path.join(ROOT, md_path)
            with open(full, encoding="utf-8") as f:
                text = f.read()
            anchor = "doc-" + slug(md_path)
            used.add(anchor)
            rendered, headings = to_html(
                text,
                link_fix=lambda h, p=md_path: rel_to_book(p, h),
                image_fix=lambda s, p=md_path: rel_to_book(p, s),
                heading_offset=1, used_slugs=used)
            title = label or os.path.basename(md_path)
            body.append('<article class="doc" id="%s">' % anchor)
            body.append('<div class="doc-head">%s<span class="src">%s</span></div>'
                        % (html.escape(title), html.escape(md_path)))
            body.append(rendered)
            body.append("</article>")
            sub.append((anchor, title))
            doc_count += 1

        body.append("</section>")
        parts.append("\n".join(body))
        toc.append((ch["id"], ch["title"], sub))

    toc_html = ["<h2>Содержание</h2>", "<ol>"]
    for anchor, title, sub in toc:
        toc_html.append('<li><a href="#%s">%s</a>' % (anchor, html.escape(title)))
        for a2, t2 in sub:
            toc_html.append('<a class="sub" href="#%s">%s</a>' % (a2, html.escape(t2)))
        toc_html.append("</li>")
    toc_html.append("</ol>")

    shots_total = sum(len(v) for v in manifest.values())
    today = datetime.date.today().strftime("%d.%m.%Y")
    version = ""
    try:
        with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
            version = f.read().strip()
    except OSError:
        pass

    page = """<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%(title)s</title>
<meta name="description" content="%(subtitle)s">
<style>%(css)s</style>
</head><body>
<div id="layout">
<nav id="toc">%(toc)s</nav>
<main>
<header class="cover"><div class="wrap">
<h1>%(title)s</h1>
<p class="sub">%(subtitle)s</p>
<div class="meta">Версия комплекса %(version)s · собрано %(date)s · %(docs)d документов, %(shots)d иллюстраций</div>
<div class="badges"><span>Python</span><span>Delphi</span><span>Swift · AppKit</span>
<span>C++Builder</span><span>Oracle</span><span>MySQL</span><span>SQLite</span>
<span>FastAPI</span><span>FiscalCloud</span></div>
</div></header>
<div class="wrap">
%(parts)s
<footer class="book-foot">
Книга собирается из документов репозитория командой
<code>python tools/make_book.py --all</code>: тексты не пересказаны, а взяты как есть,
поэтому книга не расходится с исходниками. Иллюстрации — кадры самотестов и снимки
работающих программ.
</footer>
</div>
</main></div>
<div id="lightbox"><img alt=""><p></p></div>
<button class="toggle">Содержание</button>
<script>%(js)s</script>
</body></html>
""" % {"title": html.escape(TITLE), "subtitle": html.escape(SUBTITLE), "css": CSS, "js": JS,
       "toc": "\n".join(toc_html), "parts": "\n".join(parts), "date": today,
       "version": html.escape(version or "—"), "docs": doc_count, "shots": shots_total}

    out = os.path.join(BOOK_DIR, "index.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)
    print("Книга собрана: %s (%.1f КБ, документов %d, иллюстраций %d)"
          % (out, os.path.getsize(out) / 1024.0, doc_count, shots_total))
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--shots", action="store_true", help="собрать иллюстрации")
    p.add_argument("--build", action="store_true", help="собрать книгу")
    p.add_argument("--checks", action="store_true", help="прогнать проверки и сохранить вывод")
    p.add_argument("--all", action="store_true", help="и то, и другое")
    args = p.parse_args()
    if not (args.shots or args.build or args.checks or args.all):
        args.all = True
    manifest = {}
    checks = None
    if args.shots or args.all:
        manifest = gather_shots()
    if args.checks or args.all:
        checks = gather_checks()
    if os.path.exists(MANIFEST) and not manifest:
        with open(MANIFEST, encoding="utf-8") as f:
            manifest = json.load(f)
    if args.build or args.all:
        build(manifest, checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
