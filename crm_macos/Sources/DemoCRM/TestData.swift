// Генератор тестовых данных и DML-тест всех сущностей CRM (аналог
// uTestData.pas — наборы названий и сумм взяты оттуда как есть, чтобы базы,
// засеянные на Windows и на Mac, совпадали по содержанию).
//
//   --seed-demo [база]  — наполнить базу полным набором записей; повторный
//                         запуск не дублирует: клиенты — по IDNO, остальное —
//                         по имени/№.
//   --dml-test          — INSERT → SELECT → UPDATE → SELECT → DELETE → COUNT
//                         для каждой сущности, строки заказа, проводка,
//                         конвертация лида, дедупликация, отчёты.
import Foundation

struct SeedStats {
    var clients = 0, contacts = 0, leads = 0, deals = 0, items = 0, orders = 0, lines = 0, tasks = 0, projects = 0, projectTasks = 0
    var staff = 0
    var text: String {
        "клиентов \(clients), контактов \(contacts), лидов \(leads), сделок \(deals), номенклатуры \(items), заказов \(orders) (строк \(lines)), задач \(tasks), проектов \(projects) (задач по проектам \(projectTasks)), сотрудников \(staff)"
    }
}

/// Проверка выгрузки по сигнатуре файла, а не по расширению.
func headOf(_ fileName: String, _ count: Int) -> [UInt8] {
    guard let h = FileHandle(forReadingAtPath: fileName) else { return [] }
    defer { h.closeFile() }
    return Array(h.readData(ofLength: count))
}
func isZipFile(_ f: String) -> Bool { let b = headOf(f, 2); return b.count == 2 && b[0] == 0x50 && b[1] == 0x4B }
func isPdfFile(_ f: String) -> Bool { let b = headOf(f, 4); return b == [0x25, 0x50, 0x44, 0x46] }

// ── справочные наборы ──

private struct Company {
    let idno, name, form, addr, admin, ctype, phone, email: String
}

private let COMPANIES: [Company] = [
    Company(idno: "1003600116460", name: "CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Alba-Iulia 75/B", admin: "TUHARI PAVEL [Administrator]", ctype: "Партнёр", phone: "+373 22 590-100", email: "office@unisim.md"),
    Company(idno: "1017600018242", name: "Societatea cu Răspundere Limitată ALFA-VIS COM", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, sec. Centru, str. Alecsandri Vasile, 80", admin: "BUBIS YEVGENY [Administrator]", ctype: "Клиент", phone: "+373 22 123-456", email: "office@alfa-vis.md"),
    Company(idno: "1002600021871", name: "AGRO-PRIM S.R.L.", form: "Societate cu răspundere limitată", addr: "r-l Ialoveni, s. Costeşti, str. Ştefan cel Mare 12", admin: "POPESCU ION [Administrator]", ctype: "Клиент", phone: "+373 79 111-222", email: "ion@agro-prim.md"),
    Company(idno: "1004600045213", name: "MOLDTEHNICA S.A.", form: "Societate pe acţiuni", addr: "mun. Chişinău, bd. Dacia 49/3", admin: "RUSU ANDREI [Director]", ctype: "Поставщик", phone: "+373 22 771-234", email: "sales@moldtehnica.md"),
    Company(idno: "1008600009874", name: "PANIFICATIE BĂLŢI S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Bălţi, str. Decebal 101", admin: "CEBAN MARIA [Administrator]", ctype: "Клиент", phone: "+373 231 22-333", email: "panificatie@balti.md"),
    Company(idno: "1011600032557", name: "VINĂRIA CAHUL S.R.L.", form: "Societate cu răspundere limitată", addr: "or. Cahul, str. Ştefan cel Mare 8", admin: "MUNTEANU VASILE [Administrator]", ctype: "Клиент", phone: "+373 299 33-444", email: "export@vinaria-cahul.md"),
    Company(idno: "1013600001988", name: "ELECTROMONTAJ-SERVICE S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Uzinelor 21", admin: "GROSU DUMITRU [Administrator]", ctype: "Поставщик", phone: "+373 22 470-111", email: "info@electromontaj.md"),
    Company(idno: "1015600078123", name: "Î.I. „CROITORU TATIANA”", form: "Întreprindere individuală", addr: "or. Orhei, str. Vasile Lupu 33", admin: "CROITORU TATIANA [Fondator]", ctype: "Клиент", phone: "+373 235 21-100", email: "tatiana.croitoru@mail.md"),
    Company(idno: "1016600054321", name: "LOGISTIC-TRANS GRUP S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Munceşti 271", admin: "LUNGU SERGIU [Administrator]", ctype: "Партнёр", phone: "+373 22 522-900", email: "dispatch@logistic-trans.md"),
    Company(idno: "1018600011200", name: "FARM-PLUS S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Ismail 98", admin: "CIOBANU ELENA [Administrator]", ctype: "Клиент", phone: "+373 22 210-321", email: "farm-plus@mail.md"),
    Company(idno: "1019600093456", name: "METAL-CONSTRUCT S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Petricani 19", admin: "BOTNARI VICTOR [Administrator]", ctype: "Клиент", phone: "+373 22 440-505", email: "office@metal-construct.md"),
    Company(idno: "1020600024680", name: "IT-SOLUTIONS MOLDOVA S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Puşkin 47", admin: "CODREANU ALEXANDRU [Administrator]", ctype: "Партнёр", phone: "+373 22 888-777", email: "hello@itsolutions.md"),
    Company(idno: "1021600036912", name: "MOBILA-DESIGN S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Industrială 40", admin: "SÎRBU LILIANA [Administrator]", ctype: "Клиент", phone: "+373 22 610-202", email: "sales@mobila-design.md"),
    Company(idno: "1022600048135", name: "AUTO-SERVICE EXPRESS S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Bălţi, str. Ştefan cel Mare 180", admin: "ROTARU IGOR [Administrator]", ctype: "Клиент", phone: "+373 231 44-555", email: "service@auto-express.md"),
    Company(idno: "1023600059246", name: "GOSPODARIA ŢĂRĂNEASCĂ „SPICUL”", form: "Gospodărie ţărănească", addr: "r-l Cahul, s. Manta", admin: "BURLACU PETRU [Fondator]", ctype: "Клиент", phone: "+373 299 55-666", email: ""),
]

private let CONTACT_NAMES = ["Ion Popescu", "Maria Ceban", "Andrei Rusu", "Elena Ciobanu", "Victor Botnari",
    "Liliana Sîrbu", "Igor Rotaru", "Alexandru Codreanu", "Tatiana Croitoru", "Sergiu Lungu",
    "Dumitru Grosu", "Vasile Munteanu", "Natalia Guţu", "Oleg Ţurcanu", "Ana Moraru", "Pavel Tuhari"]
private let POSITIONS = ["Директор", "Главный бухгалтер", "Менеджер по закупкам", "Технический директор", "Логист", "Коммерческий директор"]

private let LEAD_COMPANIES = ["Brutăria Codru SRL", "Ferma Eco-Lapte", "Salon Auto Nord", "Clinica Dental-Plus",
    "Hotel Nistru", "Tipografia Grafic-Art", "Pescăria Dunărea", "Apicultura Moldova",
    "Şcoala de şoferi Start", "Cafeneaua Tucano", "Atelier Textil Lux", "Serviciul IT Nord"]
private let LEAD_PERSONS = ["Radu Cojocaru", "Diana Bejan", "Mihai Ursu", "Cristina Postolachi", "Valeriu Chirilă",
    "Irina Frunză", "Grigore Ţîbîrnă", "Svetlana Roşca", "Nicolae Damian", "Olga Cazacu",
    "Eugen Bivol", "Larisa Stratan"]

private let ITEMS_SEED: [[String]] = [
    ["T-001", "Насос дозирующий ND-25", "Товар", "шт", "12500", "5"],
    ["T-002", "Фильтр тонкой очистки FT-10", "Товар", "шт", "840", "40"],
    ["T-003", "Труба ПВХ 50 мм", "Товар", "м", "95", "320"],
    ["T-004", "Кабель ВВГ 3×2.5", "Товар", "м", "38", "900"],
    ["T-005", "Контроллер PLC-200", "Товар", "шт", "6900", "4"],
    ["T-006", "Датчик уровня LS-3", "Товар", "шт", "1450", "12"],
    ["T-007", "Мука пшеничная в/с", "Товар", "кг", "9.5", "2500"],
    ["T-008", "Масло подсолнечное рафин.", "Товар", "л", "31", "600"],
    ["S-001", "Монтаж и пусконаладка", "Услуга", "час", "350", "0"],
    ["S-002", "Сервисное обслуживание (выезд)", "Услуга", "услуга", "900", "0"],
    ["S-003", "Проектирование", "Услуга", "час", "500", "0"],
    ["S-004", "Доставка по Кишинёву", "Услуга", "услуга", "250", "0"],
    ["S-005", "Консультация бухгалтера", "Услуга", "час", "400", "0"],
    ["P-001", "Установка дозирования УД-1", "Изделие", "компл", "42000", "0"],
    ["P-002", "Шкаф управления ШУ-2", "Изделие", "шт", "18500", "1"],
    ["P-003", "Хлеб «Домашний» 0,6 кг", "Изделие", "шт", "14", "0"],
    ["P-004", "Стол офисный СО-120", "Изделие", "шт", "3200", "3"],
    ["P-005", "Ворота металлические 3×2", "Изделие", "компл", "15800", "0"],
]

private let STAGES = ["Новая", "Предложение", "Переговоры", "Выиграна", "Проиграна"]
private let DEAL_TITLES = ["Поставка дозирующей установки", "Автоматизация линии розлива", "Шкафы управления для цеха",
    "Сервисный контракт на год", "Мебель для офиса", "Ворота и ограждение склада",
    "Хлебопекарная линия — модернизация", "Проект электроснабжения", "Поставка кабеля и щитов",
    "Консалтинг по учёту", "Доставка продукции сетям", "Датчики уровня для резервуаров"]
private let TASK_SUBJECTS = ["Позвонить по оплате заказа", "Отправить коммерческое предложение", "Встреча: согласование ТЗ",
    "Выезд на объект — замеры", "Согласовать график поставки", "Подготовить договор",
    "Напомнить об акте выполненных работ", "Презентация продукции", "Уточнить реквизиты",
    "Контроль отгрузки"]

// ── проекты: единичные изделия под заказ (gravura.md, BM Public) ──
private struct ProjectSeed {
    let name: String
    let clientIdx: Int
    let kind, status, tender: String
    let budget, prepayPct: Int
    let startOff, dueOff: Int
    let manager, notes: String
}

private let PARTNERS: [Company] = [
    Company(idno: "1010600044123", name: "GRAVURA.MD S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Uzinelor 19", admin: "ROŞCA DENIS [Administrator]", ctype: "Партнёр", phone: "+373 22 000-111", email: "office@gravura.md"),
    Company(idno: "1009600037654", name: "BM PUBLIC S.R.L.", form: "Societate cu răspundere limitată", addr: "mun. Chişinău, str. Calea Ieşilor 10", admin: "BOTNARI MARIN [Administrator]", ctype: "Партнёр", phone: "+373 22 000-222", email: "office@bmpublic.md"),
]

private let PROJECTS_SEED: [ProjectSeed] = [
    ProjectSeed(name: "Панно с логотипом на стену 3×1,5 м (акрил, подсветка)", clientIdx: 11, kind: "Реклама", status: "Производство", tender: "T-2026-014", budget: 48000, prepayPct: 50, startOff: -20, dueOff: 10, manager: "Ion Popescu", notes: "Тендер IT-Solutions: панно в холле офиса. Производство — партнёр BM PUBLIC (фрезеровка, объёмные буквы, LED)."),
    ProjectSeed(name: "Таблички с выжигом поздравлений, дуб, 200 шт. (юбилей)", clientIdx: 3, kind: "Гравировка", status: "Дизайн", tender: "T-2026-021", budget: 36000, prepayPct: 0, startOff: -7, dueOff: 21, manager: "Maria Ceban", notes: "Без аванса: по условиям тендера оплата после сдачи. Выжиг и лазер — партнёр GRAVURA.MD."),
    ProjectSeed(name: "Гравировка подарочных ручек и ежедневников, 500 шт.", clientIdx: 5, kind: "Сувениры", status: "Закрыт", tender: "", budget: 22500, prepayPct: 30, startOff: -60, dueOff: -25, manager: "Ion Popescu", notes: "Без тендера, прямой заказ. Сдан и оплачен полностью."),
    ProjectSeed(name: "Световой короб на фасад магазина 4×1 м", clientIdx: 12, kind: "Реклама", status: "Проигран", tender: "T-2026-009", budget: 61000, prepayPct: 40, startOff: -30, dueOff: 5, manager: "Ion Popescu", notes: "Тендер проигран по цене — заявка сохранена для следующего раза."),
    ProjectSeed(name: "Брендирование автомобиля доставки (плёнка, логотип)", clientIdx: 4, kind: "Реклама", status: "Аванс", tender: "T-2026-027", budget: 18900, prepayPct: 50, startOff: -3, dueOff: 14, manager: "Ion Popescu", notes: "Договор подписан, ждём аванс 50 % — работы начнутся после поступления."),
    ProjectSeed(name: "Деревянные медали с гравировкой для марафона, 1 200 шт.", clientIdx: 9, kind: "Сувениры", status: "Оплата", tender: "T-2026-016", budget: 54000, prepayPct: 30, startOff: -35, dueOff: -2, manager: "Maria Ceban", notes: "Сдано по акту, ждём остаток оплаты 70 %. Гравировка — GRAVURA.MD."),
    ProjectSeed(name: "Выставочный стенд Moldexpo 6×3 м с панно и подсветкой", clientIdx: 10, kind: "Монтаж", status: "Производство", tender: "T-2026-019", budget: 96000, prepayPct: 50, startOff: -25, dueOff: -3, manager: "Victor Botnari", notes: "Запаздывает: срок сдачи прошёл, конструкция ещё в производстве. Монтаж — BM PUBLIC."),
    ProjectSeed(name: "Панно-табличка ресторана из дуба с логотипом (лазер)", clientIdx: 7, kind: "Гравировка", status: "Договор", tender: "", budget: 9800, prepayPct: 50, startOff: 0, dueOff: 18, manager: "Andrei Rusu", notes: "Прямой заказ, договор на подписи; аванс 50 %."),
    ProjectSeed(name: "Наградные доски и кубки с гравировкой (конкурс)", clientIdx: 0, kind: "Сувениры", status: "Тендер", tender: "T-2026-031", budget: 27000, prepayPct: 30, startOff: 2, dueOff: 40, manager: "Maria Ceban", notes: "Заявка подана, вскрытие предложений через 5 дней."),
    ProjectSeed(name: "Вывеска и панно на входе (композит + объёмные буквы)", clientIdx: 2, kind: "Реклама", status: "Сдача", tender: "T-2026-012", budget: 74500, prepayPct: 50, startOff: -40, dueOff: 1, manager: "Victor Botnari", notes: "Смонтировано, назначена приёмка и подписание акта."),
]

// шаги проекта: тема, исполнитель, часы; шаг 7 зависит от вида проекта
// Сотрудники демо-фирмы: те же люди, что стоят исполнителями в задачах и
// менеджерами в проектах, — иначе отчёт по людям окажется пустым.
// Пароль у всех стандартный (STANDARD_PASSWORD), последний — отключённый
// счёт: на нём видно, что уволенный не войдёт, но остаётся в истории задач.
private struct StaffSeed {
    let name, login, position, role, email, phone: String
    let active: Bool
}

private let STAFF: [StaffSeed] = [
    StaffSeed(name: "Natalia Guţu", login: "ngutu", position: "Директор", role: "Руководитель",
              email: "director@demo.md", phone: "+373 69 100 100", active: true),
    StaffSeed(name: "Ion Popescu", login: "ipopescu", position: "Менеджер по продажам", role: "Коммерческий",
              email: "ion.popescu@demo.md", phone: "+373 69 100 101", active: true),
    StaffSeed(name: "Maria Ceban", login: "mceban", position: "Дизайнер", role: "Коммерческий",
              email: "maria.ceban@demo.md", phone: "+373 69 100 102", active: true),
    StaffSeed(name: "Andrei Rusu", login: "arusu", position: "Мастер производства", role: "Производство",
              email: "andrei.rusu@demo.md", phone: "+373 69 100 103", active: true),
    StaffSeed(name: "Victor Botnari", login: "vbotnari", position: "Начальник монтажа", role: "Производство",
              email: "victor.botnari@demo.md", phone: "+373 69 100 104", active: true),
    StaffSeed(name: "Elena Ciobanu", login: "eciobanu", position: "Главный бухгалтер", role: "Бухгалтерия",
              email: "elena.ciobanu@demo.md", phone: "+373 69 100 105", active: true),
    StaffSeed(name: "Sergiu Lungu", login: "slungu", position: "Кладовщик", role: "Склад",
              email: "sergiu.lungu@demo.md", phone: "+373 69 100 106", active: true),
    StaffSeed(name: "Oleg Ţurcanu", login: "oturcanu", position: "Менеджер (уволен)", role: "Наблюдатель",
              email: "oleg.turcanu@demo.md", phone: "+373 69 100 107", active: false),
]

private let PROJECT_STEPS: [[String]] = [
    ["Подготовка тендерной заявки", "Ion Popescu", "4"],
    ["Договор и спецификация", "Ion Popescu", "3"],
    ["Счёт на аванс и контроль оплаты", "Elena Ciobanu", "1"],
    ["Дизайн-макет", "Maria Ceban", "8"],
    ["Согласование макета с клиентом", "Ion Popescu", "2"],
    ["Закупка материалов", "Victor Botnari", "3"],
    ["Производство", "Andrei Rusu", "16"],
    ["Контроль качества", "Andrei Rusu", "2"],
    ["Монтаж / доставка", "Victor Botnari", "6"],
    ["Сдача работ и акт", "Ion Popescu", "1"],
    ["Итоговый счёт и закрытие оплаты", "Elena Ciobanu", "1"],
]
private let PROJECT_ITEMS: [[String]] = [
    ["P-101", "Панно с логотипом (изделие под заказ)", "Изделие", "шт", "1", "0"],
    ["P-102", "Табличка с гравировкой / выжигом, дерево", "Изделие", "шт", "1", "0"],
    ["P-103", "Стенд выставочный (изделие под заказ)", "Изделие", "компл", "1", "0"],
]

/// Сколько шагов проекта уже готово на данном этапе.
private func doneStepsFor(_ status: String) -> Int {
    switch status {
    case "Тендер": return 0
    case "Договор": return 1
    case "Аванс": return 2
    case "Дизайн": return 3
    case "Производство": return 6
    case "Сдача": return 9
    case "Оплата": return 10
    case "Закрыт": return 11
    default: return 1   // проигран: заявка подана, дальше не пошли
    }
}

private func productionStep(_ kind: String) -> (String, String, String) {
    switch kind {
    case "Реклама": return ("Резка ЧПУ, сборка панно, покраска", "Victor Botnari", "24")
    case "Гравировка": return ("Лазерная гравировка и выжиг", "Andrei Rusu", "16")
    case "Сувениры": return ("Гравировка партии и упаковка", "Andrei Rusu", "20")
    case "Монтаж": return ("Изготовление конструкции стенда", "Victor Botnari", "40")
    default: return ("Производство", "Andrei Rusu", "16")
    }
}

/// Значения по описанию сущности: умолчания + пары «поле, значение».
func vals(_ def: EntityDef, _ pairs: [String]) -> [String] {
    var r = def.fields.map { resolveDefault($0.defaultValue) }
    var i = 0
    while i < pairs.count - 1 {
        guard let idx = def.index(of: pairs[i]) else { fatalError("Нет поля \(pairs[i]) в \(def.table)") }
        r[idx] = pairs[i + 1]
        i += 2
    }
    return r
}

private func exists(_ data: CrmData, _ table: String, _ whereSql: String) -> Bool { data.count(table, whereSql) > 0 }
private func Q(_ s: String) -> String { quoted(s) }

private func cardFor(_ c: Company, inregistrare: String) -> CounterpartyCard {
    var card = CounterpartyCard()
    card.idno = c.idno; card.denumire = c.name; card.formaJuridica = c.form
    card.adresa = c.addr; card.administratori = c.admin; card.lichidata = "Nu"
    card.inregistrare = inregistrare
    card.detailsText = "=== Date de bază ===\r\nIDNO/Cod Fiscal: \(c.idno)\r\nDenumire: \(c.name)\r\nAdresa juridică: \(c.addr)"
    return card
}

// ── генератор ──

func seedDemo(_ db: ClientsDB, _ data: CrmData) -> SeedStats {
    var st = SeedStats()
    data.ensureSchema()
    let conn = data.db

    // сотрудники: администратор + люди, которые стоят в задачах и проектах
    data.ensureAdmin()
    for p in STAFF where !exists(data, "users", "login = \(Q(p.login))") {
        data.insert(DefUsers, vals(DefUsers, [
            "full_name", p.name, "login", p.login, "position", p.position, "role", p.role,
            "email", p.email, "phone", p.phone, "active", p.active ? "1" : "0",
            "erp_code", "", "notes", p.active ? "" : "Счёт отключён: сотрудник уволен."]))
        st.staff += 1
    }

    // клиенты — через тот же путь, что и SDK (addFromCard), дедупликация по IDNO
    var clientIds: [Int] = []
    for (i, c) in COMPANIES.enumerated() {
        let card = cardFor(c, inregistrare: String(format: "%02d.%02d.20%02d", 1 + i, 1 + (i % 12), 5 + i))
        if db.addFromCard(card).0 == .added { st.clients += 1 }
        let clientId = conn.scalarInt("SELECT id FROM clients WHERE idno = \(Q(c.idno))")
        conn.run("UPDATE clients SET client_type = ?, phone = ?, email = ?, contact_person = ? WHERE id = ? AND (client_type IS NULL OR client_type = '')",
                 [c.ctype, c.phone, c.email, CONTACT_NAMES[i % CONTACT_NAMES.count], clientId])
        clientIds.append(clientId)
    }

    // контакты — по 2 у первых 10 клиентов
    for i in 0..<10 {
        for j in 0..<2 {
            let n = (i * 2 + j) % CONTACT_NAMES.count
            if !exists(data, "contacts", "name = \(Q(CONTACT_NAMES[n])) AND client_id = \(clientIds[i])") {
                data.insert(DefContacts, vals(DefContacts, ["name", CONTACT_NAMES[n],
                    "client_id", String(clientIds[i]), "position", POSITIONS[(i + j) % POSITIONS.count],
                    "phone", String(format: "+373 6%d %03d-%03d", i % 10, 100 + i * 7, 200 + j * 33),
                    "email", CONTACT_NAMES[n].lowercased().replacingOccurrences(of: " ", with: ".") + "@example.md",
                    "notes", j == 0 ? "Основной контакт" : ""]))
                st.contacts += 1
            }
        }
    }

    // лиды — все статусы и источники
    for i in 0..<LEAD_COMPANIES.count where !exists(data, "leads", "company = \(Q(LEAD_COMPANIES[i]))") {
        let domain = LEAD_COMPANIES[i].replacingOccurrences(of: " ", with: "").left(8).lowercased()
        data.insert(DefLeads, vals(DefLeads, ["name", LEAD_PERSONS[i], "company", LEAD_COMPANIES[i],
            "status", splitEnum(ENUM_LEAD_STATUS)[i % 4],
            "source", splitEnum(ENUM_LEAD_SOURCE)[i % 6],
            "phone", String(format: "+373 7%d %03d-%03d", i % 10, 300 + i * 5, 400 + i * 9),
            "email", "contact\(i + 1)@\(domain).md",
            "notes", "Первичный интерес: " + DEAL_TITLES[i % DEAL_TITLES.count]]))
        st.leads += 1
    }

    // сделки — по всем этапам, суммы 5 000 … 250 000
    for i in 0..<DEAL_TITLES.count where !exists(data, "deals", "title = \(Q(DEAL_TITLES[i]))") {
        data.insert(DefDeals, vals(DefDeals, ["title", DEAL_TITLES[i],
            "client_id", String(clientIds[(i * 3) % clientIds.count]),
            "stage", STAGES[i % 5], "amount", String(5000 + i * 21000),
            "close_date", D(7 + i * 6), "notes", i % 5 == 3 ? "Договор подписан" : ""]))
        st.deals += 1
    }

    // номенклатура
    var itemIds: [Int] = [], itemPrices: [Double] = []
    for it in ITEMS_SEED {
        if !exists(data, "items", "code = \(Q(it[0]))") {
            data.insert(DefItems, vals(DefItems, ["code", it[0], "name", it[1], "kind", it[2], "unit_", it[3],
                "price", it[4], "vat", "20", "stock", it[5], "notes", ""]))
            st.items += 1
        }
        itemIds.append(conn.scalarInt("SELECT id FROM items WHERE code = \(Q(it[0]))"))
        itemPrices.append(Double(it[4]) ?? 0)
    }

    // заказы — 18 штук: продажа / услуга / производство, все статусы, 1–3 строки
    for i in 0..<18 {
        let num = String(format: "%04d", i + 1)
        if exists(data, "orders", "number = \(Q(num))") { continue }
        let kind = splitEnum(ENUM_ORDER_KIND)[i % 3]
        let status = splitEnum(ENUM_ORDER_STATUS)[i % 6]
        let orderId = data.insert(DefOrders, vals(DefOrders, ["number", num, "order_date", D(-40 + i * 2),
            "client_id", kind == "Производство" ? "" : String(clientIds[(i * 5) % clientIds.count]),
            "kind", kind, "status", status,
            // срок: часть заказов намеренно просрочена, чтобы плитки показывали запаздывание
            "due_date", D(-40 + i * 2 + (i % 4 == 1 ? 5 : 25)),
            "notes", i % 4 == 0 ? "Срочный" : ""]))
        st.orders += 1
        for j in 0...(i % 3) {
            let n: Int
            if kind == "Продажа" { n = (i + j) % 8 }
            else if kind == "Услуга" { n = 8 + (i + j) % 5 }
            else { n = 13 + (i + j) % 5 }
            data.addOrderLine(orderId, itemIds[n], Double(1 + (i + j) % 4), itemPrices[n])
            st.lines += 1
        }
        if status == "Выполнен" || status == "Оплачен" { _ = data.postOrder(orderId) }

        // деньги и отгрузка проставляются после строк: сумма заказа уже известна
        let total = conn.scalarDouble("SELECT COALESCE(total,0) FROM orders WHERE id = \(orderId)")
        if status == "Подтверждён" {
            if (i / 6) % 2 == 0 {
                conn.run("UPDATE orders SET advance = 0 WHERE id = ?", [orderId])
            } else {
                conn.run("UPDATE orders SET advance = ? WHERE id = ?", [money2(total * 0.3), orderId])
            }
        } else if status == "В работе" {
            conn.run("UPDATE orders SET advance = ? WHERE id = ?", [money2(total * 0.5), orderId])
        } else if status == "Выполнен" {
            if i / 6 == 0 {
                conn.run("UPDATE orders SET advance = ? WHERE id = ?", [money2(total * 0.4), orderId])
            } else {
                conn.run("UPDATE orders SET advance = ?, paid = ?, ship_date = ? WHERE id = ?",
                         [money2(total * 0.4), money2(total * 0.4), D(-40 + i * 2 + 20), orderId])
            }
        } else if status == "Оплачен" {
            conn.run("UPDATE orders SET advance = ?, paid = ?, ship_date = ? WHERE id = ?",
                     [money2(total * 0.5), total, D(-40 + i * 2 + 15), orderId])
        }
    }

    // заказы, созданные до появления полей процесса, дополняются здесь
    let old = conn.rows("SELECT id, status, COALESCE(total,0) AS total FROM orders WHERE COALESCE(due_date,'') = ''")
    for (i, r) in old.enumerated() {
        let id = r.int("id"), status = r.str("status"), total = r.dbl("total")
        conn.run("UPDATE orders SET due_date = ? WHERE id = ?", [D(i % 4 == 1 ? -3 : 12), id])
        if status == "Подтверждён" {
            conn.run("UPDATE orders SET advance = ? WHERE id = ?", [i % 2 == 0 ? 0 : money2(total * 0.3), id])
        } else if status == "В работе" {
            conn.run("UPDATE orders SET advance = ? WHERE id = ?", [money2(total * 0.5), id])
        } else if status == "Выполнен" {
            if i % 2 == 0 {
                conn.run("UPDATE orders SET advance = ? WHERE id = ?", [money2(total * 0.4), id])
            } else {
                conn.run("UPDATE orders SET advance = ?, paid = ?, ship_date = ? WHERE id = ?",
                         [money2(total * 0.4), money2(total * 0.4), D(-2), id])
            }
        } else if status == "Оплачен" {
            conn.run("UPDATE orders SET advance = ?, paid = ?, ship_date = ? WHERE id = ?",
                     [money2(total * 0.5), total, D(-5), id])
        }
    }

    // задачи — 24: просроченные, сегодня, будущие, часть выполнена
    for i in 0..<24 {
        let subj = TASK_SUBJECTS[i % 10] + " #\(i + 1)"
        if exists(data, "tasks", "subject = \(Q(subj))") { continue }
        var dealId = ""
        if i % 3 == 0 { dealId = conn.scalarString("SELECT id FROM deals ORDER BY id LIMIT 1 OFFSET \(i % 12)") }
        data.insert(DefTasks, vals(DefTasks, [
            "subject", subj,
            "kind", splitEnum(ENUM_TASK_KIND)[i % 3],
            "due_at", D(-6 + i),
            "client_id", String(clientIds[(i * 7) % clientIds.count]),
            "deal_id", dealId,
            "done", i < 4 ? "1" : "0",
            "notes", ""]))
        st.tasks += 1
    }

    // ── проекты: партнёры-производители, изделия, проекты с тендерами и
    //    авансами, задачи по шагам, производственные заказы ──
    for (i, c) in PARTNERS.enumerated() {
        let card = cardFor(c, inregistrare: String(format: "1%d.0%d.20%02d", i + 1, i + 3, 12 + i))
        if db.addFromCard(card).0 == .added { st.clients += 1 }
        let clientId = conn.scalarInt("SELECT id FROM clients WHERE idno = \(Q(c.idno))")
        conn.run("UPDATE clients SET client_type = ?, phone = ?, email = ?, contact_person = ? WHERE id = ? AND (client_type IS NULL OR client_type = '')",
                 [c.ctype, c.phone, c.email, c.admin, clientId])
    }
    for it in PROJECT_ITEMS where !exists(data, "items", "code = \(Q(it[0]))") {
        data.insert(DefItems, vals(DefItems, ["code", it[0], "name", it[1], "kind", it[2], "unit_", it[3],
            "price", it[4], "vat", "20", "stock", it[5], "notes", "Изделие по проекту: цена в строке заказа"]))
        st.items += 1
    }

    for (i, ps) in PROJECTS_SEED.enumerated() {
        if exists(data, "projects", "name = \(Q(ps.name))") { continue }
        let clientId = clientIds[ps.clientIdx]
        // деньги по этапу: аванс с этапа «Аванс», остаток — только у закрытых
        var prepaid = 0.0, paid = 0.0
        if doneStepsFor(ps.status) >= 2 && ps.status != "Проигран" {
            prepaid = bankRound(Double(ps.budget) * Double(ps.prepayPct) / 100)
        }
        if ps.status == "Закрыт" { paid = Double(ps.budget) - prepaid }
        let projectId = data.insert(DefProjects, vals(DefProjects, ["name", ps.name,
            "client_id", String(clientId), "kind", ps.kind, "status", ps.status,
            "tender_no", ps.tender, "tender_deadline", ps.tender.isEmpty ? "" : D(ps.startOff + 5),
            "budget", String(ps.budget), "prepay_pct", String(ps.prepayPct),
            "prepaid", String(Int(prepaid)), "paid", String(Int(paid)),
            "start_date", D(ps.startOff), "due_date", D(ps.dueOff),
            "manager", ps.manager, "notes", ps.notes]))
        st.projects += 1

        // тендер как сделка в воронке
        if !exists(data, "deals", "title = \(Q("Тендер: " + ps.name))") {
            data.insert(DefDeals, vals(DefDeals, ["title", "Тендер: " + ps.name,
                "client_id", String(clientId),
                "stage", ps.status == "Тендер" ? "Предложение" : (ps.status == "Проигран" ? "Проиграна" : "Выиграна"),
                "amount", String(ps.budget), "close_date", D(ps.startOff + 5),
                "notes", ps.tender.isEmpty ? "Прямой заказ" : "Тендер " + ps.tender]))
            st.deals += 1
        }

        // задачи по шагам: план последовательный от начала проекта
        let doneN = doneStepsFor(ps.status)
        var cursor = ps.startOff
        var prevTaskId = 0
        var stepN = 0
        for j in 0..<PROJECT_STEPS.count {
            if j == 2 && ps.prepayPct == 0 { continue }          // без аванса — нет шага аванса
            if ps.status == "Проигран" && j > 1 { break }
            var subj = PROJECT_STEPS[j][0], who = PROJECT_STEPS[j][1], hours = PROJECT_STEPS[j][2]
            if j == 6 { (subj, who, hours) = productionStep(ps.kind) }
            let h = Int(hours) ?? 0
            let days = max(1, Int(ceil(Double(h) / 8)))
            stepN += 1
            let stage: String
            if stepN <= doneN { stage = "Готово" }
            else if stepN == doneN + 1 { stage = ps.status == "Проигран" ? "Ожидание" : "В работе" }
            else { stage = "Новая" }
            var prio = j == 6 ? "Высокий" : (j == 7 ? "Низкий" : "Обычный")
            if stage == "В работе" && cursor + days - 1 < 0 { prio = "Срочно" }   // просрочено
            let taskId = data.insert(DefTasks, vals(DefTasks, [
                "subject", subj, "project_id", String(projectId), "stage", stage, "priority", prio,
                "assignee", who, "kind", j == 4 ? "Встреча" : "Задача",
                "plan_start", D(cursor), "due_at", D(cursor + days - 1),
                "hours_plan", hours, "hours_fact", stage == "Готово" ? String(Int(bankRound(Double(h) * 1.1))) : "",
                "seq", String(stepN), "depends_on", prevTaskId > 0 ? String(prevTaskId) : "",
                "client_id", String(clientId), "done", stage == "Готово" ? "1" : "0",
                "notes", j == 2 ? "Аванс \(ps.prepayPct) % от \(ps.budget) MDL" : ""]))
            st.projectTasks += 1
            prevTaskId = taskId
            cursor += days
        }

        // производственный заказ — с этапа «Производство»
        if ["Производство", "Сдача", "Оплата", "Закрыт"].contains(ps.status) {
            let num = "PR-\(1001 + i)"
            if !exists(data, "orders", "number = \(Q(num))") {
                let oStatus = ps.status == "Производство" ? "В работе" : (ps.status == "Закрыт" ? "Оплачен" : "Выполнен")
                let orderId = data.insert(DefOrders, vals(DefOrders, ["number", num, "order_date", D(ps.startOff),
                    "client_id", String(clientId), "project_id", String(projectId), "kind", "Производство",
                    "status", oStatus, "due_date", D(ps.dueOff), "notes", "По проекту: " + ps.name]))
                let itemN = ps.kind == "Реклама" ? 0 : (ps.kind == "Монтаж" ? 2 : 1)
                data.addOrderLine(orderId, conn.scalarInt("SELECT id FROM items WHERE code = \(Q(PROJECT_ITEMS[itemN][0]))"), 1, Double(ps.budget))
                st.orders += 1; st.lines += 1
                if oStatus != "В работе" { _ = data.postOrder(orderId) }
                conn.run("UPDATE orders SET advance = ?, paid = ?, ship_date = ? WHERE id = ?",
                         [prepaid, paid, (ps.status == "Оплата" || ps.status == "Закрыт") ? D(ps.dueOff) : "", orderId])
            }
        }
    }
    return st
}

// ── DML-тест ──

func runDmlTest(_ db: ClientsDB, _ data: CrmData, _ log: inout [String]) -> Bool {
    var fails = 0
    func check(_ cond: Bool, _ what: String) {
        if cond { log.append("[OK]   " + what) } else { log.append("[FAIL] " + what); fails += 1 }
    }
    func crudCycle(_ def: EntityDef, _ nameField: String, _ ins: [String], _ upd: [String]) {
        let n0 = data.count(def.table)
        let id = data.insert(def, vals(def, ins))
        check(id > 0, "\(def.table): INSERT → id \(id)")
        check(data.count(def.table) == n0 + 1, "\(def.table): COUNT после INSERT = \(n0 + 1)")
        let idx = def.index(of: nameField)!
        check(data.get(def, id)?.values[idx] == ins[1], "\(def.table): SELECT по id возвращает вставленные значения")
        check(data.list(def, filter: ins[1]).count >= 1, "\(def.table): LIST с фильтром «\(ins[1])» находит запись")
        data.update(def, id, vals(def, upd))
        check(data.get(def, id)?.values[idx] == upd[1], "\(def.table): UPDATE → SELECT видит новые значения («\(upd[1])»)")
        data.delete(def, id)
        check(data.get(def, id) == nil, "\(def.table): DELETE → SELECT по id пуст")
        check(data.count(def.table) == n0, "\(def.table): COUNT после DELETE вернулся к \(n0)")
    }

    data.ensureSchema()
    let conn = data.db
    let tmpDir = NSTemporaryDirectory() + "crm_dml_reports"

    // ── клиенты: addFromCard / дубликат / поиск / удаление ──
    var card = CounterpartyCard()
    card.idno = "1099900012345"; card.denumire = "DML-TEST S.R.L."
    card.formaJuridica = "SRL"; card.adresa = "Chişinău, str. Test 1"
    card.administratori = "TEST ION [Administrator]"
    var n = db.count()
    let (res1, id1) = db.addFromCard(card)
    check(res1 == .added, "clients: AddFromCard → arAdded")
    check(db.count() == n + 1, "clients: COUNT +1")
    check(db.existsByIdno(card.idno), "clients: ExistsByIdno")
    check(db.addFromCard(card).0 == .duplicate, "clients: повторный AddFromCard → arDuplicate (дедупликация по IDNO)")
    check(db.list(filter: "DML-TEST").count == 1, "clients: List с фильтром находит 1")
    conn.run("UPDATE clients SET phone = ?, email = ?, client_type = ? WHERE id = ?", ["+373 22 000-000", "dml@test.md", "Поставщик", id1])
    check(conn.scalarString("SELECT client_type FROM clients WHERE id = \(id1)") == "Поставщик", "clients: UPDATE карточки (тип/телефон/e-mail)")
    let clientId = id1

    // ── контакты ──
    crudCycle(DefContacts, "name",
              ["name", "Тест Контактов", "client_id", String(clientId), "position", "Бухгалтер", "phone", "+373 69 1", "email", "a@b.md"],
              ["name", "Тест Контактов (изм.)", "client_id", String(clientId), "position", "Директор"])

    // ── лиды + конвертация ──
    crudCycle(DefLeads, "name",
              ["name", "Лид Тестовый", "company", "Test Lead Co", "status", "Новый", "source", "Сайт"],
              ["name", "Лид Тестовый (изм.)", "company", "Test Lead Co", "status", "В работе", "source", "Звонок"])
    let leadId = data.insert(DefLeads, vals(DefLeads, ["name", "Конверт Лид", "company", "Convert Co SRL",
        "status", "В работе", "source", "Выставка", "phone", "+373 79 000-001", "email", "c@convert.md"]))
    n = db.count()
    let (msg1, id2) = data.convertLead(leadId)
    check(id2 > 0 && db.count() == n + 1, "leads: ConvertLead создаёт клиента: " + msg1)
    check(conn.scalarString("SELECT status FROM leads WHERE id = \(leadId)") == "Конвертирован", "leads: статус после конвертации = Конвертирован")
    let (msg2, id3) = data.convertLead(leadId)
    check(id3 == 0, "leads: повторная конвертация отклонена (\(msg2))")
    data.delete(DefLeads, leadId)
    db.delete(id2)

    // ── сделки ──
    crudCycle(DefDeals, "title",
              ["title", "Тест Сделка", "client_id", String(clientId), "stage", "Новая", "amount", "1000", "close_date", D(10)],
              ["title", "Тест Сделка (изм.)", "client_id", String(clientId), "stage", "Выиграна", "amount", "2500", "close_date", D(5)])
    check(data.list(DefDeals, extraWhere: "t.stage = 'Выиграна'").count >= 0, "deals: LIST с пресетом (ExtraWhere) выполняется")

    // ── номенклатура ──
    crudCycle(DefItems, "name",
              ["name", "Тест Товар", "code", "X-1", "kind", "Товар", "unit_", "шт", "price", "10", "stock", "7"],
              ["name", "Тест Товар (изм.)", "code", "X-1", "kind", "Товар", "unit_", "шт", "price", "12.5", "stock", "7"])
    let itemGoods = data.insert(DefItems, vals(DefItems, ["code", "DML-T", "name", "DML Товар", "kind", "Товар", "unit_", "шт", "price", "100", "stock", "10"]))
    let itemSvc = data.insert(DefItems, vals(DefItems, ["code", "DML-S", "name", "DML Услуга", "kind", "Услуга", "unit_", "час", "price", "50", "stock", "0"]))
    let itemProd = data.insert(DefItems, vals(DefItems, ["code", "DML-P", "name", "DML Изделие", "kind", "Изделие", "unit_", "шт", "price", "900", "stock", "0"]))

    // ── заказы: CRUD, строки, пересчёт, проводка по всем видам ──
    crudCycle(DefOrders, "number",
              ["number", "DML-1", "order_date", D(0), "client_id", String(clientId), "kind", "Продажа", "status", "Черновик"],
              ["number", "DML-1x", "order_date", D(0), "client_id", String(clientId), "kind", "Услуга", "status", "Подтверждён"])

    var orderId = data.insert(DefOrders, vals(DefOrders, ["number", "DML-S", "order_date", D(0), "client_id", String(clientId), "kind", "Продажа", "status", "Черновик"]))
    data.addOrderLine(orderId, itemGoods, 3, 100)
    data.addOrderLine(orderId, itemSvc, 2, 50)
    let lines = data.orderLines(orderId)
    check(lines.count == 2, "order_lines: две строки добавлены")
    check(abs(conn.scalarDouble("SELECT total FROM orders WHERE id = \(orderId)") - 400) < 0.01, "orders: итог пересчитан = 400 (3×100 + 2×50)")
    data.deleteOrderLine(lines[1].id)
    check(data.orderLines(orderId).count == 1 && abs(conn.scalarDouble("SELECT total FROM orders WHERE id = \(orderId)") - 300) < 0.01, "order_lines: удаление строки → итог 300")
    var msg = data.postOrder(orderId)
    check(msg.contains("статусом"), "orders: проводка черновика отклонена (\(msg))")
    data.update(DefOrders, orderId, vals(DefOrders, ["number", "DML-S", "order_date", D(0), "client_id", String(clientId), "kind", "Продажа", "status", "Выполнен"]))
    msg = data.postOrder(orderId)
    check(abs(conn.scalarDouble("SELECT stock FROM items WHERE id = \(itemGoods)") - 7) < 0.01, "orders: продажа проведена — остаток 10 → 7 (\(msg))")
    msg = data.postOrder(orderId)
    check(msg == "уже проведён", "orders: повторная проводка отклонена")

    var id = data.insert(DefOrders, vals(DefOrders, ["number", "DML-P", "order_date", D(0), "kind", "Производство", "status", "Выполнен"]))
    data.addOrderLine(id, itemProd, 4, 900)
    _ = data.postOrder(id)
    check(abs(conn.scalarDouble("SELECT stock FROM items WHERE id = \(itemProd)") - 4) < 0.01, "orders: производство проведено — оприходовано 0 → 4")
    data.delete(DefOrders, id)

    id = data.insert(DefOrders, vals(DefOrders, ["number", "DML-U", "order_date", D(0), "client_id", String(clientId), "kind", "Услуга", "status", "Оплачен"]))
    data.addOrderLine(id, itemSvc, 5, 50)
    msg = data.postOrder(id)
    check(msg.hasPrefix("услуги"), "orders: услуга проведена без изменения остатков (\(msg))")
    data.delete(DefOrders, id)
    check(data.count("order_lines", "order_id = \(id)") == 0, "orders: DELETE заказа удаляет его строки")
    data.delete(DefOrders, orderId)

    // ── процесс исполнения: этапы по авансу, отгрузке и оплате ──
    orderId = data.insert(DefOrders, vals(DefOrders, ["number", "DML-W", "order_date", D(0), "client_id", String(clientId), "kind", "Продажа", "status", "Подтверждён", "due_date", D(-1)]))
    data.addOrderLine(orderId, itemGoods, 1, 1000)
    check(data.stageOf(orderId) == .awaitAdvance, "process: подтверждён без аванса → «Ожидает аванс»")
    check(data.count("orders", "id = \(orderId)") == 1, "process: заказ на месте")
    let nOver = data.stageInfo(.awaitAdvance).overdue
    check(nOver > 0, "process: срок в прошлом попал в просрочку этапа (\(nOver))")
    conn.run("UPDATE orders SET advance = 300 WHERE id = ?", [orderId])
    check(data.stageOf(orderId) == .inWork, "process: аванс получен → «В работе / производство»")
    conn.run("UPDATE orders SET status = 'Выполнен' WHERE id = ?", [orderId])
    check(data.stageOf(orderId) == .readyToShip, "process: исполнен без отгрузки → «Готово к отгрузке»")
    conn.run("UPDATE orders SET ship_date = ?, paid = 300 WHERE id = ?", [D(0), orderId])
    check(data.stageOf(orderId) == .awaitPayment, "process: отгружен, оплата не закрыта → «Ждём оплату»")
    conn.run("UPDATE orders SET paid = 1000 WHERE id = ?", [orderId])
    check(data.stageOf(orderId) == .closed, "process: оплачен полностью → «Закрыто»")
    check(data.stageInfo(.closed).overdue == 0, "process: закрытый этап не считается просроченным")
    data.delete(DefOrders, orderId)

    // ── отчёты: строятся и выгружаются в оба формата ──
    for rk in ReportKind.allCases {
        let rep = buildReport(data, rk)
        check(rep.colCount > 0, "отчёт «\(rep.title)»: колонки описаны (\(rep.colCount))")
        let xlsx = (try? exportReport(data, rk, .xlsx, dir: tmpDir)) ?? ""
        let pdf = (try? exportReport(data, rk, .pdf, dir: tmpDir)) ?? ""
        check(isZipFile(xlsx), "отчёт «\(rk.title)»: xlsx — корректный zip-контейнер")
        check(isPdfFile(pdf), "отчёт «\(rk.title)»: pdf — заголовок %PDF")
    }

    // ── задачи ──
    crudCycle(DefTasks, "subject",
              ["subject", "Тест Задача", "kind", "Задача", "due_at", D(-1), "client_id", String(clientId), "done", "0"],
              ["subject", "Тест Задача (изм.)", "kind", "Звонок", "due_at", D(1), "client_id", String(clientId), "done", "1"])
    id = data.insert(DefTasks, vals(DefTasks, ["subject", "Просроченная", "kind", "Задача", "due_at", D(-3), "done", "0"]))
    check(data.list(DefTasks, extraWhere: "t.done = 0 AND t.due_at < date('now','localtime')").count >= 1, "tasks: пресет «Просроченные» находит задачу")
    conn.run("UPDATE tasks SET done = 1 WHERE id = ?", [id])
    check(data.list(DefTasks, extraWhere: "t.id = \(id) AND t.done = 0").isEmpty, "tasks: после «Выполнено» не попадает в открытые")
    data.delete(DefTasks, id)

    // ── проекты и задачи проекта: этап ⇔ «выполнено», доски, сводка ──
    crudCycle(DefProjects, "name",
              ["name", "Тест Проект", "client_id", String(clientId), "kind", "Реклама", "status", "Тендер", "budget", "1000", "prepay_pct", "50"],
              ["name", "Тест Проект (изм.)", "client_id", String(clientId), "kind", "Гравировка", "status", "Договор", "budget", "2000", "prepay_pct", "30"])
    id = data.insert(DefProjects, vals(DefProjects, ["name", "DML проект", "client_id", String(clientId), "kind", "Гравировка", "status", "Договор", "budget", "10000", "prepay_pct", "30"]))
    let tId = data.insert(DefTasks, vals(DefTasks, ["subject", "DML задача 1", "project_id", String(id), "stage", "Новая", "priority", "Высокий",
        "assignee", "Ion Popescu", "plan_start", D(-2), "due_at", D(-1), "hours_plan", "4", "seq", "1", "done", "0"]))
    check(conn.scalarInt("SELECT done FROM tasks WHERE id = \(tId)") == 0, "tasks: новая задача проекта — done = 0")
    data.setTaskStage(tId, "Готово")
    check(conn.scalarInt("SELECT done FROM tasks WHERE id = \(tId)") == 1, "tasks: этап «Готово» выставляет done = 1")
    data.setTaskDone(tId, false)
    check(conn.scalarString("SELECT stage FROM tasks WHERE id = \(tId)") == "В работе", "tasks: снятие «выполнено» возвращает этап «В работе»")
    data.update(DefTasks, tId, vals(DefTasks, ["subject", "DML задача 1", "project_id", String(id), "stage", "Проверка", "priority", "Высокий",
        "assignee", "Ion Popescu", "plan_start", D(-2), "due_at", D(-1), "hours_plan", "4", "seq", "1", "done", "1"]))
    check(conn.scalarInt("SELECT done FROM tasks WHERE id = \(tId)") == 0, "tasks: редактор: этап «Проверка» при done=1 — этап главнее, done сброшен")
    let s = data.projectSummary(id)
    check(s.total == 1 && s.done == 0 && s.overdue == 1 && abs(s.hoursPlan - 4) < 0.01,
          "projects: сводка задач всего \(s.total) / готово \(s.done) / просрочено \(s.overdue), часы план \(Int(s.hoursPlan))")
    boardProjectFilter = id
    check(moveBoardCard(data, .projectTasks, tId, 4), "board: задача проекта перенесена в колонку «Готово»")
    check(conn.scalarInt("SELECT done FROM tasks WHERE id = \(tId)") == 1 && data.projectProgress(id) == 100, "board: done = 1, готовность проекта 100 %")
    boardProjectFilter = 0
    check(moveBoardCard(data, .projects, id, 2), "board: проект перенесён в «Аванс»")
    check(abs(conn.scalarDouble("SELECT prepaid FROM projects WHERE id = \(id)") - 3000) < 0.01, "projects: аванс 30 % от 10 000 = 3 000 записан при переходе в «Аванс»")
    check(moveBoardCard(data, .projects, id, 7), "board: проект перенесён в «Закрыт»")
    check(abs(conn.scalarDouble("SELECT paid FROM projects WHERE id = \(id)") - 7000) < 0.01, "projects: при закрытии оплачен остаток 7 000")
    check(data.list(DefProjects, extraWhere: "t.status = 'Закрыт' AND t.id = \(id)").count == 1, "projects: пресет «Закрыт» находит проект")
    data.delete(DefProjects, id)
    check(data.count("tasks", "project_id = \(id)") == 0, "projects: DELETE удаляет задачи проекта")

    // ── сотрудники: регистрация, стандартный пароль, отключение, роли ──
    crudCycle(DefUsers, "full_name",
              ["full_name", "Тест Сотрудник", "login", "dmluser", "position", "Оператор", "role", "Склад",
               "email", "dml@demo.md", "phone", "+373 60 000-001", "active", "1"],
              ["full_name", "Тест Сотрудник (изм.)", "login", "dmluser", "position", "Кладовщик", "role", "Производство",
               "email", "dml2@demo.md", "phone", "+373 60 000-002", "active", "1"])
    let uId = data.insert(DefUsers, vals(DefUsers, ["full_name", "Вход Тестовый", "login", "dmllogin",
        "position", "Менеджер", "role", "Коммерческий", "email", "l@demo.md", "phone", "+373 60 000-003", "active", "1"]))
    check(uId > 0, "users: регистрация сотрудника администратором → id \(uId)")
    check(conn.scalarString("SELECT pass_state FROM users WHERE id = \(uId)") == PASS_STD,
          "users: новый сотрудник помечен «\(PASS_STD)» паролем")
    check(conn.scalarString("SELECT created_at FROM users WHERE id = \(uId)").count >= 10,
          "users: дата регистрации проставлена автоматически")
    check(data.loginCheck("dmllogin", STANDARD_PASSWORD).ok, "users: вход по стандартному паролю")
    check(!data.loginCheck("dmllogin", "неверный").ok, "users: неверный пароль не пускает")
    data.setPassword("dmllogin", "svoi-parol-1")
    check(data.loginCheck("dmllogin", "svoi-parol-1").ok && !data.loginCheck("dmllogin", STANDARD_PASSWORD).ok,
          "users: смена пароля сотрудником — старый стандартный больше не годится")
    check(conn.scalarString("SELECT pass_state FROM users WHERE id = \(uId)") == PASS_OWN, "users: пароль помечен «\(PASS_OWN)»")
    let rp = data.resetPassword(uId)
    check(rp.ok && data.loginCheck("dmllogin", STANDARD_PASSWORD).ok,
          "users: восстановление доступа администратором — снова стандартный пароль")
    conn.run("UPDATE users SET active = 0 WHERE id = ?", [uId])
    let off = data.loginCheck("dmllogin", STANDARD_PASSWORD)
    check(!off.ok && off.reason.contains("отключ"), "users: отключённый счёт не пускает («\(off.reason)»)")
    check(!data.staffNames().contains("Вход Тестовый"), "users: отключённый не предлагается исполнителем")
    conn.run("UPDATE users SET active = 1 WHERE id = ?", [uId])
    check(data.staffNames().contains("Вход Тестовый"), "users: включённый снова в списке исполнителей")
    check(data.isAdmin("admin") && !data.isAdmin("dmllogin"), "users: роль администратора отличается от прочих")
    // переименование тянет за собой задачи и проекты
    let renTask = data.insert(DefTasks, vals(DefTasks, ["subject", "Задача переименования", "assignee", "Вход Тестовый",
        "kind", "Задача", "due_at", D(1), "done", "0"]))
    data.update(DefUsers, uId, vals(DefUsers, ["full_name", "Вход Изменённый", "login", "dmllogin", "position", "Менеджер",
        "role", "Коммерческий", "email", "l@demo.md", "phone", "+373 60 000-003", "active", "1"]))
    check(conn.scalarString("SELECT assignee FROM tasks WHERE id = \(renTask)") == "Вход Изменённый",
          "users: переименование сотрудника переносится в задачи")
    data.delete(DefTasks, renTask)

    // ── обмен с ERP: очередь пишется триггерами, приём не уходит обратно ──
    let q0 = data.syncPendingCount()
    check(q0 > 0, "sync: триггеры поставили изменения сотрудников в очередь (\(q0))")
    let last = data.syncPending().last
    check(last?.entity == "users" && !(last?.payload.isEmpty ?? true), "sync: в очереди сущность users со снимком полей")
    let parsed = CrmData.parseSyncPayload(last?.payload ?? "")
    check(parsed["login"] == "dmllogin", "sync: снимок разбирается обратно (login = \(parsed["login"] ?? "—"))")
    data.syncMarkSent([last?.id ?? 0], ack: "dml")
    check(data.syncPendingCount() == q0 - 1, "sync: отправленная строка уходит из очереди")
    let before = data.syncPendingCount()
    let applied = data.applyUserFromErp(["login": "erpuser", "full_name": "ERP Сотрудник", "position": "Технолог",
                                         "role": "Производство", "email": "erp@demo.md", "phone": "+373 60 000-009",
                                         "active": "1", "erp_code": "7001"])
    check(applied == "создан", "sync: карточка из ERP заведена в CRM")
    check(data.syncPendingCount() == before, "sync: приём из ERP не ставится в очередь обратно (нет петли)")
    check(data.applyUserFromErp(["login": "erpuser", "full_name": "ERP Сотрудник", "position": "Мастер",
                                 "role": "Производство", "email": "erp@demo.md", "phone": "", "active": "0",
                                 "erp_code": "7001"]) == "обновлён", "sync: повторная карточка обновляет, а не дублирует")
    check(conn.scalarInt("SELECT active FROM users WHERE erp_code = '7001'") == 0, "sync: отключение сотрудника принято из ERP")
    conn.run("DELETE FROM users WHERE erp_code = '7001'")
    data.delete(DefUsers, uId)

    // ── отчёт по людям: строка на человека и общий итог ──
    let staffAll = buildReport(data, .staff)
    check(staffAll.rowCount >= 5, "отчёт по сотрудникам: строка на каждого человека (\(staffAll.rowCount))")
    let tasksTotal = data.count("tasks")
    check(Int(staffAll.totals[5].replacingOccurrences(of: " ", with: "")) == tasksTotal,
          "отчёт по сотрудникам: итог задач = \(tasksTotal), сходится с разделом «Календарь»")
    let staffOne = buildReport(data, .staff, person: "Ion Popescu")
    check(staffOne.rowCount == 1, "отчёт по сотрудникам: выбор человека оставляет одну строку")
    let onePersonTasks = data.count("tasks", "t.assignee = 'Ion Popescu'")
    check(Int(staffOne.totals[5].replacingOccurrences(of: " ", with: "")) == onePersonTasks,
          "отчёт по сотрудникам: итог по человеку = \(onePersonTasks) задач")
    let projOne = buildReport(data, .projects, person: "Maria Ceban")
    check(projOne.rowCount == data.count("projects", "t.manager = 'Maria Ceban'"),
          "отчёт по проектам: фильтр по менеджеру (\(projOne.rowCount))")
    let xlsxP = (try? exportReport(data, .staff, .xlsx, dir: tmpDir, person: "Ion Popescu")) ?? ""
    check(isZipFile(xlsxP) && xlsxP.contains("Ion"), "отчёт по сотруднику: отдельный файл выгрузки (\((xlsxP as NSString).lastPathComponent))")

    // ── уборка ──
    data.delete(DefItems, itemGoods)
    data.delete(DefItems, itemSvc)
    data.delete(DefItems, itemProd)
    db.delete(clientId)
    check(!db.existsByIdno("1099900012345"), "clients: DELETE")

    log.append("")
    log.append("DML-тест: \(log.count - 1) проверок, FAIL = \(fails)")
    return fails == 0
}
