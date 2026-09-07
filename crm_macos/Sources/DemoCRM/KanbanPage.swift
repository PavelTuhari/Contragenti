// Канбан-доска (аналог uKanban.pas): карточки по колонкам-этапам, перенос
// мышью с анимацией и кнопками «← Назад» / «Вперёд →». Пять досок в одном
// экране. Мышь и программный перенос (самотест) идут одним путём:
// beginDrag → dragTo → endDrag.
import AppKit

private let COL_W: CGFloat = 202, COL_GAP: CGFloat = 8, CARD_GAP: CGFloat = 6

final class KanbanPage: FlippedView, CardMouseDelegate {
    private let data: CrmData
    private let say: SayProc
    var onOpenRecord: ((BoardKind, Int) -> Void)?

    private let header = FlippedView(bg: ESPO_BODY)
    private let boardCombo: NSPopUpButton
    private let projectCombo: NSPopUpButton
    private var projectIds: [Int] = []
    private let bodyScroll: NSScrollView
    private let bodyDoc: FlippedView
    private var colW = COL_W
    private var cols: [FlippedView] = []
    private var colBodies: [NSScrollView] = []
    private var colDocs: [FlippedView] = []
    private var colHeads: [NSTextField] = []
    private var colCounts: [NSTextField] = []
    private var colLate: [NSTextField] = []
    private(set) var cards: [BoardCard] = []
    private var cardViews: [BoardCardView] = []
    private var selected = -1
    private(set) var board: BoardKind = .orders
    private var fwdBtn: EspoButton!, backBtn: EspoButton!, refreshBtn: EspoButton!
    private var legend: [NSView] = []
    // перетаскивание
    private var dragIdx = -1
    private var dragActive = false
    private var dragOrigin = NSPoint.zero   // в координатах страницы
    private var dragOffset = NSPoint.zero
    private var ghost: BoardCardView?
    private var slot: FlippedView?
    private var hoverCol = -1
    private(set) var animFrames = 0
    var animEnabled = true

    init(data: CrmData, say: @escaping SayProc) {
        self.data = data
        self.say = say
        boardCombo = NSPopUpButton(frame: NSRect(x: 125, y: 14, width: 260, height: 28), pullsDown: false)
        projectCombo = NSPopUpButton(frame: NSRect(x: 395, y: 14, width: 250, height: 28), pullsDown: false)
        (bodyScroll, bodyDoc) = makeScrollBox(bg: ESPO_BODY, horizontal: true)
        super.init(frame: .zero)
        bgColor = ESPO_BODY
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        addSubview(header)
        makeLabel(header, T.S("kanban.title"), x: 15, y: 10, w: 110, h: 30, color: ESPO_TEXT, size: 16)
        boardCombo.font = espoFont(10)
        boardCombo.addItems(withTitles: [T.S("kanban.board_orders"), T.S("kanban.board_deals"), T.S("kanban.board_tasks"),
                                         T.S("kanban.board_projects"), T.S("kanban.board_project_tasks")])
        boardCombo.target = self
        boardCombo.action = #selector(onBoardChange)
        header.addSubview(boardCombo)
        projectCombo.font = espoFont(10)
        projectCombo.isHidden = true
        projectCombo.target = self
        projectCombo.action = #selector(onProjectChange)
        header.addSubview(projectCombo)
        fwdBtn = EspoButton(T.S("btn.forward"), primary: true, width: 130) { [weak self] in self?.moveSelected(1) }
        backBtn = EspoButton(T.S("btn.back"), primary: false, width: 120) { [weak self] in self?.moveSelected(-1) }
        refreshBtn = EspoButton(T.S("btn.refresh"), primary: false, width: 110) { [weak self] in
            self?.loadCards(); self?.say(.info, T.S("kanban.refreshed"))
        }
        for b in [fwdBtn!, backBtn!, refreshBtn!] { header.addSubview(b) }
        makeLabel(header, T.S("kanban.hint"), x: 15, y: 50, w: 560, color: ESPO_MUTED, size: 9)
        // легенда цветов справа
        let items: [(String, NSColor)] = [(T.enumAt("order_kind", 0), CLR_BLUE), (T.enumAt("order_kind", 1), CLR_TEAL),
                                          (T.enumAt("order_kind", 2), CLR_AMBER), (T.S("kanban.overdue"), ST_DANGER_FG),
                                          (T.S("kanban.done_badge"), ST_SUCCESS_FG)]
        for (text, color) in items {
            let g = makeLabel(header, "■", x: 0, y: 50, w: 16, color: color, size: 10, bold: true)
            let l = makeLabel(header, text, x: 0, y: 51, w: 90, color: ESPO_MUTED, size: 8)
            l.sizeToFit()
            legend += [g, l]
        }
        addSubview(bodyScroll)
        rebuildColumns()
    }

    override func layout() {
        super.layout()
        dock(top: [(header, 72)], client: bodyScroll)
        fwdBtn.frame = NSRect(x: header.bounds.width - 145, y: 10, width: 130, height: 36)
        backBtn.frame = NSRect(x: header.bounds.width - 145 - 8 - 120, y: 10, width: 120, height: 36)
        refreshBtn.frame = NSRect(x: header.bounds.width - 145 - 8 - 120 - 8 - 110, y: 10, width: 110, height: 36)
        var x = header.bounds.width - 15
        for i in stride(from: legend.count - 1, through: 0, by: -2) {
            let l = legend[i], g = legend[i - 1]
            x -= l.frame.width
            l.frame.origin.x = x
            x -= 16
            g.frame.origin.x = x
            x -= 14
        }
        layoutColumns()
    }

    private func layoutColumns() {
        let n = cols.count
        let extra: CGFloat = n > 5 ? 18 : 0
        let h = max(100, bodyScroll.bounds.height - 24 - extra)
        let docW = max(bodyScroll.bounds.width, 15 + CGFloat(n) * (colW + COL_GAP))
        bodyDoc.frame = NSRect(x: 0, y: 0, width: docW, height: max(bodyScroll.bounds.height - extra, h + 24))
        var x: CGFloat = 15
        for i in 0..<n {
            cols[i].frame = NSRect(x: x, y: 12, width: colW, height: h)
            colBodies[i].frame = NSRect(x: 6, y: 62, width: colW - 12, height: h - 70)
            colDocs[i].frame.size.width = colW - 12
            x += colW + COL_GAP
        }
        relayoutCards()
    }

    private func rebuildColumns() {
        hideGhost()
        cols.forEach { $0.removeFromSuperview() }
        cols = []; colBodies = []; colDocs = []; colHeads = []; colCounts = []; colLate = []
        cardViews = []; cards = []; selected = -1; hoverCol = -1
        let titles = boardColumnTitles(board)
        colW = titles.count <= 5 ? COL_W : 176
        for (i, t) in titles.enumerated() {
            let p = FlippedView(bg: ESPO_WHITE)
            p.borderColor = ESPO_PANEL_BRD
            p.cornerRadius = 3
            bodyDoc.addSubview(p)
            cols.append(p)
            // цветная кромка колонки — тот же цвет, что у узла схемы процесса
            let stripe = FlippedView(bg: boardColumnColor(board, i))
            stripe.frame = NSRect(x: 2, y: 0, width: colW - 4, height: 4)
            stripe.autoresizingMask = [.width]
            p.addSubview(stripe)
            colHeads.append(makeLabel(p, t, x: 10, y: 12, w: colW - 20, color: ESPO_SOFT, size: 9, bold: true))
            colCounts.append(makeLabel(p, "", x: 10, y: 30, w: colW - 20, color: ESPO_MUTED, size: 8))
            colLate.append(makeLabel(p, "", x: 10, y: 44, w: colW - 20, color: ST_DANGER_FG, size: 8))
            let (sb, doc) = makeScrollBox(bg: ESPO_WHITE)
            p.addSubview(sb)
            colBodies.append(sb)
            colDocs.append(doc)
        }
        layoutColumns()
    }

    private func relayoutCards() {
        var ys = Array(repeating: CGFloat(4), count: cols.count)
        for (i, v) in cardViews.enumerated() {
            let c = cards[i].col
            v.frame = NSRect(x: 4, y: ys[c], width: colW - 34, height: CARD_H)
            ys[c] += CARD_H + CARD_GAP
        }
        for (i, doc) in colDocs.enumerated() {
            doc.frame.size.height = max(colBodies[i].bounds.height, ys[i] + 4)
        }
    }

    private func loadCards() {
        hideGhost()
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = []; cards = []; selected = -1
        let titles = boardColumnTitles(board)
        for col in 0..<titles.count {
            let list = loadBoardCards(data, board, col)
            for c in list {
                let v = BoardCardView(c, x: 4, y: 0, w: colW - 34)
                v.index = cards.count
                v.mouseDelegate = self
                colDocs[col].addSubview(v)
                cards.append(c)
                cardViews.append(v)
            }
            let sum = boardColumnSum(list), late = boardColumnOverdue(list)
            colCounts[col].stringValue = sum > 0 ? "\(list.count)  ·  \(fmtInt0(sum)) MDL" : "\(list.count)"
            colLate[col].stringValue = late > 0 ? T.F("kanban.col_late", [late]) : ""
        }
        relayoutCards()
    }

    func refresh() { loadCards() }

    @objc private func onBoardChange() {
        board = BoardKind(rawValue: boardCombo.indexOfSelectedItem) ?? .orders
        projectCombo.isHidden = board != .projectTasks
        if board == .projectTasks {
            fillProjects()
            boardProjectFilter = projectId
        }
        rebuildColumns()
        loadCards()
        say(.info, T.F("kanban.board", [boardCombo.titleOfSelectedItem ?? ""]))
    }

    /// Список проектов для доски задач: первый пункт — все задачи с проектом.
    private func fillProjects() {
        let keep = projectId
        projectCombo.removeAllItems()
        projectCombo.addItem(withTitle: T.S("kanban.all_projects"))
        projectIds = [0]
        for (id, name) in data.lookupPairs(.lookupProject) {
            projectCombo.menu?.addItem(withTitle: name, action: nil, keyEquivalent: "")
            projectIds.append(id)
        }
        projectCombo.selectItem(at: 0)
        if let i = projectIds.firstIndex(of: keep) { projectCombo.selectItem(at: i) }
    }

    @objc private func onProjectChange() {
        boardProjectFilter = projectId
        loadCards()
        say(.info, T.F("kanban.project", [projectCombo.titleOfSelectedItem ?? ""]))
    }

    var projectId: Int {
        let i = projectCombo.indexOfSelectedItem
        return (i >= 0 && i < projectIds.count) ? projectIds[i] : 0
    }

    func selectProject(_ id: Int) {
        if board != .projectTasks { selectBoard(.projectTasks) }
        fillProjects()
        if let i = projectIds.firstIndex(of: id) { projectCombo.selectItem(at: i) }
        onProjectChange()
    }

    func selectBoard(_ kind: BoardKind) {
        boardCombo.selectItem(at: kind.rawValue)
        onBoardChange()
    }

    // ── мышь: выбор и перетаскивание ──

    private func columnAt(_ pInPage: NSPoint) -> Int {
        let p = bodyDoc.convert(pInPage, from: self)
        for (i, c) in cols.enumerated() where p.x >= c.frame.minX && p.x <= c.frame.maxX { return i }
        return -1
    }

    /// Прямоугольник контрола в координатах страницы — для анимации перелёта.
    private func pageRect(_ v: NSView?) -> NSRect {
        guard let v = v, v.superview != nil else { return .zero }
        return convert(v.bounds, from: v)
    }

    private func showGhost(_ p: NSPoint) {
        guard dragIdx >= 0, dragIdx < cards.count else { return }
        if ghost == nil {
            let g = makeGhostCard(cards[dragIdx], frame: NSRect(x: 0, y: 0, width: colW - 34, height: CARD_H))
            addSubview(g)
            ghost = g
            cardViews[dragIdx].bgColor = ESPO_BODY
        }
        ghost?.frame.origin = NSPoint(x: p.x - dragOffset.x, y: p.y - dragOffset.y)
        ghost?.isHidden = false
    }

    private func hideGhost() {
        ghost?.removeFromSuperview(); ghost = nil
        slot?.removeFromSuperview(); slot = nil
        if dragIdx >= 0 && dragIdx < cardViews.count { paintCard(dragIdx) }
    }

    private func highlightColumn(_ col: Int) {
        if col == hoverCol { return }
        hoverCol = col
        for (i, c) in cols.enumerated() { c.bgColor = i == col ? ST_PRIMARY_BG : ESPO_WHITE }
        slot?.removeFromSuperview(); slot = nil
        if col >= 0 && dragIdx >= 0 && col != cards[dragIdx].col {
            var y: CGFloat = 4
            for c in cards where c.col == col { y += CARD_H + CARD_GAP }
            let s = FlippedView(bg: ESPO_HEAD_BG)
            s.borderColor = ESPO_PANEL_BRD
            s.frame = NSRect(x: 4, y: y, width: colW - 34, height: CARD_H)
            makeLabel(s, "⇩", x: 0, y: 30, w: colW - 34, h: 30, color: ESPO_PRIMARY, size: 16, align: .center)
            colDocs[col].addSubview(s)
            slot = s
        }
    }

    private func paintCard(_ i: Int) {
        guard i >= 0, i < cardViews.count else { return }
        cardViews[i].bgColor = i == selected ? ST_PRIMARY_BG : cardBaseColor(cards[i])
    }

    /// Нажатие на карточке: точка — в координатах страницы.
    func beginDrag(_ idx: Int, at p: NSPoint) {
        dragIdx = idx
        dragActive = false
        dragOrigin = p
        if idx >= 0 && idx < cardViews.count {
            let r = pageRect(cardViews[idx])
            dragOffset = NSPoint(x: max(0, min(p.x - r.minX, r.width)), y: max(0, min(p.y - r.minY, r.height)))
        }
        onCardClick(idx)
    }

    func dragTo(_ p: NSPoint) {
        guard dragIdx >= 0 else { return }
        // старт перетаскивания только после заметного сдвига
        if !dragActive && abs(p.x - dragOrigin.x) + abs(p.y - dragOrigin.y) < 8 { return }
        dragActive = true
        showGhost(p)
        highlightColumn(columnAt(p))
    }

    func endDrag(at p: NSPoint) {
        if dragActive {
            let col = columnAt(p)
            let fromR = pageRect(ghost)
            hideGhost()
            highlightColumn(-1)
            if col >= 0 && dragIdx >= 0 && dragIdx < cards.count && col != cards[dragIdx].col {
                moveCardTo(dragIdx, col, fromR)
            } else {
                say(.info, T.S("kanban.cancelled"))
            }
        }
        dragActive = false
        dragIdx = -1
    }

    func cardMouseDown(_ card: BoardCardView, _ event: NSEvent) {
        beginDrag(card.index, at: convert(event.locationInWindow, from: nil))
    }
    func cardMouseDragged(_ card: BoardCardView, _ event: NSEvent) {
        dragTo(convert(event.locationInWindow, from: nil))
    }
    func cardMouseUp(_ card: BoardCardView, _ event: NSEvent) {
        endDrag(at: convert(event.locationInWindow, from: nil))
    }
    func cardDoubleClick(_ card: BoardCardView) {
        let i = card.index
        guard i >= 0, i < cards.count else { return }
        onOpenRecord?(board, cards[i].id)
    }

    private func onCardClick(_ idx: Int) {
        selected = idx
        guard idx >= 0, idx < cards.count else { return }
        for i in 0..<cardViews.count { paintCard(i) }
        say(.info, T.F("kanban.selected", [cards[idx].title, boardColumnTitles(board)[cards[idx].col]]))
    }

    private func moveSelected(_ delta: Int) {
        guard selected >= 0, selected < cards.count else { say(.warn, T.S("kanban.select_card")); return }
        moveCardTo(selected, cards[selected].col + delta, pageRect(cardViews[selected]))
    }

    /// Перелёт копии карточки из fromR в toR с замедлением в конце.
    private func animateMove(_ fromR: NSRect, _ toR: NSRect, _ c: BoardCard) {
        guard animEnabled, !fromR.isEmpty, !toR.isEmpty else { return }
        let fly = makeGhostCard(c, frame: fromR)
        addSubview(fly)
        let frames = 14
        for i in 1...frames {
            var k = Double(i) / Double(frames)
            k = 1 - (1 - k) * (1 - k)   // ease-out
            fly.frame.origin = NSPoint(x: fromR.minX + (toR.minX - fromR.minX) * k, y: fromR.minY + (toR.minY - fromR.minY) * k)
            fly.displayIfNeeded()
            pumpSleep(0.012)
            animFrames += 1
        }
        fly.removeFromSuperview()
    }

    /// Короткая вспышка приземлившейся карточки.
    private func pulse(_ v: BoardCardView, base: NSColor) {
        guard animEnabled else { return }
        for c in [ST_SUCCESS_BG, ST_PRIMARY_BG, ST_SUCCESS_BG] {
            v.bgColor = c
            v.displayIfNeeded()
            pumpSleep(0.045)
            animFrames += 1
        }
        v.bgColor = base
    }

    /// Единственное место на доске, где карточка меняет этап.
    private func moveCardTo(_ index: Int, _ newCol: Int, _ fromR: NSRect) {
        guard index >= 0, index < cards.count else { say(.warn, T.S("kanban.select_card")); return }
        let c = cards[index]
        let titles = boardColumnTitles(board)
        guard newCol >= 0, newCol < titles.count else { say(.warn, T.F("kanban.edge", [titles[c.col]])); return }
        if newCol == c.col { return }
        let id = c.id
        moveBoardCard(data, board, id, newCol)
        loadCards()
        // вернуть выделение на ту же запись в новой колонке и показать перелёт
        if let i = cards.firstIndex(where: { $0.id == id }) {
            selected = i
            cardViews[i].isHidden = true
            animateMove(fromR, pageRect(cardViews[i]), cards[i])
            cardViews[i].isHidden = false
            pulse(cardViews[i], base: ST_PRIMARY_BG)
        }
        say(.ok, T.F("kanban.moved", [c.title, titles[newCol]]))
    }

    // ── хуки самотеста ──

    var columnCount: Int { cols.count }
    func cardsInColumn(_ col: Int) -> Int { cards.filter { $0.col == col }.count }

    @discardableResult
    func selectFirstCard(_ col: Int) -> Bool {
        guard let i = cards.firstIndex(where: { $0.col == col }) else { return false }
        onCardClick(i)
        return true
    }

    var selectedColumn: Int { (selected >= 0 && selected < cards.count) ? cards[selected].col : -1 }
    var selectedId: Int { (selected >= 0 && selected < cards.count) ? cards[selected].id : 0 }
    func cardById(_ id: Int) -> BoardCard? { cards.first { $0.id == id } }
    func moveForward() { moveSelected(1) }
    func moveBack() { moveSelected(-1) }

    /// Проводит карточку тем же путём, что и мышь: нажатие, перемещение и
    /// отпускание над серединой целевой колонки.
    @discardableResult
    func dragCardIndex(_ index: Int, _ toCol: Int) -> Bool {
        guard index >= 0, index < cards.count, toCol >= 0, toCol < cols.count else { return false }
        let src = pageRect(cardViews[index])
        beginDrag(index, at: NSPoint(x: src.midX, y: src.midY))
        let colR = convert(cols[toCol].bounds, from: cols[toCol])
        let target = NSPoint(x: colR.midX, y: colR.minY + 80)
        dragTo(NSPoint(x: src.midX + 20, y: src.midY))   // первый сдвиг активирует перенос
        dragTo(target)
        pumpEvents()
        endDrag(at: target)
        return true
    }

    @discardableResult
    func dragCard(_ fromCol: Int, _ toCol: Int) -> Bool {
        guard let i = cards.firstIndex(where: { $0.col == fromCol }) else { return false }
        return dragCardIndex(i, toCol)
    }

    @discardableResult
    func dragCardById(_ id: Int, _ toCol: Int) -> Bool {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return false }
        return dragCardIndex(i, toCol)
    }
}
