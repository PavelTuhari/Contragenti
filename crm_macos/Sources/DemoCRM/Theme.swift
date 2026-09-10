// Палитра и фабрики элементов в стиле EspoCRM (аналог uEspoTheme.pas) плюс
// базовые вью для раскладки «как в VCL»: FlippedView считает координаты
// сверху вниз, dock() раскладывает детей alTop / alBottom / alClient.
import AppKit

let ESPO_BODY = NSColor(hex: 0xF1F3F5)      // фон страницы и навигации
let ESPO_BORDER = NSColor(hex: 0xE0E2E3)
let ESPO_PANEL_BRD = NSColor(hex: 0xE7EAED)
let ESPO_WHITE = NSColor.white
let ESPO_TEXT = NSColor(hex: 0x262626)
let ESPO_MUTED = NSColor(hex: 0x969696)
let ESPO_GRAY = NSColor(hex: 0x6A6A6A)
let ESPO_SOFT = NSColor(hex: 0x777777)
let ESPO_PRIMARY = NSColor(hex: 0x5589CA)
let ESPO_NAV_ACT = NSColor(hex: 0xDEE1E7)
let ESPO_NAV_HOV = NSColor(hex: 0xECECED)
let ESPO_BTN_BG = NSColor(hex: 0xFCFCFC)
let ESPO_BTN_BRD = NSColor(hex: 0xC2CACC)
let ESPO_BTN_TXT = NSColor(hex: 0x585858)
let ESPO_LINK = NSColor(hex: 0x245B8C)
let ESPO_HEAD_BG = NSColor(hex: 0xECF4F8)
let ESPO_ALT_ROW = NSColor(hex: 0xF8FAFA)

let ST_PRIMARY_FG = NSColor(hex: 0x3993CA), ST_PRIMARY_BG = NSColor(hex: 0xE5F3FF)
let ST_SUCCESS_FG = NSColor(hex: 0x2A9A4C), ST_SUCCESS_BG = NSColor(hex: 0xC4EFD1)
let ST_WARNING_FG = NSColor(hex: 0x9F7122), ST_WARNING_BG = NSColor(hex: 0xFAF4D6)
let ST_DANGER_FG = NSColor(hex: 0xAD4846), ST_DANGER_BG = NSColor(hex: 0xF2DEDE)

enum MsgKind: Int { case info = 0, ok, warn, err }
typealias SayProc = (MsgKind, String) -> Void

/// Размер шрифта Delphi (пункты Segoe UI) → пункты macOS.
func espoFont(_ size: Int, bold: Bool = false) -> NSFont {
    let pt = CGFloat(size) * 1.3
    return bold ? NSFont.boldSystemFont(ofSize: pt) : NSFont.systemFont(ofSize: pt)
}

/// Вью с началом координат сверху слева и фоновым цветом (аналог TPanel).
class FlippedView: NSView {
    var bgColor: NSColor? { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var tag_ = 0

    override var isFlipped: Bool { true }

    convenience init(bg: NSColor?) {
        self.init(frame: .zero)
        bgColor = bg
    }

    override func draw(_ dirtyRect: NSRect) {
        if let bg = bgColor {
            bg.setFill()
            if cornerRadius > 0 {
                NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            } else {
                bounds.fill()
            }
        }
        if let bc = borderColor {
            bc.setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            p.lineWidth = 1
            p.stroke()
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let d = onDoubleClick { d(); return }
        if let c = onClick { c() } else { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }

    /// Раскладка: top — сверху вниз, bottom — снизу вверх, client — остаток.
    func dock(top: [(NSView, CGFloat)] = [], bottom: [(NSView, CGFloat)] = [], client: NSView? = nil,
              padding: NSEdgeInsets = NSEdgeInsets()) {
        var y = padding.top
        let w = bounds.width - padding.left - padding.right
        for (v, h) in top where !v.isHidden {
            v.frame = NSRect(x: padding.left, y: y, width: w, height: h)
            y += h
        }
        var b = bounds.height - padding.bottom
        for (v, h) in bottom where !v.isHidden {
            b -= h
            v.frame = NSRect(x: padding.left, y: b, width: w, height: h)
        }
        if let c = client {
            c.frame = NSRect(x: padding.left, y: y, width: w, height: max(0, b - y))
        }
    }
}

/// Плоская кнопка Espo (аналог MakeButton): панель с подписью, без рамок системы.
final class EspoButton: FlippedView {
    let label = NSTextField(labelWithString: "")
    var action: (() -> Void)?
    var primary = false { didSet { restyle() } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    var caption: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(_ caption: String, primary: Bool, width: CGFloat = 120, action: (() -> Void)?) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 36))
        self.action = action
        self.primary = primary
        label.stringValue = caption
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.frame = NSRect(x: 4, y: 8, width: width - 8, height: 20)
        label.autoresizingMask = [.width]
        addSubview(label)
        cornerRadius = 3
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        if primary {
            bgColor = ESPO_PRIMARY
            borderColor = nil
            label.textColor = .white
            label.font = espoFont(10, bold: true)
        } else {
            bgColor = ESPO_BTN_BG
            borderColor = ESPO_BTN_BRD
            label.textColor = ESPO_BTN_TXT
            label.font = espoFont(10)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        label.frame = NSRect(x: 4, y: (newSize.height - 20) / 2, width: newSize.width - 8, height: 20)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        action?()
    }
}

/// Панель с внешней раскладкой (страница «Клиенты» в главном окне).
final class LayoutView: FlippedView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

/// Подпись (аналог MakeLabel): без автоширины, шрифт и цвет как у Espo.
@discardableResult
func makeLabel(_ parent: NSView, _ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 18,
               color: NSColor = ESPO_MUTED, size: Int = 9, bold: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.frame = NSRect(x: x, y: y, width: w, height: h)
    l.font = espoFont(size, bold: bold)
    l.textColor = color
    l.alignment = align
    l.lineBreakMode = .byTruncatingTail
    l.isSelectable = false
    l.cell?.truncatesLastVisibleLine = true
    parent.addSubview(l)
    return l
}

/// Многострочная подпись с переносом.
@discardableResult
func makeWrapLabel(_ parent: NSView, _ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                   color: NSColor = ESPO_TEXT, size: Int = 9) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.frame = NSRect(x: x, y: y, width: w, height: h)
    l.font = espoFont(size)
    l.textColor = color
    l.isSelectable = false
    l.cell?.wraps = true
    l.cell?.isScrollable = false
    parent.addSubview(l)
    return l
}

/// Белая панель с рамкой и заголовком (аналог MakePanelBox).
final class PanelBox: FlippedView {
    var titleLabel: NSTextField?
    init(title: String) {
        super.init(frame: .zero)
        bgColor = ESPO_WHITE
        borderColor = ESPO_PANEL_BRD
        if !title.isEmpty {
            titleLabel = makeLabel(self, title, x: 14, y: 8, w: 400, h: 22, color: ESPO_SOFT, size: 11, bold: true)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

func makeEdit(_ parent: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 26, placeholder: String = "",
              secure: Bool = false) -> NSTextField {
    let e: NSTextField = secure ? NSSecureTextField() : NSTextField()
    e.frame = NSRect(x: x, y: y, width: w, height: h)
    e.font = espoFont(10)
    e.placeholderString = placeholder
    e.isBezeled = true
    e.bezelStyle = .squareBezel
    e.focusRingType = .none
    parent.addSubview(e)
    return e
}

func makeCombo(_ parent: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 26, items: [String] = []) -> NSPopUpButton {
    let c = NSPopUpButton(frame: NSRect(x: x, y: y, width: w, height: h), pullsDown: false)
    c.font = espoFont(10)
    c.addItems(withTitles: items)
    c.focusRingType = .none
    parent.addSubview(c)
    return c
}

/// Таблица в белой рамке без системного стиля (как ListView vsReport).
func makeTable(columns: [(String, CGFloat)], headers: Bool = true) -> (NSScrollView, NSTableView) {
    let table = NSTableView()
    table.rowHeight = 22
    table.usesAlternatingRowBackgroundColors = false
    table.gridStyleMask = []
    table.style = .plain
    table.selectionHighlightStyle = .regular
    table.allowsEmptySelection = true
    table.allowsMultipleSelection = false
    table.intercellSpacing = NSSize(width: 6, height: 2)
    table.font = espoFont(10)
    if !headers { table.headerView = nil }
    for (i, (title, w)) in columns.enumerated() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
        col.title = title.uppercased()
        col.width = w
        col.minWidth = 30
        table.addTableColumn(col)
    }
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = ESPO_WHITE
    return (scroll, table)
}

/// Ячейка таблицы — обычный текст без рамок.
func tableCell(_ table: NSTableView, _ text: String, muted: Bool = false, right: Bool = false) -> NSView {
    let id = NSUserInterfaceItemIdentifier("cell")
    let view = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
        let v = NSTableCellView()
        v.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(tf)
        v.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()
    view.textField?.stringValue = text
    view.textField?.font = espoFont(10)
    view.textField?.textColor = muted ? ESPO_MUTED : ESPO_TEXT
    view.textField?.alignment = right ? .right : .left
    return view
}

/// Прокручиваемый контейнер с плоским документом (аналог TScrollBox).
func makeScrollBox(bg: NSColor, horizontal: Bool = false) -> (NSScrollView, FlippedView) {
    let doc = FlippedView(bg: bg)
    let scroll = NSScrollView()
    scroll.documentView = doc
    scroll.hasVerticalScroller = !horizontal
    scroll.hasHorizontalScroller = horizontal
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = bg
    scroll.verticalScrollElasticity = .none
    scroll.horizontalScrollElasticity = .none
    return (scroll, doc)
}

/// Короткая прокачка очереди событий (Application.ProcessMessages).
func pumpEvents(_ seconds: Double = 0.01) {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
}

/// Ожидание с прокачкой (Sleep + ProcessMessages).
func pumpSleep(_ seconds: Double) {
    let until = Date(timeIntervalSinceNow: seconds)
    while Date() < until {
        RunLoop.main.run(mode: .default, before: until)
        let rest = until.timeIntervalSinceNow
        if rest > 0 { Thread.sleep(forTimeInterval: min(rest, 0.005)) }
    }
}

/// Поле даты с календарём (просьба из акта: «календарь для выбора даты»).
/// Текстовое поле «ГГГГ-ММ-ДД» + кнопка, раскрывающая календарь **внутри**
/// страницы: модальных окон в программе нет, самотест жмёт те же методы.
final class DateEdit: FlippedView {
    let edit = NSTextField()
    let btn = EspoButton("▾", primary: false, width: 26, action: nil)
    /// Страница даёт панель календаря: она одна на редактор и позиционируется
    /// под тем полем, у которого нажали кнопку.
    var onPick: ((DateEdit) -> Void)?

    var stringValue: String {
        get { edit.stringValue }
        set { edit.stringValue = newValue }
    }

    init(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 26) {
        super.init(frame: NSRect(x: x, y: y, width: w, height: h))
        edit.frame = NSRect(x: 0, y: 0, width: w - 28, height: h)
        edit.font = espoFont(10)
        edit.placeholderString = "ГГГГ-ММ-ДД"
        edit.isBezeled = true
        edit.bezelStyle = .squareBezel
        edit.focusRingType = .none
        addSubview(edit)
        btn.frame = NSRect(x: w - 26, y: 0, width: 26, height: h)
        btn.action = { [weak self] in guard let s = self else { return }; s.onPick?(s) }
        addSubview(btn)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Календарь для DateEdit: панель с NSDatePicker, живёт в редакторе страницы.
final class CalendarPopup: FlippedView {
    let picker = NSDatePicker()
    private var target: DateEdit?
    var onChosen: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 152, height: 162))
        bgColor = ESPO_WHITE
        borderColor = ESPO_PANEL_BRD
        isHidden = true
        picker.frame = NSRect(x: 6, y: 6, width: 139, height: 148)
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.target = self
        picker.action = #selector(onPickerChange)
        addSubview(picker)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Показывает календарь под полем; в нём — дата поля или сегодня.
    func open(for de: DateEdit, in parent: NSView) {
        target = de
        picker.dateValue = parseISODate(de.stringValue) ?? Date()
        let p = de.convert(NSPoint(x: 0, y: de.bounds.height + 2), to: parent)
        var x = p.x
        if x + frame.width > parent.bounds.width - 6 { x = max(6, parent.bounds.width - frame.width - 6) }
        frame.origin = NSPoint(x: x, y: p.y)
        isHidden = false
        parent.addSubview(self, positioned: .above, relativeTo: nil)
    }

    func close() { isHidden = true; target = nil }

    @objc private func onPickerChange() {
        target?.stringValue = dateStr(picker.dateValue)
        close()
        onChosen?()
    }

    /// Хук самотеста: то же, что клик по числу в календаре.
    func testPick(_ date: Date) {
        picker.dateValue = date
        onPickerChange()
    }
}

/// Редактируемый список (стрелка выбора + свободный ввод) — исполнитель,
/// менеджер: имя берётся из списка сотрудников, но можно вписать своё.
func makeComboBox(_ parent: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 26, items: [String] = []) -> NSComboBox {
    let c = NSComboBox(frame: NSRect(x: x, y: y, width: w, height: h))
    c.font = espoFont(10)
    c.isEditable = true
    c.completes = true
    c.hasVerticalScroller = true
    c.numberOfVisibleItems = 12
    c.focusRingType = .none
    c.addItems(withObjectValues: items)
    parent.addSubview(c)
    return c
}
