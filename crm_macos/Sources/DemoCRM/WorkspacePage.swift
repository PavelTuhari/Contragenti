// Рабочий стол (аналог uWorkspace.pas): плитки этапов «от контракта до
// денег», полоса ERP, сводки; и страница отчётов с предпросмотром и выгрузкой.
import AppKit

private let TILE_W: CGFloat = 190, TILE_H: CGFloat = 124, TILE_GAP: CGFloat = 10

final class WorkspacePage: FlippedView {
    private let data: CrmData
    private let erp: ErpClient
    private let say: SayProc
    var onStageClick: ((Stage) -> Void)?

    private struct Tile {
        var panel: FlippedView
        var value, title, hint, sum, over: NSTextField
    }
    private var tiles: [Stage: Tile] = [:]
    private let header = FlippedView(bg: ESPO_BODY)
    private let erpPanel = FlippedView(bg: ST_PRIMARY_BG)
    private let body = FlippedView(bg: ESPO_BODY)
    private var erpLabel: NSTextField!
    private var summary: NSTextField!
    private var lastOrders: NSTextField!
    private var nextTasks: NSTextField!
    private var refreshBtn: EspoButton!
    private var erpCheckBtn: EspoButton!
    private var erpSendBtn: EspoButton!

    init(data: CrmData, erp: ErpClient, say: @escaping SayProc) {
        self.data = data
        self.erp = erp
        self.say = say
        super.init(frame: .zero)
        bgColor = ESPO_BODY
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeTile(_ stage: Stage, x: CGFloat, y: CGFloat) -> Tile {
        let p = FlippedView(bg: ESPO_WHITE)
        p.borderColor = ESPO_PANEL_BRD
        p.cornerRadius = 3
        p.frame = NSRect(x: x, y: y, width: TILE_W, height: TILE_H)
        p.onClick = { [weak self] in self?.onStageClick?(stage) }
        body.addSubview(p)
        let title = makeLabel(p, "", x: 14, y: 10, w: TILE_W - 28, color: ESPO_SOFT, size: 10, bold: true)
        let value = makeLabel(p, "0", x: 14, y: 30, w: 120, h: 36, color: ESPO_PRIMARY, size: 24, bold: true)
        let sum = makeLabel(p, "", x: 14, y: 66, w: TILE_W - 28, color: ESPO_TEXT, size: 10)
        let over = makeLabel(p, "", x: 14, y: 86, w: TILE_W - 28, color: ST_DANGER_FG, size: 9, bold: true)
        let hint = makeLabel(p, "", x: 14, y: 104, w: TILE_W - 28, h: 16, color: ESPO_MUTED, size: 8)
        return Tile(panel: p, value: value, title: title, hint: hint, sum: sum, over: over)
    }

    private func build() {
        addSubview(header)
        let l = makeLabel(header, "Рабочий стол", x: 15, y: 14, w: 400, h: 30, color: ESPO_TEXT, size: 16)
        l.stringValue = T.S("nav.workspace")
        refreshBtn = EspoButton("Обновить", primary: false, width: 110) { [weak self] in
            self?.refresh(); self?.say(.info, "Рабочий стол обновлён.")
        }
        header.addSubview(refreshBtn)
        summary = makeLabel(header, "", x: 210, y: 22, w: 820, color: ESPO_MUTED, size: 10)

        addSubview(erpPanel)
        erpLabel = makeLabel(erpPanel, T.S("erp.not_checked"), x: 15, y: 17, w: 700, color: ST_PRIMARY_FG, size: 10)
        erpCheckBtn = EspoButton(T.S("btn.erp_check"), primary: false, width: 150) { [weak self] in self?.erpCheck() }
        erpSendBtn = EspoButton(T.S("btn.erp_send"), primary: true, width: 160) { [weak self] in
            guard let s = self else { return }
            s.erpSend(s.data.clients.dbPath)
        }
        erpPanel.addSubview(erpCheckBtn)
        erpPanel.addSubview(erpSendBtn)

        addSubview(body)
        makeLabel(body, T.S("workspace.contract"), x: 15, y: 12, w: 400, color: ESPO_MUTED, size: 8)
        var x: CGFloat = 15, y: CGFloat = 32
        for s in Stage.dealStages {
            tiles[s] = makeTile(s, x: x, y: y)
            x += TILE_W + TILE_GAP
        }
        makeLabel(body, T.S("workspace.execution"), x: 15, y: y + TILE_H + 18, w: 700, color: ESPO_MUTED, size: 8)
        x = 15; y += TILE_H + 38
        for s in Stage.orderStages {
            tiles[s] = makeTile(s, x: x, y: y)
            x += TILE_W + TILE_GAP
        }
        y += TILE_H + 18
        let b1 = PanelBox(title: T.S("workspace.last_orders"))
        b1.frame = NSRect(x: 15, y: y, width: 505, height: 190)
        body.addSubview(b1)
        lastOrders = makeWrapLabel(b1, "", x: 14, y: 34, w: 478, h: 148)
        let b2 = PanelBox(title: T.S("workspace.next_tasks"))
        b2.frame = NSRect(x: 530, y: y, width: 505, height: 190)
        body.addSubview(b2)
        nextTasks = makeWrapLabel(b2, "", x: 14, y: 34, w: 478, h: 148)
    }

    override func layout() {
        super.layout()
        dock(top: [(header, 56), (erpPanel, 52)], client: body)
        refreshBtn.frame = NSRect(x: header.bounds.width - 125, y: 12, width: 110, height: 36)
        erpCheckBtn.frame = NSRect(x: erpPanel.bounds.width - 320, y: 8, width: 150, height: 36)
        erpSendBtn.frame = NSRect(x: erpPanel.bounds.width - 160, y: 8, width: 160, height: 36)
    }

    func refresh() {
        var orders = 0, overdue = 0, money = 0.0
        for s in Stage.allCases {
            let info = data.stageInfo(s)
            guard let t = tiles[s] else { continue }
            t.title.stringValue = info.title
            t.hint.stringValue = info.hint
            t.value.stringValue = String(info.count)
            t.sum.stringValue = fmtInt0(info.sum) + " MDL"
            if info.overdue > 0 {
                t.over.stringValue = T.F("workspace.late", [info.overdue, fmtInt0(info.overdueSum)])
                t.value.textColor = ST_DANGER_FG
            } else {
                t.over.stringValue = info.count > 0 ? T.S("workspace.on_time") : ""
                t.value.textColor = s == .closed ? ST_SUCCESS_FG : ESPO_PRIMARY
            }
            t.over.textColor = info.overdue > 0 ? ST_DANGER_FG : ST_SUCCESS_FG
            if info.table == "orders" {
                orders += info.count
                overdue += info.overdue
                if s != .closed { money += info.sum }
            }
        }
        summary.stringValue = T.F("workspace.summary", [orders, fmtInt0(money), overdue])
        lastOrders.stringValue = listLastOrders()
        nextTasks.stringValue = listNextTasks()
    }

    private func listLastOrders() -> String {
        var out: [String] = []
        for r in data.rows("""
        SELECT o.number, o.order_date, o.kind, o.status, o.total, COALESCE(c.denumire, '(без клиента)') AS client
        FROM orders o LEFT JOIN clients c ON c.id = o.client_id ORDER BY o.id DESC LIMIT 7
        """) {
            out.append("• №\(r.str("number")) от \(r.str("order_date")) — \(r.str("client")), \(r.str("kind")), \(fmtMoney(r.dbl("total"))) MDL  [\(r.str("status"))]")
        }
        return out.isEmpty ? "Заказов пока нет — создайте первый в разделе «Заказы»." : out.joined(separator: "\n")
    }

    private func listNextTasks() -> String {
        var out: [String] = []
        for r in data.rows("""
        SELECT t.due_at, t.kind, t.subject, COALESCE(c.denumire,'') AS client,
          CASE WHEN t.due_at < date('now','localtime') THEN 1 ELSE 0 END AS late
        FROM tasks t LEFT JOIN clients c ON c.id = t.client_id WHERE t.done = 0 ORDER BY t.due_at LIMIT 7
        """) {
            let client = r.str("client").isEmpty ? "" : " (\(r.str("client")))"
            out.append("• \(r.str("due_at"))  \(r.str("kind")) — \(r.str("subject"))\(client)\(r.int("late") == 1 ? "  ← просрочено" : "")")
        }
        return out.isEmpty ? "Открытых задач нет." : out.joined(separator: "\n")
    }

    // хуки самотеста
    func clickTile(_ s: Stage) { onStageClick?(s) }
    func tileValue(_ s: Stage) -> String { tiles[s]?.value.stringValue ?? "" }
    func tileOverdue(_ s: Stage) -> String { tiles[s]?.over.stringValue ?? "" }
    func tileVisible(_ s: Stage) -> Bool { tiles[s]?.panel.isHidden == false }
    var erpText: String { erpLabel.stringValue }

    func erpCheck() {
        let (ok, st) = erp.health()
        erpLabel.stringValue = st.message
        erpLabel.textColor = ok ? ST_SUCCESS_FG : ST_WARNING_FG
        erpPanel.bgColor = ok ? ST_SUCCESS_BG : ST_WARNING_BG
        say(ok ? .ok : .warn, st.message)
    }

    func erpSend(_ dbPath: String) {
        let (ok, batch) = erp.sendDatabase(dbPath)
        let msg = ok ? "Данные отправлены в ERP: пакет \(batch) (\(erp.lastError))" : "Не удалось отправить в ERP: " + erp.lastError
        erpLabel.stringValue = msg
        erpLabel.textColor = ok ? ST_SUCCESS_FG : ST_WARNING_FG
        erpPanel.bgColor = ok ? ST_SUCCESS_BG : ST_WARNING_BG
        if ok {
            data.db.run("UPDATE orders SET erp_batch = ?, erp_sent_at = datetime('now','localtime') WHERE COALESCE(erp_batch,'') = ''", [batch])
        }
        say(ok ? .ok : .warn, msg)
    }
}

// ── страница отчётов ──

final class ReportsPage: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private let data: CrmData
    private let say: SayProc
    private let exportDir: String
    private(set) var current: ReportKind = .process
    private let header = FlippedView(bg: ESPO_BODY)
    private let listScroll: NSScrollView
    private let list: NSTableView
    private let previewTitle: NSTextField
    private let previewScroll: NSScrollView
    private let preview: NSTableView
    private var table: ReportTable?
    private var previewRowsData: [[String]] = []
    private var xlsxBtn: EspoButton!, pdfBtn: EspoButton!, dirBtn: EspoButton!

    init(data: CrmData, say: @escaping SayProc, exportDir: String) {
        self.data = data
        self.say = say
        self.exportDir = exportDir
        (listScroll, list) = makeTable(columns: [("Отчёт", 190), ("Что показывает", 185)])
        (previewScroll, preview) = makeTable(columns: [])
        previewTitle = NSTextField(labelWithString: "   Предпросмотр")
        super.init(frame: .zero)
        bgColor = ESPO_BODY
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        addSubview(header)
        makeLabel(header, T.S("nav.reports"), x: 15, y: 14, w: 400, h: 30, color: ESPO_TEXT, size: 16)
        xlsxBtn = EspoButton(T.S("btn.export_xlsx"), primary: true, width: 175) { [weak self] in _ = self?.export(.xlsx) }
        pdfBtn = EspoButton(T.S("btn.export_pdf"), primary: false, width: 155) { [weak self] in _ = self?.export(.pdf) }
        dirBtn = EspoButton(T.S("btn.folder"), primary: false, width: 150) { [weak self] in self?.openDir() }
        for b in [xlsxBtn!, pdfBtn!, dirBtn!] { header.addSubview(b) }
        list.dataSource = self
        list.delegate = self
        list.tag = 1
        addSubview(listScroll)
        previewTitle.font = espoFont(11, bold: true)
        previewTitle.textColor = ESPO_SOFT
        addSubview(previewTitle)
        preview.dataSource = self
        preview.delegate = self
        preview.gridStyleMask = [.solidHorizontalGridLineMask]
        addSubview(previewScroll)
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 56)
        xlsxBtn.frame = NSRect(x: header.bounds.width - 190, y: 12, width: 175, height: 36)
        pdfBtn.frame = NSRect(x: header.bounds.width - 190 - 8 - 155, y: 12, width: 155, height: 36)
        dirBtn.frame = NSRect(x: header.bounds.width - 190 - 8 - 155 - 8 - 150, y: 12, width: 150, height: 36)
        listScroll.frame = NSRect(x: 0, y: 56, width: 380, height: bounds.height - 56)
        previewTitle.frame = NSRect(x: 384, y: 56, width: bounds.width - 384, height: 26)
        previewScroll.frame = NSRect(x: 384, y: 82, width: bounds.width - 384, height: bounds.height - 82)
    }

    func refresh() { showPreview(current) }

    private func showPreview(_ kind: ReportKind) {
        current = kind
        let t = buildReport(data, kind)
        table = t
        previewTitle.stringValue = "   \(t.title) — \(t.subtitle)"
        for c in preview.tableColumns { preview.removeTableColumn(c) }
        for (i, c) in t.cols.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            col.title = c.title.uppercased()
            col.width = max(60, CGFloat(c.width) * 0.9)
            preview.addTableColumn(col)
        }
        previewRowsData = (0..<t.rowCount).map { r in (0..<t.colCount).map { t.cell(r, $0) } }
        if !t.totals.isEmpty {
            previewRowsData.append((0..<t.colCount).map { $0 < t.totals.count ? t.totals[$0] : "" })
        }
        preview.reloadData()
    }

    func selectReport(_ kind: ReportKind) {
        list.selectRowIndexes(IndexSet(integer: kind.rawValue), byExtendingSelection: false)
        showPreview(kind)
    }

    func export(_ fmt: ExportFormat) -> String {
        do {
            let path = try exportReport(data, current, fmt, dir: exportDir)
            say(.ok, "Отчёт «\(current.title)» выгружен: \(path)")
            return path
        } catch {
            say(.err, "Не удалось выгрузить отчёт: \(error)")
            return ""
        }
    }

    var previewRows: Int { previewRowsData.count }
    var previewCols: Int { preview.tableColumns.count }

    private func openDir() {
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: exportDir))
        say(.info, "Папка выгрузки: " + exportDir)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView.tag == 1 ? ReportKind.allCases.count : previewRowsData.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let ci = Int(col.identifier.rawValue.dropFirst()) else { return nil }
        if tableView.tag == 1 {
            let k = ReportKind.allCases[row]
            return tableCell(tableView, ci == 0 ? k.title : k.hint, muted: ci == 1)
        }
        let cells = previewRowsData[row]
        let kind = table?.cols[ci].kind ?? .text
        return tableCell(tableView, ci < cells.count ? cells[ci] : "", right: kind == .money || kind == .number || kind == .right)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let t = notification.object as? NSTableView, t.tag == 1, t.selectedRow >= 0 else { return }
        showPreview(ReportKind.allCases[t.selectedRow])
    }
}
