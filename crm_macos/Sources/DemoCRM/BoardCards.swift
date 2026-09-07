// Общие данные досок (аналог uBoardCards.pas): карточки заказов / сделок /
// задач / проектов по колонкам-этапам. Одни и те же карточки показывают
// канбан и схема бизнес-процесса; единственная точка смены этапа —
// moveBoardCard. Фабрика самой карточки-вью — в BoardCardView.swift.
import Foundation
import AppKit

enum BoardKind: Int, CaseIterable {
    case orders = 0, deals, tasks, projects, projectTasks
}

struct BoardCard {
    var id = 0
    var col = 0
    var title = "", subtitle = "", amount = "", due = ""
    var kindValue = ""      // вид заказа / этап сделки / вид задачи (канонический)
    var kindText = ""       // то же в переводе (+ исполнитель, приоритет)
    var total = 0.0, paid = 0.0
    var overdue = false, done = false
    var daysLeft = Int.max  // до срока; Int.max — срока нет
    var icon = ""
    var stripe = NSColor.gray
}

let CARD_H: CGFloat = 96

/// Фильтр доски задач проекта: id проекта (0 — все задачи, у которых есть проект).
var boardProjectFilter = 0

// акценты колонок: продажа/сделка — синий, работа — янтарный, готово — зелёный,
// ожидание оплаты — фиолетовый, закрыто — серый; просрочка — красный
let CLR_BLUE = NSColor(hex: 0x5589CA)
let CLR_AMBER = NSColor(hex: 0xE09B2E)
let CLR_GREEN = NSColor(hex: 0x2A9A4C)
let CLR_VIOLET = NSColor(hex: 0x8A66B0)
let CLR_GRAY = NSColor(hex: 0x969696)
let CLR_RED = NSColor(hex: 0xAD4846)
let CLR_TEAL = NSColor(hex: 0x2B8FA2)
private let ORDER_COLORS = [CLR_AMBER, CLR_BLUE, CLR_GREEN, CLR_VIOLET, CLR_GRAY]
private let DEAL_COLORS = [CLR_TEAL, CLR_BLUE, CLR_AMBER, CLR_GREEN, CLR_RED]
private let TASK_COLORS = [CLR_RED, CLR_AMBER, CLR_BLUE, CLR_GREEN]
private let PROJECT_COLORS = [CLR_TEAL, CLR_BLUE, CLR_AMBER, CLR_VIOLET, CLR_AMBER, CLR_GREEN, CLR_VIOLET, CLR_GRAY, CLR_RED]
private let TSTAGE_COLORS = [CLR_TEAL, CLR_BLUE, CLR_AMBER, CLR_VIOLET, CLR_GREEN]

func boardTable(_ kind: BoardKind) -> String {
    switch kind {
    case .deals: return "deals"
    case .tasks, .projectTasks: return "tasks"
    case .projects: return "projects"
    case .orders: return "orders"
    }
}

func boardTitle(_ kind: BoardKind) -> String {
    switch kind {
    case .deals: return T.S("kanban.board_deals")
    case .tasks: return T.S("kanban.board_tasks")
    case .projects: return T.S("kanban.board_projects")
    case .projectTasks: return T.S("kanban.board_project_tasks")
    case .orders: return T.S("kanban.board_orders")
    }
}

private func enumTitles(_ enumName: String, _ canonical: String) -> [String] {
    enumDisplayList(enumName, canonical)
}

func boardColumnTitles(_ kind: BoardKind) -> [String] {
    switch kind {
    case .orders:
        return (0..<5).map { i in
            let t = T.enumAt("stage_title", Stage.awaitAdvance.rawValue + i)
            return t.isEmpty ? "stage \(i)" : t
        }
    case .deals: return enumTitles("deal_stage", ENUM_DEAL_STAGE)
    case .projects: return enumTitles("project_status", ENUM_PROJECT_STATUS)
    case .projectTasks: return enumTitles("task_stage", ENUM_TASK_STAGE)
    case .tasks:
        let r = T.S("kanban.task_cols").split(separator: ";").map(String.init)
        return r.count == 4 ? r : ["Просрочено", "Сегодня", "Позже", "Выполнено"]
    }
}

func boardColumnWhere(_ data: CrmData, _ kind: BoardKind, _ col: Int) -> String {
    switch kind {
    case .orders:
        return data.stageWhere(Stage(rawValue: Stage.awaitAdvance.rawValue + col) ?? .closed)
    case .deals:
        return "t.stage = '\(splitEnum(ENUM_DEAL_STAGE)[col])'"
    case .projects:
        return "t.status = '\(splitEnum(ENUM_PROJECT_STATUS)[col])'"
    case .projectTasks:
        var r = "t.stage = '\(splitEnum(ENUM_TASK_STAGE)[col])'"
        r += boardProjectFilter > 0 ? " AND t.project_id = \(boardProjectFilter)" : " AND COALESCE(t.project_id,0) > 0"
        return r
    case .tasks:
        switch col {
        case 0: return "t.done = 0 AND t.due_at < date('now','localtime')"
        case 1: return "t.done = 0 AND t.due_at = date('now','localtime')"
        case 2: return "t.done = 0 AND t.due_at > date('now','localtime')"
        default: return "t.done = 1"
        }
    }
}

func boardColumnColor(_ kind: BoardKind, _ col: Int) -> NSColor {
    let arr: [NSColor]
    switch kind {
    case .orders: arr = ORDER_COLORS
    case .deals: arr = DEAL_COLORS
    case .tasks: arr = TASK_COLORS
    case .projects: arr = PROJECT_COLORS
    case .projectTasks: arr = TSTAGE_COLORS
    }
    return (col >= 0 && col < arr.count) ? arr[col] : CLR_GRAY
}

private func kindIndex(_ list: String, _ value: String) -> Int {
    splitEnum(list).firstIndex(of: value) ?? -1
}

func loadBoardCards(_ data: CrmData, _ kind: BoardKind, _ col: Int) -> [BoardCard] {
    let titles = boardColumnTitles(kind)
    let lastCol = titles.count - 1
    let todayS = D(0)
    let whereSql = boardColumnWhere(data, kind, col)
    let sql: String
    switch kind {
    case .orders:
        sql = "SELECT t.id, t.number AS a, COALESCE(c.denumire,'') AS b, COALESCE(t.total,0) AS amt, COALESCE(t.paid,0) AS paid, COALESCE(t.due_date,'') AS due, t.kind AS k, '' AS extra FROM orders t LEFT JOIN clients c ON c.id = t.client_id WHERE \(whereSql) ORDER BY t.due_date, t.id"
    case .deals:
        sql = "SELECT t.id, t.title AS a, COALESCE(c.denumire,'') AS b, COALESCE(t.amount,0) AS amt, 0 AS paid, COALESCE(t.close_date,'') AS due, t.stage AS k, '' AS extra FROM deals t LEFT JOIN clients c ON c.id = t.client_id WHERE \(whereSql) ORDER BY t.close_date, t.id"
    case .projects:
        sql = "SELECT t.id, t.name AS a, COALESCE(c.denumire,'') AS b, COALESCE(t.budget,0) AS amt, COALESCE(t.prepaid,0) + COALESCE(t.paid,0) AS paid, COALESCE(t.due_date,'') AS due, t.kind AS k, (SELECT COUNT(*) FROM tasks x WHERE x.project_id = t.id) || '/' || (SELECT COUNT(*) FROM tasks x WHERE x.project_id = t.id AND x.done = 1) AS extra FROM projects t LEFT JOIN clients c ON c.id = t.client_id WHERE \(whereSql) ORDER BY t.due_date, t.id"
    case .projectTasks:
        sql = "SELECT t.id, t.subject AS a, COALESCE(p.name,'') AS b, 0 AS amt, 0 AS paid, COALESCE(t.due_at,'') AS due, COALESCE(t.priority,'Обычный') AS k, COALESCE(t.assignee,'') AS extra FROM tasks t LEFT JOIN projects p ON p.id = t.project_id WHERE \(whereSql) ORDER BY COALESCE(t.seq,0), t.due_at, t.id"
    case .tasks:
        sql = "SELECT t.id, t.subject AS a, COALESCE(c.denumire,'') AS b, 0 AS amt, 0 AS paid, COALESCE(t.due_at,'') AS due, t.kind AS k, COALESCE(t.assignee,'') AS extra FROM tasks t LEFT JOIN clients c ON c.id = t.client_id WHERE \(whereSql) ORDER BY t.due_at, t.id"
    }
    var out: [BoardCard] = []
    for r in data.rows(sql) {
        var c = BoardCard()
        c.id = r.int("id")
        c.col = col
        c.title = r.str("a")
        c.subtitle = r.str("b")
        if c.subtitle.isEmpty { c.subtitle = T.S("kanban.no_client") }
        c.kindValue = r.str("k")
        c.total = r.dbl("amt")
        c.paid = r.dbl("paid")
        if c.total > 0 { c.amount = fmtMoney(c.total) + " MDL" }
        c.due = r.str("due")
        c.done = col == lastCol
        if !c.due.isEmpty, let d = parseISODate(c.due) {
            let n = daysBetween(today(), d)
            c.daysLeft = n
        }
        let extra = r.str("extra")
        switch kind {
        case .orders:
            let idx = kindIndex(ENUM_ORDER_KIND, c.kindValue)
            c.kindText = T.enumAt("order_kind", idx)
            c.title = "№" + c.title
            switch idx {
            case 0: c.icon = "$"; c.stripe = CLR_BLUE
            case 1: c.icon = "✎"; c.stripe = CLR_TEAL
            case 2: c.icon = "⚒"; c.stripe = CLR_AMBER
            default: c.icon = "▣"; c.stripe = CLR_GRAY
            }
        case .deals:
            let idx = kindIndex(ENUM_DEAL_STAGE, c.kindValue)
            c.kindText = T.enumAt("deal_stage", idx)
            c.icon = "◆"
            c.stripe = boardColumnColor(.deals, col)
        case .projects:
            let idx = kindIndex(ENUM_PROJECT_KIND, c.kindValue)
            c.kindText = T.enumAt("project_kind", idx)
            if c.kindText.isEmpty { c.kindText = c.kindValue }
            c.amount += "   ·   " + T.F("kanban.tasks_of", [extra])
            switch idx {
            case 0: c.icon = "▣"; c.stripe = CLR_BLUE
            case 1: c.icon = "✎"; c.stripe = CLR_AMBER
            case 2: c.icon = "★"; c.stripe = CLR_VIOLET
            case 3: c.icon = "⚒"; c.stripe = CLR_TEAL
            default: c.icon = "▤"; c.stripe = CLR_GRAY
            }
            c.done = col == 7
            if col == 8 { c.icon = "✖"; c.stripe = CLR_RED }
        case .projectTasks:
            let idx = kindIndex(ENUM_TASK_PRIORITY, c.kindValue)
            c.kindText = T.enumAt("task_priority", idx)
            if c.kindText.isEmpty { c.kindText = c.kindValue }
            if !extra.isEmpty { c.kindText += "  ·  " + extra }
            switch idx {
            case 2: c.icon = "▲"; c.stripe = CLR_AMBER
            case 3: c.icon = "‼"; c.stripe = CLR_RED
            case 0: c.icon = "▽"; c.stripe = CLR_GRAY
            default: c.icon = "☑"; c.stripe = CLR_BLUE
            }
        case .tasks:
            let idx = kindIndex(ENUM_TASK_KIND, c.kindValue)
            c.kindText = T.enumAt("task_kind", idx)
            if !extra.isEmpty { c.kindText += "  ·  " + extra }
            switch idx {
            case 1: c.icon = "☎"; c.stripe = CLR_TEAL
            case 2: c.icon = "☺"; c.stripe = CLR_VIOLET
            default: c.icon = "☑"; c.stripe = CLR_BLUE
            }
        }
        if c.kindText.isEmpty { c.kindText = c.kindValue }
        c.overdue = !c.due.isEmpty && c.due < todayS && !c.done && !(kind == .projects && col == 8)
        if c.done { c.icon = "✔"; c.stripe = CLR_GREEN }
        else if c.overdue { c.stripe = CLR_RED }
        out.append(c)
    }
    return out
}

func boardColumnSum(_ cards: [BoardCard]) -> Double { cards.reduce(0) { $0 + $1.total } }
func boardColumnOverdue(_ cards: [BoardCard]) -> Int { cards.filter { $0.overdue }.count }

/// Единственное место, где карточка меняет этап. false — колонка вне доски.
@discardableResult
func moveBoardCard(_ data: CrmData, _ kind: BoardKind, _ id: Int, _ newCol: Int) -> Bool {
    let titles = boardColumnTitles(kind)
    guard newCol >= 0, newCol < titles.count else { return false }
    let db = data.db
    switch kind {
    case .orders:
        let total = db.scalarDouble("SELECT COALESCE(total,0) FROM orders WHERE id = \(id)")
        let adv = max(0.01, money2(total * 0.3))
        switch newCol {
        case 0: db.run("UPDATE orders SET status = 'Подтверждён', advance = 0, paid = 0, ship_date = NULL WHERE id = ?", [id])
        case 1: db.run("UPDATE orders SET status = 'В работе', advance = ?, paid = 0, ship_date = NULL WHERE id = ?", [adv, id])
        case 2: db.run("UPDATE orders SET status = 'Выполнен', advance = ?, ship_date = NULL WHERE id = ?", [adv, id])
        case 3: db.run("UPDATE orders SET status = 'Выполнен', ship_date = ?, paid = ? WHERE id = ?", [D(0), money2(total * 0.3), id])
        case 4: db.run("UPDATE orders SET status = 'Оплачен', paid = ?, ship_date = COALESCE(NULLIF(ship_date,''), ?) WHERE id = ?", [total, D(0), id])
        default: break
        }
    case .deals:
        db.run("UPDATE deals SET stage = ? WHERE id = ?", [splitEnum(ENUM_DEAL_STAGE)[newCol], id])
    case .projects:
        db.run("UPDATE projects SET status = ? WHERE id = ?", [splitEnum(ENUM_PROJECT_STATUS)[newCol], id])
        switch newCol {
        case 0, 1: db.run("UPDATE projects SET prepaid = 0, paid = 0 WHERE id = ?", [id])
        case 2...5: db.run("UPDATE projects SET prepaid = ROUND(COALESCE(budget,0) * COALESCE(prepay_pct,0) / 100, 2), paid = 0 WHERE id = ?", [id])
        case 7: db.run("UPDATE projects SET paid = COALESCE(budget,0) - COALESCE(prepaid,0) WHERE id = ?", [id])
        default: break
        }
    case .projectTasks:
        data.setTaskStage(id, splitEnum(ENUM_TASK_STAGE)[newCol])
    case .tasks:
        if newCol == titles.count - 1 {
            data.setTaskDone(id, true)
        } else {
            data.setTaskDone(id, false)
            let shift = newCol == 0 ? -1 : (newCol == 1 ? 0 : 7)
            db.run("UPDATE tasks SET due_at = ? WHERE id = ?", [D(shift), id])
        }
    }
    return true
}

func daysBadgeText(_ c: BoardCard) -> String {
    if c.done { return "✔" }
    if c.daysLeft == Int.max { return "" }
    if c.daysLeft < 0 { return T.F("kanban.days_late", [-c.daysLeft]) }
    if c.daysLeft == 0 { return T.S("kanban.today") }
    return T.F("kanban.days_left", [c.daysLeft])
}

extension NSColor {
    /// Цвет из RGB-шестнадцатеричного числа вида 0xRRGGBB.
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
