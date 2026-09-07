// SDK-модуль интеграции с приложением Contragenti (аналог uContragenti.pas).
//
// Contragenti запускается процессом в режиме одноразового выбора:
//   launcher --pick --out <tmp.xml> --lang <lang> [--q "<фильтр>"] --no-server --no-tray
// после выбора он пишет XML полной карточки и закрывается. Пока он открыт,
// CRM не блокируется: цикл ожидания прокачивает RunLoop ломтиками по 200 мс
// и зовёт onWait (как OnWait в Delphi).
import Foundation

struct Founder { var name = "", share = "" }
struct Debt { var nr = "", debtType = "", sum = "" }

/// Карточка контрагента, полученная из Contragenti.
struct CounterpartyCard {
    var idno = ""
    var denumire = ""
    var inregistrare = ""
    var formaJuridica = ""
    var lichidata = ""
    var adresa = ""
    var administratori = ""
    var detailsText = ""
    var source = "date.gov.md"
    var founders: [Founder] = []
    var debts: [Debt] = []

    var isEmpty: Bool { idno.isEmpty && denumire.isEmpty }
}

final class ContragentiClient {
    var launcherExe = "Contragenti"
    var extraArgs = "--no-server --no-tray"
    var lang = "ru"
    var timeoutMs = 5 * 60 * 1000
    private(set) var lastError = ""
    /// Вызывается каждые ~200 мс, пока Contragenti открыт.
    var onWait: (() -> Void)?
    private(set) var lastCommand = ""

    private func buildArgs(filter: String, outFile: String) -> [String] {
        var a = ["--pick", "--out", outFile, "--lang", lang]
        if !filter.isEmpty { a += ["--q", filter] }
        a += splitArgs(extraArgs)
        return a
    }

    /// Чем запускать: .py — через python из .venv/venv рядом со скриптом или python3.
    func launchCommand(filter: String, outFile: String) -> (String, [String]) {
        let args = buildArgs(filter: filter, outFile: outFile)
        if launcherExe.lowercased().hasSuffix(".py") {
            let dir = (launcherExe as NSString).deletingLastPathComponent
            for cand in [dir + "/.venv/bin/python", dir + "/venv/bin/python"] {
                if FileManager.default.isExecutableFile(atPath: cand) {
                    return (cand, [launcherExe] + args)
                }
            }
            return ("/usr/bin/env", ["python3", launcherExe] + args)
        }
        return (launcherExe, args)
    }

    private func runAndWait(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        lastCommand = ([exe] + args).joined(separator: " ")
        do {
            try p.run()
        } catch {
            lastError = "Не удалось запустить Contragenti (\(error.localizedDescription)). Проверьте путь: \(launcherExe)"
            return false
        }
        var elapsed = 0
        while p.isRunning {
            let until = Date(timeIntervalSinceNow: 0.2)
            if Thread.isMainThread {
                RunLoop.main.run(mode: .default, before: until)
            }
            let rest = until.timeIntervalSinceNow
            if rest > 0 { Thread.sleep(forTimeInterval: rest) }
            elapsed += 200
            onWait?()
            if elapsed >= timeoutMs {
                lastError = "Истекло время ожидания выбора контрагента."
                p.terminate()
                return false
            }
        }
        return true
    }

    /// Запускает Contragenti в режиме выбора, ждёт закрытия и разбирает XML.
    func pick(filter: String) -> CounterpartyCard? {
        lastError = ""
        let outFile = NSTemporaryDirectory() + "contragenti_\(UInt64(Date().timeIntervalSince1970 * 1000)).xml"
        try? FileManager.default.removeItem(atPath: outFile)
        let (exe, args) = launchCommand(filter: filter, outFile: outFile)
        guard runAndWait(exe, args) else { return nil }
        guard FileManager.default.fileExists(atPath: outFile) else {
            lastError = "Контрагент не выбран."
            return nil
        }
        defer { try? FileManager.default.removeItem(atPath: outFile) }
        return parseCardFile(outFile)
    }

    func parseCardFile(_ fileName: String) -> CounterpartyCard? {
        guard let data = FileManager.default.contents(atPath: fileName),
              let xml = String(data: data, encoding: .utf8) else {
            lastError = "Не удалось прочитать файл: " + fileName
            return nil
        }
        return parseCardXml(xml)
    }

    func parseCardXml(_ xml: String) -> CounterpartyCard? {
        lastError = ""
        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: xml, options: [])
        } catch {
            lastError = "Ошибка разбора XML: \(error.localizedDescription)"
            return nil
        }
        guard let root = doc.rootElement(), root.name == "counterparty" else {
            lastError = "Неверный формат XML: ожидался <counterparty>."
            return nil
        }
        func text(_ tag: String) -> String {
            root.elements(forName: tag).first?.stringValue ?? ""
        }
        var card = CounterpartyCard()
        card.idno = text("idno")
        card.denumire = text("denumire")
        card.inregistrare = text("inregistrare")
        card.formaJuridica = text("forma_juridica")
        card.lichidata = text("lichidata")
        card.adresa = text("adresa")
        card.administratori = text("administratori")
        card.detailsText = text("details_text")
        if card.idno.isEmpty, let a = root.attribute(forName: "idno")?.stringValue { card.idno = a }
        if let s = root.attribute(forName: "source")?.stringValue, !s.isEmpty { card.source = s }
        if let f = root.elements(forName: "founders").first {
            for c in f.elements(forName: "founder") {
                card.founders.append(Founder(name: c.attribute(forName: "name")?.stringValue ?? "",
                                             share: c.attribute(forName: "share")?.stringValue ?? ""))
            }
        }
        if let d = root.elements(forName: "debts").first {
            for c in d.elements(forName: "debt") {
                card.debts.append(Debt(nr: c.attribute(forName: "nr")?.stringValue ?? "",
                                       debtType: c.attribute(forName: "type")?.stringValue ?? "",
                                       sum: c.attribute(forName: "sum")?.stringValue ?? ""))
            }
        }
        if card.isEmpty {
            lastError = "Карточка пуста (нет IDNO и названия)."
            return nil
        }
        return card
    }
}
