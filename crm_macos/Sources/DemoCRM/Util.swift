// Общие помощники: даты в формате базы (yyyy-mm-dd), форматирование чисел
// как в Delphi (FormatFloat), банковское округление (Delphi Round).
import Foundation

let isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// Сегодня, 00:00 местного времени (аналог Delphi Date).
func today() -> Date { Calendar.current.startOfDay(for: Date()) }

func dateStr(_ d: Date) -> String { isoDateFormatter.string(from: d) }

func addDays(_ d: Date, _ n: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: n, to: d) ?? d
}

/// yyyy-mm-dd для «сегодня + days» — как функция D() в uTestData.pas.
func D(_ days: Int) -> String { dateStr(addDays(today(), days)) }

/// Разбор ISO-даты без зависимости от локали; nil, если строка не дата.
func parseISODate(_ s: String) -> Date? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard t.count >= 10 else { return nil }
    let p = t.prefix(10).split(separator: "-")
    guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
          y > 1900, (1...12).contains(m), (1...31).contains(d) else { return nil }
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    return Calendar.current.date(from: c)
}

func daysBetween(_ a: Date, _ b: Date) -> Int {
    let s1 = Calendar.current.startOfDay(for: a), s2 = Calendar.current.startOfDay(for: b)
    return Calendar.current.dateComponents([.day], from: s1, to: s2).day ?? 0
}

func fmtDate(_ d: Date, _ pattern: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = pattern
    return f.string(from: d)
}

/// Delphi Round — банковское округление (к ближайшему чётному).
func bankRound(_ v: Double) -> Double { v.rounded(.toNearestOrEven) }

/// Round(x * 100) / 100 — так Delphi считает авансы.
func money2(_ v: Double) -> Double { bankRound(v * 100) / 100 }

/// FormatFloat('#,##0.00'): разряды через пробел, два знака после точки.
func fmtMoney(_ v: Double) -> String { groupThousands(String(format: "%.2f", v)) }

/// FormatFloat('#,##0').
func fmtInt0(_ v: Double) -> String { groupThousands(String(format: "%.0f", v)) }

/// FormatFloat('0.00').
func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }

/// FormatFloat('0.##') — до двух знаков без хвостовых нулей.
func fmt0_2(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s
}

/// FormatFloat('0.#').
func fmt0_1(_ v: Double) -> String {
    var s = String(format: "%.1f", v)
    if s.hasSuffix(".0") { s.removeLast(2) }
    return s
}

private func groupThousands(_ s: String) -> String {
    var sign = ""
    var body = s
    if body.hasPrefix("-") { sign = "-"; body.removeFirst() }
    let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
    var intPart = parts[0]
    var out = ""
    while intPart.count > 3 {
        out = " " + intPart.suffix(3) + out
        intPart.removeLast(3)
    }
    out = intPart + out
    if parts.count > 1 { out += "." + parts[1] }
    return sign + out
}

/// StrToFloatDef с заменой запятой на точку.
func toDouble(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    if t.isEmpty { return nil }
    return Double(t)
}

func toDoubleDef(_ s: String, _ def: Double = 0) -> Double { toDouble(s) ?? def }

/// Delphi Format('%s … %d …') — только нужные подстановки: %s, %d, %%.
func fmtDelphi(_ pattern: String, _ args: [Any]) -> String {
    var out = ""
    var i = pattern.startIndex
    var argIdx = 0
    while i < pattern.endIndex {
        let ch = pattern[i]
        if ch == "%" {
            let next = pattern.index(after: i)
            if next < pattern.endIndex {
                let n = pattern[next]
                if n == "%" { out.append("%"); i = pattern.index(after: next); continue }
                // формат вида %.2f / %d / %s — до буквы
                var j = next
                while j < pattern.endIndex, !pattern[j].isLetter { j = pattern.index(after: j) }
                if j < pattern.endIndex {
                    let spec = pattern[j]
                    let mods = String(pattern[next..<j])
                    var val = "?"
                    if argIdx < args.count {
                        let a = args[argIdx]
                        switch spec {
                        case "d":
                            if let x = a as? Int { val = String(x) }
                            else if let x = a as? Double { val = String(Int(x)) }
                            else { val = "\(a)" }
                        case "f":
                            let x = (a as? Double) ?? Double((a as? Int) ?? 0)
                            val = String(format: "%\(mods)f", x)
                        default:
                            val = "\(a)"
                        }
                    }
                    argIdx += 1
                    out.append(val)
                    i = pattern.index(after: j)
                    continue
                }
            }
        }
        out.append(ch)
        i = pattern.index(after: i)
    }
    return out
}

/// QuotedStr: 'текст' с удвоением апострофов.
func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

/// Разбор строки аргументов как у оболочки: пробелы, кавычки.
func splitArgs(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var inQ: Character? = nil
    var has = false
    for ch in s {
        if let q = inQ {
            if ch == q { inQ = nil } else { cur.append(ch) }
        } else if ch == "\"" || ch == "'" {
            inQ = ch; has = true
        } else if ch == " " || ch == "\t" {
            if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
        } else { cur.append(ch) }
    }
    if has || !cur.isEmpty { out.append(cur) }
    return out
}

extension String {
    /// Copy(S, 1, N) — первые N символов.
    func left(_ n: Int) -> String { String(prefix(n)) }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func writeStdout(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

/// Имя человека в имени файла выгрузки: пробелы и разделители пути убираются.
func safeFileName(_ s: String) -> String {
    var r = ""
    for ch in s {
        if ch.isLetter || ch.isNumber { r.append(ch) }
        else if ch == " " || ch == "-" || ch == "_" { r.append("_") }
    }
    while r.contains("__") { r = r.replacingOccurrences(of: "__", with: "_") }
    return String(r.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}
