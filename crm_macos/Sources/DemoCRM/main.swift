// Demo CRM для macOS — точка входа (аналог ContragentiCRM.dpr).
//
// Режимы (первый аргумент):
//   —                       графический интерфейс
//   --import file.xml       импорт карточки из XML (без окна): 0 добавлено/дубликат,
//                           2 файла нет, 3 не разобран, 4 не сохранён
//   --selftest              разбор встроенного XML + SQLite: добавление/дубликат (0/1)
//   --seed-demo [база]      полный набор тестовых данных (0/2)
//   --dml-test              seed + DML всех сущностей во временной базе (0/1)
//   --gui-test [outDir] [launcher]  сценарный прогон UI со снимками и report.html (0/1/2)
import Foundation
import AppKit

private func tmpDbPath(_ prefix: String) -> String {
    NSTemporaryDirectory() + "\(prefix)_\(UInt64(Date().timeIntervalSince1970 * 1000)).db"
}

/// Импорт карточки из XML в личную базу — без запуска интерфейса.
func runImport(_ xmlFile: String) -> Int32 {
    guard FileManager.default.fileExists(atPath: xmlFile) else {
        writeStdout("Файл не найден: " + xmlFile)
        return 2
    }
    let cli = ContragentiClient()
    let db = ClientsDB(path: Paths.crmDataDir + "clients.db")
    do { try db.open() } catch {
        writeStdout("ERROR: база: \(error)")
        return 4
    }
    guard let card = cli.parseCardFile(xmlFile) else {
        writeStdout("Разбор не удался: " + cli.lastError)
        return 3
    }
    var rc: Int32 = 0
    switch db.addFromCard(card) {
    case (.added, let id):
        writeStdout("OK: добавлен клиент #\(id) — \(card.denumire) (IDNO \(card.idno))")
    case (.duplicate, _):
        writeStdout("DUP: уже в базе — \(card.denumire) (IDNO \(card.idno))")
    default:
        writeStdout("ERROR: не удалось сохранить.")
        rc = 4
    }
    writeStdout("Всего в базе: \(db.count())")
    return rc
}

func runSelfTest() -> Int32 {
    var ok = true
    let sampleXml = """
    <?xml version="1.0" encoding="UTF-8"?><counterparty source="date.gov.md" idno="1234567890123"><idno>1234567890123</idno><denumire>SELFTEST SRL</denumire><forma_juridica>SRL</forma_juridica><adresa>Chisinau</adresa><administratori>ION [Administrator]</administratori><founders><founder name="ION" share="100"/></founders><debts currency="MDL"><debt nr="1" type="stat" sum="0,00"/></debts></counterparty>
    """
    let cli = ContragentiClient()
    var card = CounterpartyCard()
    if let c = cli.parseCardXml(sampleXml) {
        card = c
        writeStdout("[OK]   разбор XML: \(c.denumire) / \(c.idno) / учредителей \(c.founders.count) / долгов \(c.debts.count)")
    } else {
        writeStdout("[FAIL] разбор XML: " + cli.lastError)
        ok = false
    }
    let tmp = tmpDbPath("crm_selftest")
    let db = ClientsDB(path: tmp)
    do {
        try db.open()
        let r1 = db.addFromCard(card).0
        let r2 = db.addFromCard(card).0
        if r1 == .added && r2 == .duplicate && db.count() == 1 {
            writeStdout("[OK]   SQLite: добавление и дедупликация по IDNO")
        } else {
            writeStdout("[FAIL] SQLite: r1=\(r1.rawValue) r2=\(r2.rawValue) count=\(db.count())")
            ok = false
        }
    } catch {
        writeStdout("[FAIL] SQLite: \(error)")
        ok = false
    }
    db.db.close()
    try? FileManager.default.removeItem(atPath: tmp)
    writeStdout("")
    writeStdout("CRM self-test: " + (ok ? "True" : "False"))
    return ok ? 0 : 1
}

/// Генератор тестовых данных: полный набор записей всех сущностей (AGENTS.md §1).
func runSeed(_ dbArg: String) -> Int32 {
    let path = dbArg.isEmpty ? Paths.crmDataDir + "clients.db" : dbArg
    let db = ClientsDB(path: path)
    do { try db.open() } catch {
        writeStdout("Ошибка генерации: \(error)")
        return 2
    }
    var failed = false
    db.db.onError = { failed = true; writeStdout("Ошибка генерации: " + $0) }
    let data = CrmData(db)
    let stats = seedDemo(db, data)
    if failed { return 2 }
    writeStdout("Тестовые данные добавлены в " + path)
    writeStdout("Добавлено: " + stats.text)
    writeStdout("Всего в базе: клиентов \(db.count()), контактов \(data.count("contacts")), лидов \(data.count("leads")), сделок \(data.count("deals")), номенклатуры \(data.count("items")), заказов \(data.count("orders")), строк \(data.count("order_lines")), задач \(data.count("tasks")), сотрудников \(data.count("users"))")
    return 0
}

/// DML-тест всех сущностей во временной базе (AGENTS.md §1).
func runDml() -> Int32 {
    let tmp = tmpDbPath("crm_dml")
    let db = ClientsDB(path: tmp)
    var log: [String] = []
    var ok = false
    do {
        try db.open()
        db.db.onError = { log.append("[FAIL] SQLite: " + $0) }
        let data = CrmData(db)
        _ = seedDemo(db, data)   // сначала полный набор — DML проверяется на заполненной базе
        ok = runDmlTest(db, data, &log)
        if log.contains(where: { $0.hasPrefix("[FAIL] SQLite") }) { ok = false }
    } catch {
        log.append("[FAIL] исключение: \(error)")
    }
    for s in log { writeStdout(s) }
    db.db.close()
    try? FileManager.default.removeItem(atPath: tmp)
    return ok ? 0 : 1
}

// ── разбор аргументов ──

let args = CommandLine.arguments
if args.count >= 2 {
    let arg = args[1].lowercased()
    switch arg {
    case "--selftest":
        exit(runSelfTest())
    case "--import" where args.count >= 3:
        exit(runImport(args[2]))
    case "--seed-demo":
        exit(runSeed(args.count >= 3 ? args[2] : ""))
    case "--dml-test":
        exit(runDml())
    case "--gui-test":
        exit(runGuiTest(outDir: args.count >= 3 ? args[2] : "", launcher: args.count >= 4 ? args[3] : ""))
    default:
        break
    }
}

// ── GUI ──
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
