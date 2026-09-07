// PDF с таблицей отчёта через системный CoreGraphics (CGPDFContext) и
// CoreText: шрифт встраивается системой, кириллица без ручного CIDFont
// (PORT_MACOS_ru.md §4 разрешает PDFKit/CoreGraphics вместо uPdf.pas).
import Foundation
import CoreGraphics
import CoreText
import AppKit

func saveTableToPdf(_ table: ReportTable, _ fileName: String) throws {
    // альбомный A4 в пунктах
    let pageW: CGFloat = 842, pageH: CGFloat = 595
    let margin: CGFloat = 36
    var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
    try? FileManager.default.removeItem(atPath: fileName)
    guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: fileName) as CFURL),
          let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle as String: table.title] as CFDictionary) else {
        throw SQLiteError(message: "не удалось создать PDF: " + fileName)
    }

    let fontName = "Helvetica" as CFString
    let fontR = CTFontCreateWithName(fontName, 8.5, nil)
    let fontB = CTFontCreateCopyWithSymbolicTraits(fontR, 8.5, nil, .boldTrait, .boldTrait) ?? fontR
    let fontTitle = CTFontCreateWithName(fontName, 14, nil)
    let fontTitleB = CTFontCreateCopyWithSymbolicTraits(fontTitle, 14, nil, .boldTrait, .boldTrait) ?? fontTitle
    let fontSub = CTFontCreateWithName(fontName, 9, nil)

    // ширины колонок масштабируем под страницу
    let totalW = CGFloat(table.cols.reduce(0) { $0 + max(30, $1.width) })
    let avail = pageW - 2 * margin
    let scale = min(1.0, avail / max(totalW, 1))
    let widths = table.cols.map { CGFloat(max(30, $0.width)) * scale }

    func draw(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, font: CTFont, color: CGColor, right: Bool) {
        if text.isEmpty { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var s = text
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        // обрезаем по ширине колонки
        while CTLineGetTypographicBounds(line, nil, nil, nil) > Double(w - 4) && s.count > 1 {
            s.removeLast()
            line = CTLineCreateWithAttributedString(NSAttributedString(string: s + "…", attributes: attrs))
        }
        let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: right ? x + w - 2 - tw : x + 2, y: y)
        CTLineDraw(line, ctx)
    }

    let rowH: CGFloat = 15
    let textColor = CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
    let mutedColor = CGColor(red: 0.41, green: 0.5, blue: 0.56, alpha: 1)
    let headBg = CGColor(red: 0.925, green: 0.957, blue: 0.973, alpha: 1)
    let lineColor = CGColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1)

    var page = 0
    var y: CGFloat = 0
    func beginPage() {
        page += 1
        ctx.beginPDFPage(nil)
        y = pageH - margin
        if page == 1 {
            draw(table.title, x: margin, y: y - 14, w: avail, font: fontTitleB, color: textColor, right: false)
            y -= 22
            draw(table.subtitle, x: margin, y: y - 9, w: avail, font: fontSub, color: mutedColor, right: false)
            y -= 20
        }
        // шапка таблицы
        ctx.setFillColor(headBg)
        ctx.fill(CGRect(x: margin, y: y - rowH, width: avail, height: rowH))
        var x = margin
        for (i, c) in table.cols.enumerated() {
            draw(c.title, x: x, y: y - rowH + 4, w: widths[i], font: fontB, color: mutedColor,
                 right: c.kind == .money || c.kind == .number || c.kind == .right)
            x += widths[i]
        }
        y -= rowH
        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: y)); ctx.addLine(to: CGPoint(x: margin + avail, y: y)); ctx.strokePath()
    }
    func endPage() {
        draw("Demo CRM · \(table.title) · стр. \(page)", x: margin, y: margin - 14, w: avail, font: fontSub, color: mutedColor, right: false)
        ctx.endPDFPage()
    }

    beginPage()
    func rowLine(_ cells: [String], bold: Bool) {
        if y - rowH < margin + 10 { endPage(); beginPage() }
        var x = margin
        for (i, c) in table.cols.enumerated() {
            let text = i < cells.count ? cells[i] : ""
            draw(text, x: x, y: y - rowH + 4, w: widths[i], font: bold ? fontB : fontR, color: textColor,
                 right: c.kind == .money || c.kind == .number || c.kind == .right)
            x += widths[i]
        }
        y -= rowH
        ctx.setStrokeColor(lineColor)
        ctx.move(to: CGPoint(x: margin, y: y)); ctx.addLine(to: CGPoint(x: margin + avail, y: y)); ctx.strokePath()
    }
    for r in 0..<table.rowCount {
        rowLine((0..<table.colCount).map { table.cell(r, $0) }, bold: false)
    }
    if !table.totals.isEmpty { rowLine(table.totals, bold: true) }
    endPage()
    ctx.closePDF()
}
