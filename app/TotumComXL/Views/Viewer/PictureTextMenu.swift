import AppKit

/// Правое меню над распознанным текстом картинки — в стиле программы, как у страницы PDF.
///
/// Раньше меню не было вовсе: слова подсвечивались, тянулись мышью, но единственный путь
/// в буфер был щелчок или отпускание мыши, о котором никто не догадывался. Теперь
/// правая кнопка предлагает то, что ждут: скопировать выделенное, слово или строку под
/// курсором, выделить всё, скопировать всё.
///
/// Что показать — чистая функция от состояния, и её проверяет тест; само меню собирается
/// из тех же стилевых пунктов, что и остальные меню программы.
enum PictureTextMenu {

    struct Context: Equatable {
        /// Есть ли выделение, сделанное самим человеком.
        var hasSelection = false
        /// Слово и строка под курсором, если он стоит на тексте.
        var word: String?
        var line: String?
        /// Есть ли вообще распознанный текст.
        var hasText = false
    }

    enum Action: Equatable {
        case copySelection
        case copyWord(String)
        case copyLine(String)
        case selectAll
        case copyAll
    }

    /// Пункты по порядку важности: сначала то, что человек выделил сам.
    static func actions(for context: Context) -> [Action] {
        guard context.hasText else { return [] }
        var result: [Action] = []
        if context.hasSelection { result.append(.copySelection) }
        if let word = context.word, !word.isEmpty { result.append(.copyWord(word)) }
        if let line = context.line, !line.isEmpty, line != context.word {
            result.append(.copyLine(line))
        }
        result.append(.selectAll)
        result.append(.copyAll)
        return result
    }

    /// Устойчивое имя пункта — по нему тесты и раскладка меню узнают его без перевода.
    static func id(of action: Action) -> String {
        switch action {
        case .copySelection: return "ocr.copySelection"
        case .copyWord: return "ocr.copyWord"
        case .copyLine: return "ocr.copyLine"
        case .selectAll: return "ocr.selectAll"
        case .copyAll: return "ocr.copyAll"
        }
    }

    static func title(of action: Action) -> String {
        switch action {
        case .copySelection: return L("viewer.ocr.menu.copySelection")
        case .copyWord(let word):
            return String(format: L("viewer.ocr.menu.copyWord"), excerpt(of: word))
        case .copyLine(let line):
            return String(format: L("viewer.ocr.menu.copyLine"), excerpt(of: line))
        case .selectAll: return L("viewer.ocr.menu.selectAll")
        case .copyAll: return L("viewer.ocr.copyAll")
        }
    }

    static func symbol(of action: Action) -> String {
        switch action {
        case .copySelection: return "doc.on.doc"
        case .copyWord: return "textformat.abc"
        case .copyLine: return "text.line.first.and.arrowtriangle.forward"
        case .selectAll: return "checklist"
        case .copyAll: return "doc.on.doc.fill"
        }
    }

    /// Готовое меню: выделенное, слово, строка — разделитель — выделить всё, скопировать всё.
    static func menu(for context: Context, perform: @escaping (Action) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let actions = actions(for: context)
        for (index, action) in actions.enumerated() {
            if case .selectAll = action, index > 0 { menu.addItem(.separator()) }
            menu.addStyledItem(title: title(of: action), symbolName: symbol(of: action),
                               id: id(of: action)) { perform(action) }
        }
        menu.applyAccentStyle()
        return menu
    }

    /// Начало текста в одну строку, с многоточием, когда он длиннее пункта меню.
    static func excerpt(of text: String, limit: Int = 32) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
