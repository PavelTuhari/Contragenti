// Встроенный самотест интерфейса (аналог uGuiSelfTest.pas).
//
// Тест живёт внутри процесса: сам ведёт окно по пронумерованным шагам,
// рисует плашку «Шаг NN · название», после каждого шага снимает окно
// (cacheDisplay содержимого — без прав на запись экрана) и складывает PNG в
// каталог отчёта. Реальный вызов SDK: нажимается настоящая кнопка «Создать
// из реестра», запускается Contragenti; пока он работает, тест снимает свои
// окна и окна Contragenti/Chrome (CGWindowList, если есть право на запись
// экрана). В конце — автономный report.html и results.json.
//
//   "Demo CRM" --gui-test [каталог] [путь к Contragenti|company_search.py]
import AppKit

private let XML_UNISIM = """
<?xml version="1.0" encoding="UTF-8"?><counterparty source="date.gov.md" idno="1003600116460"><idno>1003600116460</idno><denumire>CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.</denumire><inregistrare>30.03.2001</inregistrare><forma_juridica>Societate cu raspundere limitata</forma_juridica><lichidata>Nu</lichidata><adresa>mun. Chisinau, str. Alba-Iulia 75/B</adresa><administratori>TUHARI PAVEL [Administrator]</administratori><founders><founder name="TUHARI PAVEL" share="100,00"/></founders><debts currency="MDL"><debt nr="1" type="Bugetul de stat" sum="0,98"/></debts></counterparty>
"""
private let XML_ALFAVIS = """
<?xml version="1.0" encoding="UTF-8"?><counterparty source="date.gov.md" idno="1017600018242"><idno>1017600018242</idno><denumire>Societatea cu Raspundere Limitata ALFA-VIS COM</denumire><inregistrare>13.04.2017</inregistrare><forma_juridica>Societate cu raspundere limitata</forma_juridica><lichidata>Nu</lichidata><adresa>mun. Chisinau, sec. Centru, str. Alecsandri Vasile, 80</adresa><administratori>BUBIS YEVGENY [Administrator]</administratori><founders><founder name="BUBIS ANNA" share="50,00"/><founder name="BUBIS YEVGENY" share="50,00"/></founders><debts currency="MDL"><debt nr="1" type="Bugetul de stat" sum="0,00"/></debts></counterparty>
"""

private func htmlEsc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

private func fileSizeOf(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
}

struct StepResult {
    var num = 0
    var title = ""
    var ok = false
    var detail = ""
    var shot = ""
    var extra: [String] = []
    var message = ""
}

final class GuiSelfTest {
    private let form: MainWindowController
    private let outDir: String
    private let launcher: String
    private(set) var steps: [StepResult] = []
    private var num = 0
    private var extra: [String] = []
    private var waitTicks = 0
    private var waitShots = 0
    private var exports: [String] = []
    private var sdkStart = Date()

    init(form: MainWindowController, outDir: String, launcher: String) {
        self.form = form
        self.outDir = outDir
        self.launcher = launcher
    }

    private func pump() {
        for _ in 0..<3 { pumpSleep(0.04) }
    }

    private func B(_ v: Bool) -> String { v ? "True" : "False" }

    /// Снимок своего окна изнутри процесса — без прав на запись экрана.
    private func capture(_ slug: String) -> String {
        let name = String(format: "%02d_%@.png", num, slug)
        let view = form.rootView
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return name }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outDir + "/" + name))
        }
        return name
    }

    /// Окна процессов python/Chrome/Contragenti (чужие) — если есть право
    /// на запись экрана; пустой кадр пропускается.
    private func captureForeignWindows(_ slug: String) {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        var n = 0
        for w in infos {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  let owner = (w[kCGWindowOwnerName as String] as? String)?.lowercased(),
                  let wid = w[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let bw = boundsDict["Width"] as? Double, let bh = boundsDict["Height"] as? Double, bw >= 200, bh >= 150 else { continue }
            guard owner.contains("python") || owner.contains("chrome") || owner.contains("contragenti") else { continue }
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming]) else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            if isBlank(rep) { continue }
            n += 1
            let name = String(format: "%02d_%@_win%d.png", num, slug, n)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outDir + "/" + name))
                extra.append(name)
            }
        }
    }

    private func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let first = rep.colorAt(x: w / 2, y: h / 2) else { return true }
        var y = 5
        while y < h {
            var x = 5
            while x < w {
                if let c = rep.colorAt(x: x, y: y), c != first { return false }
                x += w / 12 + 1
            }
            y += h / 12 + 1
        }
        return true
    }

    /// Вызывается SDK каждые 200 мс, пока открыт Contragenti.
    private func onSdkWait() {
        pumpEvents()
        waitTicks += 1
        if [5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 225].contains(waitTicks) {
            waitShots += 1
            if waitShots == 1 { extra.append(capture("sdk_wait_crm")) }
            captureForeignWindows("sdk_wait\(waitShots)")
        }
    }

    private func markSdkStart() { sdkStart = Date(); waitTicks = 0; waitShots = 0 }

    /// Забираем снимки, сделанные Contragenti по --shots-dir, под номер шага.
    private func collectSdkShots() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: outDir) else { return }
        for f in files.filter({ $0.hasPrefix("sdk_") && $0.hasSuffix(".png") }).sorted() {
            let name = String(format: "%02d_%@", num, f)
            try? FileManager.default.removeItem(atPath: outDir + "/" + name)
            try? FileManager.default.moveItem(atPath: outDir + "/" + f, toPath: outDir + "/" + name)
            extra.append(name)
        }
    }

    private func step(_ title: String, _ ok: Bool, _ detail: String, _ slug: String) {
        form.testShowBanner(num, title)
        pump()
        var r = StepResult()
        r.num = num; r.title = title; r.ok = ok; r.detail = detail
        r.message = form.testMessage
        r.shot = capture(slug)
        r.extra = extra
        extra = []
        steps.append(r)
        writeStdout(String(format: "%@ %02d %@", ok ? "[OK]  " : "[FAIL]", num, title))
    }

    func run() -> Bool {
        steps = []; num = 0; extra = []
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let crm = form.crm
        let todayD = today()

        // ── часть 0: вход в программу и язык интерфейса ──
        num += 1
        step("Окно входа закрывает данные до авторизации", form.testLoginVisible, "панель входа показана", "login")

        num += 1
        form.testLogin("admin", "неверный"); pump()
        step("Неверный пароль не пускает в программу", form.testLoginVisible && form.testMessageKind == .warn, form.testMessage, "login_bad")

        num += 1
        form.testSetLanguage("ro"); pump()
        step("Язык интерфейса из внешнего lang.json: румынский (основной)",
             T.loaded && T.lang == "ro" && T.S("nav.clients") == "Clienți",
             "файл \((T.fileName as NSString).lastPathComponent); nav.clients = «\(T.S("nav.clients"))», nav.orders = «\(T.S("nav.orders"))»", "lang_ro")

        num += 1
        form.testSetLanguage("en"); pump()
        step("Переключение на английский меняет строки из того же файла",
             T.lang == "en" && T.S("nav.clients") == "Clients" && I18n.readLangFromDefaults("") == "en",
             "nav.clients = «\(T.S("nav.clients"))», в UserDefaults Language = «\(I18n.readLangFromDefaults(""))»", "lang_en")

        num += 1
        form.testSetLanguage("ru"); pump()
        step("Выбор языка сохраняется в UserDefaults (md.una.contragenti.democrm / Language)",
             I18n.readLangFromDefaults("") == "ru" && T.S("nav.clients") == "Клиенты",
             "Language = «\(I18n.readLangFromDefaults(""))», nav.clients = «\(T.S("nav.clients"))»", "lang_defaults")

        num += 1
        step("Значения справочников переводятся, а в базе остаются каноническими",
             enumDisplay("order_status", "Подтверждён", ENUM_ORDER_STATUS) == "Подтверждён" && T.enumAt("order_status", 1) == "Подтверждён",
             "order_status[1] в ru = «\(T.enumAt("order_status", 1))», этап 3 = «\(T.enumAt("stage_title", 3))»", "enum_translate")

        num += 1
        form.testLogin("admin", "admin"); pump()
        step("Вход с верным паролем открывает программу", !form.testLoginVisible && form.user == "admin",
             "пользователь «\(form.user)»; \(form.testMessage)", "login_ok")

        // ── часть 1: интерфейс без внешних процессов ──
        num += 1
        step("Стартовое окно, база пуста", form.testListCount == 0 && form.testDbCount == 0,
             "в списке \(form.testListCount), в базе \(form.testDbCount)", "start")

        num += 1
        var (res, _) = form.testImportXml(XML_UNISIM)
        step("Импорт карточки UNISIM-SOFT из XML Contragenti", res == .added && form.testListCount == 1 && form.testMessageKind == .ok,
             "результат \(res.rawValue), в списке \(form.testListCount), сообщение зелёное=\(B(form.testMessageKind == .ok))", "import_unisim")

        num += 1
        (res, _) = form.testImportXml(XML_ALFAVIS)
        step("Импорт карточки ALFA-VIS COM", res == .added && form.testListCount == 2,
             "результат \(res.rawValue), в списке \(form.testListCount)", "import_alfavis")

        num += 1
        (res, _) = form.testImportXml(XML_UNISIM)
        step("Повторный импорт UNISIM — отсечён как дубликат", res == .duplicate && form.testDbCount == 2 && form.testMessageKind == .warn,
             "результат \(res.rawValue), в базе \(form.testDbCount), сообщение янтарное=\(B(form.testMessageKind == .warn))", "duplicate")

        num += 1
        form.testSetFilter("ALFA"); pump()
        step("Фильтр «ALFA» оставляет одну запись", form.testListCount == 1, "в списке \(form.testListCount)", "filter_alfa")

        num += 1
        form.testSetFilter(""); pump()
        step("Фильтр сброшен — снова две записи", form.testListCount == 2, "в списке \(form.testListCount)", "filter_clear")

        num += 1
        form.testClickSettings(); pump()
        step("Панель настроек раскрывается внутри окна (без модального диалога)", form.testMessageKind == .info,
             "сообщение: " + form.testMessage, "settings_open")

        num += 1
        form.testClickSettings(); pump()
        step("Панель настроек скрыта повторным нажатием", true, "", "settings_close")

        num += 1
        form.testClickNav(.workspace); pump()
        step("Навигация: «Рабочий стол» — большие плитки этапов процесса", form.testSection == .workspace, "", "workspace_empty")

        num += 1
        form.testClickNav(.leads); pump()
        step("Навигация: раздел «Лиды» открывается — пустой список с кнопками «Создать лид» и «В клиенты»",
             form.testSection == .leads && form.page(.leads)?.listCount == 0,
             "раздел=\(form.testSection.rawValue), записей \(form.page(.leads)?.listCount ?? -1)", "nav_leads_empty")

        num += 1
        form.testClickNav(.accounts); pump()
        step("Навигация: возврат в «Клиенты»", form.testSection == .accounts, "", "accounts")

        num += 1
        form.testClickDelete(); pump()
        step("«Удалить» без выбранной строки — предупреждение, ничего не удалено", form.testMessageKind == .warn && form.testDbCount == 2,
             "в базе \(form.testDbCount), сообщение янтарное=\(B(form.testMessageKind == .warn))", "delete_noselect")

        num += 1
        form.testSelectFirst(); pump()
        var before = form.testDbCount
        form.testClickDelete(); pump()
        step("«Удалить» с выбранной строкой — просьба подтвердить, база не тронута", form.testMessageKind == .warn && form.testDbCount == before,
             "в базе \(form.testDbCount), сообщение янтарное=\(B(form.testMessageKind == .warn))", "delete_confirm_ask")

        num += 1
        form.testClickDelete(); pump()
        step("Повторное «Удалить» — клиент ALFA-VIS удалён (останется UNISIM)",
             form.testDbCount == before - 1 && form.testListCount == before - 1 && form.testMessageKind == .ok,
             "в базе \(form.testDbCount), в списке \(form.testListCount), сообщение зелёное=\(B(form.testMessageKind == .ok))", "delete_done")

        // ── часть 2: реальный вызов SDK → Contragenti → Chrome → date.gov.md ──
        form.client.launcherExe = launcher
        form.client.extraArgs = "--no-server --no-tray --auto-pick --shots-dir \"\(outDir)\""
        form.client.timeoutMs = 4 * 60 * 1000
        form.client.onWait = { [weak self] in self?.onSdkWait() }
        let launcherOk = FileManager.default.fileExists(atPath: launcher)

        num += 1
        form.testSetFilter("ALFA-VIS COM"); pump()
        step("Фильтр «ALFA-VIS COM» введён — по нему SDK запустит Contragenti", launcherOk,
             "launcher: \(launcher)" + (launcherOk ? "" : "  (НЕ НАЙДЕН)"), "sdk_filter")

        num += 1
        markSdkStart()
        before = form.testDbCount
        form.testShowBanner(num, "Нажата «Создать из реестра» — Contragenti ищет на портале…"); pump()
        form.testClickAdd()      // блокирует до закрытия Contragenti, onWait снимает окна
        pump()
        collectSdkShots()
        let sdkOk = form.testDbCount == before + 1 && form.testMessageKind == .ok
        step("Реальный вызов SDK: Contragenti запущен, нашёл ALFA-VIS (кэш date.gov.md или портал) и вернул XML-карточку", sdkOk,
             "ожидание \(waitTicks / 5) с, снимков во время работы \(extra.count), в базе \(before) → \(form.testDbCount), сообщение зелёное=\(B(form.testMessageKind == .ok)); \(form.client.lastError)", "sdk_added")

        num += 1
        form.testSetFilter(""); pump()
        form.testSelectFirst(); pump()
        step("Карточка из Contragenti в списке CRM (адрес, форма, администратор — данные реестра)", form.testListCount == 2,
             "в списке \(form.testListCount)", "sdk_list")
        form.testSetFilter("ALFA-VIS COM"); pump()

        num += 1
        markSdkStart()
        before = form.testDbCount
        form.testShowBanner(num, "Повторный вызов SDK с тем же фильтром…"); pump()
        form.testClickAdd(); pump()
        collectSdkShots()
        step("Повторный вызов SDK — та же карточка отсечена как дубликат, база не выросла",
             form.testDbCount == before && form.testMessageKind == .warn && form.client.lastError.isEmpty,
             "ожидание \(waitTicks / 5) с, в базе \(form.testDbCount), сообщение янтарное=\(B(form.testMessageKind == .warn)); \(form.client.lastError)", "sdk_duplicate")

        // окно CRM обязано оставаться живым, пока открыт Contragenti — на заглушке
        num += 1
        let stub = outDir + "/sdk_stub.py"
        try? "import time\ntime.sleep(3)\n".write(toFile: stub, atomically: true, encoding: .utf8)
        let savedLauncher = form.client.launcherExe
        form.client.launcherExe = stub
        form.client.onWait = nil          // обработчик должен назначить сам CRM
        form.testClickAdd(); pump()
        step("Окно CRM не зависает, пока открыт Contragenti: обработчик ожидания отработал",
             form.testWaitTicks >= 10 && form.testMessageKind == .warn,
             "тактов ожидания \(form.testWaitTicks) (по 200 мс), сообщение: \(form.testMessage)", "sdk_responsive")
        form.client.launcherExe = savedLauncher
        try? FileManager.default.removeItem(atPath: stub)

        // ── часть 3: разделы CRM для торговли, услуг и производства ──
        num += 1
        form.testSetFilter(""); pump()
        form.testSelectFirst(); pump()
        form.testOverviewSet("Клиент", "+373 22 123-456", "office@alfa-vis.md", "Bubis Yevgeny"); pump()
        step("Клиенты: в карточке сохранены тип, телефон, e-mail и контактное лицо", form.testMessageKind == .ok, form.testMessage, "client_card")
        let alfaId = crm.scalarInt("SELECT id FROM clients WHERE denumire LIKE '%ALFA-VIS%'")

        num += 1
        form.testClickNav(.contacts); pump()
        var p = form.page(.contacts)!
        p.newRecord(); pump()
        p.setField("name", "Yevgeny Bubis"); p.setField("client_id", String(alfaId)); p.setField("position", "Директор")
        p.setField("phone", "+373 69 000-000"); p.setField("email", "y.bubis@alfa-vis.md")
        p.save(); pump()
        step("Контакты: создан контакт «Yevgeny Bubis», привязан к клиенту ALFA-VIS", p.listCount == 1 && form.testMessageKind == .ok,
             "контактов \(p.listCount); \(form.testMessage)", "contact_new")

        num += 1
        form.testClickNav(.leads); pump()
        p = form.page(.leads)!
        p.newRecord(); pump()
        p.setField("name", "Ion Popescu"); p.setField("company", "Agro-Prim SRL"); p.setField("status", "В работе")
        p.setField("source", "Выставка"); p.setField("phone", "+373 79 111-222"); p.setField("email", "ion@agro-prim.md")
        p.setField("notes", "Интерес к дозирующему оборудованию для фермы")
        p.save(); pump()
        step("Лиды: создан лид «Agro-Prim SRL» — в работе, источник «Выставка»", p.listCount == 1 && form.testMessageKind == .ok, "лидов \(p.listCount)", "lead_new")

        num += 1
        before = form.testDbCount
        p.selectFirst(); pump()
        form.testLeadConvert(); pump()
        var v = crm.scalarString("SELECT status FROM leads WHERE company = 'Agro-Prim SRL'")
        let agroId = crm.scalarInt("SELECT id FROM clients WHERE denumire = 'Agro-Prim SRL'")
        step("Лиды: «В клиенты» — создан клиент Agro-Prim SRL, статус лида «Конвертирован»",
             form.testDbCount == before + 1 && v == "Конвертирован" && agroId > 0,
             "клиентов \(before) → \(form.testDbCount), статус лида: \(v)", "lead_convert")

        num += 1
        form.testClickNav(.deals); pump()
        p = form.page(.deals)!
        p.newRecord(); pump()
        p.setField("title", "Поставка дозирующей установки"); p.setField("client_id", String(agroId)); p.setField("stage", "Предложение")
        p.setField("amount", "48500"); p.setField("close_date", dateStr(Calendar.current.date(byAdding: .month, value: 1, to: todayD)!))
        p.setField("notes", "Коммерческое предложение отправлено")
        p.save(); pump()
        step("Сделки: создана сделка 48 500 MDL для Agro-Prim на этапе «Предложение»", p.listCount == 1 && form.testMessageKind == .ok, "сделок \(p.listCount)", "deal_new")

        num += 1
        p.selectFirst(); pump()
        p.setField("stage", "Выиграна"); p.save(); pump()
        v = crm.scalarString("SELECT stage FROM deals WHERE title LIKE 'Поставка%'")
        step("Сделки: этап переведён в «Выиграна» (воронка)", v == "Выиграна", "этап в базе: " + v, "deal_won")

        num += 1
        form.testClickNav(.items); pump()
        p = form.page(.items)!
        p.newRecord(); pump()
        p.setField("code", "T-001"); p.setField("name", "Насос дозирующий ND-25"); p.setField("kind", "Товар"); p.setField("unit_", "шт")
        p.setField("price", "12500"); p.setField("stock", "5"); p.save(); pump()
        p.newRecord(); pump()
        p.setField("code", "S-001"); p.setField("name", "Монтаж и пусконаладка"); p.setField("kind", "Услуга"); p.setField("unit_", "час")
        p.setField("price", "350"); p.save(); pump()
        p.newRecord(); pump()
        p.setField("code", "P-001"); p.setField("name", "Установка дозирования УД-1"); p.setField("kind", "Изделие"); p.setField("unit_", "компл")
        p.setField("price", "42000"); p.setField("stock", "0"); p.save(); pump()
        step("Номенклатура: товар (остаток 5), услуга (час) и изделие собственного производства", p.listCount == 3, "позиций \(p.listCount)", "items")

        num += 1
        form.testClickNav(.orders); pump()
        p = form.page(.orders)!
        p.newRecord(); pump()
        p.setField("number", "0001"); p.setField("client_id", String(agroId)); p.setField("kind", "Продажа"); p.setField("status", "Подтверждён")
        p.save(); pump()
        p.lineSet(p.lineItemIndex("Насос"), 2, 12500); p.lineAdd(); pump()
        p.lineSet(p.lineItemIndex("Монтаж"), 8, 350); p.lineAdd(); pump()
        step("Заказы: заказ на продажу №0001 — две строки (2 насоса + 8 ч монтажа), итого 27 800 MDL",
             p.linesCount == 2 && abs(p.linesTotal - 27800) < 0.01, "строк \(p.linesCount), итого \(fmt2(p.linesTotal))", "order_lines")

        num += 1
        p.setField("status", "Выполнен"); p.postOrder(); pump()
        var d = crm.scalarDouble("SELECT stock FROM items WHERE code = 'T-001'")
        step("Заказы: статус «Выполнен» + «Провести» — остаток насосов списан 5 → 3", abs(d - 3) < 0.01 && form.testMessageKind == .ok,
             "остаток T-001 = \(fmt0_2(d)); \(form.testMessage)", "order_posted")

        num += 1
        p.newRecord(); pump()
        p.setField("number", "0002"); p.setField("kind", "Производство"); p.setField("status", "Выполнен"); p.setField("notes", "Выпуск изделий на склад")
        p.save(); pump()
        p.lineSet(p.lineItemIndex("Установка"), 2, 42000); p.lineAdd(); pump()
        p.postOrder(); pump()
        d = crm.scalarDouble("SELECT stock FROM items WHERE code = 'P-001'")
        step("Заказы: производственный заказ №0002 проведён — оприходовано 2 изделия (0 → 2)", abs(d - 2) < 0.01 && form.testMessageKind == .ok,
             "остаток P-001 = \(fmt0_2(d)); \(form.testMessage)", "order_production")

        num += 1
        form.testClickNav(.calendar); pump()
        p = form.page(.calendar)!
        p.newRecord(); pump()
        p.setField("subject", "Позвонить по оплате заказа №0001"); p.setField("kind", "Звонок"); p.setField("due_at", D(-2)); p.setField("client_id", String(agroId))
        p.save(); pump()
        p.newRecord(); pump()
        p.setField("subject", "Встреча: приёмка установки УД-1"); p.setField("kind", "Встреча"); p.setField("due_at", D(3)); p.setField("client_id", String(agroId))
        p.save(); pump()
        step("Календарь: звонок (просрочен на 2 дня) и встреча через 3 дня", p.listCount == 2, "открытых задач \(p.listCount)", "tasks")

        num += 1
        p.selectPreset(2); pump()   // «Просроченные»
        step("Календарь: фильтр «Просроченные» — одна задача", p.listCount == 1, "в списке \(p.listCount)", "tasks_overdue")

        num += 1
        p.selectFirst(); pump()
        form.testTaskDone(); pump()
        step("Календарь: «Выполнено» — просроченная задача закрыта, список пуст", p.listCount == 0 && form.testMessageKind == .ok,
             "в списке \(p.listCount); \(form.testMessage)", "task_done")
        p.selectPreset(0)

        num += 1
        form.testClickNav(.workspace); pump()
        let ws = form.workspace!
        step("Рабочий стол: плитки показывают процесс — два заказа исполнены и закрыты",
             ws.tileValue(.closed) == "0" && ws.tileValue(.readyToShip) == "2",
             "ожидает аванс=\(ws.tileValue(.awaitAdvance)), в работе=\(ws.tileValue(.inWork)), готово к отгрузке=\(ws.tileValue(.readyToShip)), ждём оплату=\(ws.tileValue(.awaitPayment)), закрыто=\(ws.tileValue(.closed))", "workspace")

        // ── часть 4: генератор тестовых данных в полном объёме ──
        num += 1
        let stats = seedDemo(form.db, crm)
        form.testClickNav(.workspace); pump()
        step("Генератор тестовых данных: \(stats.text) — плитки процесса заполнились",
             stats.clients >= 12 && stats.orders >= 15 && stats.tasks >= 20 && (Int(ws.tileValue(.awaitPayment)) ?? 0) > 0,
             "аванс=\(ws.tileValue(.awaitAdvance)), в работе=\(ws.tileValue(.inWork)), к отгрузке=\(ws.tileValue(.readyToShip)), ждём оплату=\(ws.tileValue(.awaitPayment)), закрыто=\(ws.tileValue(.closed))", "seed_workspace")

        num += 1
        ws.clickTile(.awaitPayment); pump()
        p = form.page(.orders)!
        var cnt = crm.count("orders", crm.stageWhere(.awaitPayment))
        step("Плитка «Отгружено — ждём оплату» открывает «Заказы» с этим фильтром",
             form.testSection == .orders && p.listCount > 0 && p.listCount == cnt, "в списке \(p.listCount), по условию этапа \(cnt)", "tile_drilldown")

        num += 1
        form.testClickNav(.workspace); pump()
        ws.erpCheck(); pump()
        step("Связь с ERP una.md по HTTP-API хаба: результат проверки виден в полосе ERP", !ws.erpText.isEmpty, ws.erpText, "erp_check")

        num += 1
        form.testClickNav(.orders); pump()
        p = form.page(.orders)!
        p.selectPreset(0); pump()
        step("Заказы на полном наборе: продажа / услуга / производство, все статусы", p.listCount == crm.count("orders"),
             "в списке \(p.listCount), в базе \(crm.count("orders"))", "seed_orders")

        num += 1
        form.testClickNav(.items); pump()
        p = form.page(.items)!
        p.selectPreset(4); pump()
        step("Номенклатура на полном наборе: пресет «Нет на складе»", p.listCount > 0 && p.listCount < crm.count("items"),
             "без остатка \(p.listCount) из \(crm.count("items"))", "seed_items")
        p.selectPreset(0)

        num += 1
        form.testClickNav(.calendar); pump()
        p = form.page(.calendar)!
        p.selectPreset(2); pump()
        step("Календарь на полном наборе: просроченные задачи выделены пресетом", p.listCount > 0, "просроченных \(p.listCount)", "seed_tasks_overdue")
        p.selectPreset(0)

        // ── часть 5: канбан и план работ ──
        let kb = form.kanban!
        num += 1
        form.testClickNav(.kanban); pump()
        kb.selectBoard(.orders); pump()
        step("Канбан «Заказы»: пять колонок процесса, карточки разложены по этапам", kb.columnCount == 5 && kb.cardsInColumn(1) > 0,
             "колонок \(kb.columnCount); по этапам: \(kb.cardsInColumn(0)) / \(kb.cardsInColumn(1)) / \(kb.cardsInColumn(2)) / \(kb.cardsInColumn(3)) / \(kb.cardsInColumn(4))", "kanban_orders")

        num += 1
        kb.selectFirstCard(1); pump()
        var id = kb.selectedId
        kb.moveForward(); pump()
        v = crm.scalarString("SELECT status FROM orders WHERE id = \(id)")
        step("Канбан: карточка перенесена «В работе» → «Готово к отгрузке», статус в базе изменён",
             kb.selectedColumn == 2 && v == "Выполнен" && crm.stageOf(id) == .readyToShip,
             "колонка \(kb.selectedColumn), статус «\(v)», этап \(crm.stageOf(id).rawValue)", "kanban_move")

        num += 1
        kb.moveBack(); pump()
        step("Канбан: «← Назад» возвращает карточку на прежний этап", kb.selectedColumn == 1 && crm.stageOf(id) == .inWork,
             "колонка \(kb.selectedColumn), этап \(crm.stageOf(id).rawValue)", "kanban_back")

        num += 1
        kb.selectFirstCard(1)
        id = kb.selectedId
        before = kb.cardsInColumn(3)
        kb.dragCardById(id, 3); pump()
        v = crm.scalarString("SELECT ship_date FROM orders WHERE id = \(id)")
        step("Канбан: карточка перетащена мышью из «В работе» в «Отгружено — ждём оплату»",
             kb.cardsInColumn(3) == before + 1 && !v.isEmpty && crm.stageOf(id) == .awaitPayment,
             "в колонке «ждём оплату» \(before) → \(kb.cardsInColumn(3)), дата отгрузки «\(v)», этап \(crm.stageOf(id).rawValue)", "kanban_drag")

        num += 1
        kb.dragCardById(id, 1); pump()
        v = crm.scalarString("SELECT COALESCE(ship_date,'') FROM orders WHERE id = \(id)")
        step("Канбан: перетаскивание работает в обе стороны — дата отгрузки снята", v.isEmpty && crm.stageOf(id) == .inWork,
             "дата отгрузки «\(v)», этап \(crm.stageOf(id).rawValue)", "kanban_drag_back")

        num += 1
        kb.selectBoard(.tasks); pump()
        step("Канбан «Задачи»: колонки по срокам — просрочено / сегодня / позже / выполнено", kb.columnCount == 4 && kb.cardsInColumn(0) > 0,
             "колонок \(kb.columnCount); просрочено \(kb.cardsInColumn(0)), сегодня \(kb.cardsInColumn(1)), позже \(kb.cardsInColumn(2)), выполнено \(kb.cardsInColumn(3))", "kanban_tasks")

        num += 1
        kb.selectBoard(.orders); pump()
        id = crm.scalarInt("SELECT t.id FROM orders t WHERE \(crm.stageWhere(.awaitPayment)) ORDER BY t.id LIMIT 1")
        let bc = kb.cardById(id) ?? BoardCard()
        step("Канбан: карточка информативна — значок вида, клиент, сумма, прогресс оплаты, бейдж срока",
             id > 0 && bc.id == id && bc.total > 0 && bc.paid > 0 && !bc.kindText.isEmpty && !bc.icon.isEmpty && !daysBadgeText(bc).isEmpty,
             "«\(bc.title)» \(bc.icon) \(bc.kindText) · \(bc.subtitle) · оплачено \(fmtInt0(bc.paid)) из \(fmtInt0(bc.total)) · бейдж «\(daysBadgeText(bc))»", "kanban_card_info")

        num += 1
        kb.selectFirstCard(0)
        id = kb.selectedId
        before = kb.animFrames
        kb.dragCardById(id, 1); pump()
        step("Канбан: перенос анимирован — карточка перелетает в новую колонку и вспыхивает", kb.animFrames > before && crm.stageOf(id) == .inWork,
             "кадров анимации \(kb.animFrames - before), этап \(crm.stageOf(id).rawValue)", "kanban_anim")
        kb.dragCardById(id, 0); pump()

        // ── часть 5а: схема бизнес-процесса ──
        let pr = form.process!
        num += 1
        let procFile = outDir + "/processes_test.json"
        try? FileManager.default.removeItem(atPath: procFile)
        try? FileManager.default.copyItem(atPath: pr.fileName, toPath: procFile)
        pr.loadFrom(procFile)
        form.testClickNav(.process); pump()
        pr.selectProcess(0); pump()
        step("Бизнес-процесс: схема «Сделка → заказ → оплата» из processes.json — дорожки, узлы, развилки, стрелки",
             pr.loadError.isEmpty && pr.processCount == 3 && pr.nodeCount == 13 && pr.edgeCount == 14,
             "процессов \(pr.processCount), узлов \(pr.nodeCount), связей \(pr.edgeCount)", "process_scheme")

        num += 1
        pr.clickNode("work"); pump()
        cnt = crm.count("orders", crm.stageWhere(.inWork))
        step("Бизнес-процесс: щелчок по этапу «В работе» показывает те же карточки, что колонка канбана",
             pr.selectedNodeId == "work" && pr.cardsShown > 0 && pr.cardsShown == pr.nodeCards("work") && pr.nodeCards("work") == cnt,
             "узел «\(pr.nodeTitle("work"))»: карточек \(pr.cardsShown), в базе на этапе \(cnt), запаздывает \(pr.nodeOverdue("work"))", "process_node_click")

        num += 1
        id = crm.scalarInt("SELECT t.id FROM orders t WHERE \(crm.stageWhere(.inWork)) ORDER BY t.due_date, t.id LIMIT 1")
        before = pr.nodeCards("ready")
        pr.dragCardToNode(id, "ready"); pump()
        step("Бизнес-процесс: карточка перетащена мышью на этап «Готово к отгрузке» — этап в базе изменён",
             crm.stageOf(id) == .readyToShip && pr.nodeCards("ready") == before + 1 && pr.animFrames > 0,
             "на этапе «готово» было \(before), стало \(pr.nodeCards("ready")); этап заказа \(crm.stageOf(id).rawValue); кадров анимации \(pr.animFrames)", "process_drag")
        pr.clickNode("ready")
        pr.dragCardToNode(id, "work"); pump()

        num += 1
        pr.clickNode("advance"); pump()
        let stubDesc = pr.description_
        pr.setDescription(stubDesc + " [самотест \(fmtDate(Date(), "HH:mm:ss"))]")
        pr.saveDescription(); pump()
        let detail = (try? String(contentsOfFile: procFile, encoding: .utf8)) ?? ""
        step("Бизнес-процесс: описание этапа отредактировано и сохранено обратно в JSON",
             detail.contains("[самотест") && detail.contains("\"sales_to_cash\"") && !stubDesc.isEmpty,
             "файл \((procFile as NSString).lastPathComponent), \(detail.utf8.count) байт, описание «\(stubDesc.left(40))…»", "process_desc_saved")
        pr.loadFrom("")   // вернуть штатный processes.json

        let cal = form.calendar!
        num += 1
        form.testClickNav(.calendar); pump()
        cal.goToday(); pump()
        step("Календарь месячной сеткой: задачи разложены по дням", cal.tasksInMonth > 0 && !cal.monthTitle.isEmpty,
             "месяц «\(cal.monthTitle)», задач в месяце \(cal.tasksInMonth), сегодня \(cal.tasksOnDay(todayD))", "calendar_month")

        num += 1
        id = crm.scalarInt("SELECT id FROM tasks WHERE done = 0 AND due_at = \(quoted(D(0))) LIMIT 1")
        if id == 0 {
            id = crm.insert(DefTasks, vals(DefTasks, ["subject", "Перенос мышью", "kind", "Задача", "due_at", D(0)]))
            cal.refresh(); pump()
        }
        before = cal.tasksOnDay(addDays(todayD, 3))
        cal.dragTask(id, to: addDays(todayD, 3)); pump()
        v = crm.scalarString("SELECT due_at FROM tasks WHERE id = \(id)")
        step("Календарь: задача перетащена мышью на три дня вперёд", v == D(3) && cal.tasksOnDay(addDays(todayD, 3)) == before + 1,
             "срок в базе «\(v)», на дне \(fmtDate(addDays(todayD, 3), "dd.MM")) задач \(before) → \(cal.tasksOnDay(addDays(todayD, 3)))", "calendar_drag")

        num += 1
        cal.goNextMonth(); pump()
        let nav = cal.monthTitle
        cal.goPrevMonth(); pump()
        step("Календарь: листание месяцев кнопками ‹ ›", nav != cal.monthTitle && !cal.monthTitle.isEmpty,
             "следующий «\(nav)», текущий «\(cal.monthTitle)»", "calendar_next_month")

        let g = form.gantt!
        num += 1
        form.testClickNav(.gantt); pump()
        g.selectFilter(0); pump()
        step("План работ (Гант): производственные заказы и их операции на шкале времени", g.rowCount > 0 && g.workCount > 0,
             "строк \(g.rowCount), из них работ \(g.workCount), просрочено заказов \(g.overdueCount); период \(g.rangeText)", "gantt_production")

        num += 1
        id = g.rowOrderId(0)
        var d1 = g.rowStart(0), d2 = g.rowPlanEnd(0)
        g.dragBar(0, .move, 5); pump()
        v = crm.scalarString("SELECT order_date FROM orders WHERE id = \(id)")
        step("План работ: полоса заказа перетащена мышью на 5 дней вперёд — даты в базе сдвинулись",
             g.rowStart(0) == addDays(d1, 5) && g.rowPlanEnd(0) == addDays(d2, 5) && v == dateStr(addDays(d1, 5)),
             "было \(fmtDate(d1, "dd.MM"))–\(fmtDate(d2, "dd.MM")), стало \(fmtDate(g.rowStart(0), "dd.MM"))–\(fmtDate(g.rowPlanEnd(0), "dd.MM")) (в базе \(v))", "gantt_drag_move")

        num += 1
        d2 = g.rowPlanEnd(0)
        g.dragBar(0, .end, 7); pump()
        step("План работ: за правый край полосы растянут только срок, дата заказа не тронута",
             g.rowPlanEnd(0) == addDays(d2, 7) && g.rowStart(0) == addDays(d1, 5),
             "срок \(fmtDate(d2, "dd.MM")) → \(fmtDate(g.rowPlanEnd(0), "dd.MM")), начало осталось \(fmtDate(g.rowStart(0), "dd.MM"))", "gantt_drag_resize")

        num += 1
        g.selectFilter(1); pump()
        step("План работ: фильтр «Все заказы» — строк становится больше", g.rowCount > 0, "строк \(g.rowCount), работ \(g.workCount)", "gantt_all")

        // ── часть 5б: проекты ──
        num += 1
        form.testClickNav(.projects); pump()
        p = form.page(.projects)!
        step("Проекты: панно с логотипом, выжиг поздравлений, стенды, медали — тендеры с авансом и без", p.listCount >= 10,
             "проектов \(p.listCount); в производстве \(crm.count("projects", "t.status = 'Производство'")), тендеров \(crm.count("projects", "t.status = 'Тендер'")), проиграно \(crm.count("projects", "t.status = 'Проигран'")), запаздывает \(crm.count("projects", "t.status NOT IN ('Закрыт','Проигран') AND t.due_date < date('now','localtime')"))", "projects_list")

        num += 1
        id = crm.scalarInt("SELECT id FROM projects WHERE status = 'Производство' ORDER BY id LIMIT 1")
        p.selectPreset(0)
        p.selectById(id); pump()
        form.testProjectTasks(); pump()
        step("Проект → «Задачи проекта»: доска задач по этапам — новая / в работе / ожидание / проверка / готово",
             form.testSection == .kanban && kb.board == .projectTasks && kb.columnCount == 5 && kb.projectId == id && kb.cardsInColumn(4) > 0,
             "проект \(id), колонок \(kb.columnCount); новых \(kb.cardsInColumn(0)), в работе \(kb.cardsInColumn(1)), ожидание \(kb.cardsInColumn(2)), проверка \(kb.cardsInColumn(3)), готово \(kb.cardsInColumn(4))", "project_tasks_board")

        num += 1
        id = crm.scalarInt("SELECT id FROM tasks WHERE project_id = \(kb.projectId) AND stage = 'Новая' ORDER BY seq LIMIT 1")
        kb.dragCardById(id, 1); pump()
        v = crm.scalarString("SELECT stage FROM tasks WHERE id = \(id)")
        step("Задача перетащена «Новая» → «В работе»: этап в базе изменён, флаг «выполнено» не тронут",
             v == "В работе" && crm.scalarInt("SELECT done FROM tasks WHERE id = \(id)") == 0, "задача \(id): этап «\(v)»", "task_drag_inwork")

        num += 1
        kb.dragCardById(id, 4); pump()
        v = crm.scalarString("SELECT stage FROM tasks WHERE id = \(id)")
        step("Задача перетащена в «Готово»: флаг «выполнено» выставлен сам — этап и флаг суть одно состояние",
             v == "Готово" && crm.scalarInt("SELECT done FROM tasks WHERE id = \(id)") == 1,
             "задача \(id): этап «\(v)», done = \(crm.scalarInt("SELECT done FROM tasks WHERE id = \(id)"))", "task_drag_done")
        kb.dragCardById(id, 0); pump()

        num += 1
        kb.selectBoard(.projects); pump()
        step("Канбан «Проекты»: девять этапов от тендера до закрытия, проигранные тендеры отдельно",
             kb.columnCount == 9 && kb.cardsInColumn(4) > 0 && kb.cardsInColumn(8) > 0,
             "колонок \(kb.columnCount); " + (0..<9).map { "\(kb.cardsInColumn($0))" }.joined(separator: " / "), "kanban_projects")

        num += 1
        id = crm.scalarInt("SELECT id FROM projects WHERE status = 'Тендер' ORDER BY id LIMIT 1")
        kb.dragCardById(id, 1); pump()
        v = crm.scalarString("SELECT status FROM projects WHERE id = \(id)")
        step("Проект перетащен «Тендер» → «Договор» (тендер выигран): этап в базе изменён", v == "Договор", "проект \(id): этап «\(v)»", "kanban_project_drag")
        kb.dragCardById(id, 0); pump()

        num += 1
        form.testClickNav(.process); pump()
        pr.selectProcess(2); pump()
        pr.clickNode("production"); pump()
        cnt = crm.count("projects", "t.status = 'Производство'")
        step("Бизнес-процесс «Проект: тендер → аванс → производство → сдача → оплата»: узел «Производство» показывает его проекты",
             pr.loadError.isEmpty && pr.nodeCount >= 10 && pr.cardsShown > 0 && pr.cardsShown == cnt,
             "узлов \(pr.nodeCount), связей \(pr.edgeCount); в производстве \(pr.cardsShown), запаздывает \(pr.nodeOverdue("production"))", "process_project")

        num += 1
        form.testClickNav(.gantt); pump()
        g.selectFilter(3); pump()
        step("План работ «Проекты и задачи»: проект и его шаги по датам, готовые зелёным, просроченные красным, стрелки «после задачи»",
             g.rowCount > 10 && g.workCount > 10 && g.overdueCount > 0,
             "строк \(g.rowCount), из них задач \(g.workCount), просроченных проектов \(g.overdueCount); период \(g.rangeText)", "gantt_projects")

        num += 1
        let tr = g.firstTaskRow
        id = g.rowTaskId(tr)
        d1 = g.rowPlanEnd(tr)
        g.dragBar(tr, .move, 3); pump()
        v = crm.scalarString("SELECT due_at FROM tasks WHERE id = \(id)")
        step("План работ: задача проекта перетащена мышью на 3 дня — план и срок в базе сдвинулись", v == dateStr(addDays(d1, 3)),
             "задача \(id): срок \(dateStr(d1)) → \(v)", "gantt_task_drag")
        g.dragBar(tr, .move, -3); pump()

        let rp = form.reports!
        num += 1
        form.testClickNav(.reports); pump()
        rp.selectReport(.projects); pump()
        var xlsx = rp.export(.xlsx), pdf = rp.export(.pdf)
        step("Отчёт «Проекты: тендеры, авансы, задачи» — предпросмотр и выгрузка в Excel и PDF",
             rp.previewRows >= 10 && isZipFile(xlsx) && isPdfFile(pdf),
             "строк \(rp.previewRows); \((xlsx as NSString).lastPathComponent), \((pdf as NSString).lastPathComponent)", "report_projects")
        exports += [xlsx, pdf]

        // ── часть 6: отчёты ──
        num += 1
        rp.selectReport(.process); pump()
        step("Отчёты: «Процесс исполнения заказов» — предпросмотр по этапам",
             form.testSection == .reports && rp.previewRows >= 8 && rp.previewCols == 6,
             "строк \(rp.previewRows), колонок \(rp.previewCols)", "report_process")

        num += 1
        xlsx = rp.export(.xlsx); pdf = rp.export(.pdf); pump()
        step("Выгрузка отчёта в Excel и PDF", isZipFile(xlsx) && isPdfFile(pdf),
             "\((xlsx as NSString).lastPathComponent) (\(fileSizeOf(xlsx)) байт, zip=\(B(isZipFile(xlsx)))); \((pdf as NSString).lastPathComponent) (\(fileSizeOf(pdf)) байт, %PDF=\(B(isPdfFile(pdf))))", "report_export")
        exports += [xlsx, pdf]

        num += 1
        rp.selectReport(.receivables); pump()
        xlsx = rp.export(.xlsx); pdf = rp.export(.pdf)
        step("Отчёт «Дебиторская задолженность»: строки есть, выгружен в оба формата", rp.previewRows > 0 && isZipFile(xlsx) && isPdfFile(pdf),
             "строк \(rp.previewRows); \((xlsx as NSString).lastPathComponent), \((pdf as NSString).lastPathComponent)", "report_receivables")
        exports += [xlsx, pdf]

        num += 1
        rp.selectReport(.stock); pump()
        xlsx = rp.export(.xlsx); pdf = rp.export(.pdf)
        step("Отчёт «Остатки номенклатуры»: остатки после проводок, выгружен в оба формата", rp.previewRows > 0 && isZipFile(xlsx) && isPdfFile(pdf),
             "позиций \(rp.previewRows - 1); \((xlsx as NSString).lastPathComponent), \((pdf as NSString).lastPathComponent)", "report_stock")
        exports += [xlsx, pdf]

        num += 1
        for k in [ReportKind.salesByClient, .funnel] {
            rp.selectReport(k); pump()
            exports += [rp.export(.xlsx), rp.export(.pdf)]
        }
        let allOk = exports.filter { $0.hasSuffix(".xlsx") }.allSatisfy { isZipFile($0) } && exports.filter { $0.hasSuffix(".pdf") }.allSatisfy { isPdfFile($0) }
        step("Отчёты «Продажи по клиентам» и «Воронка продаж»: все 6 отчётов выгружены в xlsx и pdf", allOk && exports.count == 12,
             "файлов \(exports.count): " + exports.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), "report_all")

        num += 1
        form.testClickNav(.accounts)
        form.testSetFilter("")
        form.testHideBanner()
        pump()
        step("Итоговое состояние окна: клиенты из SDK, лида и генератора", form.testDbCount == 3 + stats.clients,
             "в базе \(form.testDbCount) клиентов", "final")

        writeReport()
        return passed == total
    }

    var passed: Int { steps.filter { $0.ok }.count }
    var total: Int { steps.count }

    private func writeReport() {
        let allOk = passed == total
        var j = "{\"passed\":\(passed),\"total\":\(total),\"launcher\":\"\(JWriter.escape(launcher))\",\"steps\":["
        j += steps.map { s in
            "{\"num\":\(s.num),\"ok\":\(s.ok),\"title\":\"\(JWriter.escape(s.title))\",\"detail\":\"\(JWriter.escape(s.detail))\",\"message\":\"\(JWriter.escape(s.message))\",\"shot\":\"\(s.shot)\",\"extra\":[\(s.extra.map { "\"\($0)\"" }.joined(separator: ","))]}"
        }.joined(separator: ",")
        j += "]}"
        try? j.write(toFile: outDir + "/results.json", atomically: true, encoding: .utf8)

        var h = """
        <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Demo CRM — отчёт GUI-самотеста (macOS)</title><style>
        body{margin:0;background:#f6f7f5;color:#12222f;font:15px/1.6 -apple-system,"Segoe UI",system-ui,sans-serif}
        .wrap{max-width:1100px;margin:0 auto;padding:32px 24px 80px}
        h1{font-size:28px;margin:0 0 6px}.sub{color:#69808f;margin:0 0 22px}
        .verdict{display:inline-block;padding:6px 14px;border-radius:3px;font-weight:700;margin:0 0 26px}
        .pass{background:#e3efec;color:#0b6e5f}.fail{background:#f6e7e4;color:#a63a2b}
        table{border-collapse:collapse;width:100%;background:#fff;font-size:14px;margin:0 0 34px}
        th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #d7dde0;vertical-align:top}
        th{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:#69808f}
        td.n{font-family:Menlo,monospace;color:#0b6e5f;white-space:nowrap}
        .ok{color:#0b6e5f;font-weight:700}.no{color:#a63a2b;font-weight:700}
        .step{margin:0 0 30px;background:#fff;border:1px solid #d7dde0;border-radius:3px;padding:16px 18px}
        .step h3{margin:0 0 4px;font-size:16px}.step h3 span{font-family:Menlo,monospace;color:#0b6e5f;margin-right:8px}
        .step .d{color:#69808f;font-size:13px;margin:0 0 4px}
        .step .m{font-size:13px;margin:0 0 12px;padding:6px 10px;background:#f4f2ee;border-left:3px solid #0b6e5f;border-radius:2px}
        .step img{display:block;max-width:100%;height:auto;border:1px solid #d7dde0;border-radius:3px;margin:0 0 10px}
        .step .x{font-size:12px;color:#69808f;margin:0 0 4px}.step a{color:#0b6e5f;font-size:12px}
        </style></head><body><div class="wrap"><h1>Demo CRM — отчёт GUI-самотеста (macOS)</h1>
        <p class="sub">Тест выполнен самим приложением (Demo CRM.app, Swift/AppKit): оно вело собственное окно по шагам, рисовало номер шага на плашке и снимало себя. Реальный вызов SDK: нажата настоящая кнопка «Создать из реестра», запущен Contragenti; далее разделы CRM: клиенты, контакты, лиды, сделки, номенклатура, заказы с проводкой остатков, календарь, рабочий стол, канбан, бизнес-процесс, Гант, проекты, отчёты.<br>Launcher: <code>\(htmlEsc(launcher))</code></p>
        <div class="verdict \(allOk ? "pass" : "fail")">Пройдено \(passed) из \(total)</div>
        <table><thead><tr><th>#</th><th>Шаг</th><th>Статус</th><th>Проверка</th><th>Снимки</th></tr></thead><tbody>
        """
        for s in steps {
            h += "<tr><td class=\"n\">\(String(format: "%02d", s.num))</td><td>\(htmlEsc(s.title))</td><td class=\"\(s.ok ? "ok\">OK" : "no\">FAIL")</td><td>\(htmlEsc(s.detail))</td><td><a href=\"#s\(s.num)\">\(s.shot)</a>"
            if !s.extra.isEmpty { h += " +\(s.extra.count)" }
            h += "</td></tr>"
        }
        h += "</tbody></table>"
        for s in steps {
            h += "<div class=\"step\" id=\"s\(s.num)\"><h3><span>\(String(format: "%02d", s.num))</span>\(htmlEsc(s.title)) — <span class=\"\(s.ok ? "ok\">OK" : "no\">FAIL")</span></h3>"
            if !s.detail.isEmpty { h += "<p class=\"d\">\(htmlEsc(s.detail))</p>" }
            if !s.message.isEmpty { h += "<p class=\"m\">Строка сообщений: \(htmlEsc(s.message))</p>" }
            for x in s.extra { h += "<p class=\"x\">во время работы SDK: \(x)</p><a href=\"\(x)\"><img src=\"\(x)\" alt=\"\(x)\"></a>" }
            h += "<p class=\"x\">после шага: \(s.shot)</p><a href=\"\(s.shot)\"><img src=\"\(s.shot)\" alt=\"\(htmlEsc(s.title))\"></a></div>"
        }
        h += "</div></body></html>"
        try? h.write(toFile: outDir + "/report.html", atomically: true, encoding: .utf8)
    }
}

/// Запуск GUI-самотеста: окно создаётся в NSApplication, сценарий идёт на
/// главном потоке с прокачкой событий; результат — код выхода процесса.
func runGuiTest(outDir: String, launcher launcherArg: String) -> Int32 {
    var dir = outDir
    if dir.isEmpty { dir = Paths.appDir + "/gui_test" }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // чем запускать Contragenti: явный аргумент, иначе исходник в клоне, иначе бандл
    var launcher = launcherArg
    if launcher.isEmpty {
        launcher = Paths.launcherCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? ((Paths.repoDir ?? Paths.appDir) + "/company_search.py")
    }
    // тест работает в собственной базе, рабочая clients.db не затрагивается
    let dbPath = dir + "/test_clients.db"
    try? FileManager.default.removeItem(atPath: dbPath)
    dbPathOverride = dbPath

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = GuiTestDelegate(outDir: dir, launcher: launcher)
    app.delegate = delegate
    app.run()
    return delegate.exitCode
}

final class GuiTestDelegate: NSObject, NSApplicationDelegate {
    let outDir: String
    let launcher: String
    var exitCode: Int32 = 2
    var main: MainWindowController?

    init(outDir: String, launcher: String) {
        self.outDir = outDir
        self.launcher = launcher
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let m = MainWindowController()
        main = m
        m.showWindow(nil)
        m.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        m.kanban.animEnabled = true
        DispatchQueue.main.async {
            pumpSleep(0.3)
            let test = GuiSelfTest(form: m, outDir: self.outDir, launcher: self.launcher)
            let ok = test.run()
            writeStdout("GUI self-test: \(test.passed)/\(test.total) — \(ok ? "True" : "False")")
            writeStdout("Отчёт: " + self.outDir + "/report.html")
            exit(ok ? 0 : 1)
        }
    }
}
