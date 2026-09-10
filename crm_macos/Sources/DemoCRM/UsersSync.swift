// Обмен карточками сотрудников с ERP (UNIAC/OfficePlus) по тому же правилу,
// что принято в самой ERP: изменение пишет **триггер** в очередь, а программа
// эту очередь разбирает. Здесь — сторона CRM:
//
//   sync_state  — один флаг «не писать в очередь» (mute) на время приёма из
//                 ERP: иначе принятая строка тут же поехала бы обратно;
//   sync_log    — очередь: сущность, id, операция (I/U/D), снимок полей,
//                 время постановки и время отправки;
//   триггеры users_sync_ai / _au / _ad — ставят строку в очередь на каждую
//                 запись в users.
//
// Зеркальная сторона (таблица очереди и триггеры в ERP) — sql/erp_users_sync.sql.
import Foundation

/// Строка очереди обмена.
struct SyncRow {
    var id = 0
    var entity = ""
    var rowId = 0
    var op = ""          // I | U | D
    var changedAt = ""
    var payload = ""
    var sentAt = ""
}

extension CrmData {

    /// Поля карточки, которые уходят в ERP. Порядок фиксирован: он же в
    /// payload триггера и в разборе на стороне ERP.
    static let syncUserCols = ["login", "full_name", "position", "role", "email", "phone", "active", "erp_code"]

    func ensureSyncSchema() {
        db.run("""
        CREATE TABLE IF NOT EXISTS sync_state (id INTEGER PRIMARY KEY, muted INTEGER DEFAULT 0,
          pulled_at TEXT, pushed_at TEXT)
        """)
        db.run("INSERT OR IGNORE INTO sync_state (id, muted) VALUES (1, 0)")
        db.run("""
        CREATE TABLE IF NOT EXISTS sync_log (id INTEGER PRIMARY KEY AUTOINCREMENT,
          entity TEXT NOT NULL, row_id INTEGER NOT NULL, op TEXT NOT NULL,
          changed_at TEXT DEFAULT (datetime('now','localtime')), payload TEXT,
          sent_at TEXT, erp_ack TEXT)
        """)
        db.run("CREATE INDEX IF NOT EXISTS sync_log_pending ON sync_log (sent_at, id)")
        for t in ["users_sync_ai", "users_sync_au", "users_sync_ad"] { db.run("DROP TRIGGER IF EXISTS \(t)") }
        db.run("CREATE TRIGGER users_sync_ai AFTER INSERT ON users \(syncGuard) BEGIN \(syncInsertSQL("NEW", "I")) END")
        db.run("CREATE TRIGGER users_sync_au AFTER UPDATE ON users \(syncGuard) BEGIN \(syncInsertSQL("NEW", "U")) END")
        db.run("CREATE TRIGGER users_sync_ad AFTER DELETE ON users \(syncGuard) BEGIN \(syncInsertSQL("OLD", "D")) END")
    }

    /// Приём из ERP не должен отправляться обратно — на время приёма очередь молчит.
    private var syncGuard: String { "WHEN (SELECT COALESCE(muted, 0) FROM sync_state WHERE id = 1) = 0" }

    /// Снимок карточки в очередь. Собирается конкатенацией (json_object есть
    /// не в каждой сборке SQLite), кавычки в значениях удваиваются штатно —
    /// значения идут через replace(...,'"','''').
    private func syncInsertSQL(_ rec: String, _ op: String) -> String {
        let parts = CrmData.syncUserCols.map { c in
            "'\"\(c)\":\"' || replace(COALESCE(\(rec).\(c), ''), '\"', '''') || '\"'"
        }.joined(separator: " || ',' || ")
        return "INSERT INTO sync_log (entity, row_id, op, payload) VALUES ('users', \(rec).id, '\(op)', '{' || \(parts) || '}');"
    }

    // ── очередь ──

    func syncPending(_ limit: Int = 200) -> [SyncRow] {
        db.rows("SELECT * FROM sync_log WHERE COALESCE(sent_at,'') = '' ORDER BY id LIMIT \(limit)").map {
            SyncRow(id: $0.int("id"), entity: $0.str("entity"), rowId: $0.int("row_id"), op: $0.str("op"),
                    changedAt: $0.str("changed_at"), payload: $0.str("payload"), sentAt: $0.str("sent_at"))
        }
    }

    func syncPendingCount() -> Int { db.scalarInt("SELECT COUNT(*) FROM sync_log WHERE COALESCE(sent_at,'') = ''") }

    func syncMarkSent(_ ids: [Int], ack: String) {
        for i in ids {
            db.run("UPDATE sync_log SET sent_at = datetime('now','localtime'), erp_ack = ? WHERE id = ?", [ack, i])
        }
        db.run("UPDATE sync_state SET pushed_at = datetime('now','localtime') WHERE id = 1")
    }

    /// Выполняет блок с выключенной очередью — так принимают строки из ERP.
    func withSyncMuted(_ body: () -> Void) {
        db.run("UPDATE sync_state SET muted = 1 WHERE id = 1")
        body()
        db.run("UPDATE sync_state SET muted = 0 WHERE id = 1")
    }

    /// Приём карточки из ERP: тот же алгоритм, что у ERP при приёме от CRM —
    /// ищем по erp_code, потом по логину; нет — заводим со стандартным паролем.
    /// Возвращает «создан» / «обновлён» / «пропущен».
    @discardableResult
    func applyUserFromErp(_ f: [String: String]) -> String {
        let login = (f["login"] ?? "").trimmed
        let code = (f["erp_code"] ?? "").trimmed
        if login.isEmpty && code.isEmpty { return "пропущен" }
        var id = 0
        if !code.isEmpty { id = db.scalarInt("SELECT COALESCE(MAX(id),0) FROM users WHERE erp_code = \(quoted(code))") }
        if id == 0 && !login.isEmpty {
            id = db.scalarInt("SELECT COALESCE(MAX(id),0) FROM users WHERE login = \(quoted(login)) COLLATE NOCASE")
        }
        var result = "обновлён"
        withSyncMuted {
            if id == 0 {
                db.run("""
                INSERT INTO users (login, pass_hash, full_name, position, role, email, phone, active, pass_state, erp_code)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [login, passHash(login, STANDARD_PASSWORD), f["full_name"] ?? login, f["position"] ?? "",
                      f["role"] ?? "Коммерческий", f["email"] ?? "", f["phone"] ?? "",
                      (f["active"] ?? "1") == "0" ? 0 : 1, PASS_STD, code])
                result = "создан"
            } else {
                db.run("""
                UPDATE users SET full_name = ?, position = ?, role = ?, email = ?, phone = ?, active = ?,
                  erp_code = ?, updated_at = datetime('now','localtime') WHERE id = ?
                """, [f["full_name"] ?? "", f["position"] ?? "", f["role"] ?? "Коммерческий", f["email"] ?? "",
                      f["phone"] ?? "", (f["active"] ?? "1") == "0" ? 0 : 1, code, id])
            }
            db.run("UPDATE sync_state SET pulled_at = datetime('now','localtime') WHERE id = 1")
        }
        return result
    }

    /// Разбор payload очереди (тот же формат читает и сторона ERP).
    /// Ключи фиксированы и идут в порядке syncUserCols, поэтому значение —
    /// это всё между своим маркером «"ключ":"» и маркером следующего ключа:
    /// запятая или двоеточие внутри имени человека разбор не ломают.
    static func parseSyncPayload(_ s: String) -> [String: String] {
        var r: [String: String] = [:]
        let cols = syncUserCols
        for (i, c) in cols.enumerated() {
            guard let m = s.range(of: "\"\(c)\":\"") else { continue }
            let tailStart = m.upperBound
            var end = s.endIndex
            if i + 1 < cols.count, let n = s.range(of: "\",\"\(cols[i + 1])\":\"", range: tailStart..<s.endIndex) {
                end = n.lowerBound
            } else if let n = s.range(of: "\"}", options: .backwards) {
                end = n.lowerBound
            }
            if tailStart <= end { r[c] = String(s[tailStart..<end]) }
        }
        return r
    }
}
