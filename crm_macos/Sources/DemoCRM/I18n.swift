// Локализация интерфейса (аналог uI18n.pas). Тексты — во внешнем lang.json.
// Выбранный язык хранится в UserDefaults домена md.una.contragenti.democrm,
// ключ Language (аналог HKCU\Software\DemoCRM\Language на Windows); мастер
// настройки читает/пишет его через `defaults read/write`.
import Foundation

struct LangInfo { let code: String; let name: String }

final class I18n {
    static let defaultsDomain = "md.una.contragenti.democrm"

    private var strings: [String: String] = [:]
    private var enums: [String: [String]] = [:]
    private(set) var langs: [LangInfo] = []
    private(set) var lang = "ro"
    private(set) var fileName = ""
    private(set) var loaded = false
    private(set) var error = ""

    /// Домен бандла — это UserDefaults.standard; suiteName с именем своего
    /// бандла AppKit не поддерживает (значения не сохраняются).
    private static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == defaultsDomain ? .standard : (UserDefaults(suiteName: defaultsDomain) ?? .standard)
    }

    static func readLangFromDefaults(_ def: String) -> String {
        if let v = defaults.string(forKey: "Language"), !v.isEmpty { return v }
        return def
    }

    static func writeLangToDefaults(_ code: String) {
        defaults.set(code, forKey: "Language")
        defaults.synchronize()
    }

    @discardableResult
    func load(_ path: String? = nil) -> Bool {
        loaded = false
        error = ""
        let p = path ?? Paths.resource("lang.json") ?? (Paths.appDir + "/lang.json")
        fileName = p
        guard FileManager.default.fileExists(atPath: p) else {
            error = "Не найден файл переводов: " + p
            return false
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: p))
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error = "lang.json повреждён: не удалось разобрать JSON"
                return false
            }
            langs = []
            if let arr = root["languages"] as? [[String: Any]] {
                for l in arr {
                    langs.append(LangInfo(code: l["code"] as? String ?? "", name: l["name"] as? String ?? ""))
                }
            }
            if langs.isEmpty {
                error = "в lang.json не описан ни один язык"
                return false
            }
            loaded = true
            parseLang(root, code: lang)
            return true
        } catch {
            self.error = "lang.json: \(error.localizedDescription)"
            return false
        }
    }

    private func parseLang(_ root: [String: Any], code: String) {
        strings = [:]
        enums = [:]
        guard let l = root[code] as? [String: Any] else { return }
        if let s = l["strings"] as? [String: Any] {
            for (k, v) in s { strings[k] = "\(v)" }
        }
        if let e = l["enums"] as? [String: Any] {
            for (k, v) in e {
                if let arr = v as? [Any] { enums[k] = arr.map { "\($0)" } }
            }
        }
    }

    func useLang(_ code: String) {
        guard langs.contains(where: { $0.code.lowercased() == code.lowercased() }) else { return }
        lang = code
        if loaded, let data = FileManager.default.contents(atPath: fileName),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            parseLang(root, code: code)
        }
        I18n.writeLangToDefaults(code)
    }

    /// Ключ, которого нет в переводе, показываем как есть.
    func S(_ key: String) -> String { strings[key] ?? key }

    func F(_ key: String, _ args: [Any]) -> String { fmtDelphi(S(key), args) }

    func enumList(_ name: String) -> [String] { enums[name] ?? [] }

    func enumAt(_ name: String, _ index: Int) -> String {
        let l = enumList(name)
        return (index >= 0 && index < l.count) ? l[index] : ""
    }
}

/// Единственный экземпляр на приложение (T в Delphi).
let T = I18n()
