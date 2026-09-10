// Слой данных CRM (аналог uCrmData.pas): описания сущностей (метаданные
// полей) и универсальный CRUD поверх той же SQLite-базы, что и клиенты.
// Одна таблица — одно описание EntityDef; страницы интерфейса строятся из
// этих описаний автоматически.
import Foundation
import CryptoKit

enum FieldKind {
    case text, memo, number, money, date, `enum`
    case lookupClient, lookupDeal, lookupItem, lookupProject
    case bool, readOnly
    /// Имя сотрудника: список активных сотрудников со стрелкой выбора,
    /// но можно вписать своё — в базе остаётся тот же текст.
    case user
    /// Только для показа (дата регистрации, состояние пароля): выводится как
    /// есть и не пишется обобщённым CRUD — значение ведёт программа.
    case infoText

    var isLookup: Bool { [.lookupClient, .lookupDeal, .lookupItem, .lookupProject].contains(self) }
    var isNumeric: Bool { self == .number || self == .money }
    /// Колонки, которые обобщённый CRUD не пишет.
    var isCalculated: Bool { self == .readOnly || self == .infoText }
}

struct FieldDef {
    var name: String          // колонка в таблице
    var caption: String
    var kind: FieldKind
    var enumValues = ""       // канонические значения через ';' — они лежат в базе
    var enumName = ""         // имя списка в lang.json для показа перевода
    var listWidth = 0         // ширина колонки в списке, 0 — не показывать
    var required = false
    var defaultValue = ""

    var enumItems: [String] { enumValues.split(separator: ";", omittingEmptySubsequences: false).map(String.init) }
}

func fieldDef(_ name: String, _ caption: String, _ kind: FieldKind, _ listWidth: Int = 0,
              _ required: Bool = false, _ enumValues: String = "", _ def: String = "",
              _ enumName: String = "") -> FieldDef {
    FieldDef(name: name, caption: caption, kind: kind, enumValues: enumValues, enumName: enumName,
             listWidth: listWidth, required: required, defaultValue: def)
}

struct EntityDef {
    var table: String
    var title: String         // «Сделки»
    var titleOne: String      // «сделку»
    var fields: [FieldDef]
    var orderBy: String
    var searchCols: String    // колонки для фильтра через ','

    func index(of field: String) -> Int? { fields.firstIndex { $0.name == field } }
}

struct EntityRow {
    var id = 0
    var values: [String] = []   // по порядку fields
    var display: [String] = []  // то же, но lookup/enum раскрыты для показа
}

struct OrderLine {
    var id = 0, itemId = 0
    var itemName = "", unit = ""
    var qty = 0.0, price = 0.0, sum = 0.0
}

/// Этап процесса «от контракта до денег» — по нему строятся плитки
/// рабочего стола. Условия взаимоисключающие, см. stageWhere.
enum Stage: Int, CaseIterable {
    case dealOffer = 0, dealTalks, dealWon, awaitAdvance, inWork, readyToShip, awaitPayment, closed

    var isDeal: Bool { rawValue <= Stage.dealWon.rawValue }
    static var orderStages: [Stage] { [.awaitAdvance, .inWork, .readyToShip, .awaitPayment, .closed] }
    static var dealStages: [Stage] { [.dealOffer, .dealTalks, .dealWon] }
}

struct StageInfo {
    var stage: Stage
    var title = ""       // «Ожидает аванс»
    var hint = ""
    var table = ""       // deals | orders
    var count = 0
    var sum = 0.0
    var overdue = 0
    var overdueSum = 0.0
}

// ── канонические значения перечислений (в базе — по-русски) ──
let ENUM_CLIENT_TYPE = "Клиент;Поставщик;Партнёр"
let ENUM_PROJECT_KIND = "Реклама;Гравировка;Сувениры;Монтаж;Другое"
let ENUM_PROJECT_STATUS = "Тендер;Договор;Аванс;Дизайн;Производство;Сдача;Оплата;Закрыт;Проигран"
let ENUM_TASK_STAGE = "Новая;В работе;Ожидание;Проверка;Готово"
let ENUM_TASK_PRIORITY = "Низкий;Обычный;Высокий;Срочно"
let ENUM_LEAD_STATUS = "Новый;В работе;Конвертирован;Отказ"
let ENUM_LEAD_SOURCE = "Сайт;Звонок;Рекомендация;Выставка;Реклама;Другое"
let ENUM_DEAL_STAGE = "Новая;Предложение;Переговоры;Выиграна;Проиграна"
let ENUM_ITEM_KIND = "Товар;Услуга;Изделие"
let ENUM_UNIT = "шт;час;кг;м;м2;л;компл;услуга"
let ENUM_ORDER_KIND = "Продажа;Услуга;Производство"
let ENUM_ORDER_STATUS = "Черновик;Подтверждён;В работе;Выполнен;Оплачен;Отменён"
let ENUM_TASK_KIND = "Задача;Звонок;Встреча"
/// Роль сотрудника в CRM: администратор регистрирует людей и видит всё,
/// остальные роли — подсказка для отчётов и прав (значения в базе русские).
let ENUM_USER_ROLE = "Администратор;Руководитель;Коммерческий;Производство;Склад;Бухгалтерия;Наблюдатель"

/// Стандартный пароль нового сотрудника: администратор называет его человеку,
/// тот меняет пароль в «Настройках». Кнопка «Сбросить пароль» возвращает его.
let STANDARD_PASSWORD = "crm2026"
/// Состояние пароля в списке сотрудников (колонка pass_state).
let PASS_STD = "стандартный"
let PASS_OWN = "свой"

func splitEnum(_ s: String) -> [String] { s.split(separator: ";", omittingEmptySubsequences: false).map(String.init) }

/// Перевод списка для показа; перевода нет или он неполный — канонические значения.
func enumDisplayList(_ enumName: String, _ canonicalList: String) -> [String] {
    let r = T.enumList(enumName)
    let canon = splitEnum(canonicalList)
    return r.count == canon.count ? r : canon
}

/// Перевод значения перечисления для показа: в базе остаётся каноническое.
func enumDisplay(_ enumName: String, _ canonical: String, _ canonicalList: String) -> String {
    let canon = splitEnum(canonicalList)
    let disp = enumDisplayList(enumName, canonicalList)
    if let i = canon.firstIndex(of: canonical) { return disp[i] }
    return canonical
}

/// «today» / «today+N» → дата; остальное как есть.
func resolveDefault(_ s: String) -> String {
    if s.lowercased().hasPrefix("today") {
        let n = Int(s.dropFirst(5)) ?? 0
        return D(n)
    }
    return s
}

// ── описания сущностей ──
let DefContacts = EntityDef(table: "contacts", title: "Контакты", titleOne: "контакт", fields: [
    fieldDef("name", "Имя", .text, 220, true),
    fieldDef("client_id", "Клиент", .lookupClient, 240),
    fieldDef("position", "Должность", .text, 140),
    fieldDef("phone", "Телефон", .text, 120),
    fieldDef("email", "E-mail", .text, 160),
    fieldDef("notes", "Заметки", .memo)],
    orderBy: "name", searchCols: "name,phone,email,position")

let DefLeads = EntityDef(table: "leads", title: "Лиды", titleOne: "лид", fields: [
    fieldDef("name", "Имя", .text, 180, true),
    fieldDef("company", "Компания", .text, 200),
    fieldDef("status", "Статус", .enum, 110, true, ENUM_LEAD_STATUS, "Новый", "lead_status"),
    fieldDef("source", "Источник", .enum, 110, false, ENUM_LEAD_SOURCE, "Сайт", "lead_source"),
    fieldDef("phone", "Телефон", .text, 120),
    fieldDef("email", "E-mail", .text, 150),
    fieldDef("notes", "Заметки", .memo)],
    orderBy: "id DESC", searchCols: "name,company,phone,email")

let DefDeals = EntityDef(table: "deals", title: "Сделки", titleOne: "сделку", fields: [
    fieldDef("title", "Название", .text, 240, true),
    fieldDef("client_id", "Клиент", .lookupClient, 220),
    fieldDef("stage", "Этап", .enum, 110, true, ENUM_DEAL_STAGE, "Новая", "deal_stage"),
    fieldDef("amount", "Сумма, MDL", .money, 110),
    fieldDef("close_date", "Закрытие", .date, 100),
    fieldDef("notes", "Заметки", .memo)],
    orderBy: "id DESC", searchCols: "title")

let DefItems = EntityDef(table: "items", title: "Номенклатура", titleOne: "позицию", fields: [
    fieldDef("code", "Код", .text, 80),
    fieldDef("name", "Наименование", .text, 260, true),
    fieldDef("kind", "Вид", .enum, 90, true, ENUM_ITEM_KIND, "Товар", "item_kind"),
    fieldDef("unit_", "Ед.", .enum, 60, true, ENUM_UNIT, "шт", "unit"),
    fieldDef("price", "Цена, MDL", .money, 100),
    fieldDef("vat", "НДС, %", .number, 70, false, "", "20"),
    fieldDef("stock", "Остаток", .number, 80, false, "", "0"),
    fieldDef("notes", "Описание", .memo)],
    orderBy: "name", searchCols: "code,name")

let DefOrders = EntityDef(table: "orders", title: "Заказы", titleOne: "заказ", fields: [
    fieldDef("number", "№", .text, 60, true),
    fieldDef("order_date", "Дата", .date, 85, true, "", "today"),
    fieldDef("client_id", "Клиент", .lookupClient, 190),
    fieldDef("project_id", "Проект", .lookupProject, 150),
    fieldDef("kind", "Вид", .enum, 100, true, ENUM_ORDER_KIND, "Продажа", "order_kind"),
    fieldDef("status", "Статус", .enum, 100, true, ENUM_ORDER_STATUS, "Черновик", "order_status"),
    fieldDef("total", "Итого, MDL", .readOnly, 90),
    fieldDef("advance", "Аванс", .money, 80),
    fieldDef("paid", "Оплачено", .money, 85),
    fieldDef("due_date", "Срок", .date, 85, false, "", "today+14"),
    fieldDef("ship_date", "Отгружен", .date, 85),
    fieldDef("notes", "Примечание", .memo)],
    orderBy: "id DESC", searchCols: "number")

let DefTasks = EntityDef(table: "tasks", title: "Календарь", titleOne: "задачу", fields: [
    fieldDef("subject", "Тема", .text, 220, true),
    fieldDef("project_id", "Проект", .lookupProject, 170),
    fieldDef("stage", "Этап", .enum, 90, true, ENUM_TASK_STAGE, "Новая", "task_stage"),
    fieldDef("priority", "Приоритет", .enum, 80, true, ENUM_TASK_PRIORITY, "Обычный", "task_priority"),
    fieldDef("assignee", "Исполнитель", .user, 120),
    fieldDef("kind", "Вид", .enum, 80, true, ENUM_TASK_KIND, "Задача", "task_kind"),
    fieldDef("plan_start", "Начало", .date, 85, false, "", "today"),
    fieldDef("due_at", "Срок", .date, 85, true, "", "today"),
    fieldDef("hours_plan", "Часы план", .number, 70),
    fieldDef("hours_fact", "Часы факт", .number, 70),
    fieldDef("seq", "№ в проекте", .number, 60),
    fieldDef("depends_on", "После задачи №", .number, 0),
    fieldDef("client_id", "Клиент", .lookupClient, 160),
    fieldDef("deal_id", "Сделка", .lookupDeal, 0),
    fieldDef("done", "Выполнено", .bool, 80),
    fieldDef("notes", "Заметки", .memo)],
    orderBy: "done, due_at, seq", searchCols: "subject,assignee")

let DefProjects = EntityDef(table: "projects", title: "Проекты", titleOne: "проект", fields: [
    fieldDef("name", "Проект", .text, 260, true),
    fieldDef("client_id", "Клиент", .lookupClient, 170),
    fieldDef("kind", "Вид", .enum, 90, true, ENUM_PROJECT_KIND, "Реклама", "project_kind"),
    fieldDef("status", "Этап", .enum, 100, true, ENUM_PROJECT_STATUS, "Тендер", "project_status"),
    fieldDef("tender_no", "Тендер №", .text, 90),
    fieldDef("tender_deadline", "Срок тендера", .date, 0),
    fieldDef("budget", "Бюджет, MDL", .money, 100),
    fieldDef("prepay_pct", "Аванс, %", .number, 60, false, "", "0"),
    fieldDef("prepaid", "Аванс получен", .money, 95),
    fieldDef("paid", "Оплачено", .money, 90),
    fieldDef("start_date", "Начало", .date, 85, false, "", "today"),
    fieldDef("due_date", "Сдача", .date, 85, true, "", "today+30"),
    fieldDef("manager", "Менеджер", .user, 110),
    fieldDef("notes", "Описание", .memo)],
    orderBy: "id DESC", searchCols: "name,tender_no,manager")

// Сотрудник — он же пользователь входа. Регистрирует администратор: логин,
// стандартный пароль, контакты; счёт можно выключить («Работает» снято) —
// такой человек не войдёт, но остаётся в задачах и отчётах.
let DefUsers = EntityDef(table: "users", title: "Сотрудники", titleOne: "сотрудника", fields: [
    fieldDef("full_name", "Сотрудник", .text, 165, true),
    fieldDef("login", "Логин", .text, 85, true),
    fieldDef("position", "Должность", .text, 120),
    fieldDef("role", "Роль", .enum, 100, true, ENUM_USER_ROLE, "Коммерческий", "user_role"),
    fieldDef("email", "E-mail", .text, 155),
    fieldDef("phone", "Телефон", .text, 110),
    fieldDef("active", "Работает", .bool, 60, false, "", "1"),
    fieldDef("created_at", "Зарегистрирован", .infoText, 110),
    fieldDef("pass_state", "Пароль", .infoText, 85),
    fieldDef("erp_code", "Код в ERP", .text, 0),
    fieldDef("notes", "Заметки", .memo)],
    orderBy: "active DESC, full_name", searchCols: "full_name,login,email,phone,position")

/// Пароль хранится только как SHA-256 с солью из логина.
func passHash(_ user: String, _ password: String) -> String {
    let data = Data(("crm:" + user.lowercased() + ":" + password).utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

final class CrmData {
    let clients: ClientsDB
    var db: SQLiteDB { clients.db }

    init(_ clients: ClientsDB) { self.clients = clients }

    // ── схема ──

    func ensureSchema() {
        let ddl = [
            "CREATE TABLE IF NOT EXISTS contacts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, client_id INTEGER, position TEXT, phone TEXT, email TEXT, notes TEXT)",
            "CREATE TABLE IF NOT EXISTS leads (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, company TEXT, status TEXT, source TEXT, phone TEXT, email TEXT, notes TEXT, client_id INTEGER, created_at TEXT DEFAULT (datetime('now','localtime')))",
            "CREATE TABLE IF NOT EXISTS deals (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, client_id INTEGER, stage TEXT, amount REAL DEFAULT 0, close_date TEXT, notes TEXT, created_at TEXT DEFAULT (datetime('now','localtime')))",
            "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT, name TEXT NOT NULL, kind TEXT, unit_ TEXT, price REAL DEFAULT 0, vat REAL DEFAULT 20, stock REAL DEFAULT 0, notes TEXT)",
            "CREATE TABLE IF NOT EXISTS orders (id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT NOT NULL, order_date TEXT, client_id INTEGER, kind TEXT, status TEXT, total REAL DEFAULT 0, advance REAL DEFAULT 0, paid REAL DEFAULT 0, due_date TEXT, ship_date TEXT, notes TEXT, posted INTEGER DEFAULT 0, erp_batch TEXT, erp_sent_at TEXT, created_at TEXT DEFAULT (datetime('now','localtime')))",
            "CREATE TABLE IF NOT EXISTS order_lines (id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL, item_id INTEGER NOT NULL, qty REAL DEFAULT 1, price REAL DEFAULT 0, sum REAL DEFAULT 0)",
            "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, login TEXT UNIQUE NOT NULL, pass_hash TEXT NOT NULL, full_name TEXT, created_at TEXT DEFAULT (datetime('now','localtime')))",
            "CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, kind TEXT, due_at TEXT, client_id INTEGER, deal_id INTEGER, done INTEGER DEFAULT 0, notes TEXT, created_at TEXT DEFAULT (datetime('now','localtime')))",
            "CREATE TABLE IF NOT EXISTS projects (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, client_id INTEGER, kind TEXT, status TEXT, tender_no TEXT, tender_deadline TEXT, budget REAL DEFAULT 0, prepay_pct REAL DEFAULT 0, prepaid REAL DEFAULT 0, paid REAL DEFAULT 0, start_date TEXT, due_date TEXT, manager TEXT, notes TEXT, created_at TEXT DEFAULT (datetime('now','localtime')))",
        ]
        for s in ddl { db.run(s) }
        for c in ["client_type", "phone", "email", "notes", "contact_person"] { addColumn("clients", c, "TEXT") }
        for c in ["advance REAL DEFAULT 0", "paid REAL DEFAULT 0", "due_date TEXT", "ship_date TEXT",
                  "erp_batch TEXT", "erp_sent_at TEXT", "project_id INTEGER"] {
            let p = c.split(separator: " ", maxSplits: 1).map(String.init)
            addColumn("orders", p[0], p.count > 1 ? p[1] : "")
        }
        for c in ["project_id INTEGER", "stage TEXT", "priority TEXT", "assignee TEXT", "plan_start TEXT",
                  "hours_plan REAL", "hours_fact REAL", "depends_on INTEGER", "seq INTEGER"] {
            let p = c.split(separator: " ", maxSplits: 1).map(String.init)
            addColumn("tasks", p[0], p.count > 1 ? p[1] : "")
        }
        // сотрудники: карточка человека поверх старой таблицы входа
        for c in ["position TEXT", "role TEXT", "email TEXT", "phone TEXT", "active INTEGER DEFAULT 1",
                  "pass_state TEXT", "erp_code TEXT", "notes TEXT", "updated_at TEXT"] {
            let p = c.split(separator: " ", maxSplits: 1).map(String.init)
            addColumn("users", p[0], p.count > 1 ? p[1] : "")
        }
        db.run("UPDATE users SET active = 1 WHERE active IS NULL")
        db.run("UPDATE users SET role = 'Администратор' WHERE COALESCE(role,'') = '' AND login = 'admin'")
        db.run("UPDATE users SET role = 'Коммерческий' WHERE COALESCE(role,'') = ''")
        db.run("UPDATE users SET pass_state = '\(PASS_OWN)' WHERE COALESCE(pass_state,'') = ''")
        ensureSyncSchema()
        // задачи старой базы: этап из флага «выполнено», приоритет обычный
        db.run("UPDATE tasks SET stage = CASE WHEN COALESCE(done,0) = 1 THEN 'Готово' ELSE 'Новая' END WHERE COALESCE(stage,'') = ''")
        db.run("UPDATE tasks SET priority = 'Обычный' WHERE COALESCE(priority,'') = ''")
        db.run("UPDATE tasks SET plan_start = due_at WHERE COALESCE(plan_start,'') = ''")
    }

    /// Добавляет колонку, если её ещё нет — база могла быть создана старой версией.
    private func addColumn(_ table: String, _ col: String, _ decl: String) {
        let have = db.rows("PRAGMA table_info(\(table))").contains { $0.str("name").lowercased() == col.lowercased() }
        if !have { db.run("ALTER TABLE \(table) ADD COLUMN \(col) \(decl)") }
    }

    func columns(_ table: String) -> [String] { db.rows("PRAGMA table_info(\(table))").map { $0.str("name") } }

    // ── задачи и проекты ──

    /// Этап и флаг «выполнено» — одно состояние: «Готово» ⇔ done.
    func setTaskDone(_ taskId: Int, _ done: Bool) {
        if done {
            db.run("UPDATE tasks SET done = 1, stage = 'Готово' WHERE id = ?", [taskId])
        } else {
            db.run("UPDATE tasks SET done = 0, stage = CASE WHEN stage = 'Готово' THEN 'В работе' ELSE stage END WHERE id = ?", [taskId])
        }
    }

    func setTaskStage(_ taskId: Int, _ stage: String) {
        db.run("UPDATE tasks SET stage = ?, done = ? WHERE id = ?", [stage, stage == "Готово" ? 1 : 0, taskId])
    }

    /// Сводка по проекту: задач всего / готово / просрочено, часы план / факт.
    func projectSummary(_ projectId: Int) -> (total: Int, done: Int, overdue: Int, hoursPlan: Double, hoursFact: Double) {
        let r = db.rows("""
        SELECT COUNT(*) AS n, SUM(CASE WHEN done = 1 THEN 1 ELSE 0 END) AS d,
          SUM(CASE WHEN done = 0 AND COALESCE(due_at,'') <> '' AND due_at < date('now','localtime') THEN 1 ELSE 0 END) AS o,
          COALESCE(SUM(hours_plan),0) AS hp, COALESCE(SUM(hours_fact),0) AS hf
        FROM tasks WHERE project_id = \(projectId)
        """).first
        return (r?.int("n") ?? 0, r?.int("d") ?? 0, r?.int("o") ?? 0, r?.dbl("hp") ?? 0, r?.dbl("hf") ?? 0)
    }

    func projectProgress(_ projectId: Int) -> Int {
        let s = projectSummary(projectId)
        return s.total == 0 ? 0 : Int(bankRound(Double(s.done) * 100 / Double(s.total)))
    }

    // ── пользователи ──

    func ensureAdmin() {
        if userCount() == 0 {
            db.run("""
            INSERT INTO users (login, pass_hash, full_name, position, role, email, active, pass_state)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?)
            """, ["admin", passHash("admin", "admin"), "Administrator", "Администратор системы",
                  "Администратор", "admin@demo.md", PASS_OWN])
        }
    }

    func userCount() -> Int { db.scalarInt("SELECT COUNT(*) FROM users") }

    /// Вход: логин ищется без учёта регистра, выключенный счёт не пускают.
    /// Возвращает причину для строки сообщений — нужна и самотесту.
    func loginCheck(_ user: String, _ password: String) -> (ok: Bool, reason: String) {
        let u = user.trimmed
        if u.isEmpty { return (false, "не указан логин") }
        guard let r = db.rows("SELECT pass_hash, active FROM users WHERE login = ? COLLATE NOCASE", [u]).first else {
            return (false, "нет такого сотрудника")
        }
        if r.str("pass_hash") != passHash(u, password) { return (false, "неверный пароль") }
        if r.int("active") != 1 { return (false, "счёт отключён администратором") }
        return (true, "")
    }

    func checkLogin(_ user: String, _ password: String) -> Bool { loginCheck(user, password).ok }

    /// Свой пароль сотрудника: состояние в списке переключается на «свой».
    @discardableResult
    func setPassword(_ user: String, _ password: String) -> Bool {
        if password.trimmed.isEmpty { return false }
        db.run("UPDATE users SET pass_hash = ?, pass_state = ?, updated_at = datetime('now','localtime') WHERE login = ? COLLATE NOCASE",
               [passHash(user.trimmed, password), PASS_OWN, user.trimmed])
        return true
    }

    /// Восстановление доступа администратором: пароль снова стандартный.
    /// Возвращает сам пароль — его называют сотруднику.
    func resetPassword(_ userId: Int) -> (ok: Bool, login: String, password: String) {
        let login = db.scalarString("SELECT login FROM users WHERE id = \(userId)")
        if login.isEmpty { return (false, "", "") }
        db.run("UPDATE users SET pass_hash = ?, pass_state = ?, updated_at = datetime('now','localtime') WHERE id = ?",
               [passHash(login, STANDARD_PASSWORD), PASS_STD, userId])
        return (true, login, STANDARD_PASSWORD)
    }

    func userRole(_ login: String) -> String {
        db.scalarString("SELECT COALESCE(role,'') FROM users WHERE login = \(quoted(login.trimmed)) COLLATE NOCASE")
    }

    func isAdmin(_ login: String) -> Bool { userRole(login) == "Администратор" }

    /// Имена активных сотрудников — список выбора исполнителя и менеджера.
    func staffNames() -> [String] {
        db.rows("SELECT full_name FROM users WHERE COALESCE(active,1) = 1 AND COALESCE(full_name,'') <> '' ORDER BY full_name")
            .map { $0.str("full_name") }
    }

    /// Переименование сотрудника тянет за собой задачи и проекты: имя лежит
    /// в них текстом, иначе отчёт по людям развалится на два имени.
    func renameStaff(_ oldName: String, _ newName: String) {
        if oldName.trimmed.isEmpty || oldName == newName { return }
        db.run("UPDATE tasks SET assignee = ? WHERE assignee = ?", [newName, oldName])
        db.run("UPDATE projects SET manager = ? WHERE manager = ?", [newName, oldName])
    }

    // ── этапы процесса ──

    static let stageTitles = ["Предложение", "Переговоры", "Готово к заказу", "Ожидает аванс",
                              "В работе / производство", "Готово к отгрузке", "Отгружено — ждём оплату", "Закрыто"]
    static let stageHints = ["КП отправлено клиенту", "Согласование условий", "Сделка выиграна — оформить заказ",
                             "Заказ подтверждён, аванс не поступил", "Аванс есть, идёт исполнение",
                             "Исполнен, отгрузка не оформлена", "Отгружен, оплата не закрыта", "Отгружен и полностью оплачен"]

    func stageWhere(_ stage: Stage) -> String {
        let nc = "t.status <> 'Отменён' AND "
        switch stage {
        case .dealOffer: return "t.stage = 'Предложение'"
        case .dealTalks: return "t.stage = 'Переговоры'"
        case .dealWon: return "t.stage = 'Выиграна'"
        case .awaitAdvance: return nc + "t.status = 'Подтверждён' AND COALESCE(t.advance,0) <= 0"
        case .inWork: return nc + "t.status IN ('Подтверждён','В работе') AND COALESCE(t.advance,0) > 0"
        case .readyToShip: return nc + "t.status IN ('Выполнен','Оплачен') AND COALESCE(t.ship_date,'') = ''"
        case .awaitPayment: return nc + "COALESCE(t.ship_date,'') <> '' AND COALESCE(t.paid,0) < t.total"
        case .closed: return nc + "COALESCE(t.ship_date,'') <> '' AND COALESCE(t.paid,0) >= t.total"
        }
    }

    /// Запаздывает: срок в прошлом, а этап ещё не закрыт.
    func overdueWhere(_ stage: Stage) -> String {
        if stage.isDeal {
            return stageWhere(stage) + " AND COALESCE(t.close_date,'') <> '' AND t.close_date < date('now','localtime')"
        } else if stage == .closed {
            return stageWhere(stage) + " AND 1=0"
        }
        return stageWhere(stage) + " AND COALESCE(t.due_date,'') <> '' AND t.due_date < date('now','localtime')"
    }

    func stageInfo(_ stage: Stage) -> StageInfo {
        var r = StageInfo(stage: stage)
        r.title = T.enumAt("stage_title", stage.rawValue)
        if r.title.isEmpty { r.title = CrmData.stageTitles[stage.rawValue] }
        r.hint = T.enumAt("stage_hint", stage.rawValue)
        if r.hint.isEmpty { r.hint = CrmData.stageHints[stage.rawValue] }
        let tbl = stage.isDeal ? "deals" : "orders"
        r.table = tbl
        let sumCol = stage.isDeal ? "amount" : "total"
        r.count = db.scalarInt("SELECT COUNT(*) FROM \(tbl) t WHERE \(stageWhere(stage))")
        r.sum = db.scalarDouble("SELECT COALESCE(SUM(t.\(sumCol)),0) FROM \(tbl) t WHERE \(stageWhere(stage))")
        r.overdue = db.scalarInt("SELECT COUNT(*) FROM \(tbl) t WHERE \(overdueWhere(stage))")
        r.overdueSum = db.scalarDouble("SELECT COALESCE(SUM(t.\(sumCol)),0) FROM \(tbl) t WHERE \(overdueWhere(stage))")
        return r
    }

    func stageOf(_ orderId: Int) -> Stage {
        for s in Stage.orderStages {
            if db.scalarInt("SELECT COUNT(*) FROM orders t WHERE t.id = \(orderId) AND (\(stageWhere(s)))") > 0 { return s }
        }
        return .awaitAdvance
    }

    // ── универсальный CRUD ──

    func lookupTable(_ kind: FieldKind) -> (String, String)? {
        switch kind {
        case .lookupClient: return ("clients", "denumire")
        case .lookupDeal: return ("deals", "title")
        case .lookupItem: return ("items", "name")
        case .lookupProject: return ("projects", "name")
        default: return nil
        }
    }

    func list(_ def: EntityDef, filter: String = "", extraWhere: String = "") -> [EntityRow] {
        var cols = "t.id"
        for f in def.fields {
            cols += ", t.\(f.name)"
            if let (lt, ld) = lookupTable(f.kind) {
                cols += ", (SELECT \(ld) FROM \(lt) x WHERE x.id = t.\(f.name)) AS \(f.name)__disp"
            }
        }
        var whereParts: [String] = []
        var params: [Any?] = []
        if !filter.isEmpty && !def.searchCols.isEmpty {
            let parts = def.searchCols.split(separator: ",").map { "t.\($0.trimmingCharacters(in: .whitespaces)) LIKE ?" }
            whereParts.append("(" + parts.joined(separator: " OR ") + ")")
            params = Array(repeating: "%" + filter + "%", count: parts.count)
        }
        if !extraWhere.isEmpty { whereParts.append("(" + extraWhere + ")") }
        var sql = "SELECT \(cols) FROM \(def.table) t"
        if !whereParts.isEmpty { sql += " WHERE " + whereParts.joined(separator: " AND ") }
        if !def.orderBy.isEmpty { sql += " ORDER BY " + def.orderBy }
        return db.rows(sql, params).map { r in
            var row = EntityRow(id: r.int("id"))
            for f in def.fields {
                let v = r.str(f.name)
                row.values.append(v)
                switch f.kind {
                case .lookupClient, .lookupDeal, .lookupItem, .lookupProject:
                    row.display.append(r.str(f.name + "__disp"))
                case .enum:
                    row.display.append(enumDisplay(f.enumName, v, f.enumValues))
                case .bool:
                    row.display.append(v == "1" ? "Да" : "")
                case .money, .readOnly:
                    row.display.append(fmtMoney(toDouble(v) ?? 0))
                case .infoText:
                    // дата регистрации показывается без секунд
                    row.display.append(v.count >= 16 && v.contains(":") ? String(v.prefix(16)) : v)
                default:
                    row.display.append(v)
                }
            }
            return row
        }
    }

    func get(_ def: EntityDef, _ id: Int) -> EntityRow? {
        let rows = list(def, extraWhere: "t.id = \(id)")
        return rows.count == 1 ? rows[0] : nil
    }

    private func bindValue(_ f: FieldDef, _ v: String) -> Any? {
        if v.isEmpty && f.kind.isLookup { return nil }          // NULL для пустой ссылки
        if v.isEmpty && f.kind.isNumeric { return nil }          // пустое число — NULL
        if !v.isEmpty && f.kind.isNumeric { return toDouble(v) ?? 0 }
        return v
    }

    @discardableResult
    func insert(_ def: EntityDef, _ values: [String]) -> Int {
        var cols: [String] = [], pars: [Any?] = []
        for (i, f) in def.fields.enumerated() where !f.kind.isCalculated {
            cols.append(f.name)
            pars.append(bindValue(f, i < values.count ? values[i] : ""))
        }
        if def.table == "users" {
            // pass_hash объявлен NOT NULL: новый сотрудник получает стандартный
            // пароль, администратор называет его человеку (кнопка «Сбросить пароль»)
            let login = (def.index(of: "login").map { $0 < values.count ? values[$0] : "" } ?? "").trimmed
            cols.append("pass_hash"); pars.append(passHash(login, STANDARD_PASSWORD))
            cols.append("pass_state"); pars.append(PASS_STD)
        }
        let sql = "INSERT INTO \(def.table) (\(cols.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ", ")))"
        guard db.run(sql, pars) else { return 0 }
        let id = db.lastInsertId
        if def.table == "tasks" {
            db.run("UPDATE tasks SET done = CASE WHEN stage = 'Готово' THEN 1 ELSE COALESCE(done,0) END, stage = CASE WHEN COALESCE(done,0) = 1 AND COALESCE(stage,'') <> 'Готово' THEN 'Готово' ELSE stage END WHERE id = ?", [id])
        }
        return id
    }

    func update(_ def: EntityDef, _ id: Int, _ values: [String]) {
        // имя сотрудника лежит в задачах и проектах текстом: переименование
        // должно дойти и туда, иначе отчёт по людям раздвоится
        let oldName = def.table == "users" ? db.scalarString("SELECT COALESCE(full_name,'') FROM users WHERE id = \(id)") : ""
        var sets: [String] = [], pars: [Any?] = []
        for (i, f) in def.fields.enumerated() where !f.kind.isCalculated {
            sets.append("\(f.name) = ?")
            pars.append(bindValue(f, i < values.count ? values[i] : ""))
        }
        pars.append(id)
        db.run("UPDATE \(def.table) SET \(sets.joined(separator: ", ")) WHERE id = ?", pars)
        if def.table == "users" {
            db.run("UPDATE users SET updated_at = datetime('now','localtime') WHERE id = ?", [id])
            if let i = def.index(of: "full_name"), i < values.count { renameStaff(oldName, values[i].trimmed) }
        }
        // задача: этап и флаг «выполнено» — одно состояние, этап главнее
        if def.table == "tasks" {
            db.run("UPDATE tasks SET done = CASE WHEN stage = 'Готово' THEN 1 ELSE 0 END WHERE id = ?", [id])
        }
    }

    func delete(_ def: EntityDef, _ id: Int) {
        if def.table == "orders" { db.run("DELETE FROM order_lines WHERE order_id = ?", [id]) }
        if def.table == "projects" {
            // задачи проекта уходят вместе с ним; заказы остаются, ссылка снимается
            db.run("DELETE FROM tasks WHERE project_id = ?", [id])
            db.run("UPDATE orders SET project_id = NULL WHERE project_id = ?", [id])
        }
        db.run("DELETE FROM \(def.table) WHERE id = ?", [id])
    }

    /// Псевдоним t обязателен: условия этапов и пресетов написаны через «t.».
    func count(_ table: String, _ whereClause: String = "") -> Int {
        db.scalarInt("SELECT COUNT(*) FROM \(table) t" + (whereClause.isEmpty ? "" : " WHERE " + whereClause))
    }

    func scalarInt(_ sql: String) -> Int { db.scalarInt(sql) }
    func scalarDouble(_ sql: String) -> Double { db.scalarDouble(sql) }
    func scalarString(_ sql: String) -> String { db.scalarString(sql) }
    func rows(_ sql: String) -> [DBRow] { db.rows(sql) }

    func lookupPairs(_ kind: FieldKind) -> [(Int, String)] {
        guard let (lt, ld) = lookupTable(kind) else { return [] }
        return db.rows("SELECT id, \(ld) AS d FROM \(lt) ORDER BY \(ld)").map { ($0.int("id"), $0.str("d")) }
    }

    // ── строки заказа ──

    func orderLines(_ orderId: Int) -> [OrderLine] {
        db.rows("""
        SELECT l.id, l.item_id, i.name, i.unit_, l.qty, l.price, l.sum
        FROM order_lines l LEFT JOIN items i ON i.id = l.item_id WHERE l.order_id = ? ORDER BY l.id
        """, [orderId]).map {
            OrderLine(id: $0.int("id"), itemId: $0.int("item_id"), itemName: $0.str("name"), unit: $0.str("unit_"),
                      qty: $0.dbl("qty"), price: $0.dbl("price"), sum: $0.dbl("sum"))
        }
    }

    func addOrderLine(_ orderId: Int, _ itemId: Int, _ qty: Double, _ price: Double) {
        db.run("INSERT INTO order_lines (order_id, item_id, qty, price, sum) VALUES (?, ?, ?, ?, ?)",
               [orderId, itemId, qty, price, qty * price])
        recalcOrderTotal(orderId)
    }

    func deleteOrderLine(_ lineId: Int) {
        let orderId = db.scalarInt("SELECT order_id FROM order_lines WHERE id = \(lineId)")
        db.run("DELETE FROM order_lines WHERE id = ?", [lineId])
        if orderId > 0 { recalcOrderTotal(orderId) }
    }

    @discardableResult
    func recalcOrderTotal(_ orderId: Int) -> Double {
        let t = db.scalarDouble("SELECT COALESCE(SUM(sum), 0) FROM order_lines WHERE order_id = \(orderId)")
        db.run("UPDATE orders SET total = ? WHERE id = ?", [t, orderId])
        return t
    }

    /// Проводка заказа: продажа списывает остаток, производство приходует
    /// изделия, услуги остатки не трогают. Возвращает описание для строки сообщений.
    func postOrder(_ orderId: Int) -> String {
        let kind = db.scalarString("SELECT kind FROM orders WHERE id = \(orderId)")
        let status = db.scalarString("SELECT status FROM orders WHERE id = \(orderId)")
        let posted = db.scalarInt("SELECT posted FROM orders WHERE id = \(orderId)")
        if posted == 1 { return "уже проведён" }
        if !(status == "Выполнен" || status == "Оплачен") {
            return "проводится только со статусом «Выполнен» или «Оплачен»"
        }
        let sign: Int = kind == "Продажа" ? -1 : (kind == "Производство" ? 1 : 0)
        let lines = orderLines(orderId)
        if lines.isEmpty { return "нет строк" }
        for l in lines where sign != 0 {
            db.run("UPDATE items SET stock = COALESCE(stock,0) + ? WHERE id = ?", [Double(sign) * l.qty, l.itemId])
        }
        db.run("UPDATE orders SET posted = 1 WHERE id = ?", [orderId])
        switch sign {
        case -1: return "списано со склада по \(lines.count) строкам"
        case 1: return "оприходовано изделий по \(lines.count) строкам"
        default: return "услуги — остатки без изменений"
        }
    }

    /// Лид → клиент: всегда вставляет нового клиента, повторный вызов отклоняется.
    func convertLead(_ leadId: Int) -> (String, Int) {
        guard let row = get(DefLeads, leadId) else { return ("лид не найден", 0) }
        let name = row.values[0], company = row.values[1]
        let phone = row.values[4], email = row.values[5]
        if row.values[2] == "Конвертирован" { return ("уже конвертирован", 0) }
        let den = company.isEmpty ? name : company
        db.run("INSERT INTO clients (denumire, contact_person, phone, email, client_type, source) VALUES (?, ?, ?, ?, ?, ?)",
               [den, name, phone, email, "Клиент", "lead"])
        let clientId = db.lastInsertId
        db.run("UPDATE leads SET status = ?, client_id = ? WHERE id = ?", ["Конвертирован", clientId, leadId])
        return ("создан клиент «\(den)»", clientId)
    }
}
