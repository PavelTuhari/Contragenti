// Календарь месячной сеткой (аналог uCalendarView.pas): 7 × 6 дней, в ячейке
// задачи дня. Задачу можно перетащить мышью на другой день — меняется срок
// (due_at). Перенос идёт через один метод moveTask, как мышью, так и из теста.
import AppKit

struct CalTask {
    var id = 0
    var subject = "", kind = ""
    var due = Date()
    var done = false, overdue = false
}

private let HEAD_H: CGFloat = 78, WEEK_H: CGFloat = 24

/// Подпись задачи в ячейке: мышь уходит календарю.
final class CalTaskLabel: NSTextField {
    weak var page: CalendarPage?
    var taskId = 0
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { page?.onOpenTask?(taskId); return }
        page?.taskMouseDown(taskId, at: page!.convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) { page?.taskMouseDragged(page!.convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { page?.taskMouseUp(page!.convert(event.locationInWindow, from: nil)) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class CalendarPage: FlippedView {
    private let data: CrmData
    private let say: SayProc
    var onOpenTask: ((Int) -> Void)?
    var onNewTask: ((Date) -> Void)?
    var onShowList: (() -> Void)?

    private var month: Date          // первое число показываемого месяца
    private var selectedDay: Date
    private let header = FlippedView(bg: ESPO_BODY)
    private let week = FlippedView(bg: ESPO_BODY)
    private let grid = FlippedView(bg: ESPO_BODY)
    private let dayPanel = PanelBox(title: "")
    private var titleLbl: NSTextField!
    private var dayTitle: NSTextField!, dayList: NSTextField!
    private var weekLabels: [NSTextField] = []
    private var cells: [FlippedView] = []
    private var cellDates: [Date] = []
    private var cellInMonth: [Bool] = []
    private var dayLabels: [NSTextField] = []
    private var taskLabels: [CalTaskLabel] = []
    private var extraLabels: [NSTextField] = []
    private(set) var tasks: [CalTask] = []
    private var newBtn: EspoButton!, listBtn: EspoButton!
    // перетаскивание
    private var dragId = -1
    private var dragActive = false
    private var dragOrigin = NSPoint.zero
    private var ghost: FlippedView?
    private var ghostText: NSTextField?
    private var hoverCell = -1

    init(data: CrmData, say: @escaping SayProc) {
        self.data = data
        self.say = say
        let t = today()
        let c = Calendar.current.dateComponents([.year, .month], from: t)
        month = Calendar.current.date(from: c) ?? t
        selectedDay = t
        super.init(frame: .zero)
        bgColor = ESPO_BODY
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        addSubview(header)
        makeLabel(header, T.S("calendar.title"), x: 15, y: 10, w: 140, h: 30, color: ESPO_TEXT, size: 16)
        let prev = EspoButton("‹", primary: false, width: 40) { [weak self] in self?.goPrevMonth() }
        prev.frame = NSRect(x: 160, y: 10, width: 40, height: 32); header.addSubview(prev)
        let next = EspoButton("›", primary: false, width: 40) { [weak self] in self?.goNextMonth() }
        next.frame = NSRect(x: 204, y: 10, width: 40, height: 32); header.addSubview(next)
        let todayB = EspoButton(T.S("calendar.today"), primary: false, width: 110) { [weak self] in self?.goToday() }
        todayB.frame = NSRect(x: 248, y: 10, width: 110, height: 32); header.addSubview(todayB)
        titleLbl = makeLabel(header, "", x: 370, y: 16, w: 300, h: 22, color: ESPO_TEXT, size: 13, bold: true)
        newBtn = EspoButton(T.S("btn.create"), primary: true, width: 150) { [weak self] in
            guard let s = self else { return }
            s.onNewTask?(s.selectedDay)
        }
        header.addSubview(newBtn)
        listBtn = EspoButton("Список", primary: false, width: 130) { [weak self] in self?.onShowList?() }
        header.addSubview(listBtn)
        makeLabel(header, T.S("calendar.hint"), x: 15, y: 52, w: 720, color: ESPO_MUTED, size: 9)

        addSubview(week)
        let days = T.S("calendar.week_days").split(separator: ";").map(String.init)
        for i in 0..<7 {
            weekLabels.append(makeLabel(week, i < days.count ? days[i] : "", x: 15 + CGFloat(i) * 100, y: 4, w: 96, color: ESPO_MUTED, size: 9))
        }

        addSubview(dayPanel)
        dayTitle = makeLabel(dayPanel, "", x: 14, y: 8, w: 500, h: 22, color: ESPO_SOFT, size: 11, bold: true)
        dayList = makeWrapLabel(dayPanel, "", x: 14, y: 30, w: 1000, h: 60)

        addSubview(grid)
        for i in 0..<42 {
            let c = FlippedView(bg: ESPO_WHITE)
            c.borderColor = ESPO_PANEL_BRD
            c.tag_ = i
            c.onClick = { [weak self] in self?.cellClick(i) }
            grid.addSubview(c)
            cells.append(c)
            dayLabels.append(makeLabel(c, "", x: 6, y: 4, w: 40, color: ESPO_TEXT, size: 10))
            cellDates.append(today())
            cellInMonth.append(true)
        }
    }

    override func layout() {
        super.layout()
        dock(top: [(header, HEAD_H), (week, WEEK_H)], bottom: [(dayPanel, 96)], client: grid)
        newBtn.frame = NSRect(x: header.bounds.width - 165, y: 10, width: 150, height: 34)
        listBtn.frame = NSRect(x: header.bounds.width - 165 - 8 - 130, y: 10, width: 130, height: 34)
        let cw = max(60, (grid.bounds.width - 30) / 7)
        let ch = max(50, (grid.bounds.height - 12) / 6)
        for i in 0..<42 {
            cells[i].frame = NSRect(x: 15 + CGFloat(i % 7) * cw, y: 4 + CGFloat(i / 7) * ch, width: cw - 3, height: ch - 3)
        }
        for i in 0..<7 { weekLabels[i].frame = NSRect(x: 15 + CGFloat(i) * cw + 4, y: 4, width: cw - 8, height: 18) }
        for l in taskLabels { l.frame.size.width = (l.superview?.bounds.width ?? 100) - 12 }
    }

    private func loadMonth() {
        taskLabels.forEach { $0.removeFromSuperview() }; taskLabels = []
        extraLabels.forEach { $0.removeFromSuperview() }; extraLabels = []
        tasks = []
        let cal = Calendar.current
        let months = T.S("calendar.months").split(separator: ";").map(String.init)
        let m = cal.component(.month, from: month), y = cal.component(.year, from: month)
        titleLbl.stringValue = (m - 1 < months.count ? months[m - 1] : fmtDate(month, "MMMM")) + " \(y)"

        // сетка начинается с понедельника недели, в которую попало 1-е число
        let shift = (cal.component(.weekday, from: month) + 5) % 7   // Пн = 0
        let first = addDays(month, -shift)
        let todayD = today()
        for i in 0..<42 {
            let d = addDays(first, i)
            cellDates[i] = d
            cellInMonth[i] = cal.component(.month, from: d) == m
            dayLabels[i].stringValue = String(cal.component(.day, from: d))
            dayLabels[i].textColor = !cellInMonth[i] ? ESPO_PANEL_BRD : (d == todayD ? ST_DANGER_FG : ESPO_TEXT)
            dayLabels[i].font = espoFont(10, bold: d == todayD)
            cells[i].bgColor = d == selectedDay ? ST_PRIMARY_BG : (cellInMonth[i] ? ESPO_WHITE : ESPO_ALT_ROW)
        }
        // задачи всего показываемого окна одним запросом
        for q in data.rows("SELECT id, subject, kind, due_at, done FROM tasks WHERE due_at >= \(quoted(dateStr(first))) AND due_at <= \(quoted(dateStr(addDays(first, 41)))) ORDER BY due_at, id") {
            var t = CalTask()
            t.id = q.int("id"); t.subject = q.str("subject"); t.kind = q.str("kind")
            t.due = parseISODate(q.str("due_at")) ?? todayD
            t.done = q.int("done") == 1
            t.overdue = !t.done && t.due < todayD
            tasks.append(t)
        }
        var cnt = Array(repeating: 0, count: 42)
        for t in tasks {
            let i = cellIndexOf(t.due)
            if i < 0 { continue }
            cnt[i] += 1
            if cnt[i] > 3 { continue }
            let l = CalTaskLabel(labelWithString: (t.done ? "✓ " : "") + t.subject)
            l.page = self
            l.taskId = t.id
            l.font = espoFont(8)
            l.textColor = t.done ? ESPO_MUTED : (t.overdue ? ST_DANGER_FG : ESPO_TEXT)
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: 6, y: 20 + CGFloat(cnt[i] - 1) * 15, width: cells[i].bounds.width - 12, height: 14)
            cells[i].addSubview(l)
            taskLabels.append(l)
        }
        for i in 0..<42 where cnt[i] > 3 {
            extraLabels.append(makeLabel(cells[i], "+ \(cnt[i] - 3)", x: 6, y: 65, w: 60, h: 14, color: ESPO_MUTED, size: 8))
        }
        fillDayPanel()
    }

    private func fillDayPanel() {
        dayTitle.stringValue = T.S("calendar.day_tasks") + "  ·  " + fmtDate(selectedDay, "dd.MM.yyyy")
        var lines: [String] = []
        for t in tasks where t.due == selectedDay {
            lines.append("• \(t.kind) — \(t.subject)" + (t.done ? "  ✓" : (t.overdue ? "  ← " + T.S("kanban.overdue") : "")))
        }
        dayList.stringValue = lines.isEmpty ? T.S("calendar.no_tasks") : lines.joined(separator: "\n")
    }

    func refresh() { loadMonth() }

    func cellIndexOf(_ d: Date) -> Int {
        let s = Calendar.current.startOfDay(for: d)
        return cellDates.firstIndex { $0 == s } ?? -1
    }

    private func cellAt(_ pInPage: NSPoint) -> Int {
        let p = grid.convert(pInPage, from: self)
        return cells.firstIndex { $0.frame.contains(p) } ?? -1
    }

    private func showGhost(_ p: NSPoint) {
        if ghost == nil {
            let g = FlippedView(bg: ST_PRIMARY_BG)
            g.borderColor = ESPO_PRIMARY
            g.frame = NSRect(x: 0, y: 0, width: 200, height: 26)
            ghostText = makeLabel(g, "", x: 8, y: 5, w: 184, color: ST_PRIMARY_FG, size: 9)
            addSubview(g)
            ghost = g
        }
        ghostText?.stringValue = tasks.first { $0.id == dragId }?.subject ?? ""
        ghost?.frame.origin = NSPoint(x: p.x + 12, y: p.y + 8)
        ghost?.isHidden = false
    }

    private func hideGhost() { ghost?.isHidden = true }

    private func highlightCell(_ index: Int) {
        if index == hoverCell { return }
        if hoverCell >= 0 && hoverCell < 42 {
            cells[hoverCell].bgColor = cellDates[hoverCell] == selectedDay ? ST_PRIMARY_BG : (cellInMonth[hoverCell] ? ESPO_WHITE : ESPO_ALT_ROW)
        }
        hoverCell = index
        if index >= 0 && index < 42 { cells[index].bgColor = ST_SUCCESS_BG }
    }

    func taskMouseDown(_ id: Int, at p: NSPoint) {
        dragId = id
        dragActive = false
        dragOrigin = p
    }

    func taskMouseDragged(_ p: NSPoint) {
        guard dragId >= 0 else { return }
        if !dragActive && abs(p.x - dragOrigin.x) + abs(p.y - dragOrigin.y) < 8 { return }
        dragActive = true
        showGhost(p)
        highlightCell(cellAt(p))
    }

    func taskMouseUp(_ p: NSPoint) {
        if dragActive {
            let cell = cellAt(p)
            hideGhost()
            highlightCell(-1)
            if cell >= 0 && dragId >= 0 { moveTask(dragId, to: cellDates[cell]) }
        }
        dragActive = false
        dragId = -1
    }

    func moveTask(_ taskId: Int, to newDate: Date) {
        let nd = Calendar.current.startOfDay(for: newDate)
        var subject = ""
        if let t = tasks.first(where: { $0.id == taskId }) {
            if t.due == nd { return }
            subject = t.subject
        }
        data.db.run("UPDATE tasks SET due_at = ? WHERE id = ?", [dateStr(nd), taskId])
        selectedDay = nd
        loadMonth()
        say(.ok, T.F("calendar.moved", [subject, fmtDate(nd, "dd.MM.yyyy")]))
    }

    private func cellClick(_ i: Int) {
        guard i >= 0, i < 42 else { return }
        selectedDay = cellDates[i]
        loadMonth()
    }

    func goPrevMonth() { month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month; loadMonth() }
    func goNextMonth() { month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month; loadMonth() }
    func goToday() {
        let c = Calendar.current.dateComponents([.year, .month], from: today())
        month = Calendar.current.date(from: c) ?? today()
        selectedDay = today()
        loadMonth()
    }
    func selectDay(_ d: Date) {
        selectedDay = Calendar.current.startOfDay(for: d)
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        month = Calendar.current.date(from: c) ?? d
        loadMonth()
    }
    var selectedDate: Date { selectedDay }
    var monthTitle: String { titleLbl.stringValue }
    var tasksInMonth: Int {
        let m = Calendar.current.component(.month, from: month)
        return tasks.filter { Calendar.current.component(.month, from: $0.due) == m }.count
    }
    func tasksOnDay(_ d: Date) -> Int {
        let s = Calendar.current.startOfDay(for: d)
        return tasks.filter { $0.due == s }.count
    }

    /// Тянет задачу мышью на другой день: нажатие, сдвиг, отпускание над ячейкой.
    @discardableResult
    func dragTask(_ taskId: Int, to date: Date) -> Bool {
        let cell = cellIndexOf(date)
        guard cell >= 0, let l = taskLabels.first(where: { $0.taskId == taskId }) else { return false }
        let src = convert(l.bounds, from: l)
        let start = NSPoint(x: src.midX, y: src.midY)
        taskMouseDown(taskId, at: start)
        let target = convert(NSPoint(x: cells[cell].frame.midX, y: cells[cell].frame.midY), from: grid)
        taskMouseDragged(NSPoint(x: start.x + 20, y: start.y + 5))
        taskMouseDragged(target)
        taskMouseUp(target)
        return true
    }
}
