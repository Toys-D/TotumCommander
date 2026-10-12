import AppKit
import SwiftUI

/// Вид текста в редакторе F4 — один выбор на оба его места: окно и панель напротив.
///
/// Выбранное сразу уходит в редактор. Клавиши окна (⇧⌘W, ⇧⌘M, ⇧⌘I) меняют этот же выбор, так
/// что полоса показывает то, что в тексте на самом деле, — раньше значки окна от клавиш не
/// менялись.
@MainActor
final class EditorViewOptions: ObservableObject {
    static let whitespaceModes = ["none", "boundary", "all"]
    static let lineHighlightModes = ["none", "gutter", "line", "all"]

    /// Куда уходит выбор. Пока редактора нет, выбор копится и уходит целиком в `apply(to:)`.
    weak var editor: MonacoEditorController?
    /// Окно F4 помнит язык у каждой вкладки.
    var onLanguageChange: ((String) -> Void)?
    /// Окно F4 перекрашивает свою рамку под тему текста (EditorChrome).
    var onThemeChange: ((String) -> Void)?

    @Published var font = "SF Mono" {
        didSet { if font != oldValue { editor?.setFontFamily(font) } }
    }
    @Published var fontSize = 13 {
        didSet { if fontSize != oldValue { editor?.setFontSize(fontSize) } }
    }
    @Published var theme = "vs-dark" {
        didSet {
            guard theme != oldValue else { return }
            editor?.setTheme(theme)
            onThemeChange?(theme)
        }
    }
    @Published var wordWrap = true {
        didSet { if wordWrap != oldValue { editor?.toggleWordWrap(wordWrap) } }
    }
    @Published var whitespace = 0 {
        didSet { if whitespace != oldValue { editor?.toggleWhitespace(Self.whitespaceModes[whitespace]) } }
    }
    @Published var minimap = true {
        didSet { if minimap != oldValue { editor?.toggleMinimap(minimap) } }
    }
    @Published var lineHighlight = 0 {
        didSet { if lineHighlight != oldValue { editor?.setLineHighlight(Self.lineHighlightModes[lineHighlight]) } }
    }
    @Published var language = "plaintext" {
        didSet {
            guard language != oldValue else { return }
            editor?.setLanguage(language)
            onLanguageChange?(language)
        }
    }

    /// Всё выбранное — в редактор: он только что готов или в нём сменился файл.
    func apply(to editor: MonacoEditorController) {
        editor.setFontFamily(font)
        editor.setFontSize(fontSize)
        editor.setTheme(theme)
        editor.toggleWordWrap(wordWrap)
        editor.toggleWhitespace(Self.whitespaceModes[whitespace])
        editor.toggleMinimap(minimap)
        editor.setLineHighlight(Self.lineHighlightModes[lineHighlight])
    }

    static func whitespaceTitle(_ index: Int) -> String {
        L("editor.whitespace.\(whitespaceModes[index])")
    }

    static func lineHighlightTitle(_ index: Int) -> String {
        L("editor.lineHighlight.\(lineHighlightModes[index])")
    }
}

/// Цвета рамки редактора — заголовка, полос и строки состояния — по теме текста.
///
/// Полосы стояли на подложке панели или окна, а подписи брали цвет из темы программы: у тёмного
/// текста под светлой темой выходили чёрные буквы на сером. Теперь рамка того же цвета, что и сам
/// текст в Monaco: тёмная тема — тёмная рамка со светлыми подписями, светлая — светлая.
struct EditorChrome: Equatable {
    /// Ровно фон текста в теме Monaco (editor.background).
    let background: NSColor
    /// Светлые или тёмные подписи, поля и меню.
    let scheme: ColorScheme

    static func forTheme(_ id: String) -> EditorChrome {
        switch id {
        case "vs": return EditorChrome(background: rgb(0xFF, 0xFF, 0xFE), scheme: .light)
        case "hc-black": return EditorChrome(background: rgb(0x00, 0x00, 0x00), scheme: .dark)
        default: return EditorChrome(background: rgb(0x1E, 0x1E, 0x1E), scheme: .dark)
        }
    }

    /// Оформление окна AppKit под эту рамку — для окна F4 целиком.
    var appearance: NSAppearance? {
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// Рамка редактора цветом темы текста; следит за выбором темы на полосе.
struct EditorChromeModifier: ViewModifier {
    @ObservedObject var options: EditorViewOptions

    func body(content: Content) -> some View {
        let chrome = EditorChrome.forTheme(options.theme)
        content
            .background(Color(nsColor: chrome.background))
            .environment(\.colorScheme, chrome.scheme)
    }
}

extension View {
    /// Фон и цвет подписей — как у текста в редакторе (EditorChrome).
    func editorChrome(_ options: EditorViewOptions) -> some View {
        modifier(EditorChromeModifier(options: options))
    }
}

/// Панель инструментов редактора: у каждой кнопки значок и подпись, без серых плашек — подложка
/// появляется под мышью, а включённое стоит на подложке акцента.
struct EditorToolbar: View {
    @ObservedObject var options: EditorViewOptions
    /// Поиск и замена — у каждого редактора свои (EditorFindModel).
    let onFind: () -> Void
    let onReplace: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                FCXLBarMenu(items: MonacoEditorController.editorFonts, selection: $options.font,
                            title: { $0 }, symbol: "textformat", captionWidth: 64)
                    .help(L("editor.toolbar.font.tip"))
                fontSize
                FCXLBarMenu(items: MonacoEditorController.editorThemes.map(\.id), selection: $options.theme,
                            title: { id in MonacoEditorController.editorThemes.first { $0.id == id }?.name ?? id },
                            symbol: "circle.lefthalf.filled")
                    .help(L("editor.toolbar.theme.tip"))
                separator
                Button(action: onFind) {
                    FCXLBarLabel(title: L("editor.toolbar.find"), symbol: "magnifyingglass")
                }
                .help(L("editor.toolbar.find.tip"))
                Button(action: onReplace) {
                    FCXLBarLabel(title: L("editor.toolbar.replace"), symbol: "arrow.left.arrow.right")
                }
                .help(L("editor.toolbar.replace.tip"))
                separator
                Button { options.wordWrap.toggle() } label: {
                    FCXLBarLabel(title: L("editor.toolbar.wordWrap"), symbol: "arrow.turn.down.left")
                }
                .buttonStyle(FCXLBarButtonStyle(isOn: options.wordWrap))
                .help(L("editor.toolbar.wordWrap.tip"))
                FCXLBarMenu(items: Array(EditorViewOptions.whitespaceModes.indices), selection: $options.whitespace,
                            title: { EditorViewOptions.whitespaceTitle($0) }, symbol: "paragraphsign",
                            caption: L("editor.toolbar.whitespace"), isOn: options.whitespace != 0)
                    .help(L("editor.toolbar.whitespace.tip"))
                Button { options.minimap.toggle() } label: {
                    FCXLBarLabel(title: L("editor.toolbar.minimap"), symbol: "map")
                }
                .buttonStyle(FCXLBarButtonStyle(isOn: options.minimap))
                .help(L("editor.toolbar.minimap.tip"))
                FCXLBarMenu(items: Array(EditorViewOptions.lineHighlightModes.indices),
                            selection: $options.lineHighlight,
                            title: { EditorViewOptions.lineHighlightTitle($0) }, symbol: "highlighter",
                            caption: L("editor.toolbar.lineHighlight"), isOn: options.lineHighlight != 0)
                    .help(L("editor.toolbar.lineHighlight.tip"))
                separator
                FCXLBarMenu(items: MonacoEditorController.editorLanguages.map(\.id), selection: $options.language,
                            title: { MonacoEditorController.languageName(for: $0) },
                            symbol: "chevron.left.forwardslash.chevron.right")
                    .help(L("editor.toolbar.language.tip"))
            }
            .buttonStyle(FCXLBarButtonStyle())
            .padding(.horizontal, 6)
        }
        .frame(height: 30)
    }

    /// Размер шрифта: значок с числом и шаг на пункт в обе стороны.
    private var fontSize: some View {
        HStack(spacing: 0) {
            Button { options.fontSize = max(8, options.fontSize - 1) } label: {
                Image(systemName: "minus")
            }
            HStack(spacing: 4) {
                Image(systemName: "textformat.size")
                Text("\(options.fontSize)")
                    .monospacedDigit()
                    .frame(minWidth: 14)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.primary.opacity(0.82))
            .padding(.horizontal, 2)
            Button { options.fontSize = min(72, options.fontSize + 1) } label: {
                Image(systemName: "plus")
            }
        }
        .help(L("editor.toolbar.size"))
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }
}
