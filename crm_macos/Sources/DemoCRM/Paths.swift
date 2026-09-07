// Где программа и где данные (аналог CrmDataDir из uClientsDB.pas и
// поиска lang.json / processes.json рядом с программой).
//
//   <appDir>/Demo CRM.app            — бандл
//   <appDir>/DemoCRM/clients.db …    — «рядом с программой», если туда можно
//                                      писать и это не /Applications
//   ~/Library/Application Support/Contragenti/DemoCRM/ — иначе (см. PORT_MACOS_ru.md §1.2)
import Foundation

enum Paths {
    /// Каталог, где лежит бандл (или бинарник, если запущен не из .app).
    static var appDir: String = {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let comps = exe.pathComponents
        if let i = comps.lastIndex(where: { $0.hasSuffix(".app") }) {
            return NSString.path(withComponents: Array(comps[0..<i]))
        }
        return exe.deletingLastPathComponent().path
    }()

    static var bundleResources: String? {
        Bundle.main.resourcePath
    }

    /// Каталог исходников репозитория (запуск из DerivedData / из клона) — для
    /// разработки: там же лежат crm_delphi/lang.json и company_search.py.
    static var repoDir: String? = {
        var dir = URL(fileURLWithPath: appDir)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("company_search.py").path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
            if dir.path == "/" { break }
        }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: src.appendingPathComponent("company_search.py").path) {
            return src.path
        }
        return nil
    }()

    private static var dataDirCache: String?

    static func isInsideApplications(_ dir: String) -> Bool {
        let home = NSHomeDirectory()
        return dir.hasPrefix("/Applications/") || dir == "/Applications" ||
            dir.hasPrefix(home + "/Applications/") || dir == home + "/Applications"
    }

    private static func writable(_ dir: String) -> Bool {
        let probe = dir + "/~w\(ProcessInfo.processInfo.processIdentifier).tmp"
        guard FileManager.default.createFile(atPath: probe, contents: Data()) else { return false }
        try? FileManager.default.removeItem(atPath: probe)
        return true
    }

    /// Каталог данных CRM (clients.db, crm.ini, reports/), со слэшем на конце.
    static var crmDataDir: String {
        if let c = dataDirCache { return c }
        let local = appDir + "/DemoCRM"
        if !isInsideApplications(appDir) {
            try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
            if writable(local) {
                dataDirCache = local + "/"
                return dataDirCache!
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Contragenti/DemoCRM").path
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        // первый запуск: демо-база и настройки из установки становятся рабочими
        for name in ["clients.db", "crm.ini"] {
            let src = local + "/" + name, dst = support + "/" + name
            if FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst) {
                try? FileManager.default.copyItem(atPath: src, toPath: dst)
            }
        }
        dataDirCache = support + "/"
        return dataDirCache!
    }

    static var logsDir: String {
        let d = NSHomeDirectory() + "/Library/Logs/Contragenti"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// Внешний файл (lang.json, processes.json, sample_card.xml): приоритет у
    /// DemoCRM/ рядом с бандлом — мастер может обновлять переводы без пересборки;
    /// затем каталог данных, затем Contents/Resources, затем crm_delphi/ в клоне.
    static func resource(_ name: String) -> String? {
        var cands = [appDir + "/DemoCRM/" + name, appDir + "/" + name, crmDataDir + name]
        if let r = bundleResources { cands.append(r + "/" + name) }
        if let repo = repoDir { cands.append(repo + "/crm_delphi/" + name) }
        return cands.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Кандидаты на запуск Contragenti (PORT_MACOS_ru.md §6.2), по порядку.
    static var launcherCandidates: [String] {
        let home = NSHomeDirectory()
        var c = [
            appDir + "/Contragenti.app/Contents/MacOS/Contragenti",
            (appDir as NSString).deletingLastPathComponent + "/Contragenti.app/Contents/MacOS/Contragenti",
            (appDir as NSString).deletingLastPathComponent + "/company_search.py",
        ]
        if let repo = repoDir { c.append(repo + "/company_search.py") }
        c += ["/Applications/Contragenti/Contragenti.app/Contents/MacOS/Contragenti",
              home + "/Applications/Contragenti/Contragenti.app/Contents/MacOS/Contragenti"]
        return c
    }
}
