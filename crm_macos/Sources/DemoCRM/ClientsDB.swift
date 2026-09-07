// Локальная база клиентов CRM на SQLite (аналог uClientsDB.pas): открыть/
// создать, перечислить, добавить из карточки Contragenti с дедупликацией по
// IDNO, удалить.
import Foundation

struct ClientRow {
    var id = 0
    var idno = "", denumire = "", formaJuridica = "", adresa = "", administrator = "", addedAt = ""
}

enum AddResult: Int { case added = 0, duplicate = 1, error = 2 }

final class ClientsDB {
    let db: SQLiteDB
    var dbPath: String { db.path }

    init(path: String) { db = SQLiteDB(path: path) }

    func open() throws {
        try db.open()
        try ensureSchema()
    }

    private func ensureSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS clients (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          idno          TEXT UNIQUE,
          denumire      TEXT NOT NULL,
          forma_juridica TEXT,
          inregistrare  TEXT,
          lichidata     TEXT,
          adresa        TEXT,
          administrator TEXT,
          details       TEXT,
          source        TEXT,
          added_at      TEXT DEFAULT (datetime('now','localtime'))
        )
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS ix_clients_denumire ON clients(denumire)")
    }

    func count() -> Int { db.scalarInt("SELECT COUNT(*) AS n FROM clients") }

    func list(filter: String = "") -> [ClientRow] {
        var sql = "SELECT id, idno, denumire, forma_juridica, adresa, administrator, added_at FROM clients"
        var params: [Any?] = []
        if !filter.isEmpty {
            sql += " WHERE idno LIKE ? OR denumire LIKE ? OR administrator LIKE ?"
            let f = "%" + filter + "%"
            params = [f, f, f]
        }
        sql += " ORDER BY added_at DESC, id DESC"
        return db.rows(sql, params).map { r in
            ClientRow(id: r.int("id"), idno: r.str("idno"), denumire: r.str("denumire"),
                      formaJuridica: r.str("forma_juridica"), adresa: r.str("adresa"),
                      administrator: r.str("administrator"), addedAt: r.str("added_at"))
        }
    }

    func existsByIdno(_ idno: String) -> Bool {
        if idno.isEmpty { return false }
        return !db.rows("SELECT 1 FROM clients WHERE idno = ?", [idno]).isEmpty
    }

    /// Дедупликация по IDNO: тот же контрагент не заводится дважды.
    func addFromCard(_ card: CounterpartyCard) -> (AddResult, Int) {
        if !card.idno.isEmpty && existsByIdno(card.idno) { return (.duplicate, 0) }
        do {
            try db.exec("""
            INSERT INTO clients (idno, denumire, forma_juridica, inregistrare, lichidata, adresa,
                                 administrator, details, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [card.idno.isEmpty ? nil : card.idno, card.denumire, card.formaJuridica, card.inregistrare,
                  card.lichidata, card.adresa, card.administratori, card.detailsText, card.source])
            return (.added, db.lastInsertId)
        } catch {
            // гонка: другая копия успела вставить тот же IDNO
            if existsByIdno(card.idno) { return (.duplicate, 0) }
            db.onError?("\(error)")
            return (.error, 0)
        }
    }

    func delete(_ id: Int) {
        db.run("DELETE FROM clients WHERE id = ?", [id])
    }
}
