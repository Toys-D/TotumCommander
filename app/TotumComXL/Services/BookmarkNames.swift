import AppKit
import PDFKit

/// Чем закладка называет себя сама.
///
/// «Страница 9» ничего не говорит через неделю: человек ставил закладку не на девятую
/// страницу, а на место, где о чём-то шла речь. Имя берётся с самой страницы — заголовком,
/// первой строкой, названием главы, — и остаётся до тех пор, пока человек не назовёт её
/// по-своему.
/// Как считаются страницы в сканах.
///
/// В файле обложка — первый лист, но в книге она не страница: нумерация начинается после
/// обложки, титула и его оборота. Пока счётчик считал листы, «стр. 9 из 282» расходилось с
/// тем, что напечатано на странице.
enum PageNumbering {

    /// Номер, напечатанный в книге, или nil — если лист лежит до начала нумерации.
    static func printed(index: Int, start: Int) -> Int? {
        let number = index - start + 1
        return number > 0 ? number : nil
    }

    /// Сколько страниц НАПЕЧАТАНО: обложка и титул в счёт книги не входят, иначе последняя
    /// страница оказалась бы «283-й из 282».
    static func numberedCount(total: Int, start: Int) -> Int {
        max(1, total - start)
    }

    /// Про этот файл ещё не решали. У DjVu первый лист — обложка: так эти книги и сканируют,
    /// и счёт с неё сбивает нумерацию с самого начала. Остальное считается как есть.
    static func defaultStart(forFile path: String) -> Int {
        fileCategory(extension: (path as NSString).pathExtension) == .djvu ? 1 : 0
    }
}

enum BookmarkName {

    /// Сколько знаков имени влезает в строку меню, не растягивая его на весь экран.
    static let maxLength = 42

    /// Собрать имя из номера и названия. Номер — тот, что НАПЕЧАТАН в книге: обложка и
    /// титул номера не имеют, и закладка на них так и называется. Иначе счётчик говорил бы
    /// «стр. 9», а закладка на том же месте — «Страница 12».
    static func compose(number: Int?, title: String?) -> String {
        let name = title.map { shorten($0) }.flatMap { $0.isEmpty ? nil : $0 }
        guard let number else {
            return name.map { String(format: L("viewer.bookmark.coverIn"), $0) }
                ?? L("viewer.page.cover")
        }
        return name.map { String(format: L("viewer.bookmark.pageIn"), number, $0) }
            ?? String(format: L("viewer.bookmark.pageOnly"), number)
    }

    /// Название страницы — раздел оглавления или заголовок с самой страницы. Дорогая часть:
    /// читается документ. Вызывать только не на главном потоке.
    static func title(ofFile path: String, page: Int) -> String? {
        firstMeaningfulLine(ofFile: path, page: page)
    }

    // MARK: - Откуда берётся строка

    /// Только надёжные источники. Скан — не источник: у двухколоночной книги распознавание
    /// сшивает колонки, и «первая строка страницы» оказывается серединой чужой фразы
    /// («Крез Кре6 13. Kpi4» — настоящий улов с настоящей страницы). Честное «Страница 9»
    /// лучше уверенного вранья, а назвать место по-своему человек может сам.
    private static func firstMeaningfulLine(ofFile path: String, page: Int) -> String? {
        guard fileCategory(extension: (path as NSString).pathExtension) == .pdf,
              let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        // Оглавление документа — лучшее, что может быть: раздел назван автором.
        if let section = sectionTitle(in: document, page: page) { return section }
        // Иначе текстовый слой страницы: там сохранён порядок строк, а не догадка о нём.
        guard let text = document.page(at: page)?.string else { return nil }
        return pick(from: text)
    }

    /// Раздел оглавления, внутри которого лежит страница.
    static func sectionTitle(in document: PDFDocument, page: Int) -> String? {
        guard let root = document.outlineRoot else { return nil }
        var best: (page: Int, title: String)?
        var stack = [root]
        while let node = stack.popLast() {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                stack.append(child)
                guard let destination = child.destination?.page,
                      let label = child.label, !label.isEmpty else { continue }
                let start = document.index(for: destination)
                guard start != NSNotFound, start <= page else { continue }
                if best == nil || start > best!.page { best = (start, label) }
            }
        }
        return best?.title
    }

    /// Первая строка, которая действительно что-то НАЗЫВАЕТ. Мера строгая, и намеренно:
    /// строка обязана начинаться с начала — с заглавной буквы, а не с середины разорванного
    /// слова — и не обрываться переносом.
    static func pick(from text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = stripLeadingNumbering(
                raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard names(line) else { continue }
            return line
        }
        return nil
    }

    private static func names(_ line: String) -> Bool {
        // Колонцифры, номера и обрывки в два слога отсекаются длиной.
        guard line.count >= 8 else { return false }
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 5 else { return false }
        // Со строчной начинается продолжение чужой фразы, а не название.
        guard let first = line.first, !first.isLowercase else { return false }
        // Слово, разорванное переносом, дочитать неоткуда.
        return !line.hasSuffix("-") && !line.hasSuffix("–") && !line.hasSuffix("¬")
    }

    /// Убрать нумерацию впереди: «1.1 Identify the purpose» → «Identify the purpose».
    /// Номер страницы у закладки и так есть, а нумерация пунктов съедает ту половину строки,
    /// по которой место и узнаётся.
    private static func stripLeadingNumbering(_ line: String) -> String {
        let junk = CharacterSet(charactersIn: "0123456789. \t)(-–—§№")
        var trimmed = Substring(line)
        while let first = trimmed.unicodeScalars.first, junk.contains(first) {
            trimmed = trimmed.dropFirst()
        }
        // Если после чистки не осталось ничего — строка и была одними цифрами.
        return trimmed.count >= 4 ? String(trimmed) : line
    }

    /// Обрезать по слову, а не по букве: «Центр и фла…» читается хуже, чем «Центр и…».
    static func shorten(_ text: String, limit: Int = maxLength) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let cut = clean.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return cut[cut.startIndex..<space] + "…"
        }
        return cut + "…"
    }
}
