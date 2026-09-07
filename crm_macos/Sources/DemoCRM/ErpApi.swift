// Связь CRM с ERP una.md по HTTP-API хаба (аналог uErpApi.pas):
//   GET  /api/v1/health, GET /api/v1/stats, POST /api/v1/batches (gzip(sqlite)),
//   GET  /api/v1/batches/<id>. Параметры — crm.ini, секция [erp].
import Foundation

struct ErpStatus {
    var online = false
    var message = ""
    var queueDepth = 0
    var serverTime = ""
    var rowsNew = 0
    var batches = 0
}

final class ErpClient {
    var url = "http://127.0.0.1:9000"
    var key = ""
    var clientId = "demo-crm"
    var timeoutMs = 15000
    private(set) var lastError = ""

    var configured: Bool { !url.trimmed.isEmpty }

    private var baseUrl: String {
        var r = url.trimmed
        while r.hasSuffix("/") { r.removeLast() }
        return r
    }

    /// Синхронный запрос (как THTTPClient в Delphi): семафор поверх URLSession.
    private func request(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:],
                         timeout: Double) -> (Int, Data)? {
        guard let u = URL(string: baseUrl + path) else { lastError = "неверный адрес: " + baseUrl; return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "X-API-Key") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        var err: Error?
        let task = URLSession.shared.dataTask(with: req) { data, resp, e in
            if let e = e { err = e } else { result = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        if let e = err { lastError = e.localizedDescription; return nil }
        if result == nil { lastError = "нет ответа"; task.cancel() }
        return result
    }

    private func get(_ path: String) -> [String: Any]? {
        lastError = ""
        if !configured { lastError = "адрес ERP не задан (crm.ini, секция [erp])"; return nil }
        guard let (code, data) = request("GET", path, timeout: Double(timeoutMs) / 1000) else { return nil }
        let body = String(data: data, encoding: .utf8) ?? ""
        if code != 200 { lastError = "HTTP \(code): \(body.left(200))"; return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func jstr(_ j: [String: Any]?, _ name: String) -> String {
        guard let v = j?[name], !(v is NSNull) else { return "" }
        return "\(v)"
    }
    private func jint(_ j: [String: Any]?, _ name: String) -> Int { Int(jstr(j, name)) ?? 0 }

    func health() -> (Bool, ErpStatus) {
        var st = ErpStatus()
        guard let j = get("/api/v1/health") else {
            st.message = "ERP недоступна: " + lastError
            return (false, st)
        }
        st.online = jstr(j, "status") == "ok"
        st.serverTime = jstr(j, "time")
        st.queueDepth = jint(j, "queue")
        if let s = get("/api/v1/stats") {
            st.rowsNew = jint(s, "rows_new")
            st.batches = jint(s, "batches")
        }
        st.message = "ERP на связи (\(baseUrl)): очередь \(st.queueDepth), пакетов \(st.batches), записей принято \(st.rowsNew)"
        return (true, st)
    }

    /// gzip = заголовок + сырой deflate + crc32 + размер.
    static func gzip(_ data: Data) -> Data? {
        guard let body = deflateRaw(data) else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out += body
        var crc = crc32(data).littleEndian
        out += Data(bytes: &crc, count: 4)
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out += Data(bytes: &size, count: 4)
        return out
    }

    /// Отправляет копию базы в ERP; возвращает id пакета.
    func sendDatabase(_ dbPath: String) -> (Bool, String) {
        lastError = ""
        if !configured { lastError = "адрес ERP не задан (crm.ini, секция [erp])"; return (false, "") }
        guard FileManager.default.fileExists(atPath: dbPath) else { lastError = "база не найдена: " + dbPath; return (false, "") }
        let tmp = NSTemporaryDirectory() + "crm_erp_\(UInt64(Date().timeIntervalSince1970 * 1000)).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: tmp)
            let src = try Data(contentsOf: URL(fileURLWithPath: tmp))
            guard let gz = ErpClient.gzip(src) else { lastError = "gzip"; return (false, "") }
            guard let (code, data) = request("POST", "/api/v1/batches", body: gz,
                                             headers: ["Content-Type": "application/gzip", "X-Client-Id": clientId],
                                             timeout: Double(timeoutMs) * 4 / 1000) else { return (false, "") }
            let body = String(data: data, encoding: .utf8) ?? ""
            if [200, 201, 202].contains(code) {
                let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                var id = jstr(j, "batch_id")
                if id.isEmpty { id = jstr(j, "id") }
                lastError = jstr(j, "status")   // accepted | duplicate
                return (true, id)
            }
            lastError = "HTTP \(code): \(body.left(200))"
            return (false, "")
        } catch {
            lastError = error.localizedDescription
            return (false, "")
        }
    }

    func batchStatus(_ batchId: String) -> String? {
        guard let j = get("/api/v1/batches/" + batchId) else { return nil }
        return jstr(j, "status")
    }
}
