// Тонкая обёртка над системной SQLite3 (libsqlite3 из macOS) — аналог
// FireDAC-подключения в uClientsDB. Параметры — позиционные «?».
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Строка результата: значения по имени колонки; NULL → nil.
struct DBRow {
    var cols: [String: Any?] = [:]
    /// AsString: NULL → '', число → его текст.
    func str(_ name: String) -> String {
        guard let v = cols[name], let x = v else { return "" }
        if let s = x as? String { return s }
        if let i = x as? Int64 { return String(i) }
        if let d = x as? Double { return (d == d.rounded() && abs(d) < 1e15) ? String(Int64(d)) : String(d) }
        return "\(x)"
    }
    /// AsFloat: NULL/текст → 0.
    func dbl(_ name: String) -> Double {
        guard let v = cols[name], let x = v else { return 0 }
        if let d = x as? Double { return d }
        if let i = x as? Int64 { return Double(i) }
        if let s = x as? String { return toDouble(s) ?? 0 }
        return 0
    }
    func int(_ name: String) -> Int {
        guard let v = cols[name], let x = v else { return 0 }
        if let i = x as? Int64 { return Int(i) }
        if let d = x as? Double { return Int(d) }
        if let s = x as? String { return Int(s) ?? Int(toDouble(s) ?? 0) }
        return 0
    }
    func isNull(_ name: String) -> Bool {
        guard let v = cols[name] else { return true }
        return v == nil
    }
}

final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    let path: String
    /// Ошибки из «мягких» вызовов (run/rows/scalar) уходят сюда — окно
    /// показывает их в строке сообщений (аналог Application.OnException).
    var onError: ((String) -> Void)?
    private(set) var lastError = ""

    init(path: String) { self.path = path }
    deinit { close() }

    func open() throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open failed"
            if let d = db { sqlite3_close(d) }
            throw SQLiteError(message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA synchronous = FULL")
        try exec("PRAGMA foreign_keys = OFF")
    }

    func close() {
        if let h = handle { sqlite3_close(h); handle = nil }
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Any?]) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            var rc: Int32
            switch p {
            case nil: rc = sqlite3_bind_null(stmt, idx)
            case let v as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as Int32: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Bool: rc = sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: rc = sqlite3_bind_double(stmt, idx, v)
            case let v as Float: rc = sqlite3_bind_double(stmt, idx, Double(v))
            case let v as String: rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_PTR)
            case let v as Data:
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT_PTR) }
            default: rc = sqlite3_bind_text(stmt, idx, "\(p!)", -1, SQLITE_TRANSIENT_PTR)
            }
            if rc != SQLITE_OK { throw SQLiteError(message: "bind \(idx): \(errmsg())") }
        }
    }

    private func errmsg() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no db"
    }

    func exec(_ sql: String, _ params: [Any?] = []) throws {
        guard let h = handle else { throw SQLiteError(message: "база не открыта") }
        if params.isEmpty && !sql.contains("?") {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? errmsg()
                sqlite3_free(err)
                throw SQLiteError(message: m)
            }
            return
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError(message: errmsg() + " — " + sql)
        }
        defer { sqlite3_finalize(s) }
        try bind(s, params)
        let rc = sqlite3_step(s)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { throw SQLiteError(message: errmsg() + " — " + sql) }
    }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [DBRow] {
        guard let h = handle else { throw SQLiteError(message: "база не открыта") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError(message: errmsg() + " — " + sql)
        }
        defer { sqlite3_finalize(s) }
        try bind(s, params)
        let n = sqlite3_column_count(s)
        var names: [String] = []
        for i in 0..<n { names.append(String(cString: sqlite3_column_name(s, i))) }
        var out: [DBRow] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                var row = DBRow()
                for i in 0..<n {
                    let v: Any?
                    switch sqlite3_column_type(s, i) {
                    case SQLITE_INTEGER: v = sqlite3_column_int64(s, i)
                    case SQLITE_FLOAT: v = sqlite3_column_double(s, i)
                    case SQLITE_TEXT: v = String(cString: sqlite3_column_text(s, i))
                    case SQLITE_BLOB:
                        if let p = sqlite3_column_blob(s, i) {
                            v = Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
                        } else { v = Data() }
                    default: v = nil
                    }
                    row.cols[names[Int(i)]] = v
                }
                out.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(message: errmsg() + " — " + sql)
            }
        }
        return out
    }

    var lastInsertId: Int {
        handle.map { Int(sqlite3_last_insert_rowid($0)) } ?? 0
    }

    // ── мягкие вызовы: ошибка — в onError, программа продолжает работать ──

    private func report(_ e: Error) {
        lastError = "\(e)"
        FileHandle.standardError.write(("SQLite: " + lastError + "\n").data(using: .utf8)!)
        onError?(lastError)
    }

    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) -> Bool {
        do { try exec(sql, params); return true } catch { report(error); return false }
    }

    func rows(_ sql: String, _ params: [Any?] = []) -> [DBRow] {
        do { return try query(sql, params) } catch { report(error); return [] }
    }

    /// Первое значение первой строки; NULL/пусто → nil.
    func scalar(_ sql: String, _ params: [Any?] = []) -> Any? {
        guard let r = rows(sql, params).first, let first = r.cols.first else { return nil }
        // порядок колонок в словаре не гарантирован — берём по имени первой колонки запроса
        if r.cols.count == 1 { return first.value }
        return firstColumnValue(sql, params)
    }

    private func firstColumnValue(_ sql: String, _ params: [Any?]) -> Any? {
        guard let h = handle else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return nil }
        defer { sqlite3_finalize(s) }
        try? bind(s, params)
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        switch sqlite3_column_type(s, 0) {
        case SQLITE_INTEGER: return sqlite3_column_int64(s, 0)
        case SQLITE_FLOAT: return sqlite3_column_double(s, 0)
        case SQLITE_TEXT: return String(cString: sqlite3_column_text(s, 0))
        default: return nil
        }
    }

    func scalarInt(_ sql: String, _ params: [Any?] = []) -> Int {
        switch scalar(sql, params) {
        case let v as Int64: return Int(v)
        case let v as Double: return Int(v)
        case let v as String: return Int(v) ?? Int(toDouble(v) ?? 0)
        default: return 0
        }
    }

    func scalarDouble(_ sql: String, _ params: [Any?] = []) -> Double {
        switch scalar(sql, params) {
        case let v as Int64: return Double(v)
        case let v as Double: return v
        case let v as String: return toDouble(v) ?? 0
        default: return 0
        }
    }

    /// VarToStr: NULL → ''.
    func scalarString(_ sql: String, _ params: [Any?] = []) -> String {
        switch scalar(sql, params) {
        case let v as Int64: return String(v)
        case let v as Double: return v == v.rounded() ? String(Int64(v)) : String(v)
        case let v as String: return v
        default: return ""
        }
    }
}
