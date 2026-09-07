// Главное окно CRM (аналог uMainForm.pas): боковая навигация, верхняя полоса,
// разделы, панель входа поверх содержимого, панель настроек, строка
// сообщений. Никаких модальных окон: сообщения — в цветной строке внизу,
// удаление — повторным нажатием, необработанные ошибки — туда же.
import AppKit

enum NavSection: Int, CaseIterable {
    case workspace = 0, kanban, process, gantt, accounts, contacts, leads, deals, items, orders, projects, calendar, reports, settings

    var key: String {
        ["nav.workspace", "nav.kanban", "nav.process", "nav.gantt", "nav.clients", "nav.contacts", "nav.leads", "nav.deals",
         "nav.items", "nav.orders", "nav.projects", "nav.calendar", "nav.reports", "nav.settings"][rawValue]
    }
    var glyph: String {
        ["⌂", "▦", "⇶", "▤", "▣", "☺", "✉", "$", "▤", "▥", "⚑", "▦", "▤", "⚙"][rawValue]
    }
}

/// Путь к базе для тестов (аналог GDBPathOverride).
var dbPathOverride = ""

private let NAV_WIDTH: CGFloat = 232, NAV_ITEM_H: CGFloat = 40, TOPBAR_H: CGFloat = 32
private let OV_LABELS = ["Название", "IDNO", "Форма", "Адрес", "Руководитель", "Добавлен"]
private let COL_WIDTHS: [CGFloat] = [300, 120, 90, 230, 150, 120]

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let db: ClientsDB
    let crm: CrmData
    let client = ContragentiClient()
    let erp = ErpClient()
    private let iniPath: String
    private var pendingDeleteId = 0
    private(set) var section: NavSection = .workspace
    private var adding = false
    private(set) var waitTicks = 0
    private(set) var user = ""

    private let root = FlippedView(bg: ESPO_BODY)
    private let testBanner = FlippedView(bg: NSColor(hex: 0xFFE8D9))
    private var testBannerLabel: NSTextField!
    private let sidebar = FlippedView(bg: ESPO_BODY)
    private var navItems: [NavSection: FlippedView] = [:]
    private var navLabels: [NavSection: NSTextField] = [:]
    private let topBar = FlippedView(bg: ESPO_BODY)
    private var globalSearch: NSTextField!
    private let content = FlippedView(bg: ESPO_BODY)
    private let msgBar = FlippedView(bg: ST_PRIMARY_BG)
    private var msgLabel: NSTextField!
    private var msgKind: MsgKind = .info

    // «Клиенты»
    private let pageAccounts = LayoutView(bg: ESPO_BODY)
    private var btnAdd: EspoButton!, btnDelete: EspoButton!, btnRefresh: EspoButton!
    private var preset: NSPopUpButton!
    private var search: NSTextField!
    private var pager: NSTextField!
    private var listScroll: NSScrollView!
    private var list: NSTableView!
    private var clientRows: [ClientRow] = []
    private var overview: PanelBox!
    private var ovValues: [NSTextField] = []
    private var ovType: NSPopUpButton!
    private var ovPhone: NSTextField!, ovEmail: NSTextField!, ovContact: NSTextField!
    private var accHeader: FlippedView!, accSearchRow: FlippedView!

    // универсальные страницы
    private var pages: [NavSection: EntityPage] = [:]
    private(set) var workspace: WorkspacePage!
    private(set) var reports: ReportsPage!
    private(set) var kanban: KanbanPage!
    private(set) var process: ProcessPage!
    private(set) var gantt: GanttPage!
    private(set) var calendar: CalendarPage!
    private var calendarAsGrid = true

    // вход
    private let loginPanel = FlippedView(bg: ESPO_BODY)
    private var loginBox: PanelBox!
    private var loginUser: NSTextField!, loginPass: NSTextField!
    private var loginLang: NSPopUpButton!
    private var loginError: NSTextField!

    // настройки
    private let settingsPanel = FlippedView(bg: ST_PRIMARY_BG)
    private var launcherEdit: NSTextField!, erpUrlEdit: NSTextField!, erpKeyEdit: NSTextField!, passEdit: NSTextField!
    private var langEdit: NSPopUpButton!

    init() {
        iniPath = Paths.crmDataDir + "crm.ini"
        let dbPath = dbPathOverride.isEmpty ? Paths.crmDataDir + "clients.db" : dbPathOverride
        db = ClientsDB(path: dbPath)
        do { try db.open() } catch { FileHandle.standardError.write("DB: \(error)\n".data(using: .utf8)!) }
        crm = CrmData(db)
        crm.ensureSchema()
        crm.ensureAdmin()
        // язык из UserDefaults: переживает переустановку и не зависит от crm.ini
        if !T.load() { T.useLang("ru") }
        T.useLang(I18n.readLangFromDefaults("ro"))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Demo CRM · Клиенты"
        win.minSize = NSSize(width: 1000, height: 640)
        win.center()
        super.init(window: win)
        win.delegate = self
        db.db.onError = { [weak self] msg in self?.say(.err, "Ошибка: " + msg) }
        loadSettings()
        buildUI()
        refreshList()
        selectSection(.workspace)
        buildLogin()
        if !T.loaded { say(.warn, "Переводы не загружены: " + T.error) }
        else { say(.info, "База: \(db.dbPath)   |   клиентов: \(db.count())") }
    }

    required init?(coder: NSCoder) { fatalError() }

    // ── каркас ──

    private func buildUI() {
        guard let win = window else { return }
        root.frame = win.contentView!.bounds
        root.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(root)

        testBanner.isHidden = true
        testBannerLabel = makeLabel(testBanner, "", x: 12, y: 6, w: 1200, h: 20, color: NSColor(hex: 0x803A20), size: 10, bold: true)
        root.addSubview(testBanner)

        msgLabel = makeLabel(msgBar, "", x: 12, y: 6, w: 1200, h: 20, color: ST_PRIMARY_FG, size: 10, bold: true)
        msgLabel.autoresizingMask = [.width]
        root.addSubview(msgBar)

        buildSidebar()
        buildTopBar()
        root.addSubview(content)
        buildSettingsPanel()
        buildAccountsPage()
        buildEntityPages()
        buildWorkspacePages()
        root.needsLayout = true
        layoutRoot()
    }

    private func layoutRoot() {
        let b = root.bounds
        var top: CGFloat = 0
        if !testBanner.isHidden { testBanner.frame = NSRect(x: 0, y: 0, width: b.width, height: 30); top = 30 }
        msgBar.frame = NSRect(x: 0, y: b.height - 30, width: b.width, height: 30)
        sidebar.frame = NSRect(x: 0, y: top, width: NAV_WIDTH, height: b.height - 30 - top)
        topBar.frame = NSRect(x: NAV_WIDTH, y: top, width: b.width - NAV_WIDTH, height: TOPBAR_H)
        content.frame = NSRect(x: NAV_WIDTH, y: top + TOPBAR_H, width: b.width - NAV_WIDTH, height: b.height - 30 - top - TOPBAR_H)
        loginPanel.frame = NSRect(x: 0, y: top, width: b.width, height: b.height - 30 - top)
        if let lb = loginBox { lb.frame.origin.x = max(10, (loginPanel.bounds.width - lb.frame.width) / 2) }
        globalSearch.frame = NSRect(x: topBar.bounds.width - 260 - 34 - 34 - 120 - 12, y: 4, width: 260, height: 24)
        layoutContent()
    }

    private func layoutContent() {
        var y: CGFloat = 0
        if !settingsPanel.isHidden {
            settingsPanel.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: 128)
            y = 128
        }
        let r = NSRect(x: 0, y: y, width: content.bounds.width, height: content.bounds.height - y)
        for v in [pageAccounts, workspace, reports, kanban, process, gantt, calendar] as [NSView?] { v?.frame = r; v?.needsLayout = true }
        for p in pages.values { p.frame = r; p.needsLayout = true }
        topBarRelayout?()
    }

    func windowDidResize(_ notification: Notification) { layoutRoot() }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    private func addNavItem(_ s: NavSection) {
        let p = FlippedView(bg: ESPO_BODY)
        p.onClick = { [weak self] in self?.onNavClick(s) }
        sidebar.addSubview(p)
        makeLabel(p, s.glyph, x: 16, y: 9, w: 20, h: 22, color: ESPO_GRAY, size: 11)
        let l = makeLabel(p, T.S(s.key), x: 44, y: 10, w: 170, h: 22, color: ESPO_TEXT, size: 10)
        navItems[s] = p
        navLabels[s] = l
    }

    private func buildSidebar() {
        root.addSubview(sidebar)
        let line = FlippedView(bg: ESPO_BORDER)
        line.frame = NSRect(x: NAV_WIDTH - 1, y: 0, width: 1, height: 2000)
        line.autoresizingMask = [.height]
        sidebar.addSubview(line)
        makeLabel(sidebar, T.S("app.title"), x: 18, y: 14, w: 200, h: 26, color: ESPO_PRIMARY, size: 14, bold: true)
        makeLabel(sidebar, T.S("app.subtitle"), x: 19, y: 40, w: 200, h: 16, color: ESPO_MUTED, size: 8)
        var y: CGFloat = 65
        for s in NavSection.allCases where s != .settings {
            addNavItem(s)
            navItems[s]?.frame = NSRect(x: 0, y: y, width: NAV_WIDTH - 1, height: NAV_ITEM_H)
            y += NAV_ITEM_H
        }
        let sep = FlippedView(bg: ESPO_BORDER)
        sep.frame = NSRect(x: 16, y: y + 4, width: NAV_WIDTH - 33, height: 1)
        sidebar.addSubview(sep)
        y += 9
        addNavItem(.settings)
        navItems[.settings]?.frame = NSRect(x: 0, y: y, width: NAV_WIDTH - 1, height: NAV_ITEM_H)
    }

    private func buildTopBar() {
        root.addSubview(topBar)
        let line = FlippedView(bg: ESPO_BORDER)
        line.frame = NSRect(x: 0, y: TOPBAR_H - 1, width: 3000, height: 1)
        topBar.addSubview(line)
        let userL = makeLabel(topBar, T.S("app.user") + "  ⋮", x: 0, y: 6, w: 120, color: ESPO_TEXT, size: 10, align: .center)
        userL.autoresizingMask = [.minXMargin]
        let bell = makeLabel(topBar, "🔔", x: 0, y: 6, w: 34, color: ESPO_GRAY, size: 10, align: .center)
        bell.autoresizingMask = [.minXMargin]
        let plus = makeLabel(topBar, "+", x: 0, y: 3, w: 34, h: 26, color: ESPO_GRAY, size: 14, align: .center)
        plus.autoresizingMask = [.minXMargin]
        globalSearch = makeEdit(topBar, x: 0, y: 4, w: 260, h: 24, placeholder: T.S("app.search"))
        globalSearch.delegate = self
        // раскладка справа налево — при смене размера окна
        let relayout = { [weak self] in
            guard let s = self else { return }
            let w = s.topBar.bounds.width
            userL.frame.origin.x = w - 120
            bell.frame.origin.x = w - 120 - 34
            plus.frame.origin.x = w - 120 - 34 - 34
        }
        topBarRelayout = relayout
        relayout()
    }
    private var topBarRelayout: (() -> Void)?

    private func buildAccountsPage() {
        content.addSubview(pageAccounts)
        let hdr = FlippedView(bg: ESPO_BODY)
        pageAccounts.addSubview(hdr)
        accHeader = hdr
        makeLabel(hdr, T.S("nav.clients"), x: 0, y: 6, w: 400, h: 30, color: ESPO_TEXT, size: 16)
        btnAdd = EspoButton(T.S("btn.from_registry"), primary: true, width: 180) { [weak self] in self?.onAddClick() }
        btnRefresh = EspoButton(T.S("btn.refresh"), primary: false, width: 100) { [weak self] in self?.onRefreshClick() }
        btnDelete = EspoButton(T.S("btn.delete"), primary: false, width: 100) { [weak self] in self?.onDeleteClick() }
        for b in [btnAdd!, btnRefresh!, btnDelete!] { hdr.addSubview(b) }

        let searchRow = FlippedView(bg: ESPO_BODY)
        pageAccounts.addSubview(searchRow)
        accSearchRow = searchRow
        preset = makeCombo(searchRow, x: 0, y: 8, w: 190, h: 28, items: ["Все", "Добавлены сегодня", "С юридическим адресом"])
        preset.target = self
        preset.action = #selector(onPresetChange)
        search = makeEdit(searchRow, x: 198, y: 8, w: 320, h: 28, placeholder: "Название, IDNO или руководитель…")
        search.delegate = self
        let mag = EspoButton("🔍", primary: false, width: 36) { [weak self] in self?.onRefreshClick() }
        mag.frame = NSRect(x: 524, y: 4, width: 36, height: 36)
        searchRow.addSubview(mag)
        pager = makeLabel(searchRow, "", x: 0, y: 12, w: 200, h: 22, color: ESPO_MUTED, size: 10, align: .right)

        // карточка клиента: реестровые поля (только чтение) + поля CRM
        overview = PanelBox(title: T.S("card.client"))
        pageAccounts.addSubview(overview)
        for i in 0..<6 {
            makeLabel(overview, OV_LABELS[i], x: 14 + CGFloat(i % 3) * 340, y: 36 + CGFloat(i / 3) * 40, w: 300)
            ovValues.append(makeLabel(overview, "—", x: 14 + CGFloat(i % 3) * 340, y: 52 + CGFloat(i / 3) * 40, w: 330, color: ESPO_TEXT, size: 10))
        }
        makeLabel(overview, T.S("col.type"), x: 14, y: 118, w: 150)
        ovType = makeCombo(overview, x: 14, y: 136, w: 150, items: splitEnum(ENUM_CLIENT_TYPE))
        makeLabel(overview, T.S("col.phone"), x: 178, y: 118, w: 150)
        ovPhone = makeEdit(overview, x: 178, y: 136, w: 150)
        makeLabel(overview, T.S("col.email"), x: 342, y: 118, w: 200)
        ovEmail = makeEdit(overview, x: 342, y: 136, w: 200)
        makeLabel(overview, T.S("col.contact"), x: 556, y: 118, w: 220)
        ovContact = makeEdit(overview, x: 556, y: 136, w: 220)
        let saveB = EspoButton(T.S("btn.save"), primary: true, width: 120) { [weak self] in self?.onOverviewSave() }
        saveB.frame = NSRect(x: 790, y: 131, width: 120, height: 36)
        overview.addSubview(saveB)

        (listScroll, list) = makeTable(columns: zip(OV_LABELS, COL_WIDTHS).map { ($0, $1) })
        list.dataSource = self
        list.delegate = self
        list.tag = 7
        pageAccounts.addSubview(listScroll)
        pageAccounts.onLayout = { [weak self] in
            guard let s = self else { return }
            s.pageAccounts.dock(top: [(hdr, 48), (searchRow, 48)], bottom: [(s.overview, 196)], client: s.listScroll,
                                padding: NSEdgeInsets(top: 12, left: 15, bottom: 12, right: 15))
            var x = hdr.bounds.width
            for b in [s.btnAdd!, s.btnRefresh!, s.btnDelete!] {
                x -= b.frame.width
                b.frame = NSRect(x: x, y: 4, width: b.frame.width, height: 36)
                x -= 8
            }
            s.pager.frame = NSRect(x: searchRow.bounds.width - 200, y: 12, width: 200, height: 22)
        }
    }

    private func buildEntityPages() {
        let sayP: SayProc = { [weak self] k, m in self?.say(k, m) }
        let defs: [(NavSection, EntityDef)] = [(.contacts, DefContacts), (.leads, DefLeads), (.deals, DefDeals), (.items, DefItems),
                                               (.orders, DefOrders), (.calendar, DefTasks), (.projects, DefProjects)]
        for (s, d) in defs {
            let p = EntityPage(data: crm, def: d, say: sayP)
            content.addSubview(p)
            pages[s] = p
        }
        pages[.leads]?.addExtraButton(T.S("btn.to_clients"), width: 120) { [weak self] in self?.onLeadConvert() }
        pages[.leads]?.setPresets(["Все", "Новые", "В работе", "Конвертированные"],
                                  ["", "t.status = 'Новый'", "t.status = 'В работе'", "t.status = 'Конвертирован'"])
        pages[.deals]?.setPresets(["Все", "Открытые", "Выигранные", "Проигранные"],
                                  ["", "t.stage NOT IN ('Выиграна','Проиграна')", "t.stage = 'Выиграна'", "t.stage = 'Проиграна'"])
        pages[.items]?.setPresets(["Все", "Товары", "Услуги", "Изделия", "Нет на складе"],
                                  ["", "t.kind = 'Товар'", "t.kind = 'Услуга'", "t.kind = 'Изделие'", "t.kind <> 'Услуга' AND COALESCE(t.stock,0) <= 0"])
        pages[.orders]?.setPresets(["Все", "Открытые", "Не проведённые", "Продажи", "Услуги", "Производство"],
                                   ["", "t.status NOT IN ('Выполнен','Оплачен','Отменён')", "t.posted = 0", "t.kind = 'Продажа'", "t.kind = 'Услуга'", "t.kind = 'Производство'"])
        pages[.calendar]?.addExtraButton(T.S("btn.done"), width: 120) { [weak self] in self?.onTaskDone() }
        pages[.calendar]?.setPresets(["Открытые", "Сегодня", "Просроченные", "Все", "В работе", "По проектам"],
                                     ["t.done = 0", "t.done = 0 AND t.due_at = date('now','localtime')",
                                      "t.done = 0 AND t.due_at < date('now','localtime')", "",
                                      "t.done = 0 AND t.stage = 'В работе'", "COALESCE(t.project_id,0) > 0"])
        pages[.projects]?.addExtraButton("Задачи проекта", width: 140) { [weak self] in self?.onProjectTasks() }
        pages[.projects]?.addExtraButton("План (Гант)", width: 120) { [weak self] in self?.onProjectGantt() }
        pages[.projects]?.setPresets(
            ["Все", "Тендер", "Договор", "Аванс", "Дизайн", "Производство", "Сдача", "Оплата", "Закрыт", "Проигран", "Запаздывают"],
            ["", "t.status = 'Тендер'", "t.status = 'Договор'", "t.status = 'Аванс'", "t.status = 'Дизайн'", "t.status = 'Производство'",
             "t.status = 'Сдача'", "t.status = 'Оплата'", "t.status = 'Закрыт'", "t.status = 'Проигран'",
             "t.status NOT IN ('Закрыт','Проигран') AND COALESCE(t.due_date,'') <> '' AND t.due_date < date('now','localtime')"])
    }

    /// Пресеты разделов совпадают с плитками рабочего стола.
    private func setStagePresets() {
        pages[.deals]?.setPresets(["Все", "Предложение", "Переговоры", "Выиграна", "Проиграна", "Открытые"],
                                  ["", crm.stageWhere(.dealOffer), crm.stageWhere(.dealTalks), crm.stageWhere(.dealWon),
                                   "t.stage = 'Проиграна'", "t.stage NOT IN ('Выиграна','Проиграна')"])
        pages[.orders]?.setPresets(["Все", "Ожидает аванс", "В работе / производство", "Готово к отгрузке", "Отгружено — ждём оплату", "Закрыто", "Запаздывает"],
                                   ["", crm.stageWhere(.awaitAdvance), crm.stageWhere(.inWork), crm.stageWhere(.readyToShip),
                                    crm.stageWhere(.awaitPayment), crm.stageWhere(.closed),
                                    "t.status <> 'Отменён' AND COALESCE(t.due_date,'') <> '' AND t.due_date < date('now','localtime') AND NOT (COALESCE(t.ship_date,'') <> '' AND COALESCE(t.paid,0) >= t.total)"])
    }

    private func buildWorkspacePages() {
        let sayP: SayProc = { [weak self] k, m in self?.say(k, m) }
        workspace = WorkspacePage(data: crm, erp: erp, say: sayP)
        workspace.onStageClick = { [weak self] s in self?.onStageClick(s) }
        content.addSubview(workspace)
        reports = ReportsPage(data: crm, say: sayP, exportDir: Paths.crmDataDir + "reports")
        content.addSubview(reports)
        kanban = KanbanPage(data: crm, say: sayP)
        kanban.onOpenRecord = { [weak self] b, id in self?.onKanbanOpen(b, id) }
        content.addSubview(kanban)
        process = ProcessPage(data: crm, say: sayP)
        process.onOpenRecord = { [weak self] b, id in self?.onKanbanOpen(b, id) }
        process.onOpenColumn = { [weak self] b, c in self?.onProcessOpenColumn(b, c) }
        content.addSubview(process)
        gantt = GanttPage(data: crm, say: sayP)
        gantt.onOpenOrder = { [weak self] id in self?.openRecord(.orders, id) }
        gantt.onOpenProject = { [weak self] id in self?.openRecord(.projects, id) }
        gantt.onOpenTask = { [weak self] id in self?.calendarAsGrid = false; self?.openRecord(.calendar, id) }
        content.addSubview(gantt)
        calendar = CalendarPage(data: crm, say: sayP)
        calendar.onOpenTask = { [weak self] id in self?.calendarAsGrid = false; self?.openRecord(.calendar, id) }
        calendar.onNewTask = { [weak self] d in self?.onCalendarNewTask(d) }
        calendar.onShowList = { [weak self] in self?.calendarAsGrid = false; self?.selectSection(.calendar) }
        content.addSubview(calendar)
        calendarAsGrid = true
        pages[.calendar]?.addExtraButton(T.S("calendar.title"), width: 120) { [weak self] in
            self?.calendarAsGrid = true; self?.selectSection(.calendar)
        }
        setStagePresets()
    }

    // ── вход в программу: панель поверх содержимого, не модальное окно ──

    private func buildLogin() {
        root.addSubview(loginPanel)
        let box = PanelBox(title: "")
        box.frame = NSRect(x: 0, y: 120, width: 460, height: 300)
        loginPanel.addSubview(box)
        loginBox = box
        makeLabel(box, T.S("app.title"), x: 30, y: 22, w: 400, h: 30, color: ESPO_PRIMARY, size: 18, bold: true)
        makeLabel(box, T.S("login.title"), x: 30, y: 60, w: 400, h: 22, color: ESPO_TEXT, size: 12)
        makeLabel(box, T.S("login.subtitle"), x: 30, y: 82, w: 400, color: ESPO_MUTED, size: 9)
        makeLabel(box, T.S("login.user"), x: 30, y: 112, w: 180)
        loginUser = makeEdit(box, x: 30, y: 130, w: 200)
        loginUser.stringValue = "admin"
        makeLabel(box, T.S("login.password"), x: 245, y: 112, w: 180)
        loginPass = makeEdit(box, x: 245, y: 130, w: 185, secure: true)
        makeLabel(box, T.S("login.language"), x: 30, y: 168, w: 180)
        loginLang = makeCombo(box, x: 30, y: 186, w: 200, items: T.langs.map { $0.name })
        if let i = T.langs.firstIndex(where: { $0.code.lowercased() == T.lang.lowercased() }) { loginLang.selectItem(at: i) }
        loginLang.target = self
        loginLang.action = #selector(onLoginLangChange)
        let btn = EspoButton(T.S("login.enter"), primary: true, width: 185) { [weak self] in self?.onLoginClick() }
        btn.frame = NSRect(x: 245, y: 181, width: 185, height: 36)
        box.addSubview(btn)
        loginError = makeLabel(box, "", x: 30, y: 228, w: 400, color: ST_DANGER_FG, size: 9)
        makeLabel(box, T.S("login.hint"), x: 30, y: 252, w: 410, color: ESPO_MUTED, size: 8)
        layoutRoot()
        // Enter в поле пароля — вход
        loginPass.target = self
        loginPass.action = #selector(onLoginEnter)
    }

    @objc private func onLoginEnter() { onLoginClick() }

    /// Меню переписываем сразу при смене языка; остальные подписи — после перезапуска.
    private func applyNavCaptions() {
        for s in NavSection.allCases { navLabels[s]?.stringValue = T.S(s.key) }
        selectSection(section)
    }

    @objc private func onLoginLangChange() {
        let i = loginLang.indexOfSelectedItem
        if i >= 0 && i < T.langs.count {
            T.useLang(T.langs[i].code)
            applyNavCaptions()
            say(.info, T.S("settings.lang_saved"))
        }
    }

    private func onLoginClick() {
        if crm.checkLogin(loginUser.stringValue, loginPass.stringValue) {
            user = loginUser.stringValue.trimmed
            loginPanel.isHidden = true
            say(.ok, T.F("login.welcome", [user]))
        } else {
            loginError.stringValue = T.S("login.bad")
            say(.warn, T.S("login.bad"))
        }
    }

    // ── переходы между разделами ──

    private func openRecord(_ s: NavSection, _ id: Int) {
        selectSection(s)
        pages[s]?.selectPreset(0)
        if pages[s]?.selectById(id) == true {
            say(.info, "Открыта запись из " + (s == .orders ? "плана работ" : "канбана") + ".")
        } else {
            say(.warn, "Запись не найдена в разделе — возможно, она была удалена.")
        }
    }

    private func onKanbanOpen(_ board: BoardKind, _ id: Int) {
        let sections: [BoardKind: NavSection] = [.orders: .orders, .deals: .deals, .tasks: .calendar, .projects: .projects, .projectTasks: .calendar]
        if board == .tasks || board == .projectTasks { calendarAsGrid = false }
        openRecord(sections[board] ?? .orders, id)
    }

    /// Двойной щелчок по узлу схемы: раздел с фильтром этапа.
    private func onProcessOpenColumn(_ board: BoardKind, _ col: Int) {
        switch board {
        case .orders: selectSection(.orders); pages[.orders]?.selectPreset(col + 1)
        case .deals: selectSection(.deals); pages[.deals]?.selectPreset(col >= 1 ? col : 0)
        case .projects: selectSection(.projects); pages[.projects]?.selectPreset(col + 1)
        case .projectTasks: calendarAsGrid = false; selectSection(.calendar); pages[.calendar]?.selectPreset(5)
        case .tasks:
            calendarAsGrid = false
            selectSection(.calendar)
            switch col {
            case 0: pages[.calendar]?.selectPreset(2)
            case 1: pages[.calendar]?.selectPreset(1)
            case 3: pages[.calendar]?.selectPreset(3)
            default: pages[.calendar]?.selectPreset(0)
            }
        }
        say(.info, T.F("process.opened", [pages[section]?.listCount ?? 0]))
    }

    private func onProjectTasks() {
        let id = pages[.projects]?.selectedId ?? 0
        if id == 0 { say(.warn, "Выберите проект в списке."); return }
        selectSection(.kanban)
        kanban.selectProject(id)
    }

    private func onProjectGantt() {
        selectSection(.gantt)
        gantt.selectFilter(3)
    }

    private func onCalendarNewTask(_ d: Date) {
        calendarAsGrid = false
        selectSection(.calendar)
        pages[.calendar]?.newRecord()
        pages[.calendar]?.setField("due_at", dateStr(d))
    }

    /// Нажатие на плитку: открыть раздел с соответствующим фильтром.
    private func onStageClick(_ stage: Stage) {
        if stage.isDeal {
            selectSection(.deals)
            pages[.deals]?.selectPreset(stage.rawValue + 1)
            say(.info, "Сделки, этап «\(crm.stageInfo(stage).title)»: \(pages[.deals]?.listCount ?? 0)")
        } else {
            selectSection(.orders)
            pages[.orders]?.selectPreset(stage.rawValue - Stage.awaitAdvance.rawValue + 1)
            say(.info, "Заказы, этап «\(crm.stageInfo(stage).title)»: \(pages[.orders]?.listCount ?? 0)")
        }
    }

    private func buildSettingsPanel() {
        settingsPanel.isHidden = true
        content.addSubview(settingsPanel)
        makeLabel(settingsPanel, T.S("settings.launcher"), x: 15, y: 14, w: 200, color: ST_PRIMARY_FG, size: 10)
        launcherEdit = makeEdit(settingsPanel, x: 220, y: 10, w: 555)
        makeLabel(settingsPanel, T.S("settings.erp_url"), x: 15, y: 50, w: 200, color: ST_PRIMARY_FG, size: 10)
        erpUrlEdit = makeEdit(settingsPanel, x: 220, y: 46, w: 330, placeholder: "http://127.0.0.1:9000")
        makeLabel(settingsPanel, T.S("settings.erp_key"), x: 560, y: 50, w: 60, color: ST_PRIMARY_FG, size: 10)
        erpKeyEdit = makeEdit(settingsPanel, x: 620, y: 46, w: 155, secure: true)
        makeLabel(settingsPanel, T.S("settings.language"), x: 15, y: 86, w: 200, color: ST_PRIMARY_FG, size: 10)
        langEdit = makeCombo(settingsPanel, x: 220, y: 82, w: 200, items: T.langs.map { $0.name })
        if let i = T.langs.firstIndex(where: { $0.code.lowercased() == T.lang.lowercased() }) { langEdit.selectItem(at: i) }
        makeLabel(settingsPanel, T.S("settings.password"), x: 430, y: 86, w: 130, color: ST_PRIMARY_FG, size: 10)
        passEdit = makeEdit(settingsPanel, x: 560, y: 82, w: 215, secure: true)
        let btn = EspoButton(T.S("btn.save"), primary: true, width: 110) { [weak self] in self?.onSettingsSave() }
        btn.frame = NSRect(x: 790, y: 46, width: 110, height: 36)
        settingsPanel.addSubview(btn)
    }

    // ── навигация ──

    func selectSection(_ s: NavSection) {
        if s == .settings {
            settingsPanel.isHidden.toggle()
            if !settingsPanel.isHidden {
                launcherEdit.stringValue = client.launcherExe
                erpUrlEdit.stringValue = erp.url
                erpKeyEdit.stringValue = erp.key
                say(.info, "Путь к Contragenti и адрес ERP — затем «Сохранить».")
            }
            navItems[.settings]?.bgColor = settingsPanel.isHidden ? ESPO_BODY : ESPO_NAV_ACT
            layoutContent()
            return
        }
        section = s
        for (k, v) in navItems where k != .settings { v.bgColor = k == s ? ESPO_NAV_ACT : ESPO_BODY }
        pageAccounts.isHidden = s != .accounts
        workspace.isHidden = s != .workspace
        reports.isHidden = s != .reports
        kanban.isHidden = s != .kanban
        process.isHidden = s != .process
        gantt.isHidden = s != .gantt
        calendar.isHidden = !(s == .calendar && calendarAsGrid)
        for (k, p) in pages {
            p.isHidden = !(k == s && !(!calendar.isHidden && k == .calendar))
            if k == s {
                p.cancel()     // при входе в раздел — чистый список, без редактора прошлой записи
                p.refresh()
            }
        }
        layoutContent()
        if s == .workspace { workspace.refresh() }
        if s == .reports { reports.refresh() }
        if s == .kanban { kanban.refresh() }
        if s == .process { process.refresh() }
        if s == .gantt { gantt.refresh() }
        if !calendar.isHidden { calendar.refresh() }
        window?.title = "Demo CRM · " + T.S(s.key)
    }

    private func onNavClick(_ s: NavSection) {
        pendingDeleteId = 0
        selectSection(s)
    }

    func page(_ s: NavSection) -> EntityPage? { pages[s] }

    // ── настройки ──

    private func readIni() -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        guard let text = try? String(contentsOfFile: iniPath, encoding: .utf8) else { return out }
        var sec = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") { sec = String(line.dropFirst().dropLast()); continue }
            if let eq = line.firstIndex(of: "=") {
                out[sec, default: [:]][String(line[..<eq]).trimmed] = String(line[line.index(after: eq)...]).trimmed
            }
        }
        return out
    }

    private func loadSettings() {
        let ini = readIni()
        let defExe = Paths.launcherCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? Paths.launcherCandidates[0]
        client.launcherExe = ini["contragenti"]?["launcher"] ?? defExe
        client.lang = ini["contragenti"]?["lang"] ?? "ru"
        erp.url = ini["erp"]?["url"] ?? "http://127.0.0.1:9000"
        erp.key = ini["erp"]?["key"] ?? ""
        erp.clientId = ini["erp"]?["client_id"] ?? "demo-crm"
    }

    private func saveSettings() {
        let text = """
        [contragenti]
        launcher=\(client.launcherExe)
        lang=\(client.lang)
        [erp]
        url=\(erp.url)
        key=\(erp.key)
        client_id=\(erp.clientId)

        """
        try? text.write(toFile: iniPath, atomically: true, encoding: .utf8)
    }

    // ── данные ──

    func say(_ kind: MsgKind, _ msg: String) {
        switch kind {
        case .ok: msgBar.bgColor = ST_SUCCESS_BG; msgLabel.textColor = ST_SUCCESS_FG
        case .warn: msgBar.bgColor = ST_WARNING_BG; msgLabel.textColor = ST_WARNING_FG
        case .err: msgBar.bgColor = ST_DANGER_BG; msgLabel.textColor = ST_DANGER_FG
        case .info: msgBar.bgColor = ST_PRIMARY_BG; msgLabel.textColor = ST_PRIMARY_FG
        }
        msgLabel.stringValue = msg
        msgKind = kind
    }

    private func refreshList() {
        let todayS = D(0)
        clientRows = db.list(filter: search.stringValue).filter { r in
            if preset.indexOfSelectedItem == 1 && !r.addedAt.hasPrefix(todayS) { return false }
            if preset.indexOfSelectedItem == 2 && r.adresa.trimmed.isEmpty { return false }
            return true
        }
        list.reloadData()
        pager.stringValue = clientRows.isEmpty ? "0 записей" : "1 – \(clientRows.count) из \(db.count())"
        showOverview(nil)
    }

    private func showOverview(_ row: ClientRow?) {
        guard let r = row else {
            for v in ovValues { v.stringValue = "—" }
            ovType.selectItem(at: 0); ovPhone.stringValue = ""; ovEmail.stringValue = ""; ovContact.stringValue = ""
            return
        }
        let vals = [r.denumire, r.idno, r.formaJuridica, r.adresa, r.administrator, r.addedAt]
        for (i, v) in vals.enumerated() { ovValues[i].stringValue = v.trimmed.isEmpty ? "—" : v }
        let t = crm.scalarString("SELECT client_type FROM clients WHERE id = \(r.id)")
        ovType.selectItem(at: max(0, splitEnum(ENUM_CLIENT_TYPE).firstIndex(of: t) ?? 0))
        ovPhone.stringValue = crm.scalarString("SELECT phone FROM clients WHERE id = \(r.id)")
        ovEmail.stringValue = crm.scalarString("SELECT email FROM clients WHERE id = \(r.id)")
        ovContact.stringValue = crm.scalarString("SELECT contact_person FROM clients WHERE id = \(r.id)")
    }

    private var selectedId: Int {
        let r = list.selectedRow
        return (r >= 0 && r < clientRows.count) ? clientRows[r].id : 0
    }

    // ── действия ──

    /// Пока открыт Contragenti, SDK зовёт это каждые 200 мс — окно живёт.
    private func onContragentiWait() {
        waitTicks += 1
        if waitTicks % 5 == 0 {
            say(.warn, T.F("msg.contragenti_wait", [waitTicks / 5]))
        }
        pumpEvents()
    }

    /// Путь из настроек, а если его нет — известные места.
    private func resolveLauncher() -> String {
        if FileManager.default.fileExists(atPath: client.launcherExe) { return client.launcherExe }
        for c in Paths.launcherCandidates where FileManager.default.fileExists(atPath: c) {
            client.launcherExe = c
            saveSettings()
            return c
        }
        return client.launcherExe
    }

    private func onAddClick() {
        if adding { say(.warn, T.S("msg.contragenti_busy")); return }
        if section != .accounts { selectSection(.accounts) }
        if !FileManager.default.fileExists(atPath: resolveLauncher()) {
            say(.err, T.F("msg.contragenti_missing", [client.launcherExe]))
            return
        }
        say(.warn, T.S("msg.contragenti_open"))
        adding = true
        waitTicks = 0
        let savedWait = client.onWait
        client.onWait = { [weak self] in self?.onContragentiWait(); savedWait?() }
        btnAdd.isEnabled = false
        defer { btnAdd.isEnabled = true; client.onWait = savedWait; adding = false }
        if let card = client.pick(filter: search.stringValue.trimmed) {
            switch db.addFromCard(card) {
            case (.added, _):
                refreshList()
                say(.ok, T.F("msg.client_added", [card.denumire, card.idno]))
            case (.duplicate, _):
                say(.warn, T.F("msg.duplicate", [card.denumire, card.idno]))
            default:
                say(.err, "Не удалось сохранить клиента.")
            }
        } else {
            say(.warn, T.F("msg.pick_cancelled", [client.lastError]))
        }
    }

    private func onDeleteClick() {
        let id = selectedId
        if id == 0 { say(.warn, "Выберите клиента в списке, затем нажмите «Удалить»."); return }
        let name = clientRows[list.selectedRow].denumire
        if pendingDeleteId != id {
            pendingDeleteId = id
            say(.warn, T.F("msg.confirm_delete", [name]))
            return
        }
        pendingDeleteId = 0
        db.delete(id)
        refreshList()
        say(.ok, "Удалён клиент «\(name)».   Записей: \(db.count())")
    }

    private func onRefreshClick() {
        pendingDeleteId = 0
        refreshList()
        say(.info, "Обновлено.   Записей: \(db.count())")
    }

    private func onSearchChange() {
        pendingDeleteId = 0
        refreshList()
        if !search.stringValue.isEmpty {
            say(.info, "Фильтр «\(search.stringValue)»: показано \(clientRows.count) из \(db.count())")
        }
    }

    @objc private func onPresetChange() {
        pendingDeleteId = 0
        refreshList()
        say(.info, "Фильтр «\(preset.titleOfSelectedItem ?? "")»: показано \(clientRows.count) из \(db.count())")
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === search { onSearchChange() }
        else if f === globalSearch {
            if section != .accounts { selectSection(.accounts) }
            search.stringValue = globalSearch.stringValue
            onSearchChange()
        }
    }

    private func onOverviewSave() {
        let id = selectedId
        if id == 0 { say(.warn, "Выберите клиента в списке."); return }
        db.db.run("UPDATE clients SET client_type = ?, phone = ?, email = ?, contact_person = ? WHERE id = ?",
                  [ovType.titleOfSelectedItem ?? "", ovPhone.stringValue.trimmed, ovEmail.stringValue.trimmed, ovContact.stringValue.trimmed, id])
        say(.ok, "Карточка клиента «\(clientRows[list.selectedRow].denumire)» сохранена.")
    }

    private func onLeadConvert() {
        let id = pages[.leads]?.selectedId ?? 0
        if id == 0 { say(.warn, "Выберите лид в списке."); return }
        let (msg, clientId) = crm.convertLead(id)
        pages[.leads]?.refresh()
        refreshList()
        if clientId > 0 { say(.ok, "Лид конвертирован: " + msg) } else { say(.warn, "Лид не конвертирован: " + msg) }
    }

    private func onTaskDone() {
        let id = pages[.calendar]?.selectedId ?? 0
        if id == 0 { say(.warn, "Выберите задачу в списке."); return }
        crm.setTaskDone(id, true)   // этап «Готово» и флаг — одно состояние
        pages[.calendar]?.cancel()
        pages[.calendar]?.refresh()
        say(.ok, "Задача отмечена выполненной.")
    }

    private func onSettingsSave() {
        client.launcherExe = launcherEdit.stringValue.trimmed
        erp.url = erpUrlEdit.stringValue.trimmed
        erp.key = erpKeyEdit.stringValue.trimmed
        saveSettings()
        var msg = T.S("settings.saved")
        let i = langEdit.indexOfSelectedItem
        if i >= 0 && i < T.langs.count && T.langs[i].code.lowercased() != T.lang.lowercased() {
            T.useLang(T.langs[i].code)
            applyNavCaptions()
            msg += "  " + T.S("settings.lang_saved")
        }
        if !passEdit.stringValue.trimmed.isEmpty {
            crm.setPassword(user.isEmpty ? "admin" : user, passEdit.stringValue.trimmed)
            passEdit.stringValue = ""
            msg += "  " + T.S("settings.pass_changed")
        }
        selectSection(.settings)
        if FileManager.default.fileExists(atPath: client.launcherExe) { say(.ok, msg) }
        else { say(.warn, msg + "  " + T.F("msg.contragenti_missing", [client.launcherExe])) }
    }

    // ── таблица клиентов ──

    func numberOfRows(in tableView: NSTableView) -> Int { clientRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let ci = Int(col.identifier.rawValue.dropFirst()) else { return nil }
        let r = clientRows[row]
        return tableCell(tableView, [r.denumire, r.idno, r.formaJuridica, r.adresa, r.administrator, r.addedAt][ci])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let id = selectedId
        if id != 0 && id != pendingDeleteId { pendingDeleteId = 0 }
        showOverview(id == 0 ? nil : clientRows[list.selectedRow])
    }

    // ── хуки самотеста ──

    func testShowBanner(_ step: Int, _ title: String) {
        testBannerLabel.stringValue = String(format: "Шаг %02d · %@", step, title)
        testBanner.isHidden = false
        layoutRoot()
    }
    func testHideBanner() { testBanner.isHidden = true; layoutRoot() }
    func testSetFilter(_ text: String) { search.stringValue = text; onSearchChange() }
    func testClickAdd() { onAddClick() }
    func testClickNav(_ s: NavSection) { onNavClick(s) }
    func testImportXml(_ xml: String) -> (AddResult, CounterpartyCard?) {
        guard let card = client.parseCardXml(xml) else {
            say(.err, "Разбор XML не удался: " + client.lastError)
            return (.error, nil)
        }
        let (r, _) = db.addFromCard(card)
        refreshList()
        switch r {
        case .added: say(.ok, T.F("msg.client_added", [card.denumire, card.idno]))
        case .duplicate: say(.warn, T.F("msg.duplicate", [card.denumire, card.idno]))
        case .error: say(.err, "Не удалось сохранить клиента.")
        }
        return (r, card)
    }
    @discardableResult
    func testSelectFirst() -> Bool {
        guard !clientRows.isEmpty else { return false }
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showOverview(clientRows[0])
        return true
    }
    func testClickDelete() { onDeleteClick() }
    func testClickSettings() { onNavClick(.settings) }
    func testLeadConvert() { onLeadConvert() }
    func testTaskDone() { onTaskDone() }
    func testProjectTasks() { onProjectTasks() }
    func testOverviewSet(_ type: String, _ phone: String, _ email: String, _ contact: String) {
        ovType.selectItem(at: max(0, splitEnum(ENUM_CLIENT_TYPE).firstIndex(of: type) ?? 0))
        ovPhone.stringValue = phone; ovEmail.stringValue = email; ovContact.stringValue = contact
        onOverviewSave()
    }
    var testListCount: Int { clientRows.count }
    var testDbCount: Int { db.count() }
    var testMessage: String { msgLabel.stringValue.trimmed }
    var testMessageKind: MsgKind { msgKind }
    var testSection: NavSection { section }
    var testWaitTicks: Int { waitTicks }
    var testLoginVisible: Bool { !loginPanel.isHidden }
    @discardableResult
    func testLogin(_ u: String, _ p: String) -> Bool {
        loginUser.stringValue = u
        loginPass.stringValue = p
        onLoginClick()
        return !testLoginVisible
    }
    func testSetLanguage(_ code: String) { T.useLang(code); applyNavCaptions() }
    func testNavCaption(_ s: NavSection) -> String { navLabels[s]?.stringValue ?? "" }
    var rootView: NSView { root }
}

// ── приложение ──

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let m = MainWindowController()
        main = m
        m.showWindow(nil)
        m.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О программе Demo CRM", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть Demo CRM", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить Demo CRM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = menu
    }
}
