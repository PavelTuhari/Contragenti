// Отчёты CRM и их выгрузка в Excel (.xlsx) и PDF (аналог uReports.pas).
// Каждый отчёт — SQL-запрос → ReportTable, а дальше один и тот же объект
// отдаётся в Xlsx или Pdf.
import Foundation

enum ReportKind: Int, CaseIterable {
    case process = 0, receivables, salesByClient, funnel, stock, projects

    var title: String {
        switch self {
        case .process: return "Процесс исполнения заказов"
        case .receivables: return "Дебиторская задолженность"
        case .salesByClient: return "Продажи по клиентам"
        case .funnel: return "Воронка продаж"
        case .stock: return "Остатки номенклатуры"
        case .projects: return "Проекты: тендеры, авансы, задачи"
        }
    }

    var hint: String {
        switch self {
        case .process: return "Этапы от аванса до оплаты, суммы и просрочка"
        case .receivables: return "Отгружено, но не оплачено — по клиентам и срокам"
        case .salesByClient: return "Заказы, выручка, оплата и долг по каждому клиенту"
        case .funnel: return "Сделки по этапам: количество, сумма, средний чек"
        case .stock: return "Товары и изделия: остаток и его стоимость"
        case .projects: return "Каждый проект: этап, бюджет, аванс и оплата, долг, задачи и просрочка"
        }
    }

    var slug: String {
        ["process", "receivables", "sales_by_client", "funnel", "stock", "projects"][rawValue]
    }
}

enum ExportFormat { case xlsx, pdf }

private func M(_ v: Double) -> String { fmtMoney(v) }
private func N(_ v: Int) -> String { String(v) }
private var todayStr: String { D(0) }

private func reportProcess(_ data: CrmData) -> ReportTable {
    let t = ReportTable()
    t.title = ReportKind.process.title
    t.subtitle = "Состояние на \(todayStr). Просрочка — срок исполнения в прошлом, этап не закрыт."
    t.addCol("Этап процесса", .text, 190)
    t.addCol("Что означает", .text, 210)
    t.addCol("Кол-во", .number, 60)
    t.addCol("Сумма, MDL", .money, 100)
    t.addCol("Запаздывает", .number, 80)
    t.addCol("Сумма просрочки, MDL", .money, 120)
    var cnt = 0, over = 0, sum = 0.0
    for s in Stage.allCases {
        let i = data.stageInfo(s)
        t.addRow([i.title, i.hint, N(i.count), M(i.sum), i.overdue > 0 ? N(i.overdue) : "", i.overdue > 0 ? M(i.overdueSum) : ""])
        if i.table == "orders" { cnt += i.count; over += i.overdue; sum += i.sum }
    }
    t.setTotals(["Итого по заказам", "", N(cnt), M(sum), N(over), ""])
    return t
}

private func reportReceivables(_ data: CrmData) -> ReportTable {
    let t = ReportTable()
    t.title = ReportKind.receivables.title
    t.subtitle = "Отгруженные заказы с непогашенной оплатой на \(todayStr)"
    t.addCol("Заказ", .text, 60)
    t.addCol("Клиент", .text, 220)
    t.addCol("Отгружен", .date, 80)
    t.addCol("Срок оплаты", .date, 80)
    t.addCol("Итого, MDL", .money, 95)
    t.addCol("Оплачено, MDL", .money, 95)
    t.addCol("Долг, MDL", .money, 95)
    t.addCol("Просрочка, дн.", .number, 85)
    var sum = 0.0
    for r in data.rows("""
    SELECT o.number, COALESCE(c.denumire, '—') AS client, o.ship_date, o.due_date, o.total, COALESCE(o.paid,0) AS paid,
      julianday('now','localtime') - julianday(o.due_date) AS overdue
    FROM orders o LEFT JOIN clients c ON c.id = o.client_id
    WHERE o.status <> 'Отменён' AND COALESCE(o.ship_date,'') <> '' AND COALESCE(o.paid,0) < o.total
    ORDER BY overdue DESC, o.total DESC
    """) {
        let debt = r.dbl("total") - r.dbl("paid")
        sum += debt
        let days = r.str("due_date").isEmpty ? 0 : Int(r.dbl("overdue"))
        t.addRow([r.str("number"), r.str("client"), r.str("ship_date"), r.str("due_date"),
                  M(r.dbl("total")), M(r.dbl("paid")), M(debt), days > 0 ? N(days) : ""])
    }
    t.setTotals(["Итого", "заказов: \(t.rowCount)", "", "", "", "", M(sum), ""])
    return t
}

private func reportSalesByClient(_ data: CrmData) -> ReportTable {
    let t = ReportTable()
    t.title = ReportKind.salesByClient.title
    t.subtitle = "Все заказы, кроме отменённых, на \(todayStr)"
    t.addCol("Клиент", .text, 240)
    t.addCol("IDNO", .text, 100)
    t.addCol("Заказов", .number, 70)
    t.addCol("Сумма, MDL", .money, 110)
    t.addCol("Оплачено, MDL", .money, 110)
    t.addCol("Долг, MDL", .money, 110)
    t.addCol("Последний заказ", .date, 100)
    var sum = 0.0, paid = 0.0
    for r in data.rows("""
    SELECT COALESCE(c.denumire, '(без клиента)') AS client, COALESCE(c.idno,'') AS idno, COUNT(o.id) AS cnt,
      COALESCE(SUM(o.total),0) AS total, COALESCE(SUM(o.paid),0) AS paid, MAX(o.order_date) AS last_date
    FROM orders o LEFT JOIN clients c ON c.id = o.client_id
    WHERE o.status <> 'Отменён' GROUP BY o.client_id ORDER BY total DESC
    """) {
        sum += r.dbl("total"); paid += r.dbl("paid")
        t.addRow([r.str("client"), r.str("idno"), N(r.int("cnt")), M(r.dbl("total")), M(r.dbl("paid")),
                  M(r.dbl("total") - r.dbl("paid")), r.str("last_date")])
    }
    t.setTotals(["Итого", "", N(t.rowCount), M(sum), M(paid), M(sum - paid), ""])
    return t
}

private func reportFunnel(_ data: CrmData) -> ReportTable {
    let t = ReportTable()
    t.title = ReportKind.funnel.title
    t.subtitle = "Сделки по этапам на \(todayStr)"
    t.addCol("Этап", .text, 160)
    t.addCol("Сделок", .number, 70)
    t.addCol("Сумма, MDL", .money, 120)
    t.addCol("Средний чек, MDL", .money, 130)
    t.addCol("Ближайшее закрытие", .date, 130)
    var sum = 0.0, cnt = 0
    for r in data.rows("""
    SELECT stage, COUNT(*) AS cnt, COALESCE(SUM(amount),0) AS total, MIN(NULLIF(close_date,'')) AS nearest
    FROM deals GROUP BY stage ORDER BY total DESC
    """) {
        sum += r.dbl("total"); cnt += r.int("cnt")
        t.addRow([r.str("stage"), N(r.int("cnt")), M(r.dbl("total")), M(r.dbl("total") / Double(max(1, r.int("cnt")))), r.str("nearest")])
    }
    t.setTotals(["Итого", N(cnt), M(sum), M(sum / Double(max(1, cnt))), ""])
    return t
}

private func reportStock(_ data: CrmData) -> ReportTable {
    let t = ReportTable()
    t.title = ReportKind.stock.title
    t.subtitle = "Товары и изделия (услуги не имеют остатка) на \(todayStr)"
    t.addCol("Код", .text, 70)
    t.addCol("Наименование", .text, 250)
    t.addCol("Вид", .text, 80)
    t.addCol("Ед.", .text, 50)
    t.addCol("Цена, MDL", .money, 95)
    t.addCol("Остаток", .number, 75)
    t.addCol("Стоимость, MDL", .money, 115)
    var sum = 0.0
    for r in data.rows("""
    SELECT code, name, kind, unit_, COALESCE(price,0) AS price, COALESCE(stock,0) AS stock,
      COALESCE(price,0) * COALESCE(stock,0) AS value FROM items WHERE kind <> 'Услуга' ORDER BY value DESC, name
    """) {
        sum += r.dbl("value")
        t.addRow([r.str("code"), r.str("name"), r.str("kind"), r.str("unit_"), M(r.dbl("price")), fmt0_2(r.dbl("stock")), M(r.dbl("value"))])
    }
    t.setTotals(["Итого", "позиций: \(t.rowCount)", "", "", "", "", M(sum)])
    return t
}

private func reportProjects(_ data: CrmData) -> ReportTable {
    let t = ReportTable()
    t.title = ReportKind.projects.title
    t.subtitle = "Состояние на \(todayStr). Долг = бюджет − аванс − оплата (для незакрытых и не проигранных)."
    t.addCol("Проект", .text, 200)
    t.addCol("Клиент", .text, 150)
    t.addCol("Этап", .text, 80)
    t.addCol("Тендер", .text, 70)
    t.addCol("Бюджет, MDL", .money, 90)
    t.addCol("Аванс, %", .number, 55)
    t.addCol("Аванс, MDL", .money, 85)
    t.addCol("Оплачено, MDL", .money, 90)
    t.addCol("Долг, MDL", .money, 85)
    t.addCol("Задач", .number, 50)
    t.addCol("Готово", .number, 55)
    t.addCol("Просрочено", .number, 70)
    t.addCol("Сдача", .date, 80)
    var sumBudget = 0.0, sumPaid = 0.0, sumDebt = 0.0, cnt = 0, overAll = 0
    for r in data.rows("""
    SELECT p.id, p.name, COALESCE(c.denumire, '—') AS client, p.status, COALESCE(p.tender_no,'') AS tender,
      COALESCE(p.budget,0) AS budget, COALESCE(p.prepay_pct,0) AS pct, COALESCE(p.prepaid,0) AS prepaid,
      COALESCE(p.paid,0) AS paid, COALESCE(p.due_date,'') AS due
    FROM projects p LEFT JOIN clients c ON c.id = p.client_id
    ORDER BY CASE p.status WHEN 'Закрыт' THEN 2 WHEN 'Проигран' THEN 3 ELSE 1 END, p.due_date
    """) {
        let status = r.str("status")
        let budget = r.dbl("budget"), prepaid = r.dbl("prepaid"), paid = r.dbl("paid")
        let debt = (status == "Закрыт" || status == "Проигран") ? 0 : max(0, budget - prepaid - paid)
        let s = data.projectSummary(r.int("id"))
        t.addRow([r.str("name"), r.str("client"), status, r.str("tender"), M(budget), N(Int(bankRound(r.dbl("pct")))),
                  M(prepaid), M(paid), debt > 0 ? M(debt) : "", N(s.total), N(s.done), s.overdue > 0 ? N(s.overdue) : "", r.str("due")])
        if status != "Проигран" { sumBudget += budget; sumPaid += prepaid + paid; sumDebt += debt }
        cnt += 1
        overAll += s.overdue
    }
    t.setTotals(["Итого", "проектов: \(cnt)", "", "", M(sumBudget), "", "", M(sumPaid), M(sumDebt), "", "", N(overAll), ""])
    return t
}

func buildReport(_ data: CrmData, _ kind: ReportKind) -> ReportTable {
    switch kind {
    case .process: return reportProcess(data)
    case .receivables: return reportReceivables(data)
    case .salesByClient: return reportSalesByClient(data)
    case .funnel: return reportFunnel(data)
    case .stock: return reportStock(data)
    case .projects: return reportProjects(data)
    }
}

/// Сохраняет отчёт в каталог и возвращает полный путь к файлу.
func exportReport(_ data: CrmData, _ kind: ReportKind, _ fmt: ExportFormat, dir: String) throws -> String {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let ext = fmt == .xlsx ? ".xlsx" : ".pdf"
    let path = (dir as NSString).appendingPathComponent("\(kind.slug)_\(D(0))\(ext)")
    let t = buildReport(data, kind)
    if fmt == .xlsx { try saveTableToXlsx(t, path) } else { try saveTableToPdf(t, path) }
    return path
}
