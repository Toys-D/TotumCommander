import AppKit
import FCXLBridgeObjC
import FCXLDjVuUI
import PDFKit

/// Печать — одна дорога для всей программы: файлы из панели, открытый в просмотре документ,
/// текст редактора. Всё, что печатается за раз, собирается в один PDF и уходит одним заданием в
/// системное окно печати: там выбор принтера, копии, страницы, двусторонняя печать, бумага и
/// предпросмотр, и там же macOS помнит последний принтер.
@MainActor
enum PrintService {
    /// Что открывается как оформленный документ средствами самой macOS: Word, OpenDocument,
    /// RTF, HTML. Таблицы и презентации (xlsx, pptx, Numbers, Keynote) она так не читает.
    static let documentExtensions: Set<String> = [
        "doc", "docx", "odt", "rtf", "rtfd", "html", "htm", "webarchive",
    ]

    /// Можно ли напечатать файл: есть ли чем превратить его в страницы.
    static func canPrint(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if documentExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        switch fileCategory(forFileName: name) {
        case .pdf, .image, .vectorImage, .text, .markdown, .djvu, .postScript:
            return true
        default:
            return false
        }
    }

    /// Файлы — одним заданием, в том порядке, в каком даны. Чего напечатать нельзя, пропускается;
    /// что не удалось подготовить, называется до окна печати.
    static func print(files paths: [String], window: NSWindow? = nil) {
        let printable = paths.filter(canPrint)
        guard !printable.isEmpty else {
            DialogService.shared.showWarning(title: L("print.title"), message: L("print.nothing"))
            return
        }
        let title = printable.count == 1
            ? (printable[0] as NSString).lastPathComponent
            : L("print.jobTitle.files", printable.count)
        Task { @MainActor in
            let (document, failed) = await assemble(printable)
            if !failed.isEmpty {
                let names = failed.map { "• " + ($0 as NSString).lastPathComponent }.joined(separator: "\n")
                DialogService.shared.showWarning(
                    title: L("print.title"),
                    message: L(document.pageCount > 0 ? "print.someFailed" : "print.allFailed", names))
            }
            guard document.pageCount > 0 else { return }
            run(document, title: title, window: window)
        }
    }

    /// Текст как есть — у редактора с несохранёнными правками, у просмотра в выбранной кодировке.
    static func print(text: String, title: String, window: NSWindow? = nil) {
        print(attributed: plainText(text), title: title, window: window)
    }

    /// Оформленный текст — RTF-редактор.
    static func print(attributed text: NSAttributedString, title: String, window: NSWindow? = nil) {
        guard let document = paginate(text), document.pageCount > 0 else { return }
        run(document, title: title, window: window)
    }

    // MARK: - Сборка

    /// Страницы всех файлов подряд. Тяжёлое — чтение PDF, картинок, DjVu и PostScript — идёт вне
    /// главного потока; текст раскладывается на страницы на нём: это делает NSTextView.
    static func assemble(_ paths: [String]) async -> (document: PDFDocument, failed: [String]) {
        let document = PDFDocument()
        var failed: [String] = []
        for path in paths {
            let part: PDFDocument?
            if let text = await styledText(of: path) {
                part = paginate(text)
            } else {
                let data = await Task.detached(priority: .userInitiated) { pagesData(of: path) }.value
                part = data.flatMap(PDFDocument.init(data:))
            }
            guard let part, part.pageCount > 0 else {
                failed.append(path)
                continue
            }
            for index in 0..<part.pageCount {
                if let page = part.page(at: index) { document.insert(page, at: document.pageCount) }
            }
        }
        return (document, failed)
    }

    /// Текст файла, если это текст или документ; nil — файл страничный (PDF, картинка, скан).
    private static func styledText(of path: String) async -> NSAttributedString? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if documentExtensions.contains(url.pathExtension.lowercased()) {
            // HTML разбирает WebKit — только на главном потоке.
            return try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
        switch fileCategory(forFileName: name) {
        case .markdown:
            guard let source = readText(path) else { return nil }
            return MarkdownStyler.render(source, baseFont: .systemFont(ofSize: 11),
                                          ink: .black, link: .systemBlue) ?? plainText(source)
        case .text:
            return readText(path).map(plainText)
        default:
            return nil
        }
    }

    /// Страничный файл — PDF-данными, чтобы их можно было передать из фонового потока.
    nonisolated private static func pagesData(of path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let document = PDFDocument()
        func add(_ image: NSImage?) {
            if let image, let page = PDFPage(image: image) { document.insert(page, at: document.pageCount) }
        }
        switch fileCategory(forFileName: name) {
        case .pdf:
            return PDFDocument(url: url)?.dataRepresentation()
        case .image:
            add(NSImage(contentsOf: url))
        case .vectorImage:
            // Illustrator с PDF внутри открывается как PDF, остальное — картинкой или Ghostscript'ом.
            if let pdf = PDFDocument(url: url), pdf.pageCount > 0 { return pdf.dataRepresentation() }
            add(NSImage(contentsOf: url) ?? PostScriptRenderer.renderToImage(path: path, targetLongEdge: 3508))
        case .postScript:
            add(PostScriptRenderer.renderToImage(path: path, targetLongEdge: 3508))
        case .djvu:
            guard let reader = try? FCXLDjVuReader(path: path) else { return nil }
            for index in 0..<reader.pageCount {
                let size = reader.pageSize(at: index)
                // Около 300 точек на дюйм для листа шириной 8,5 дюйма.
                let scale = size.width > 1 ? (300 * 8.5) / size.width : 1
                add(DjVuPagesView.render(reader: reader, index: index, scale: max(1, min(scale, 4))))
            }
        default:
            return nil
        }
        return document.pageCount > 0 ? document.dataRepresentation() : nil
    }

    /// Текст файла: в своей кодировке, а не угадалась — UTF-8 и Windows-1251.
    private static func readText(_ path: String) -> String? {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOfFile: path, usedEncoding: &encoding) { return text }
        for fallback in [String.Encoding.utf8, .windowsCP1251] {
            if let text = try? String(contentsOfFile: path, encoding: fallback) { return text }
        }
        return nil
    }

    /// Простой текст для бумаги: моноширинный, чёрный — как бы ни был оформлен экран.
    static func plainText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.black,
        ])
    }

    /// Текст — листами бумаги, на которую печатают. Текст разливается по контейнерам размером с
    /// поле листа, и каждый рисуется своей страницей PDF: одна длинная страница, как выходило у
    /// pdfOperation, на бумаге ужалась бы до нечитаемой.
    static func paginate(_ text: NSAttributedString) -> PDFDocument? {
        let info = printInfo()
        let paper = info.paperSize
        let field = NSSize(width: paper.width - info.leftMargin - info.rightMargin,
                           height: paper.height - info.topMargin - info.bottomMargin)
        guard field.width > 0, field.height > 0 else { return nil }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var sheets: [NSTextContainer] = []
        repeat {
            let sheet = NSTextContainer(size: field)
            sheet.lineFragmentPadding = 0
            layout.addTextContainer(sheet)
            sheets.append(sheet)
            // Лист, на который не легло ничего (картинка выше листа), — конец: иначе листы
            // добавлялись бы без конца.
            if layout.glyphRange(for: sheet).length == 0, layout.numberOfGlyphs > 0 { break }
        } while NSMaxRange(layout.glyphRange(for: sheets[sheets.count - 1])) < layout.numberOfGlyphs
            && sheets.count < 5000

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        // Цвета вроде «цвет текста» — светлого вида: на бумаге текст чёрный, а не белый тёмной темы.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for sheet in sheets {
                context.beginPDFPage(nil)
                context.translateBy(x: 0, y: paper.height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let glyphs = layout.glyphRange(for: sheet)
                let origin = NSPoint(x: info.leftMargin, y: info.topMargin)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    // MARK: - Печать

    private static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        for margin in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] {
            info[keyPath: margin] = 36
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        return info
    }

    /// Системное окно печати — листом на окне программы.
    private static func run(_ document: PDFDocument, title: String, window: NSWindow?) {
        guard let operation = document.printOperation(for: printInfo(), scalingMode: .pageScaleToFit,
                                                      autoRotate: true) else { return }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize,
                                                .showsOrientation, .showsScaling, .showsPreview])
        // Окно просмотра плавающее и не берёт фокус — лист на нём не держится; тогда на главном.
        let host = [window, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { !($0 is NSPanel) && $0.isVisible }
        if let host {
            operation.runModal(for: host, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

/// Чем печатать открытый документ: вид кладёт сюда свою печать, а клавиша и меню её зовут.
@MainActor
final class PrintHandle {
    var action: (() -> Void)?
}
