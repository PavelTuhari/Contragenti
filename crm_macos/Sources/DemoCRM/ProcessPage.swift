// Схема бизнес-процесса (аналог uProcess.pas): дорожки, узлы start/step/gate/
// end и стрелки из processes.json. Узел с board/col привязан к колонке канбана
// и показывает её карточки; карточку можно перетащить на другой узел того же
// процесса — этап меняется через moveBoardCard. Описание этапа редактируется
// и сохраняется обратно в processes.json.
import AppKit

enum NodeKind { case start, step, gate, end }

struct ProcNode {
    var id = ""
    var kind = NodeKind.step
    var hasBoard = false
    var board = BoardKind.orders
    var col = 0
    var x = 0, y = 0            // слот и дорожка
    var title = "", owner = "", desc = ""
    var slaDays = -1
    var jsonIndex = 0           // индекс узла в массиве nodes — для сохранения
    var rect = NSRect.zero      // прямоугольник на схеме (после layout)
    var cards: [BoardCard] = []
    var count = 0, overdue = 0
    var sum = 0.0
}

struct ProcEdge { var from = 0, to = 0; var label = "" }

private let MARGIN: CGFloat = 20, LANE_H: CGFloat = 140, NODE_H: CGFloat = 92, LANE_TITLE_H: CGFloat = 22
private let CARD_W_MIN: CGFloat = 250

/// Текст по языку: значение — либо строка, либо объект с ключами ro/en/ru.
private func lText(_ o: JValue, _ name: String) -> String {
    guard let v = o[name] else { return "" }
    if case .object(let pairs) = v {
        if let s = v[T.lang]?.stringValue { return s }
        if let s = v["ru"]?.stringValue { return s }
        return pairs.first?.1.stringValue ?? ""
    }
    return v.stringValue ?? ""
}

private func lInt(_ o: JValue, _ name: String, _ def: Int) -> Int { o[name]?.intValue ?? def }

/// Холст схемы: рисует и принимает щелчки.
final class ProcessCanvas: FlippedView {
    weak var page: ProcessPage?
    override func draw(_ dirtyRect: NSRect) { page?.paint(self) }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { page?.canvasDoubleClick(p) } else { page?.canvasMouseDown(p) }
    }
}

final class ProcessPage: FlippedView, CardMouseDelegate {
    private let data: CrmData
    private let say: SayProc
    private var root: JValue?
    private(set) var fileName = ""
    private var procIdx = -1
    private var nodes: [ProcNode] = []
    private var edges: [ProcEdge] = []
    private var lanes: [String] = []
    private var selected = -1
    private var hoverNode = -1
    private var pulseNodeIdx = -1
    private let combo: NSPopUpButton
    private let canvas = ProcessCanvas()
    private let bottom = FlippedView(bg: ESPO_BODY)
    private let header = FlippedView(bg: ESPO_BODY)
    private var descTitle: NSTextField!, ownerLbl: NSTextField!, slaLbl: NSTextField!, cardsTitle: NSTextField!
    private var descView: NSTextView!
    private var descScroll: NSScrollView!
    private var saveBtn: EspoButton!, refreshBtn: EspoButton!
    private let leftBox = PanelBox(title: "")
    private let rightBox = PanelBox(title: "")
    private var cardsScroll: NSScrollView!
    private var cardsDoc: FlippedView!
    private var cards: [BoardCard] = []
    private var cardViews: [BoardCardView] = []
    var onOpenColumn: ((BoardKind, Int) -> Void)?
    var onOpenRecord: ((BoardKind, Int) -> Void)?
    // перетаскивание карточки на узел
    private var dragIdx = -1
    private var dragActive = false
    private var dragOrigin = NSPoint.zero, dragOffset = NSPoint.zero
    private var ghost: BoardCardView?
    private(set) var animFrames = 0
    var animEnabled = true
    private(set) var loadError = ""

    init(data: CrmData, say: @escaping SayProc) {
        self.data = data
        self.say = say
        combo = NSPopUpButton(frame: NSRect(x: 225, y: 14, width: 320, height: 28), pullsDown: false)
        super.init(frame: .zero)
        bgColor = ESPO_BODY
        isHidden = true
        build()
        _ = loadFile()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        addSubview(header)
        makeLabel(header, T.S("process.title"), x: 15, y: 10, w: 200, h: 30, color: ESPO_TEXT, size: 16)
        combo.font = espoFont(10)
        combo.target = self
        combo.action = #selector(onComboChange)
        header.addSubview(combo)
        refreshBtn = EspoButton(T.S("btn.refresh"), primary: false, width: 110) { [weak self] in
            self?.refresh(); self?.say(.info, T.S("kanban.refreshed"))
        }
        header.addSubview(refreshBtn)
        makeLabel(header, T.S("process.hint"), x: 15, y: 50, w: 900, color: ESPO_MUTED, size: 9)

        addSubview(bottom)
        bottom.addSubview(rightBox)
        cardsTitle = makeLabel(rightBox, T.S("process.cards"), x: 14, y: 8, w: 300, h: 22, color: ESPO_SOFT, size: 11, bold: true)
        (cardsScroll, cardsDoc) = makeScrollBox(bg: ESPO_WHITE)
        rightBox.addSubview(cardsScroll)
        bottom.addSubview(leftBox)
        descTitle = makeLabel(leftBox, T.S("process.desc"), x: 14, y: 8, w: 500, h: 22, color: ESPO_SOFT, size: 11, bold: true)
        ownerLbl = makeLabel(leftBox, "", x: 14, y: 32, w: 400, color: ESPO_MUTED, size: 9)
        slaLbl = makeLabel(leftBox, "", x: 14, y: 50, w: 400, color: ESPO_MUTED, size: 9)
        descScroll = NSScrollView()
        descView = NSTextView()
        descView.font = espoFont(10)
        descView.isRichText = false
        descView.backgroundColor = ESPO_HEAD_BG
        descView.autoresizingMask = [.width]
        descScroll.documentView = descView
        descScroll.hasVerticalScroller = true
        descScroll.borderType = .noBorder
        leftBox.addSubview(descScroll)
        saveBtn = EspoButton(T.S("process.save"), primary: true, width: 190) { [weak self] in self?.saveDescription() }
        leftBox.addSubview(saveBtn)

        canvas.page = self
        canvas.bgColor = ESPO_BODY
        addSubview(canvas)
    }

    override func layout() {
        super.layout()
        dock(top: [(header, 72)], bottom: [(bottom, 250)], client: canvas)
        refreshBtn.frame = NSRect(x: header.bounds.width - 125, y: 10, width: 110, height: 36)
        rightBox.frame = NSRect(x: bottom.bounds.width - 330, y: 0, width: 330, height: bottom.bounds.height)
        cardsScroll.frame = NSRect(x: 8, y: 34, width: rightBox.bounds.width - 16, height: rightBox.bounds.height - 42)
        leftBox.frame = NSRect(x: 0, y: 0, width: bottom.bounds.width - 330 - 8, height: bottom.bounds.height)
        descScroll.frame = NSRect(x: 14, y: 72, width: leftBox.bounds.width - 28, height: leftBox.bounds.height - 72 - 50)
        descView.frame.size.width = descScroll.contentSize.width
        saveBtn.frame = NSRect(x: 14, y: leftBox.bounds.height - 44, width: 190, height: 36)
        layoutNodes()
        canvas.needsDisplay = true
    }

    @discardableResult
    func loadFile(_ path: String? = nil) -> Bool {
        loadError = ""
        let p = path ?? Paths.resource("processes.json") ?? (Paths.appDir + "/processes.json")
        fileName = p
        root = nil
        combo.removeAllItems()
        guard FileManager.default.fileExists(atPath: p), let text = try? String(contentsOfFile: p, encoding: .utf8) else {
            loadError = T.F("process.missing", [p])
            canvas.needsDisplay = true
            return false
        }
        do {
            let r = try JParser.parse(text)
            guard case .array(let procs)? = r["processes"] else {
                loadError = "processes.json: no \"processes\""
                return false
            }
            root = r
            for pr in procs { combo.addItem(withTitle: lText(pr, "title")) }
            if !procs.isEmpty {
                combo.selectItem(at: 0)
                loadProcess(0)
            }
            return true
        } catch {
            loadError = "processes.json: \(error)"
            canvas.needsDisplay = true
            return false
        }
    }

    private var procs: [JValue] { root?["processes"]?.arrayValue ?? [] }

    private func loadProcess(_ index: Int) {
        nodes = []; edges = []; lanes = []
        selected = -1; hoverNode = -1
        procIdx = index
        guard index >= 0, index < procs.count else { return }
        let p = procs[index]
        for lane in p["lanes"]?.arrayValue ?? [] { lanes.append(lText(lane, "title")) }
        for (i, n) in (p["nodes"]?.arrayValue ?? []).enumerated() {
            var node = ProcNode()
            node.jsonIndex = i
            node.id = lText(n, "id")
            switch lText(n, "kind") {
            case "start": node.kind = .start
            case "gate": node.kind = .gate
            case "end": node.kind = .end
            default: node.kind = .step
            }
            let board = lText(n, "board")
            node.hasBoard = !board.isEmpty
            switch board {
            case "deals": node.board = .deals
            case "tasks": node.board = .tasks
            case "projects": node.board = .projects
            case "project_tasks": node.board = .projectTasks
            default: node.board = .orders
            }
            node.col = lInt(n, "col", 0)
            node.x = lInt(n, "x", i)
            node.y = lInt(n, "y", 0)
            node.title = lText(n, "title")
            node.owner = lText(n, "owner")
            node.desc = lText(n, "desc")
            node.slaDays = lInt(n, "sla_days", -1)
            nodes.append(node)
        }
        for e in p["edges"]?.arrayValue ?? [] {
            let f = nodeIndex(lText(e, "from")), t = nodeIndex(lText(e, "to"))
            if f >= 0 && t >= 0 { edges.append(ProcEdge(from: f, to: t, label: lText(e, "label"))) }
        }
        loadNodeData()
        layoutNodes()
        showCards()
        canvas.needsDisplay = true
    }

    /// Карточки каждого узла — те же, что в колонке канбана.
    private func loadNodeData() {
        for i in 0..<nodes.count {
            nodes[i].cards = []; nodes[i].count = 0; nodes[i].overdue = 0; nodes[i].sum = 0
            if nodes[i].hasBoard {
                let c = loadBoardCards(data, nodes[i].board, nodes[i].col)
                nodes[i].cards = c
                nodes[i].count = c.count
                nodes[i].overdue = boardColumnOverdue(c)
                nodes[i].sum = boardColumnSum(c)
            }
        }
    }

    private func layoutNodes() {
        var maxX = 0, maxY = 0
        for n in nodes { maxX = max(maxX, n.x); maxY = max(maxY, n.y) }
        let slotW = max(96, (canvas.bounds.width - 2 * MARGIN) / CGFloat(maxX + 1))
        let nodeW = slotW - 18
        let gateW = min(nodeW, 104)
        for i in 0..<nodes.count {
            let n = nodes[i]
            let x = MARGIN + CGFloat(n.x) * slotW
            let y = MARGIN + LANE_TITLE_H + CGFloat(n.y) * LANE_H
            if n.kind == .gate {
                nodes[i].rect = NSRect(x: x + (slotW - gateW) / 2, y: y + (NODE_H - gateW) / 2 + 4, width: gateW, height: gateW)
            } else {
                nodes[i].rect = NSRect(x: x, y: y, width: nodeW, height: NODE_H)
            }
        }
    }

    private func nodeIndex(_ id: String) -> Int { nodes.firstIndex { $0.id == id } ?? -1 }
    private func nodeAt(_ p: NSPoint) -> Int { nodes.firstIndex { $0.rect.contains(p) } ?? -1 }

    // ── рисование ──

    private func drawArrow(_ pts: [NSPoint], _ text: String) {
        guard pts.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = 2
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        ESPO_GRAY.setStroke()
        path.stroke()
        let a = pts[pts.count - 2], b = pts[pts.count - 1]
        let dx: CGFloat = b.x > a.x ? 1 : (b.x < a.x ? -1 : 0)
        let dy: CGFloat = b.y > a.y ? 1 : (b.y < a.y ? -1 : 0)
        let tri = NSBezierPath()
        tri.move(to: b)
        if dx != 0 {
            tri.line(to: NSPoint(x: b.x - dx * 9, y: b.y - 5)); tri.line(to: NSPoint(x: b.x - dx * 9, y: b.y + 5))
        } else {
            tri.line(to: NSPoint(x: b.x - 5, y: b.y - dy * 9)); tri.line(to: NSPoint(x: b.x + 5, y: b.y - dy * 9))
        }
        tri.close()
        ESPO_GRAY.setFill()
        tri.fill()
        if !text.isEmpty {
            // подпись у середины самого длинного отрезка
            var best: CGFloat = -1
            var mid = NSPoint.zero
            for i in 1..<pts.count {
                let len = abs(pts[i].x - pts[i - 1].x) + abs(pts[i].y - pts[i - 1].y)
                if len > best { best = len; mid = NSPoint(x: (pts[i].x + pts[i - 1].x) / 2, y: (pts[i].y + pts[i - 1].y) / 2) }
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: espoFont(7), .foregroundColor: ESPO_GRAY, .backgroundColor: ESPO_BODY]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: mid.x - sz.width / 2, y: mid.y - sz.height - 2))
        }
    }

    private func textIn(_ s: String, _ r: NSRect, size: Int, bold: Bool, color: NSColor, center: Bool = false, wrap: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        para.alignment = center ? .center : .left
        let attrs: [NSAttributedString.Key: Any] = [.font: espoFont(size, bold: bold), .foregroundColor: color, .paragraphStyle: para]
        NSAttributedString(string: s, attributes: attrs).draw(in: r)
    }

    func paint(_ view: NSView) {
        ESPO_BODY.setFill()
        view.bounds.fill()
        if !loadError.isEmpty {
            textIn(loadError, NSRect(x: MARGIN, y: MARGIN, width: view.bounds.width - 2 * MARGIN, height: 40), size: 10, bold: false, color: ST_DANGER_FG)
            return
        }
        // дорожки
        for (i, lane) in lanes.enumerated() {
            let y = MARGIN + CGFloat(i) * LANE_H
            let r = NSRect(x: MARGIN - 8, y: y - 6, width: view.bounds.width - 2 * MARGIN + 16, height: LANE_H)
            (i % 2 == 1 ? ESPO_BODY : ESPO_WHITE).setFill(); r.fill()
            ESPO_BORDER.setStroke(); NSBezierPath(rect: r).stroke()
            textIn(lane, NSRect(x: MARGIN, y: y, width: 500, height: 18), size: 8, bold: true, color: ESPO_MUTED)
        }
        // связи
        for e in edges {
            let a = nodes[e.from].rect, b = nodes[e.to].rect
            var pts: [NSPoint]
            if nodes[e.from].y == nodes[e.to].y {
                if b.minX > a.maxX {
                    pts = [NSPoint(x: a.maxX, y: a.midY), NSPoint(x: b.minX, y: b.midY)]
                } else {
                    // возврат назад — дугой под узлами
                    let midY = max(a.maxY, b.maxY) + 14
                    pts = [NSPoint(x: a.midX, y: a.maxY), NSPoint(x: a.midX, y: midY), NSPoint(x: b.midX, y: midY), NSPoint(x: b.midX, y: b.maxY)]
                }
            } else {
                let down = nodes[e.to].y > nodes[e.from].y
                let midY = MARGIN + CGFloat(nodes[e.from].y + 1) * LANE_H - 12 + (down ? 0 : -LANE_H + 8)
                if down {
                    pts = [NSPoint(x: a.midX, y: a.maxY), NSPoint(x: a.midX, y: midY), NSPoint(x: b.midX, y: midY), NSPoint(x: b.midX, y: b.minY)]
                } else {
                    pts = [NSPoint(x: a.midX, y: a.minY), NSPoint(x: a.midX, y: midY), NSPoint(x: b.midX, y: midY), NSPoint(x: b.midX, y: b.maxY)]
                }
            }
            drawArrow(pts, e.label)
        }
        // узлы
        for (i, n) in nodes.enumerated() {
            let rc = n.rect
            var accent = n.hasBoard ? boardColumnColor(n.board, n.col) : ESPO_GRAY
            if n.kind == .gate { accent = CLR_AMBER }
            var fill = ESPO_WHITE
            if i == pulseNodeIdx { fill = ST_SUCCESS_BG }
            else if i == selected { fill = ST_PRIMARY_BG }
            else if i == hoverNode { fill = ESPO_HEAD_BG }
            else if n.overdue > 0 { fill = NSColor(hex: 0xFAF0F0) }

            func shape(_ r: NSRect) -> NSBezierPath {
                switch n.kind {
                case .gate:
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: r.midX, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.midY))
                    p.line(to: NSPoint(x: r.midX, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.midY)); p.close()
                    return p
                case .start: return NSBezierPath(roundedRect: r, xRadius: NODE_H / 2, yRadius: NODE_H / 2)
                default: return NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
                }
            }
            // тень
            ESPO_BORDER.setFill()
            shape(rc.offsetBy(dx: 3, dy: 3)).fill()
            fill.setFill()
            let sp = shape(rc)
            sp.fill()
            (i == selected ? ESPO_PRIMARY : accent).setStroke()
            sp.lineWidth = i == selected ? 3 : 2
            sp.stroke()
            if n.kind == .gate {
                textIn(n.title, rc.insetBy(dx: 14, dy: 14).offsetBy(dx: 0, dy: 8), size: 7, bold: true, color: ESPO_TEXT, center: true, wrap: true)
                continue
            }
            if n.kind == .end {
                let inner = NSBezierPath(roundedRect: rc.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8)
                inner.lineWidth = 2
                inner.stroke()
            } else if n.kind == .step {
                accent.setFill()
                NSRect(x: rc.minX + 6, y: rc.minY + 1, width: rc.width - 12, height: 5).fill()
            }
            let th: CGFloat = n.kind == .start ? 16 : 10
            textIn(n.title, NSRect(x: rc.minX + th, y: rc.minY + 9, width: rc.width - 2 * th, height: 32), size: 9, bold: true, color: ESPO_TEXT, wrap: true)
            if n.hasBoard {
                let txt = n.sum > 0 ? "\(n.count)  ·  \(fmtInt0(n.sum)) MDL" : T.F("process.count", [n.count])
                textIn(txt, NSRect(x: rc.minX + th, y: rc.minY + 44, width: rc.width - 2 * th, height: 16), size: 9, bold: false, color: accent)
                if n.overdue > 0 {
                    textIn(T.F("kanban.col_late", [n.overdue]), NSRect(x: rc.minX + th, y: rc.minY + 61, width: rc.width - 2 * th, height: 14), size: 8, bold: true, color: ST_DANGER_FG)
                } else if n.count > 0 && n.kind != .end {
                    textIn(T.S("workspace.on_time"), NSRect(x: rc.minX + th, y: rc.minY + 61, width: rc.width - 2 * th, height: 14), size: 8, bold: false, color: ST_SUCCESS_FG)
                }
            }
            if !n.owner.isEmpty {
                textIn("☺ " + n.owner, NSRect(x: rc.minX + th, y: rc.maxY - 18, width: rc.width - 2 * th, height: 14), size: 7, bold: false, color: ESPO_MUTED)
            }
        }
    }

    func canvasMouseDown(_ p: NSPoint) { selectNode(nodeAt(p)) }

    func canvasDoubleClick(_ p: NSPoint) {
        let i = nodeAt(p)
        if i >= 0 && nodes[i].hasBoard { onOpenColumn?(nodes[i].board, nodes[i].col) }
    }

    private func selectNode(_ index: Int) {
        selected = index
        canvas.needsDisplay = true
        guard index >= 0, index < nodes.count else {
            descTitle.stringValue = T.S("process.desc")
            ownerLbl.stringValue = ""; slaLbl.stringValue = ""
            descView.string = ""
            showCards()
            return
        }
        let n = nodes[index]
        descTitle.stringValue = T.S("process.desc") + ": " + n.title
        ownerLbl.stringValue = n.owner.isEmpty ? "" : T.F("process.owner", [n.owner])
        slaLbl.stringValue = n.slaDays >= 0 ? T.F("process.sla", [n.slaDays]) : ""
        descView.string = n.desc
        showCards()
        if n.hasBoard { say(.info, T.F("process.node_info", [n.title, n.count, n.overdue])) } else { say(.info, n.title) }
    }

    private func showCards() {
        hideGhost()
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = []; cards = []
        guard selected >= 0, nodes[selected].hasBoard else {
            cardsTitle.stringValue = T.S("process.cards")
            cardsDoc.frame.size.height = cardsScroll.bounds.height
            return
        }
        cards = nodes[selected].cards
        cardsTitle.stringValue = "\(T.S("process.cards")): \(nodes[selected].title) (\(cards.count))"
        let w = max(CARD_W_MIN, cardsScroll.bounds.width - 26)
        var y: CGFloat = 4
        for (i, c) in cards.enumerated() {
            let v = BoardCardView(c, x: 4, y: y, w: w)
            v.index = i
            v.mouseDelegate = self
            cardsDoc.addSubview(v)
            cardViews.append(v)
            y += CARD_H + 6
        }
        cardsDoc.frame = NSRect(x: 0, y: 0, width: cardsScroll.contentSize.width, height: max(cardsScroll.bounds.height, y))
    }

    // ── перетаскивание карточки на узел ──

    private func pageRect(_ v: NSView?) -> NSRect {
        guard let v = v, v.superview != nil else { return .zero }
        return convert(v.bounds, from: v)
    }

    private func showGhost(_ p: NSPoint) {
        guard dragIdx >= 0, dragIdx < cards.count else { return }
        if ghost == nil {
            let g = makeGhostCard(cards[dragIdx], frame: NSRect(x: 0, y: 0, width: CARD_W_MIN, height: CARD_H))
            addSubview(g)
            ghost = g
            cardViews[dragIdx].bgColor = ESPO_BODY
        }
        ghost?.frame.origin = NSPoint(x: p.x - min(dragOffset.x, CARD_W_MIN - 10), y: p.y - dragOffset.y)
    }

    private func hideGhost() {
        ghost?.removeFromSuperview(); ghost = nil
        if dragIdx >= 0 && dragIdx < cardViews.count { cardViews[dragIdx].bgColor = cardBaseColor(cards[dragIdx]) }
    }

    func beginDrag(_ idx: Int, at p: NSPoint) {
        dragIdx = idx
        dragActive = false
        dragOrigin = p
        if idx >= 0 && idx < cardViews.count {
            let r = pageRect(cardViews[idx])
            dragOffset = NSPoint(x: max(0, min(p.x - r.minX, r.width)), y: max(0, min(p.y - r.minY, r.height)))
        }
    }

    func dragTo(_ p: NSPoint) {
        guard dragIdx >= 0 else { return }
        if !dragActive && abs(p.x - dragOrigin.x) + abs(p.y - dragOrigin.y) < 8 { return }
        dragActive = true
        showGhost(p)
        var n = nodeAt(canvas.convert(p, from: self))
        if n >= 0 && !(nodes[n].hasBoard && selected >= 0 && nodes[n].board == nodes[selected].board) { n = -1 }
        if n != hoverNode { hoverNode = n; canvas.needsDisplay = true }
    }

    func endDrag(at p: NSPoint) {
        if dragActive {
            let n = nodeAt(canvas.convert(p, from: self))
            let fromR = pageRect(ghost)
            hideGhost()
            hoverNode = -1
            if n >= 0, dragIdx >= 0, dragIdx < cards.count, selected >= 0, nodes[n].hasBoard,
               nodes[n].board == nodes[selected].board, nodes[n].col != cards[dragIdx].col {
                moveCardToNode(dragIdx, n, fromR)
            } else {
                canvas.needsDisplay = true
                say(.info, T.S("kanban.cancelled"))
            }
        }
        dragActive = false
        dragIdx = -1
    }

    func cardMouseDown(_ card: BoardCardView, _ event: NSEvent) { beginDrag(card.index, at: convert(event.locationInWindow, from: nil)) }
    func cardMouseDragged(_ card: BoardCardView, _ event: NSEvent) { dragTo(convert(event.locationInWindow, from: nil)) }
    func cardMouseUp(_ card: BoardCardView, _ event: NSEvent) { endDrag(at: convert(event.locationInWindow, from: nil)) }
    func cardDoubleClick(_ card: BoardCardView) {
        guard card.index >= 0, card.index < cards.count, selected >= 0 else { return }
        onOpenRecord?(nodes[selected].board, cards[card.index].id)
    }

    private func animateTo(_ fromR: NSRect, _ toR: NSRect, _ c: BoardCard) {
        guard animEnabled, !fromR.isEmpty, !toR.isEmpty else { return }
        let fly = makeGhostCard(c, frame: fromR)
        addSubview(fly)
        let frames = 14
        for i in 1...frames {
            var k = Double(i) / Double(frames)
            k = 1 - (1 - k) * (1 - k)
            // карточка летит к узлу и уменьшается до его размера
            let w = fromR.width + (toR.width - fromR.width) * k
            let h = fromR.height + (toR.height - fromR.height) * k
            fly.frame = NSRect(x: fromR.minX + (toR.minX - fromR.minX) * k, y: fromR.minY + (toR.minY - fromR.minY) * k, width: w, height: h)
            fly.displayIfNeeded()
            pumpSleep(0.012)
            animFrames += 1
        }
        fly.removeFromSuperview()
    }

    private func pulseNode(_ index: Int) {
        guard animEnabled else { return }
        for i in 1...3 {
            pulseNodeIdx = i % 2 == 1 ? index : -1
            canvas.display()
            pumpSleep(0.05)
            animFrames += 1
        }
        pulseNodeIdx = -1
        canvas.needsDisplay = true
    }

    /// Смена этапа через ту же точку, что и канбан.
    private func moveCardToNode(_ cardIdx: Int, _ nodeIdx: Int, _ fromR: NSRect) {
        let c = cards[cardIdx]
        guard moveBoardCard(data, nodes[nodeIdx].board, c.id, nodes[nodeIdx].col) else { return }
        let toR = convert(nodes[nodeIdx].rect, from: canvas)
        animateTo(fromR, toR, c)
        let keep = selected
        loadNodeData()
        selected = keep
        showCards()
        pulseNode(nodeIdx)
        say(.ok, T.F("kanban.moved", [c.title, nodes[nodeIdx].title]))
    }

    @objc private func onComboChange() {
        loadProcess(combo.indexOfSelectedItem)
        selectNode(-1)
    }

    func refresh() {
        if root == nil { _ = loadFile(); return }
        let keep = selected
        loadNodeData()
        layoutNodes()
        selected = keep
        showCards()
        canvas.needsDisplay = true
    }

    // ── хуки самотеста ──

    @discardableResult
    func loadFrom(_ path: String) -> Bool {
        let r = loadFile(path.isEmpty ? nil : path)
        selectNode(-1)
        canvas.needsDisplay = true
        return r
    }

    var processCount: Int { combo.numberOfItems }
    func selectProcess(_ index: Int) {
        guard index >= 0, index < combo.numberOfItems else { return }
        combo.selectItem(at: index)
        onComboChange()
    }
    var nodeCount: Int { nodes.count }
    var edgeCount: Int { edges.count }
    func nodeTitle(_ id: String) -> String { let i = nodeIndex(id); return i >= 0 ? nodes[i].title : "" }
    func nodeCards(_ id: String) -> Int { let i = nodeIndex(id); return i >= 0 ? nodes[i].count : -1 }
    func nodeOverdue(_ id: String) -> Int { let i = nodeIndex(id); return i >= 0 ? nodes[i].overdue : -1 }

    @discardableResult
    func clickNode(_ id: String) -> Bool {
        let i = nodeIndex(id)
        guard i >= 0 else { return false }
        canvasMouseDown(NSPoint(x: nodes[i].rect.midX, y: nodes[i].rect.midY))
        return true
    }

    var selectedNodeId: String { (selected >= 0 && selected < nodes.count) ? nodes[selected].id : "" }
    var cardsShown: Int { cardViews.count }

    @discardableResult
    func dragCardToNode(_ cardId: Int, _ nodeId: String) -> Bool {
        let n = nodeIndex(nodeId)
        guard n >= 0, let i = cards.firstIndex(where: { $0.id == cardId }) else { return false }
        let src = pageRect(cardViews[i])
        beginDrag(i, at: NSPoint(x: src.midX, y: src.midY))
        let target = convert(NSPoint(x: nodes[n].rect.midX, y: nodes[n].rect.midY), from: canvas)
        dragTo(NSPoint(x: src.midX + 20, y: src.midY))
        dragTo(target)
        pumpEvents()
        endDrag(at: target)
        return true
    }

    var description_: String { descView.string }
    func setDescription(_ text: String) { descView.string = text }

    func saveDescription() {
        guard selected >= 0, selected < nodes.count, var r = root, procIdx >= 0 else {
            say(.warn, T.S("process.select_node")); return
        }
        let text = descView.string.trimmed
        // processes[procIdx].nodes[jsonIndex].desc[lang] = text
        var procsArr = r["processes"] ?? .array([])
        var proc = procsArr.arrayValue[procIdx]
        var nodesArr = proc["nodes"] ?? .array([])
        var node = nodesArr.arrayValue[nodes[selected].jsonIndex]
        var desc = node["desc"] ?? .object([])
        if case .object = desc {} else { desc = .object([]) }
        desc.set(T.lang, .string(text))
        node.set("desc", desc)
        nodesArr.setAt(nodes[selected].jsonIndex, node)
        proc.set("nodes", nodesArr)
        procsArr.setAt(procIdx, proc)
        r.set("processes", procsArr)
        root = r
        nodes[selected].desc = text
        do {
            try (JWriter.pretty(r) + "\n").write(toFile: fileName, atomically: true, encoding: .utf8)
            say(.ok, T.F("process.saved", [nodes[selected].title, (fileName as NSString).lastPathComponent]))
        } catch {
            say(.err, error.localizedDescription)
        }
    }
}
