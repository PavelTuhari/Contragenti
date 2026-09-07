// JSON с сохранением порядка ключей — для processes.json, который CRM
// редактирует и записывает обратно (JsonPretty в uProcess.pas). Стандартный
// JSONSerialization порядок ключей теряет.
import Foundation

indirect enum JValue {
    case object([(String, JValue)])
    case array([JValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(key: String) -> JValue? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    var arrayValue: [JValue] {
        if case .array(let a) = self { return a }
        return []
    }

    /// Установить ключ в объекте (заменяет существующий, иначе добавляет).
    mutating func set(_ key: String, _ value: JValue) {
        guard case .object(var pairs) = self else { return }
        if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
        self = .object(pairs)
    }

    mutating func setAt(_ index: Int, _ value: JValue) {
        guard case .array(var a) = self, index >= 0, index < a.count else { return }
        a[index] = value
        self = .array(a)
    }
}

struct JParseError: Error { let message: String }

struct JParser {
    private let s: [UInt8]
    private var i = 0

    init(_ text: String) { s = Array(text.utf8) }

    static func parse(_ text: String) throws -> JValue {
        var p = JParser(text)
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        if p.i != p.s.count { throw JParseError(message: "лишние данные после JSON") }
        return v
    }

    private mutating func skipWS() {
        while i < s.count, [0x20, 0x09, 0x0A, 0x0D].contains(s[i]) { i += 1 }
    }

    private mutating func value() throws -> JValue {
        guard i < s.count else { throw JParseError(message: "неожиданный конец") }
        switch s[i] {
        case UInt8(ascii: "{"):
            i += 1
            var pairs: [(String, JValue)] = []
            skipWS()
            if i < s.count, s[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWS()
                let k = try string()
                skipWS()
                guard i < s.count, s[i] == UInt8(ascii: ":") else { throw JParseError(message: "ожидалось ':'") }
                i += 1
                skipWS()
                pairs.append((k, try value()))
                skipWS()
                guard i < s.count else { throw JParseError(message: "незакрытый объект") }
                if s[i] == UInt8(ascii: ",") { i += 1; continue }
                if s[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw JParseError(message: "ожидалось ',' или '}'")
            }
        case UInt8(ascii: "["):
            i += 1
            var arr: [JValue] = []
            skipWS()
            if i < s.count, s[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
            while true {
                skipWS()
                arr.append(try value())
                skipWS()
                guard i < s.count else { throw JParseError(message: "незакрытый массив") }
                if s[i] == UInt8(ascii: ",") { i += 1; continue }
                if s[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                throw JParseError(message: "ожидалось ',' или ']'")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null"); return .null
        default:
            let start = i
            while i < s.count, "+-0123456789.eE".utf8.contains(s[i]) { i += 1 }
            guard let d = Double(String(decoding: s[start..<i], as: UTF8.self)) else {
                throw JParseError(message: "неверное число")
            }
            return .number(d)
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= s.count, Array(s[i..<i + w.count]) == w else { throw JParseError(message: "ожидалось \(word)") }
        i += w.count
    }

    private mutating func string() throws -> String {
        guard i < s.count, s[i] == UInt8(ascii: "\"") else { throw JParseError(message: "ожидалась строка") }
        i += 1
        var out: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < s.count else { break }
                let e = s[i]
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard i + 4 < s.count, var code = UInt32(String(decoding: s[i + 1...i + 4], as: UTF8.self), radix: 16) else {
                        throw JParseError(message: "неверная \\u-последовательность")
                    }
                    i += 4
                    // суррогатная пара
                    if (0xD800...0xDBFF).contains(code), i + 6 < s.count, s[i + 1] == UInt8(ascii: "\\"), s[i + 2] == UInt8(ascii: "u"),
                       let lo = UInt32(String(decoding: s[i + 3...i + 6], as: UTF8.self), radix: 16), (0xDC00...0xDFFF).contains(lo) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                        i += 6
                    }
                    if let sc = Unicode.Scalar(code) { out.append(contentsOf: Array(String(Character(sc)).utf8)) }
                default: out.append(e)
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        throw JParseError(message: "незакрытая строка")
    }
}

/// Читаемая запись (как JsonPretty в uProcess.pas): короткие объекты из
/// строк — переводы { "ro": …, "en": …, "ru": … } — в одну строку.
enum JWriter {
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if ch.value < 32 { out += String(format: "\\u%04X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    static func pretty(_ v: JValue, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch v {
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            var simple = pairs.count <= 3
            for (_, val) in pairs { if case .string = val {} else { simple = false } }
            if simple {
                return "{ " + pairs.map { "\"\(escape($0.0))\": \(pretty($0.1, indent: 0))" }.joined(separator: ", ") + " }"
            }
            var out = "{\n"
            for (i, (k, val)) in pairs.enumerated() {
                out += inner + "\"\(escape(k))\": " + pretty(val, indent: indent + 2)
                if i < pairs.count - 1 { out += "," }
                out += "\n"
            }
            return out + pad + "}"
        case .array(let arr):
            if arr.isEmpty { return "[]" }
            var out = "[\n"
            for (i, val) in arr.enumerated() {
                out += inner + pretty(val, indent: indent + 2)
                if i < arr.count - 1 { out += "," }
                out += "\n"
            }
            return out + pad + "]"
        case .string(let s): return "\"" + escape(s) + "\""
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
}
