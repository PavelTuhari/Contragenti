// Диаграмма Ганта (аналог uGantt.pas): строка — заказ (план/факт, красный
// просрочен, зелёный закрыт, линия «сегодня»), под производственным заказом
// его операции; режим «Проекты и задачи» со стрелками зависимостей. Полосу
// тянут мышью: за середину — сдвиг, за края — изменение начала или срока.
import AppKit

struct GanttRow {
    var isWork = false
    var orderId = 0, projectId = 0, taskId = 0, dependsOn = 0
    var caption = "", sub = ""
    var start = Date(), planEnd = Date(), factEnd = Date()
    var overdue = false, closed = false
}

enum DragMode { case none, move, start, end }

private let LEFT_W: CGFloat = 300, ROW_H: CGFloat = 22, HEAD_H: CGFloat = 34

final class GanttCanvas: FlippedView {
    weak var page: GanttPage?
    override func draw(_ dirtyRect: NSRect) { page?.paint(self) }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { page?.canvasDoubleClick(p) } else { page?.canvasMouseDown(p) }
    }
    override func mouseDragged(with event: NSEvent) { page?.canvasMouseDragged(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { page?.canvasMouseUp(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { page?.canvasMouseMoved(convert(event.locationInWindow, from: nil)) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
}

final class GanttPage: FlippedView {
    private let data: CrmData
    private let say: SayProc
    private let header = FlippedView(bg: ESPO_BODY)
    private let filter: NSPopUpButton
    private let canvas = GanttCanvas()
    private let scroll = NSScrollView()
    private var info: NSTextField!
    private var refreshBtn: EspoButton!
    private(set) var rows: [GanttRow] = []
    private var minD = Date(), maxD = Date()
    private var chartW: CGFloat = 1
    var onOpenOrder: ((Int) -> Void)?
    var onOpenProject: ((Int) -> Void)?
    var onOpenTask: ((Int) -> Void)?
    // перетаскивание полосы
    private var dragRow = -1
    private var dragMode = DragMode.none
    private var dragX0: CGFloat = 0
    private var dragDays = 0

    init(data: CrmData, say: @escaping SayProc) {
        self.data = data
        self.say = say
        filter = NSPopUpButton(frame: NSRect(x: 210, y: 18, width: 240, height: 28), pullsDown: false)
        super.init(frame: .zero)
        bgColor = ESPO_BODY
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        addSubview(header)
        makeLabel(header, T.S("gantt.title"), x: 15, y: 14, w: 190, h: 30, color: ESPO_TEXT, size: 16)
        filter.font = espoFont(10)
        filter.addItems(withTitles: [T.S("gantt.production"), T.S("gantt.all"), T.S("gantt.open"), "Проекты и задачи"])
        filter.target = self
        filter.action = #selector(onFilterChange)
        header.addSubview(filter)
        info = makeLabel(header, "", x: 465, y: 20, w: 560, color: ESPO_MUTED, size: 9)
        makeLabel(header, T.S("gantt.hint"), x: 15, y: 50, w: 700, color: ESPO_MUTED, size: 9)
        refreshBtn = EspoButton(T.S("btn.refresh"), primary: false, width: 110) { [weak self] in
            self?.loadRows(); self?.say(.info, "План работ обновлён: " + (self?.info.stringValue ?? ""))
        }
        header.addSubview(refreshBtn)
        canvas.page = self
        canvas.bgColor = ESPO_WHITE
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = ESPO_WHITE
        scroll.drawsBackground = true
        addSubview(scroll)
    }

    override func layout() {
        super.layout()
        dock(top: [(header, 72)], client: scroll)
        refreshBtn.frame = NSRect(x: header.bounds.width - 125, y: 12, width: 110, height: 36)
        canvas.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                              height: max(scroll.contentSize.height, HEAD_H + CGFloat(rows.count) * ROW_H + 40))
        canvas.needsDisplay = true
    }

    // ── перетаскивание ──

    private func xOfDate(_ d: Date) -> CGFloat {
        let total = maxD.timeIntervalSince(minD)
        if total <= 0 { return LEFT_W }
        return LEFT_W + CGFloat(d.timeIntervalSince(minD) / total) * chartW
    }

    private var daysPerPixel: Double {
        chartW <= 0 ? 0 : (maxD.timeIntervalSince(minD) / 86400) / Double(chartW)
    }

    /// Что под курсором: край полосы (растянуть) или её середина (сдвинуть).
    private func hitTest(_ p: NSPoint) -> (DragMode, Int) {
        let row = Int((p.y - HEAD_H) / ROW_H)
        guard row >= 0, row < rows.count, !(rows[row].isWork && rows[row].taskId == 0), p.y >= HEAD_H else { return (.none, -1) }
        let x1 = xOfDate(rows[row].start), x2 = xOfDate(rows[row].planEnd)
        if x2 - x1 < 14 {
            return (p.x >= x1 - 4 && p.x <= x2 + 4) ? (.move, row) : (.none, -1)
        }
        if abs(p.x - x1) <= 4 { return (.start, row) }
        if abs(p.x - x2) <= 4 { return (.end, row) }
        if p.x > x1 && p.x < x2 { return (.move, row) }
        return (.none, -1)
    }

    func canvasMouseDown(_ p: NSPoint) {
        let (m, r) = hitTest(p)
        dragMode = m
        dragRow = r
        dragX0 = p.x
        dragDays = 0
    }

    func canvasMouseDragged(_ p: NSPoint) {
        guard dragMode != .none else { return }
        dragDays = Int(bankRound(Double(p.x - dragX0) * daysPerPixel))
        canvas.needsDisplay = true
    }

    func canvasMouseMoved(_ p: NSPoint) {
        let (m, _) = hitTest(p)
        switch m {
        case .start, .end: NSCursor.resizeLeftRight.set()
        case .move: NSCursor.pointingHand.set()
        default: NSCursor.arrow.set()
        }
    }

    func canvasMouseUp(_ p: NSPoint) {
        if dragMode != .none && dragRow >= 0 && dragDays != 0 {
            commitDrag()
        } else if dragMode != .none {
            say(.info, "Перетаскивание отменено: даты не изменились.")
        }
        dragMode = .none
        dragRow = -1
        dragDays = 0
        canvas.needsDisplay = true
    }

    private func commitDrag() {
        let r = rows[dragRow]
        var newStart = r.start, newEnd = r.planEnd
        var what = ""
        switch dragMode {
        case .move: newStart = addDays(r.start, dragDays); newEnd = addDays(r.planEnd, dragDays); what = "сдвинут"
        case .start: newStart = addDays(r.start, dragDays); what = "смещено начало"
        case .end: newEnd = addDays(r.planEnd, dragDays); what = "изменён срок"
        case .none: return
        }
        if newEnd < newStart {
            say(.warn, "Срок не может быть раньше даты заказа — изменение отменено.")
            return
        }
        if r.taskId > 0 {
            data.db.run("UPDATE tasks SET plan_start = ?, due_at = ? WHERE id = ?", [dateStr(newStart), dateStr(newEnd), r.taskId])
        } else if r.projectId > 0 {
            data.db.run("UPDATE projects SET start_date = ?, due_date = ? WHERE id = ?", [dateStr(newStart), dateStr(newEnd), r.projectId])
        } else {
            data.db.run("UPDATE orders SET order_date = ?, due_date = ? WHERE id = ?", [dateStr(newStart), dateStr(newEnd), r.orderId])
        }
        loadRows()
        let sign = dragDays > 0 ? "+" : ""
        say(.ok, "\(r.caption): \(what) — \(fmtDate(r.start, "dd.MM"))–\(fmtDate(r.planEnd, "dd.MM")) → \(fmtDate(newStart, "dd.MM"))–\(fmtDate(newEnd, "dd.MM")) (\(sign)\(dragDays) дн.)")
    }

    func canvasDoubleClick(_ p: NSPoint) {
        let row = Int((p.y - HEAD_H) / ROW_H)
        guard row >= 0, row < rows.count, p.y >= HEAD_H else { return }
        if rows[row].taskId > 0 { onOpenTask?(rows[row].taskId) }
        else if rows[row].projectId > 0 { onOpenProject?(rows[row].projectId) }
        else { onOpenOrder?(rows[row].orderId) }
    }

    /// Тянет полосу тем же путём, что и мышь: нажатие, сдвиг на days дней, отпускание.
    @discardableResult
    func dragBar(_ row: Int, _ mode: DragMode, _ days: Int) -> Bool {
        guard row >= 0, row < rows.count, mode != .none, !rows[row].isWork || rows[row].taskId > 0 else { return false }
        let y0 = HEAD_H + CGFloat(row) * ROW_H + ROW_H / 2
        let x0: CGFloat
        switch mode {
        case .start: x0 = xOfDate(rows[row].start)
        case .end: x0 = xOfDate(rows[row].planEnd)
        default: x0 = (xOfDate(rows[row].start) + xOfDate(rows[row].planEnd)) / 2
        }
        let dx = CGFloat(Double(days) / max(daysPerPixel, 1e-6))
        canvasMouseDown(NSPoint(x: x0, y: y0))
        canvasMouseDragged(NSPoint(x: x0 + dx, y: y0))
        canvasMouseUp(NSPoint(x: x0 + dx, y: y0))
        return true
    }

    func rowStart(_ r: Int) -> Date { (r >= 0 && r < rows.count) ? rows[r].start : Date(timeIntervalSince1970: 0) }
    func rowPlanEnd(_ r: Int) -> Date { (r >= 0 && r < rows.count) ? rows[r].planEnd : Date(timeIntervalSince1970: 0) }
    func rowOrderId(_ r: Int) -> Int { (r >= 0 && r < rows.count) ? rows[r].orderId : 0 }
    func rowTaskId(_ r: Int) -> Int { (r >= 0 && r < rows.count) ? rows[r].taskId : 0 }
    func rowProjectId(_ r: Int) -> Int { (r >= 0 && r < rows.count) ? rows[r].projectId : 0 }
    var firstTaskRow: Int { rows.firstIndex { $0.taskId > 0 } ?? -1 }

    // ── данные ──

    private func asDate(_ s: String, _ def: Date) -> Date { parseISODate(s) ?? def }

    /// Режим «Проекты и задачи»: строка — проект, под ним — его задачи.
    private func loadProjectRows() {
        rows = []
        let todayD = today()
        for q in data.rows("""
        SELECT p.id, p.name, p.status, p.kind, COALESCE(c.denumire,'(без клиента)') AS client,
          COALESCE(p.start_date,'') AS d1, COALESCE(p.due_date,'') AS d2
        FROM projects p LEFT JOIN clients c ON c.id = p.client_id
        WHERE p.status NOT IN ('Проигран') ORDER BY p.start_date, p.id
        """) {
            var r = GanttRow()
            r.projectId = q.int("id")
            let status = q.str("status")
            r.caption = q.str("name")
            r.sub = q.str("client") + "  ·  " + status
            r.start = asDate(q.str("d1"), todayD)
            r.planEnd = asDate(q.str("d2"), addDays(r.start, 30))
            if r.planEnd < r.start { r.planEnd = addDays(r.start, 1) }
            r.closed = status == "Закрыт"
            r.factEnd = r.closed ? r.planEnd : todayD
            r.overdue = !r.closed && r.planEnd < todayD
            rows.append(r)
            for t in data.rows("""
            SELECT t.id, t.subject, COALESCE(t.assignee,'') AS who, COALESCE(t.stage,'') AS stage, COALESCE(t.done,0) AS done,
              COALESCE(t.plan_start,'') AS d1, COALESCE(t.due_at,'') AS d2, COALESCE(t.depends_on,0) AS dep, COALESCE(t.hours_plan,0) AS hp
            FROM tasks t WHERE t.project_id = \(r.projectId) ORDER BY COALESCE(t.seq,0), t.plan_start, t.id
            """) {
                var w = GanttRow()
                w.isWork = true
                w.projectId = r.projectId
                w.taskId = t.int("id")
                w.dependsOn = t.int("dep")
                w.caption = "   " + t.str("subject")
                w.sub = t.str("who") + "  ·  " + t.str("stage") + (t.dbl("hp") > 0 ? "  ·  \(fmt0_1(t.dbl("hp"))) ч" : "")
                w.planEnd = asDate(t.str("d2"), r.planEnd)
                w.start = asDate(t.str("d1"), addDays(w.planEnd, -1))
                if w.planEnd < w.start { w.planEnd = addDays(w.start, 1) }
                w.closed = t.int("done") == 1
                w.factEnd = w.closed ? w.planEnd : min(todayD, w.planEnd)
                if w.factEnd < w.start { w.factEnd = w.start }
                w.overdue = !w.closed && w.planEnd < todayD
                rows.append(w)
            }
        }
    }

    private func loadRows() {
        if filter.indexOfSelectedItem == 3 {
            loadProjectRows()
            finishRows()
            return
        }
        rows = []
        let todayD = today()
        let whereSql: String
        switch filter.indexOfSelectedItem {
        case 0: whereSql = "t.kind = 'Производство' AND t.status <> 'Отменён'"
        case 2: whereSql = "t.status NOT IN ('Отменён') AND NOT (COALESCE(t.ship_date,'') <> '' AND COALESCE(t.paid,0) >= t.total)"
        default: whereSql = "t.status <> 'Отменён'"
        }
        for q in data.rows("""
        SELECT t.id, t.number, t.kind, t.status, COALESCE(c.denumire,'(без клиента)') AS client,
          COALESCE(t.order_date,'') AS d1, COALESCE(t.due_date,'') AS d2, COALESCE(t.ship_date,'') AS d3,
          COALESCE(t.total,0) AS total, COALESCE(t.paid,0) AS paid
        FROM orders t LEFT JOIN clients c ON c.id = t.client_id WHERE \(whereSql) ORDER BY t.order_date, t.id
        """) {
            var r = GanttRow()
            r.orderId = q.int("id")
            r.caption = "№\(q.str("number"))  \(q.str("kind"))"
            r.sub = q.str("client") + "  ·  " + q.str("status")
            r.start = asDate(q.str("d1"), todayD)
            r.planEnd = asDate(q.str("d2"), addDays(r.start, 14))
            if r.planEnd < r.start { r.planEnd = addDays(r.start, 1) }
            r.factEnd = q.str("d3").isEmpty ? todayD : asDate(q.str("d3"), r.planEnd)
            r.closed = !q.str("d3").isEmpty && q.dbl("paid") >= q.dbl("total")
            r.overdue = !r.closed && r.planEnd < todayD
            rows.append(r)
            // операции: строки заказа, распределённые по плановому окну
            let lines = data.rows("SELECT i.name, i.unit_, l.qty FROM order_lines l LEFT JOIN items i ON i.id = l.item_id WHERE l.order_id = \(r.orderId) ORDER BY l.id")
            if !lines.isEmpty {
                let span = max(1, r.planEnd.timeIntervalSince(r.start) / 86400) / Double(lines.count)
                for (i, l) in lines.enumerated() {
                    var w = GanttRow()
                    w.isWork = true
                    w.orderId = r.orderId
                    w.caption = "   " + l.str("name")
                    w.sub = fmt0_2(l.dbl("qty")) + " " + l.str("unit_")
                    w.start = r.start.addingTimeInterval(Double(i) * span * 86400)
                    w.planEnd = r.start.addingTimeInterval(Double(i + 1) * span * 86400)
                    w.factEnd = min(w.planEnd, max(w.start, r.factEnd))
                    w.closed = r.closed
                    w.overdue = r.overdue   // факта по операциям нет — наследуется от заказа
                    rows.append(w)
                }
            }
        }
        finishRows()
    }

    private func finishRows() {
        minD = today(); maxD = addDays(today(), 7)
        for r in rows {
            if r.start < minD { minD = r.start }
            if r.planEnd > maxD { maxD = r.planEnd }
            if r.factEnd > maxD { maxD = r.factEnd }
        }
        minD = addDays(minD, -2)
        maxD = addDays(maxD, 2)
        info.stringValue = "строк: \(rows.count) (работ: \(workCount)), просрочено: \(overdueCount)   ·   \(rangeText)"
        needsLayout = true
        canvas.needsDisplay = true
    }

    func paint(_ view: NSView) {
        let w = view.bounds.width
        chartW = max(50, w - LEFT_W - 16)
        ESPO_WHITE.setFill()
        view.bounds.fill()
        func xOf(_ d: Date) -> CGFloat { xOfDate(d) }
        func applyDrag(_ row: inout GanttRow, _ index: Int) {
            guard dragMode != .none, dragRow >= 0, dragDays != 0 else { return }
            if rows[dragRow].taskId > 0 {
                if index != dragRow { return }
            } else if row.orderId != rows[dragRow].orderId || row.projectId != rows[dragRow].projectId { return }
            switch dragMode {
            case .move: row.start = addDays(row.start, dragDays); row.planEnd = addDays(row.planEnd, dragDays)
            case .start: if index == dragRow { row.start = addDays(row.start, dragDays) }
            case .end: if index == dragRow { row.planEnd = addDays(row.planEnd, dragDays) }
            case .none: break
            }
        }
        func bar(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat, _ h: CGFloat, _ c: NSColor) {
            let x2c = max(x2, x1 + 2)
            c.setFill()
            NSRect(x: x1, y: y, width: x2c - x1, height: h).fill()
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ maxW: CGFloat, size: Int, bold: Bool, color: NSColor) {
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: s, attributes: [.font: espoFont(size, bold: bold), .foregroundColor: color, .paragraphStyle: para])
                .draw(in: NSRect(x: x, y: y, width: maxW, height: 18))
        }
        // шкала времени: недели
        var d = minD
        let bottom = view.bounds.height - 20
        while d <= maxD {
            let x = xOf(d)
            let wd = Calendar.current.component(.weekday, from: d)
            (wd == 2 ? ESPO_BORDER : ESPO_PANEL_BRD).setStroke()
            let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: HEAD_H - 6)); p.line(to: NSPoint(x: x, y: bottom)); p.stroke()
            text(fmtDate(d, "dd.MM"), x + 3, 6, 60, size: 8, bold: false, color: ESPO_MUTED)
            d = addDays(d, 7)
        }
        // сегодня
        let xt = xOf(today())
        ST_DANGER_FG.setStroke()
        let tp = NSBezierPath(); tp.lineWidth = 2; tp.move(to: NSPoint(x: xt, y: HEAD_H - 10)); tp.line(to: NSPoint(x: xt, y: bottom)); tp.stroke()
        text("сегодня", xt + 3, HEAD_H - 24, 80, size: 8, bold: false, color: ST_DANGER_FG)
        // строки
        for (i, r0) in rows.enumerated() {
            var r = r0
            applyDrag(&r, i)
            let y = HEAD_H + CGFloat(i) * ROW_H
            if i % 2 == 1 { ESPO_ALT_ROW.setFill(); NSRect(x: 0, y: y, width: w, height: ROW_H).fill() }
            text(r.caption, 10, y + 3, LEFT_W - 134, size: r.isWork ? 8 : 9, bold: !r.isWork, color: r.isWork ? ESPO_MUTED : ESPO_TEXT)
            text(r.sub, LEFT_W - 120, y + 5, 114, size: 8, bold: false, color: ESPO_MUTED)
            let barY = y + (r.isWork ? 7 : 4)
            let h: CGFloat = r.isWork ? 8 : 14
            bar(xOf(r.start), xOf(r.planEnd), barY, h, NSColor(hex: 0xD2DFE8))          // план
            if r.closed { bar(xOf(r.start), xOf(r.factEnd), barY, h, ST_SUCCESS_FG) }
            else if r.overdue { bar(xOf(r.planEnd), xOf(max(r.factEnd, today())), barY, h, ST_DANGER_FG) }
            else { bar(xOf(r.start), xOf(r.factEnd), barY, h, ESPO_PRIMARY) }
        }
        // стрелки зависимостей задач
        ESPO_GRAY.setStroke(); ESPO_GRAY.setFill()
        for i in 0..<rows.count where rows[i].taskId > 0 && rows[i].dependsOn > 0 {
            guard let j = rows.firstIndex(where: { $0.taskId == rows[i].dependsOn }) else { continue }
            var a = rows[j]; applyDrag(&a, j)
            var b = rows[i]; applyDrag(&b, i)
            let x = xOf(a.planEnd), y = HEAD_H + CGFloat(j) * ROW_H + 11
            let x2 = xOf(b.start), y2 = HEAD_H + CGFloat(i) * ROW_H + 11
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: x + 4, y: y)); p.line(to: NSPoint(x: x + 4, y: y2)); p.line(to: NSPoint(x: x2, y: y2))
            p.stroke()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: x2, y: y2)); tri.line(to: NSPoint(x: x2 - 5, y: y2 - 3)); tri.line(to: NSPoint(x: x2 - 5, y: y2 + 3)); tri.close()
            tri.fill()
        }
        // легенда
        let ly = HEAD_H + CGFloat(rows.count) * ROW_H + 8
        bar(10, 30, ly, 10, NSColor(hex: 0xD2DFE8)); text(T.S("gantt.plan"), 36, ly - 2, 50, size: 8, bold: false, color: ESPO_MUTED)
        bar(90, 110, ly, 10, ESPO_PRIMARY); text(T.S("gantt.run"), 116, ly - 2, 50, size: 8, bold: false, color: ESPO_MUTED)
        bar(170, 190, ly, 10, ST_DANGER_FG); text(T.S("gantt.late"), 196, ly - 2, 80, size: 8, bold: false, color: ESPO_MUTED)
        bar(280, 300, ly, 10, ST_SUCCESS_FG); text(T.S("gantt.closed"), 306, ly - 2, 70, size: 8, bold: false, color: ESPO_MUTED)
        let legendText = filter.indexOfSelectedItem == 3
            ? "отступом показаны задачи проекта в порядке выполнения; стрелка — «после задачи»; задачи можно тянуть"
            : T.S("gantt.legend")
        text(legendText, 380, ly - 2, w - 390, size: 8, bold: false, color: ESPO_MUTED)
    }

    func refresh() { loadRows() }

    @objc private func onFilterChange() {
        loadRows()
        say(.info, "План работ: \(filter.titleOfSelectedItem ?? "")   ·   \(info.stringValue)")
    }

    func selectFilter(_ index: Int) {
        filter.selectItem(at: index)
        onFilterChange()
    }

    var rowCount: Int { rows.count }
    var workCount: Int { rows.filter { $0.isWork }.count }
    var overdueCount: Int { rows.filter { $0.overdue && !$0.isWork }.count }
    var rangeText: String { "\(fmtDate(minD, "dd.MM.yyyy")) — \(fmtDate(maxD, "dd.MM.yyyy"))" }
}
