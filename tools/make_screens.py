"""Генерация скриншотов нативного окна Contragenti (реальный захват через Quartz)."""
import os, sys, time
sys.path.insert(0, os.path.abspath('.'))
sys.path.insert(0, os.path.abspath('tools'))
import company_search as cs
from _capture import capture_window

OUT = os.path.abspath('docs/screenshots')
os.makedirs(OUT, exist_ok=True)
PID = os.getpid()

def settle(app, n=16):
    app.update(); app.deiconify(); app.lift()
    for _ in range(n):
        app.update(); time.sleep(0.05)

def shot(app, name):
    settle(app)
    ok = capture_window(PID, os.path.join(OUT, name))
    print(f'  {name}: {"ok" if ok else "FAIL"}')

# дополнить карточку UNISIM полными реальными деталями из образца портала
html = open('xml_in_site_http__date.gov.md__open__company-detail.txt', encoding='utf-8').read()
basic = cs.parse_detail_basic(html)
founders, debts = cs.classify_tables(cs.parse_tables(html))
cs.db_save_details({'idno': '1003600116460', 'basic': basic,
                    'text': '\n'.join(l for l in html and
                    ['=== Date de bază ===',
                     'IDNO/Cod Fiscal: 1003600116460',
                     'Denumire: CENTRUL … UNISIM-SOFT S.R.L.',
                     'Data înregistrării: 30.03.2001',
                     'Forma juridică: Societate cu răspundere limitată',
                     'Lichidată: Nu',
                     'Adresa juridică: mun. Chişinău, sec. Buiucani, str. Alba-Iulia, 75/B',
                     'Conducători: TUHARI PAVEL [Administrator]',
                     '',
                     '=== Restanțe față de bugetul de stat ===',
                     'Nr.  Tipul bugetului  Suma (MDL)',
                     '1  Bugetul de stat și local  0,00',
                     '2  Bugetul de stat  180,78',
                     '4  Bugetul asigurărilor sociale de stat  143,19']),
                    'founders': founders, 'debts': debts})

import argparse
args = argparse.Namespace(port=9491, host='127.0.0.1', lang='ru', q=None,
                          pick=False, out=None, no_server=True, no_tray=True)
app = cs.App(args)
app.on_search = lambda: None   # без реального браузера при демонстрации

# 01 — Онлайн-поиск (стартовый вид)
app.notebook.select(0)
shot(app, '01_online_ru.png')

# 02 — Вкладка «Только БД» со всеми записями
app.notebook.select(1)
app.on_db_find()
shot(app, '02_db_list_ru.png')

# 03 — Карточка master-detail: выбрать UNISIM
def select_idno(tree, idno):
    for iid in tree.get_children():
        if tree._idno_map.get(iid) == idno:
            tree.selection_set(iid); tree.focus(iid)
            app._on_row_select(tree)
            return True
    return False

select_idno(app.tree_offline, '1003600116460')
shot(app, '03_card_ru.png')

# 04 — Тот же экран на английском (демонстрация i18n)
app.set_lang('en')
app.on_db_find()
select_idno(app.tree_offline, '1003600116460')
shot(app, '04_card_en.png')

# 05 — Режим внешнего вызова: видна кнопка «Вернуть контрагента»
app.set_lang('ru')
app.on_db_find()
select_idno(app.tree_offline, '1003600116460')
app._show_return_button(True)
app.status.set(app.t('status_pick', q='UNISIM'))
shot(app, '05_return_ru.png')

app.destroy()
print('done')
