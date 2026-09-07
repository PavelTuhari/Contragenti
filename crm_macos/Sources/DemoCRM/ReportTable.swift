// Модель отчёта, общая для экспорта в Excel (Xlsx.swift) и PDF (Pdf.swift).
import Foundation

enum ColKind { case text, number, money, date, right }

struct ReportCol {
    var title: String
    var kind: ColKind
    var width: Int   // ширина в пунктах (PDF); для Excel делится
}

final class ReportTable {
    var title = ""
    var subtitle = ""
    var cols: [ReportCol] = []
    private(set) var rows: [[String]] = []
    var totals: [String] = []   // пусто — итогов нет

    func addCol(_ title: String, _ kind: ColKind, _ width: Int) { cols.append(ReportCol(title: title, kind: kind, width: width)) }
    func addRow(_ cells: [String]) { rows.append(cells) }
    func setTotals(_ cells: [String]) { totals = cells }
    var rowCount: Int { rows.count }
    var colCount: Int { cols.count }
    func cell(_ r: Int, _ c: Int) -> String {
        guard r >= 0, r < rows.count, c >= 0, c < rows[r].count else { return "" }
        return rows[r][c]
    }
    func isNumeric(_ c: Int) -> Bool { c >= 0 && c < cols.count && (cols[c].kind == .number || cols[c].kind == .money) }
}
