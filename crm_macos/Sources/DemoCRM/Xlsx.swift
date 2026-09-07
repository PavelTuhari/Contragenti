// Запись настоящего .xlsx без внешних библиотек (аналог uXlsx.pas): Open XML —
// это zip с несколькими XML внутри. Zip пишем сами (deflate через системный
// Compression, CRC32 — таблицей), строки — inlineStr.
import Foundation
import Compression

// ── минимальный zip-писатель ──

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

/// Сырой deflate (без zlib-заголовка) — то, что нужно и zip, и gzip.
func deflateRaw(_ data: Data) -> Data? {
    if data.isEmpty { return Data([0x03, 0x00]) }
    let dstSize = data.count + data.count / 2 + 64
    var dst = [UInt8](repeating: 0, count: dstSize)
    let n = data.withUnsafeBytes { src -> Int in
        compression_encode_buffer(&dst, dstSize, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
    }
    return n > 0 ? Data(dst[0..<n]) : nil
}

final class ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0

    private func le16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    func add(_ name: String, _ content: Data) {
        let nameData = Data(name.utf8)
        let crc = crc32(content)
        var method = 0
        var payload = content
        if let d = deflateRaw(content), d.count < content.count { method = 8; payload = d }
        let offset = UInt32(body.count)
        var local = Data()
        local += le32(0x04034b50); local += le16(20); local += le16(0x0800); local += le16(method)
        local += le16(0); local += le16(0x21); local += le32(crc)
        local += le32(UInt32(payload.count)); local += le32(UInt32(content.count))
        local += le16(nameData.count); local += le16(0); local += nameData
        body += local; body += payload
        var c = Data()
        c += le32(0x02014b50); c += le16(20); c += le16(20); c += le16(0x0800); c += le16(method)
        c += le16(0); c += le16(0x21); c += le32(crc)
        c += le32(UInt32(payload.count)); c += le32(UInt32(content.count))
        c += le16(nameData.count); c += le16(0); c += le16(0); c += le16(0); c += le16(0)
        c += le32(0); c += le32(offset); c += nameData
        central += c
        count += 1
    }

    func finish() -> Data {
        var end = Data()
        end += le32(0x06054b50); end += le16(0); end += le16(0); end += le16(count); end += le16(count)
        end += le32(UInt32(central.count)); end += le32(UInt32(body.count)); end += le16(0)
        return body + central + end
    }
}

// ── xlsx ──

func xmlEsc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

private func colName(_ index: Int) -> String {
    var n = index + 1
    var out = ""
    while n > 0 {
        out = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + out
        n = (n - 1) / 26
    }
    return out
}

/// Число для Excel: точка как разделитель, без пробелов-разрядов.
private func asNumber(_ s: String) -> String? {
    let t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
        .replacingOccurrences(of: ",", with: ".").trimmed
    guard !t.isEmpty, let d = Double(t) else { return nil }
    var out = String(format: "%.4f", d)
    while out.hasSuffix("0") { out.removeLast() }
    if out.hasSuffix(".") { out.removeLast() }
    return out
}

private let CONTENT_TYPES = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
"""
private let RELS = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
"""
private let WB_RELS = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
"""
// стили: 0 обычный, 1 заголовок отчёта, 2 шапка таблицы, 3 деньги, 4 итог, 5 итог-деньги
private let STYLES = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts><fonts count="4"><font><sz val="10"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font><font><b/><sz val="10"/><color rgb="FF444444"/><name val="Calibri"/></font><font><b/><sz val="10"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFECF4F8"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border/><border><left/><right/><top/><bottom style="thin"><color rgb="FFD0D7DC"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="3" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/><xf numFmtId="164" fontId="3" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
"""

func saveTableToXlsx(_ table: ReportTable, _ fileName: String) throws {
    // в имени листа Excel запрещены : \ / ? * [ ]
    var sheetName = String(table.title.map { ":\\/?*[]".contains($0) ? "-" : $0 }).left(28)
    if sheetName.isEmpty { sheetName = "Отчёт" }
    var sheet = ""
    func writeCell(_ col: Int, _ row: Int, _ text: String, _ style: String, _ numeric: Bool) {
        if text.isEmpty { return }
        sheet += "<c r=\"\(colName(col))\(row)\""
        if !style.isEmpty { sheet += " s=\"\(style)\"" }
        if numeric, let n = asNumber(text) {
            sheet += "><v>\(n)</v></c>"
        } else {
            sheet += " t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEsc(text))</t></is></c>"
        }
    }
    sheet += "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cols>"
    for c in 0..<table.colCount {
        sheet += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(max(9, table.cols[c].width / 6))\" customWidth=\"1\"/>"
    }
    sheet += "</cols><sheetData>"
    sheet += "<row r=\"1\" ht=\"20\" customHeight=\"1\">"; writeCell(0, 1, table.title, "1", false); sheet += "</row>"
    sheet += "<row r=\"2\">"; writeCell(0, 2, table.subtitle, "", false); sheet += "</row>"
    var rowNo = 4
    sheet += "<row r=\"\(rowNo)\">"
    for c in 0..<table.colCount { writeCell(c, rowNo, table.cols[c].title, "2", false) }
    sheet += "</row>"
    for r in 0..<table.rowCount {
        rowNo += 1
        sheet += "<row r=\"\(rowNo)\">"
        for c in 0..<table.colCount {
            writeCell(c, rowNo, table.cell(r, c), table.cols[c].kind == .money ? "3" : "", table.isNumeric(c))
        }
        sheet += "</row>"
    }
    if !table.totals.isEmpty {
        rowNo += 1
        sheet += "<row r=\"\(rowNo)\">"
        for c in 0..<table.colCount where c < table.totals.count {
            writeCell(c, rowNo, table.totals[c], table.cols[c].kind == .money ? "5" : "4", table.isNumeric(c))
        }
        sheet += "</row>"
    }
    sheet += "</sheetData><autoFilter ref=\"A4:\(colName(table.colCount - 1))\(4 + table.rowCount)\"/></worksheet>"

    let zip = ZipWriter()
    zip.add("[Content_Types].xml", Data(CONTENT_TYPES.utf8))
    zip.add("_rels/.rels", Data(RELS.utf8))
    zip.add("xl/workbook.xml", Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xmlEsc(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
    """.utf8))
    zip.add("xl/_rels/workbook.xml.rels", Data(WB_RELS.utf8))
    zip.add("xl/styles.xml", Data(STYLES.utf8))
    zip.add("xl/worksheets/sheet1.xml", Data(sheet.utf8))
    try? FileManager.default.removeItem(atPath: fileName)
    try zip.finish().write(to: URL(fileURLWithPath: fileName))
}
