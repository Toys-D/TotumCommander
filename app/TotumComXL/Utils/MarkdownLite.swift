import Foundation

/// Крошечный переводчик Markdown в HTML — ровно для справки программы.
///
/// Справка пишется в Markdown: так её удобно читать и в репозитории, и на GitHub. В окне
/// же она показывается веб-видом, и ему нужен HTML. Тащить ради этого чужую библиотеку —
/// лишний вес в бандле; Foundation умеет разбирать Markdown, но SwiftUI рисует из него
/// только строчные стили, без заголовков и таблиц. Здесь — то подмножество, которым
/// написана справка: заголовки, абзацы, списки, таблицы, линейки, жирный, код, ссылки.
enum MarkdownLite {

    /// Весь документ в HTML-тело (без <html>/<body>: их даёт тот, кто показывает).
    static func html(from markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var table: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>")
            paragraph.removeAll()
        }
        func flushList() {
            guard let current = list else { return }
            let tag = current.ordered ? "ol" : "ul"
            out.append("<\(tag)>" + current.items.map { "<li>" + inline($0) + "</li>" }.joined() + "</\(tag)>")
            list = nil
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            out.append(tableHTML(table))
            table.removeAll()
        }
        func flushAll() { flushParagraph(); flushList(); flushTable() }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushAll(); continue }

            if line.hasPrefix("|") {
                flushParagraph(); flushList()
                table.append(line)
                continue
            }
            flushTable()

            if line == "---" { flushAll(); out.append("<hr>"); continue }

            if let level = headingLevel(line) {
                flushAll()
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                out.append("<h\(level) id=\"\(anchor(text))\">" + inline(text) + "</h\(level)>")
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                if list == nil || list?.ordered == true { flushList(); list = (false, []) }
                list?.items.append(String(line.dropFirst(2)))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber),
               !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                if list == nil || list?.ordered == false { flushList(); list = (true, []) }
                list?.items.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }

            // Строка списка с отступом — продолжение последнего пункта; иначе — абзац.
            if list != nil, rawLine.hasPrefix("  "), var items = list?.items, !items.isEmpty {
                items[items.count - 1] += " " + line
                list?.items = items
                continue
            }
            flushList()
            paragraph.append(line)
        }
        flushAll()
        return out.joined(separator: "\n")
    }

    /// Разделы документа по заголовкам второго уровня: заголовок и его текст в Markdown.
    /// Текст до первого «## » — вступление под пустым заголовком.
    static func sections(of markdown: String) -> [(title: String, body: String)] {
        var result: [(String, String)] = []
        var title = ""
        var body: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                result.append((title, body.joined(separator: "\n")))
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = []
            } else {
                body.append(line)
            }
        }
        result.append((title, body.joined(separator: "\n")))
        return result.filter { !$0.0.isEmpty || !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Кусочки

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...4).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func tableHTML(_ lines: [String]) -> String {
        func cells(_ line: String) -> [String] {
            var body = line
            if body.hasPrefix("|") { body.removeFirst() }
            if body.hasSuffix("|") { body.removeLast() }
            return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparator(_ line: String) -> Bool {
            cells(line).allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }
        }
        var rows = lines
        var head: [String]? = nil
        if rows.count >= 2, isSeparator(rows[1]) {
            head = cells(rows[0])
            rows.removeFirst(2)
        }
        var html = "<table>"
        if let head {
            html += "<thead><tr>" + head.map { "<th>" + inline($0) + "</th>" }.joined() + "</tr></thead>"
        }
        html += "<tbody>"
        for row in rows where !isSeparator(row) {
            html += "<tr>" + cells(row).map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>"
        }
        return html + "</tbody></table>"
    }

    /// Строчные стили: `код`, **жирный**, [текст](адрес). Сначала экранирование — текст
    /// справки не должен превращаться в разметку, даже если в нём есть «<».
    static func inline(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, pattern: "`([^`]+)`") { "<code>\($0)</code>" }
        s = replace(s, pattern: "\\*\\*(.+?)\\*\\*") { "<strong>\($0)</strong>" }
        s = replaceLinks(s)
        return s
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replace(_ s: String, pattern: String, _ wrap: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let inner = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(whole, with: wrap(String(result[inner])))
        }
        return result
    }

    private static func replaceLinks(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)") else { return s }
        var result = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let text = Range(match.range(at: 1), in: result),
                  let href = Range(match.range(at: 2), in: result) else { continue }
            result.replaceSubrange(whole, with: "<a href=\"\(result[href])\">\(result[text])</a>")
        }
        return result
    }

    /// Якорь заголовка: латиница и кириллица, цифры, дефисы.
    static func anchor(_ title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}
