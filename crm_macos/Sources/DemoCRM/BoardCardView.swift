// Информативная карточка канбана / схемы процесса (аналог MakeBoardCard):
// цветная полоса и значок по виду, клиент, вид, сумма, прогресс оплаты,
// бейдж срока. Мышь обрабатывает сама карточка и передаёт владельцу
// (канбан, схема) через делегат — так же, как HookMouse в Delphi.
import AppKit

protocol CardMouseDelegate: AnyObject {
    func cardMouseDown(_ card: BoardCardView, _ event: NSEvent)
    func cardMouseDragged(_ card: BoardCardView, _ event: NSEvent)
    func cardMouseUp(_ card: BoardCardView, _ event: NSEvent)
    func cardDoubleClick(_ card: BoardCardView)
}

final class BoardCardView: FlippedView {
    let card: BoardCard
    var index = 0
    weak var mouseDelegate: CardMouseDelegate?
    private var pressed = false

    init(_ c: BoardCard, x: CGFloat, y: CGFloat, w: CGFloat) {
        card = c
        super.init(frame: NSRect(x: x, y: y, width: w, height: CARD_H))
        bgColor = cardBaseColor(c)
        borderColor = ESPO_PANEL_BRD
        cornerRadius = 3
        build(w)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(_ w: CGFloat) {
        let c = card
        // цветная полоса слева — вид записи (или просрочка / выполнено)
        let stripe = FlippedView(bg: c.stripe)
        stripe.frame = NSRect(x: 0, y: 0, width: 5, height: CARD_H)
        addSubview(stripe)

        makeLabel(self, c.icon, x: 11, y: 5, w: 18, h: 20, color: c.stripe, size: 11, bold: true)
        makeLabel(self, c.title, x: 30, y: 6, w: w - 36 - 52, h: 18, color: ESPO_TEXT, size: 9, bold: true)

        // бейдж срока: «−3 д» красный, «сегодня» янтарный, «5 д» серый, «✔» зелёный
        let badgeText = daysBadgeText(c)
        if !badgeText.isEmpty {
            let badge = FlippedView(bg: ESPO_BORDER)
            badge.cornerRadius = 3
            badge.frame = NSRect(x: w - 56, y: 6, width: 48, height: 18)
            var fg = ESPO_GRAY
            if c.done { badge.bgColor = ST_SUCCESS_FG; fg = .white }
            else if c.daysLeft < 0 { badge.bgColor = ST_DANGER_FG; fg = .white }
            else if c.daysLeft == 0 { badge.bgColor = CLR_AMBER; fg = .white }
            makeLabel(badge, badgeText, x: 0, y: 1, w: 48, h: 16, color: fg, size: 8, bold: true, align: .center)
            addSubview(badge)
        }

        makeLabel(self, "☺ " + c.subtitle, x: 11, y: 26, w: w - 18, h: 16, color: ESPO_MUTED, size: 8)
        makeLabel(self, c.kindText, x: 11, y: 43, w: w - 18 - 70, h: 16, color: c.stripe, size: 8, bold: true)
        makeLabel(self, c.amount, x: 11, y: 59, w: w - 18, h: 18, color: ESPO_TEXT, size: 9, bold: true)

        // прогресс оплаты (только записи с суммой)
        if c.total > 0 && c.paid >= 0 && c.icon != "◆" {
            let pct = min(100, Int(bankRound(c.paid / c.total * 100)))
            let barBg = FlippedView(bg: ESPO_BORDER)
            barBg.frame = NSRect(x: 11, y: 78, width: w - 22, height: 6)
            addSubview(barBg)
            let fill = FlippedView(bg: pct >= 100 ? ST_SUCCESS_FG : CLR_BLUE)
            fill.frame = NSRect(x: 0, y: 0, width: max(0, (w - 22) * CGFloat(pct) / 100), height: 6)
            barBg.addSubview(fill)
            makeLabel(self, T.F("kanban.paid_pct", [pct]), x: w - 80, y: 43, w: 70, h: 16, color: ESPO_MUTED, size: 8, align: .right)
        } else if !c.due.isEmpty {
            makeLabel(self, (c.overdue ? T.S("kanban.overdue") : T.S("kanban.due")) + " " + c.due,
                      x: 11, y: 76, w: w - 18, h: 16, color: c.overdue ? ST_DANGER_FG : ESPO_MUTED, size: 8)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // все подписи внутри «прозрачны» для мыши: событие получает карточка
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { mouseDelegate?.cardDoubleClick(self); return }
        pressed = true
        mouseDelegate?.cardMouseDown(self, event)
    }

    override func mouseDragged(with event: NSEvent) {
        if pressed { mouseDelegate?.cardMouseDragged(self, event) }
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        mouseDelegate?.cardMouseUp(self, event)
    }
}

func cardBaseColor(_ c: BoardCard) -> NSColor {
    if c.done { return ST_SUCCESS_BG }
    if c.overdue { return ST_DANGER_BG }
    return ESPO_WHITE
}

/// Ghost-копия карточки (без обработки мыши) для анимаций.
func makeGhostCard(_ c: BoardCard, frame: NSRect) -> BoardCardView {
    let g = BoardCardView(c, x: frame.minX, y: frame.minY, w: frame.width)
    g.bgColor = ST_PRIMARY_BG
    g.borderColor = ESPO_PRIMARY
    g.mouseDelegate = nil
    return g
}
