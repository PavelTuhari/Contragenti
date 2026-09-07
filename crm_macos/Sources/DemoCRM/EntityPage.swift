// Универсальная страница раздела CRM (аналог uEntityPage.pas): заголовок с
// кнопками, строка фильтра, таблица записей и встроенный редактор (панель
// внутри страницы, без модальных окон). Строится из EntityDef.
// Для заказов дополнительно — строки заказа с итогом и кнопка «Провести».
import AppKit

final class EntityPage: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    let data: CrmData
    let def: EntityDef
    private(set) var rows: [EntityRow] = []
    private let say: SayProc
    var onChanged: (() -> Void)?

    private let header = FlippedView(bg: ESPO_BODY)
    private let titleLabel: NSTextField
    private let btnNew: EspoButton
    private let btnDelete: EspoButton
    private let btnRefresh: EspoButton
    private var extraBtns: [EspoButton] = []
    private let searchRow = FlippedView(bg: ESPO_BODY)
    private let preset: NSPopUpButton
    private var presetWheres: [String] = [""]
    private let search: NSTextField
    private let pager: NSTextField
    private let listScroll: NSScrollView
    private let list: NSTableView
    private var listCols: [Int] = []   // индексы полей, показанных в списке

    private let editor = PanelBox(title: "")
    private let editTitle: NSTextField
    private var ctrls: [NSView] = []
    private var lookupIds: [[Int]] = []
    private var editingId = -1
    private var pendingDeleteId = 0
    private var editorHeight: CGFloat = 200

    // строки заказа
    private var linesBox: PanelBox?
    private var linesTable: NSTableView?
    private var linesScroll: NSScrollView?
    private var lines: [OrderLine] = []
    private var lineItem: NSPopUpButton?
    private var lineItemIds: [Int] = []
    private var lineQty: NSTextField?
    private var linePrice: NSTextField?
    private var linesTotalLabel: NSTextField?
    private var pendingLineDelete = 0
    private var suppressSelect = false

    init(data: CrmData, def: EntityDef, say: @escaping SayProc) {
        self.data = data
        self.def = def
        self.say = say
        titleLabel = NSTextField(labelWithString: def.title)
        btnNew = EspoButton("Создать " + def.titleOne, primary: true, width: 170, action: nil)
        btnRefresh = EspoButton("Обновить", primary: false, width: 100, action: nil)
        btnDelete = EspoButton("Удалить", primary: false, width: 100, action: nil)
        preset = NSPopUpButton(frame: NSRect(x: 0, y: 8, width: 190, height: 28), pullsDown: false)
        search = NSTextField(frame: NSRect(x: 198, y: 8, width: 320, height: 28))
        pager = NSTextField(labelWithString: "")
        editTitle = NSTextField(labelWithString: "")
        let cols = def.fields.enumerated().filter { $0.element.listWidth > 0 }
        listCols = cols.map { $0.offset }
        (listScroll, list) = makeTable(columns: cols.map { ($0.element.caption, CGFloat($0.element.listWidth)) })
        super.init(frame: .zero)
        bgColor = ESPO_BODY
        isHidden = true
        buildHeader()
        buildSearchRow()
        buildEditor()
        if def.table == "orders" { buildLines() }
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(onListDblClick)
        addSubview(listScroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildHeader() {
        addSubview(header)
        titleLabel.frame = NSRect(x: 0, y: 6, width: 400, height: 30)
        titleLabel.font = espoFont(16)
        titleLabel.textColor = ESPO_TEXT
        header.addSubview(titleLabel)
        btnNew.action = { [weak self] in self?.newRecord() }
        btnRefresh.action = { [weak self] in self?.onRefreshClick() }
        btnDelete.action = { [weak self] in self?.deleteSelected() }
        for b in [btnNew, btnRefresh, btnDelete] { header.addSubview(b) }
    }

    private func layoutHeader() {
        var x = header.bounds.width
        for b in [btnNew, btnRefresh, btnDelete] + extraBtns {
            x -= b.frame.width
            b.frame = NSRect(x: x, y: 4, width: b.frame.width, height: 36)
            x -= 8
        }
    }

    @discardableResult
    func addExtraButton(_ caption: String, primary: Bool = false, width: CGFloat = 130, action: @escaping () -> Void) -> EspoButton {
        let b = EspoButton(caption, primary: primary, width: width, action: action)
        header.addSubview(b)
        extraBtns.append(b)
        layoutHeader()
        return b
    }

    private func buildSearchRow() {
        addSubview(searchRow)
        preset.font = espoFont(10)
        preset.addItem(withTitle: "Все")
        preset.target = self
        preset.action = #selector(onSearchChange)
        searchRow.addSubview(preset)
        search.font = espoFont(10)
        search.placeholderString = "Поиск…"
        search.bezelStyle = .squareBezel
        search.focusRingType = .none
        search.delegate = self
        searchRow.addSubview(search)
        pager.font = espoFont(10)
        pager.textColor = ESPO_MUTED
        pager.alignment = .right
        searchRow.addSubview(pager)
    }

    func setPresets(_ names: [String], _ wheres: [String]) {
        preset.removeAllItems()
        preset.addItems(withTitles: names)
        presetWheres = wheres
        preset.selectItem(at: 0)
    }

    private var extraWhere: String {
        let i = preset.indexOfSelectedItem
        return (i >= 0 && i < presetWheres.count) ? presetWheres[i] : ""
    }

    private func buildEditor() {
        editor.isHidden = true
        addSubview(editor)
        editTitle.frame = NSRect(x: 14, y: 8, width: 500, height: 22)
        editTitle.font = espoFont(11, bold: true)
        editTitle.textColor = ESPO_SOFT
        editor.addSubview(editTitle)
        // три колонки полей, memo на всю ширину
        let w: CGFloat = 300
        var col = 0, rowN = 0
        var memoIdx = -1
        ctrls = Array(repeating: NSView(), count: def.fields.count)
        lookupIds = Array(repeating: [], count: def.fields.count)
        for (i, f) in def.fields.enumerated() {
            if f.kind == .memo { memoIdx = i; continue }
            let x = 14 + CGFloat(col) * (w + 20)
            let y = 36 + CGFloat(rowN) * 52
            makeLabel(editor, f.caption + (f.required ? " *" : ""), x: x, y: y, w: w)
            switch f.kind {
            case .enum, .lookupClient, .lookupDeal, .lookupItem, .lookupProject:
                let cb = makeCombo(editor, x: x, y: y + 18, w: w)
                if f.kind == .enum { cb.addItems(withTitles: enumDisplayList(f.enumName, f.enumValues)) }
                ctrls[i] = cb
            case .bool:
                let ck = NSButton(checkboxWithTitle: "Да", target: nil, action: nil)
                ck.frame = NSRect(x: x, y: y + 20, width: w, height: 22)
                ck.font = espoFont(10)
                editor.addSubview(ck)
                ctrls[i] = ck
            default:
                let e = makeEdit(editor, x: x, y: y + 18, w: w, placeholder: f.kind == .date ? "ГГГГ-ММ-ДД" : "")
                e.isEditable = f.kind != .readOnly
                ctrls[i] = e
            }
            col += 1
            if col == 3 { col = 0; rowN += 1 }
        }
        if col > 0 { rowN += 1 }
        var y = 36 + CGFloat(rowN) * 52
        if memoIdx >= 0 {
            makeLabel(editor, def.fields[memoIdx].caption, x: 14, y: y, w: 300)
            let scroll = NSScrollView(frame: NSRect(x: 14, y: y + 18, width: 3 * w + 40, height: 54))
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 3 * w + 40, height: 54))
            tv.font = espoFont(10)
            tv.isRichText = false
            tv.autoresizingMask = [.width]
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            editor.addSubview(scroll)
            ctrls[memoIdx] = tv
            y += 18 + 54 + 10
        }
        let save = EspoButton("Сохранить", primary: true, width: 120) { [weak self] in self?.save() }
        save.frame = NSRect(x: 14, y: y, width: 120, height: 36)
        editor.addSubview(save)
        let cancel = EspoButton("Отмена", primary: false, width: 100) { [weak self] in self?.cancel() }
        cancel.frame = NSRect(x: 142, y: y, width: 100, height: 36)
        editor.addSubview(cancel)
        editorHeight = y + 36 + 14
    }

    private func buildLines() {
        let box = PanelBox(title: "Строки заказа")
        box.isHidden = true
        addSubview(box)
        linesBox = box
        let (scroll, table) = makeTable(columns: [("Позиция", 300), ("Ед.", 50), ("Кол-во", 80), ("Цена", 90), ("Сумма", 100)])
        scroll.frame = NSRect(x: 14, y: 34, width: 640, height: 100)
        scroll.autoresizingMask = [.width]
        scroll.backgroundColor = ESPO_HEAD_BG
        table.dataSource = self
        table.delegate = self
        table.tag = 1
        box.addSubview(scroll)
        linesScroll = scroll
        linesTable = table
        makeLabel(box, "Позиция", x: 14, y: 140, w: 300)
        let cb = makeCombo(box, x: 14, y: 158, w: 300)
        cb.target = self
        cb.action = #selector(onLineItemChange)
        lineItem = cb
        makeLabel(box, "Кол-во", x: 324, y: 140, w: 80)
        lineQty = makeEdit(box, x: 324, y: 158, w: 80)
        lineQty?.stringValue = "1"
        makeLabel(box, "Цена", x: 414, y: 140, w: 100)
        linePrice = makeEdit(box, x: 414, y: 158, w: 100)
        let add = EspoButton("+ Строка", primary: true, width: 100) { [weak self] in self?.lineAdd() }
        add.frame = NSRect(x: 524, y: 152, width: 100, height: 32)
        box.addSubview(add)
        let del = EspoButton("Убрать строку", primary: false, width: 130) { [weak self] in self?.onLineDelete() }
        del.frame = NSRect(x: 632, y: 152, width: 130, height: 32)
        box.addSubview(del)
        let post = EspoButton("Провести", primary: false, width: 110) { [weak self] in self?.postOrder() }
        post.frame = NSRect(x: 770, y: 152, width: 110, height: 32)
        box.addSubview(post)
        linesTotalLabel = makeLabel(box, "Итого: 0.00 MDL", x: 670, y: 34, w: 240, h: 20, color: ESPO_TEXT, size: 11, bold: true, align: .right)
        linesTotalLabel?.autoresizingMask = [.minXMargin]
    }

    override func layout() {
        super.layout()
        var bottom: [(NSView, CGFloat)] = []
        if !editor.isHidden { bottom.append((editor, editorHeight)) }
        if let lb = linesBox, !lb.isHidden { bottom.append((lb, 190)) }
        dock(top: [(header, 48), (searchRow, 48)], bottom: bottom, client: listScroll,
             padding: NSEdgeInsets(top: 12, left: 15, bottom: 12, right: 15))
        layoutHeader()
        pager.frame = NSRect(x: searchRow.bounds.width - 200, y: 12, width: 200, height: 22)
        if let s = linesScroll, let lb = linesBox { s.frame = NSRect(x: 14, y: 34, width: lb.bounds.width - 28, height: 100) }
        if let l = linesTotalLabel, let lb = linesBox { l.frame = NSRect(x: lb.bounds.width - 254, y: 34, width: 240, height: 20) }
    }

    private func fillLookups() {
        for (i, f) in def.fields.enumerated() where f.kind.isLookup {
            guard let cb = ctrls[i] as? NSPopUpButton else { continue }
            cb.removeAllItems()
            cb.addItem(withTitle: "—")
            var ids = [0]
            for (id, name) in data.lookupPairs(f.kind) {
                cb.menu?.addItem(withTitle: name.isEmpty ? "(\(id))" : name, action: nil, keyEquivalent: "")
                ids.append(id)
            }
            lookupIds[i] = ids
        }
        if def.table == "orders", let cb = lineItem {
            cb.removeAllItems()
            lineItemIds = []
            for (id, name) in data.lookupPairs(.lookupItem) {
                cb.menu?.addItem(withTitle: name, action: nil, keyEquivalent: "")
                lineItemIds.append(id)
            }
        }
    }

    func refresh() {
        let keep = selectedId
        rows = data.list(def, filter: search.stringValue, extraWhere: extraWhere)
        suppressSelect = true
        list.reloadData()
        if keep > 0, let i = rows.firstIndex(where: { $0.id == keep }) {
            list.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        suppressSelect = false
        pager.stringValue = rows.isEmpty ? "0 записей" : "1 – \(rows.count) из \(data.count(def.table))"
    }

    func setFilter(_ text: String) {
        search.stringValue = text
        onSearchChange()
    }

    private func showEditor(_ id: Int) {
        fillLookups()
        editingId = id
        var row: EntityRow?
        if id > 0 {
            guard let r = data.get(def, id) else { return }
            row = r
            editTitle.stringValue = "Изменить " + def.titleOne
        } else {
            editTitle.stringValue = "Новая запись: " + def.titleOne
        }
        for (i, f) in def.fields.enumerated() {
            // дата подставляется только там, где объявлена по умолчанию («today»)
            let v = id > 0 ? (row?.values[i] ?? "") : resolveDefault(f.defaultValue)
            switch f.kind {
            case .enum:
                let idx = f.enumItems.firstIndex(of: v) ?? 0
                (ctrls[i] as? NSPopUpButton)?.selectItem(at: max(0, idx))
            case .lookupClient, .lookupDeal, .lookupItem, .lookupProject:
                let cb = ctrls[i] as? NSPopUpButton
                cb?.selectItem(at: 0)
                if let j = lookupIds[i].firstIndex(where: { String($0) == v }) { cb?.selectItem(at: j) }
            case .bool:
                (ctrls[i] as? NSButton)?.state = v == "1" ? .on : .off
            case .memo:
                (ctrls[i] as? NSTextView)?.string = v
            default:
                (ctrls[i] as? NSTextField)?.stringValue = v
            }
        }
        editor.isHidden = false
        if def.table == "orders" {
            linesBox?.isHidden = !(id > 0)   // строки — только у сохранённого заказа
            if id > 0 { loadLines() }
        }
        needsLayout = true
    }

    private func loadLines() {
        lines = data.orderLines(editingId)
        linesTable?.reloadData()
        let total = linesTotal
        linesTotalLabel?.stringValue = "Итого: \(fmtMoney(total)) MDL"
        for (i, f) in def.fields.enumerated() where f.kind == .readOnly {
            (ctrls[i] as? NSTextField)?.stringValue = fmt2(total)
        }
    }

    // ── действия — они же хуки самотеста ──

    func newRecord() {
        pendingDeleteId = 0
        showEditor(0)
        say(.info, "Заполните поля и нажмите «Сохранить».")
    }

    func editSelected() {
        if selectedId == 0 { say(.warn, "Выберите запись в списке."); return }
        showEditor(selectedId)
    }

    func setField(_ name: String, _ value: String) {
        guard let i = def.index(of: name) else { return }
        let f = def.fields[i]
        switch f.kind {
        case .enum:
            // принимаем каноническое значение — оно же лежит в базе
            (ctrls[i] as? NSPopUpButton)?.selectItem(at: max(0, f.enumItems.firstIndex(of: value) ?? -1))
        case .lookupClient, .lookupDeal, .lookupItem, .lookupProject:
            let cb = ctrls[i] as? NSPopUpButton
            var j = cb?.indexOfItem(withTitle: value) ?? -1
            if j < 0 { j = lookupIds[i].lastIndex(where: { String($0) == value }) ?? 0 }
            cb?.selectItem(at: max(0, j))
        case .bool:
            (ctrls[i] as? NSButton)?.state = (value == "1" || value.lowercased() == "true") ? .on : .off
        case .memo:
            (ctrls[i] as? NSTextView)?.string = value
        default:
            (ctrls[i] as? NSTextField)?.stringValue = value
        }
    }

    func getField(_ name: String) -> String {
        guard let i = def.index(of: name) else { return "" }
        let f = def.fields[i]
        switch f.kind {
        case .enum:
            let k = (ctrls[i] as? NSPopUpButton)?.indexOfSelectedItem ?? -1
            return (k >= 0 && k < f.enumItems.count) ? f.enumItems[k] : ""
        case .lookupClient, .lookupDeal, .lookupItem, .lookupProject:
            let k = (ctrls[i] as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            return (k > 0 && k < lookupIds[i].count) ? String(lookupIds[i][k]) : ""
        case .bool:
            return (ctrls[i] as? NSButton)?.state == .on ? "1" : "0"
        case .memo:
            return (ctrls[i] as? NSTextView)?.string ?? ""
        default:
            return (ctrls[i] as? NSTextField)?.stringValue ?? ""
        }
    }

    func save() {
        if editor.isHidden { return }
        var values: [String] = []
        for f in def.fields {
            var v = getField(f.name).trimmed
            if f.required && v.isEmpty {
                say(.err, "Не заполнено обязательное поле «\(f.caption)».")
                return
            }
            if f.kind.isNumeric && !v.isEmpty {
                v = v.replacingOccurrences(of: ",", with: ".")
                if toDouble(v) == nil {
                    say(.err, "Поле «\(f.caption)» должно быть числом.")
                    return
                }
            }
            values.append(v)
        }
        let newId: Int
        if editingId > 0 {
            data.update(def, editingId, values)
            say(.ok, "Сохранено: \(def.titleOne) «\(values[0])».")
            newId = editingId
        } else {
            newId = data.insert(def, values)
            say(.ok, "Добавлено: \(def.titleOne) «\(values[0])».")
        }
        refresh()
        selectById(newId)
        if def.table == "orders" {
            showEditor(newId)      // остаться в заказе — теперь доступны строки
        } else {
            editor.isHidden = true
            needsLayout = true
        }
        onChanged?()
    }

    func cancel() {
        editor.isHidden = true
        linesBox?.isHidden = true
        editingId = -1
        needsLayout = true
    }

    func deleteSelected() {
        let id = selectedId
        if id == 0 { say(.warn, "Выберите запись в списке, затем нажмите «Удалить»."); return }
        let name = rows.first { $0.id == id }.map { r in listCols.first.map { r.display[$0] } ?? "" } ?? ""
        if pendingDeleteId != id {
            pendingDeleteId = id
            say(.warn, "Удалить «\(name)»? Нажмите «Удалить» ещё раз для подтверждения.")
            return
        }
        pendingDeleteId = 0
        data.delete(def, id)
        cancel()
        refresh()
        say(.ok, "Удалено: «\(name)».")
        onChanged?()
    }

    @discardableResult
    func selectFirst() -> Bool {
        guard !rows.isEmpty else { return false }
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if editor.isHidden || editingId != rows[0].id { showEditor(rows[0].id) }
        return true
    }

    @discardableResult
    func selectById(_ id: Int) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        list.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        list.scrollRowToVisible(i)
        if editor.isHidden || editingId != id { showEditor(id) }
        return true
    }

    var selectedId: Int {
        let r = list.selectedRow
        return (r >= 0 && r < rows.count) ? rows[r].id : 0
    }

    var listCount: Int { rows.count }
    var editorVisible: Bool { !editor.isHidden }

    // ── строки заказа ──

    func lineSet(_ itemIndex: Int, _ qty: Double, _ price: Double) {
        if itemIndex >= 0 { lineItem?.selectItem(at: itemIndex) }
        lineQty?.stringValue = fmt0_2(qty)
        linePrice?.stringValue = fmt2(price)
    }

    func lineItemIndex(_ namePart: String) -> Int {
        guard let cb = lineItem else { return -1 }
        return cb.itemTitles.firstIndex { $0.localizedCaseInsensitiveContains(namePart) } ?? -1
    }

    func selectPreset(_ index: Int) {
        preset.selectItem(at: index)
        onSearchChange()
    }

    func lineAdd() {
        if editingId <= 0 { say(.warn, "Сначала сохраните заказ, потом добавляйте строки."); return }
        guard let cb = lineItem, cb.indexOfSelectedItem >= 0, cb.indexOfSelectedItem < lineItemIds.count else {
            say(.warn, "Выберите позицию номенклатуры."); return
        }
        let qty = toDoubleDef(lineQty?.stringValue ?? "")
        let price = toDoubleDef(linePrice?.stringValue ?? "")
        if qty <= 0 { say(.err, "Количество должно быть больше нуля."); return }
        data.addOrderLine(editingId, lineItemIds[cb.indexOfSelectedItem], qty, price)
        loadLines()
        refresh()
        selectById(editingId)
        say(.ok, "Строка добавлена. Итого по заказу: \(fmtMoney(linesTotal)) MDL")
        onChanged?()
    }

    func postOrder() {
        if editingId <= 0 { say(.warn, "Откройте сохранённый заказ."); return }
        // проводка использует статус из базы — сначала сохраняем редактор
        save()
        let msg = data.postOrder(editingId)
        if msg.hasPrefix("списано") || msg.hasPrefix("оприходовано") || msg.hasPrefix("услуги") {
            say(.ok, "Заказ проведён: " + msg)
        } else {
            say(.warn, "Заказ не проведён: " + msg)
        }
        onChanged?()
    }

    var linesCount: Int { lines.count }

    var linesTotal: Double {
        editingId <= 0 ? 0 : data.scalarDouble("SELECT COALESCE(SUM(sum),0) FROM order_lines WHERE order_id = \(editingId)")
    }

    // ── обработчики ──

    private func onRefreshClick() {
        pendingDeleteId = 0
        refresh()
        say(.info, "Обновлено. Записей: \(data.count(def.table))")
    }

    @objc private func onSearchChange() {
        pendingDeleteId = 0
        refresh()
        if !search.stringValue.isEmpty || preset.indexOfSelectedItem > 0 {
            say(.info, "Фильтр: показано \(rows.count) из \(data.count(def.table))")
        }
    }

    @objc private func onListDblClick() { editSelected() }

    @objc private func onLineItemChange() {
        guard let cb = lineItem, cb.indexOfSelectedItem >= 0, cb.indexOfSelectedItem < lineItemIds.count else { return }
        linePrice?.stringValue = fmt2(data.scalarDouble("SELECT price FROM items WHERE id = \(lineItemIds[cb.indexOfSelectedItem])"))
    }

    private func onLineDelete() {
        guard let t = linesTable, t.selectedRow >= 0, t.selectedRow < lines.count else {
            say(.warn, "Выберите строку заказа."); return
        }
        let l = lines[t.selectedRow]
        if pendingLineDelete != l.id {
            pendingLineDelete = l.id
            say(.warn, "Убрать строку «\(l.itemName)»? Нажмите ещё раз.")
            return
        }
        pendingLineDelete = 0
        data.deleteOrderLine(l.id)
        loadLines()
        refresh()
        selectById(editingId)
        say(.ok, "Строка убрана.")
    }

    // ── NSTableView ──

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView.tag == 1 ? lines.count : rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let ci = Int(col.identifier.rawValue.dropFirst()) else { return nil }
        if tableView.tag == 1 {
            let l = lines[row]
            let txt = [l.itemName, l.unit, fmt0_2(l.qty), fmt2(l.price), fmt2(l.sum)][ci]
            return tableCell(tableView, txt, right: ci >= 2)
        }
        let fi = listCols[ci]
        let f = def.fields[fi]
        return tableCell(tableView, rows[row].display[fi], right: f.kind == .money || f.kind == .readOnly || f.kind == .number)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let t = notification.object as? NSTableView, t.tag != 1, !suppressSelect else { return }
        let id = selectedId
        if id != 0 && id != pendingDeleteId { pendingDeleteId = 0 }
        // выбор строки открывает её в редакторе (detail view EspoCRM)
        if id > 0 { showEditor(id) }
    }
}

extension EntityPage: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === search { onSearchChange() }
    }
}
