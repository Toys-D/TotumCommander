import Foundation

/// Таблицы Excel в просмотре — страницей, а не окошком Quick Look.
///
/// Quick Look рисует таблицу сам, в своём процессе, и искать в ней нечем: ни текста, ни
/// подсветки от него не добиться. Но ту же самую страницу — таблицу со стилями, по файлу на
/// лист — система отдаёт и наружу (`qlmanage -p -o`). Здесь листы собираются в одну страницу,
/// один под другим, и её показывает свой вид документов: с выделением текста, масштабом и
/// поиском по всем листам сразу.
enum SpreadsheetPreview {
    /// Что открывается так. Таблицы iWork и OpenDocument система отдаёт иначе — они остаются
    /// на Quick Look.
    static let extensions: Set<String> = ["xls", "xlsx", "xlsm", "xlt", "xltx", "xltm"]

    static func isSpreadsheet(extension ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    /// Имя собранной страницы внутри папки предпросмотра.
    static let pageName = "Sheets.html"

    /// Страница таблицы в кэше `cache`; nil — система её не отдала (тогда остаётся Quick Look).
    /// Вне главного потока: запускается `qlmanage` (десятки миллисекунд на обычной таблице).
    static func convert(_ source: URL, cache: URL, timeout: TimeInterval = 30) -> URL? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: source.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let folder = cache.appendingPathComponent("sheets-\(abs(source.path.hashValue))-\(Int(stamp))",
                                                  isDirectory: true)
        if let ready = previewFolder(in: folder)?.appendingPathComponent(pageName),
           fm.fileExists(atPath: ready.path) {
            return ready
        }
        try? fm.removeItem(at: folder)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }

        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        tool.arguments = ["-p", "-o", folder.path, source.path]
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        do { try tool.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while tool.isRunning, Date() < deadline { usleep(20_000) }
        if tool.isRunning {
            tool.terminate()
            return nil
        }

        guard let preview = previewFolder(in: folder),
              let main = try? String(contentsOf: preview.appendingPathComponent("Preview.html"), encoding: .utf8)
        else { return nil }
        // Несколько листов — страница с вкладками, каждый лист в своём файле; один — страница
        // и есть лист.
        let tabs = sheets(inPreview: main)
        var parts: [(name: String, sheet: SheetParts)] = []
        if tabs.isEmpty {
            parts = [("", sheetParts(of: main, scope: scope(0)))]
        } else {
            for (index, tab) in tabs.enumerated() {
                guard let html = try? String(contentsOf: preview.appendingPathComponent(tab.file),
                                             encoding: .utf8) else { continue }
                parts.append((tab.name, sheetParts(of: html, scope: scope(index))))
            }
        }
        guard !parts.isEmpty, parts.contains(where: { !$0.sheet.body.isEmpty }) else { return nil }
        let output = preview.appendingPathComponent(pageName)
        let html = page(title: source.lastPathComponent, sheets: parts)
        guard (try? html.write(to: output, atomically: true, encoding: .utf8)) != nil else { return nil }
        return output
    }

    /// Папка, которую оставил `qlmanage`: «<имя файла>.qlpreview».
    private static func previewFolder(in folder: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "qlpreview" }
    }

    static func scope(_ index: Int) -> String { "fcxl-sheet-\(index)" }

    // MARK: Разбор страницы системы

    /// Листы книги из страницы с вкладками: имя (как в разметке, уже экранированное) и файл
    /// листа. Пусто — вкладок нет: в книге один лист, и страница — он сам.
    static func sheets(inPreview html: String) -> [(name: String, file: String)] {
        let pattern = #"<div class="TabHeader">(.*?)</div>\s*<a href="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let source = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: source.length)).map {
            (source.substring(with: $0.range(at: 1)), source.substring(with: $0.range(at: 2)))
        }
    }

    /// Лист, разобранный на то, что нужно общей странице.
    struct SheetParts: Equatable {
        /// Подключённые таблицы стилей (общий вид таблицы).
        var stylesheets: [String] = []
        /// Стили ячеек — привязанные к своему листу.
        var css = ""
        /// Сама таблица.
        var body = ""
    }

    /// Стили и таблица одного листа. Классы ячеек у листов называются одинаково («s0», «s1»), а
    /// значат разное — поэтому стили листа привязываются к его обёртке `scope`.
    static func sheetParts(of html: String, scope: String) -> SheetParts {
        var parts = SheetParts()
        parts.stylesheets = captures(#"<link\b[^>]*\bhref="([^"]+\.css)""#, in: html)
        parts.css = captures(#"<style\b[^>]*>(.*?)</style>"#, in: html)
            .map { scoped(css: $0, under: scope) }.joined(separator: "\n")
        parts.body = captures(#"<body\b[^>]*>(.*)</body>"#, in: html).first ?? ""
        return parts
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range(at: 1))
        }
    }

    /// Правила CSS — только внутри своей обёртки: «.s0.s0.s0 {…}» → «.fcxl-sheet-2 .s0.s0.s0 {…}».
    /// Вложенные правила (@media) в стилях ячеек не встречаются; встретятся — стили останутся
    /// как есть, лучше общий вид, чем сломанный.
    static func scoped(css: String, under scope: String) -> String {
        guard !css.contains("@") else { return css }
        return css.components(separatedBy: "}").compactMap { rule -> String? in
            guard let brace = rule.firstIndex(of: "{") else { return nil }
            let selectors = rule[..<brace].split(separator: ",").map {
                ".\(scope) " + $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return selectors.joined(separator: ", ") + " " + rule[brace...] + "}"
        }.joined(separator: "\n")
    }

    // MARK: Своя страница

    /// Одна страница на всю книгу: листы один под другим, у каждого заголовок с именем, сверху —
    /// полоса с именами листов (щелчок прокручивает к листу). Без `<!DOCTYPE>` — как у системы:
    /// её разметка пишет ширины колонок числом без единиц, а это понимает только старый режим.
    static func page(title: String, sheets: [(name: String, sheet: SheetParts)]) -> String {
        var links: [String] = []
        // Общая таблица стилей у всех листов одна и та же — подключаем первую.
        if let first = sheets.lazy.compactMap({ $0.sheet.stylesheets.first }).first { links.append(first) }
        var html = "<html><head><meta charset=\"utf-8\"><title>\(escaped(title))</title>"
        for link in links { html += "<link href=\"\(link)\" rel=\"stylesheet\" type=\"text/css\">" }
        html += "<style type=\"text/css\">\(ownCSS)\n"
        html += sheets.map(\.sheet.css).joined(separator: "\n")
        html += "</style></head><body>"
        let named = sheets.count > 1
        if named {
            // Полоса листов — оглавление, а не текст книги: поиск по ней не ходит.
            html += "<div class=\"fcxl-tabs\" data-fcxl-nofind>"
            for (index, sheet) in sheets.enumerated() {
                html += "<a href=\"#\(scope(index))\">\(sheet.name)</a>"
            }
            html += "</div>"
        }
        for (index, sheet) in sheets.enumerated() {
            if named { html += "<h2 class=\"fcxl-sheet-title\" id=\"\(scope(index))\">\(sheet.name)</h2>" }
            html += "<div class=\"fcxl-sheet \(scope(index))\">\(sheet.sheet.body)</div>"
        }
        return html + "</body></html>"
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Широкая таблица не сжимается под окно, а прокручивается вбок — как в Excel; полоса листов
    /// остаётся на виду.
    private static let ownCSS = """
    html, body { background: #fff; }
    table.worksheet { max-width: none !important; }
    .fcxl-sheet { overflow-x: auto; margin-bottom: 10px; }
    .fcxl-tabs { position: sticky; top: 0; z-index: 5; display: flex; flex-wrap: wrap; gap: 6px;
      padding: 6px 0 8px; background: #fff; font: 12px -apple-system, sans-serif; }
    .fcxl-tabs a { padding: 3px 10px; border: 1px solid #c8c8d0; border-radius: 6px; color: #222;
      text-decoration: none; background: #f4f4f7; }
    .fcxl-sheet-title { font: 600 13px -apple-system, sans-serif; color: #444; margin: 18px 0 6px; }
    """
}
