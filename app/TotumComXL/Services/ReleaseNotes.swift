import Foundation

/// Текст выпуска с GitHub — для раздела «Обновления».
///
/// Заметки пишутся на двух языках: английская половина, черта, русская, у каждой свой
/// заголовок «## What's new» / «## Что нового». Раздел показывает половину на языке программы
/// и раскладывает её построчно: жирная строка — группа, «- » — пункт, остальное — абзац.
/// Строчная разметка (жирное, ссылки) остаётся в тексте строки — её разбирает `Text`.
enum ReleaseNotes {

    enum Line: Equatable {
        case group(String)
        case item(String)
        case text(String)
    }

    static func lines(of body: String, russian: Bool) -> [Line] {
        var rows = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Русская половина начинается с заголовка по-русски; если его нет — язык один.
        if let split = rows.firstIndex(where: { $0.hasPrefix("#") && $0.contains(where: isCyrillic) }) {
            rows = russian ? Array(rows[split...]) : Array(rows[..<split])
        }
        var result: [Line] = []
        var titled = false
        for row in rows where !row.isEmpty && row != "---" {
            if row.hasPrefix("#") {
                // Первый заголовок — «Что нового»: версия и так написана над заметками.
                let title = row.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if titled { result.append(.group(title)) }
                titled = true
            } else if row.hasPrefix("- ") || row.hasPrefix("* ") {
                result.append(.item(String(row.dropFirst(2))))
            } else if row.count > 4, row.hasPrefix("**"), row.hasSuffix("**"),
                      !row.dropFirst(2).dropLast(2).contains("**") {
                result.append(.group(String(row.dropFirst(2).dropLast(2))))
            } else {
                result.append(.text(row))
            }
        }
        return result
    }

    private static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
