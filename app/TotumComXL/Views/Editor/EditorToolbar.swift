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

    @Published var font = "SF Mono" {
        didSet { if font != oldValue { editor?.setFontFamily(font) } }
    }
    @Published var fontSize = 13 {
        didSet { if fontSize != oldValue { editor?.setFontSize(fontSize) } }
    }
    @Published var theme = "vs-dark" {
        didSet { if theme != oldValue { editor?.setTheme(theme) } }
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

/// Панель инструментов редактора. Что делает кнопка, написано на ней: значки без подписей
/// приходилось угадывать.
struct EditorToolbar: View {
    @ObservedObject var options: EditorViewOptions
    /// Поиск и замена — у каждого редактора свои (EditorFindModel).
    let onFind: () -> Void
    let onReplace: () -> Void

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FCXLDialogMenuPicker(items: MonacoEditorController.editorFonts, selection: $options.font,
                                     title: { $0 }, compact: true, chipWidth: 78)
                HStack(spacing: 3) {
                    Text(L("editor.toolbar.size"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("−") { options.fontSize = max(8, options.fontSize - 1) }
                    Text("\(options.fontSize)")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(minWidth: 18)
                    Button("+") { options.fontSize = min(72, options.fontSize + 1) }
                }
                separator
                FCXLDialogMenuPicker(items: MonacoEditorController.editorThemes.map(\.id), selection: $options.theme,
                                     title: { id in MonacoEditorController.editorThemes.first { $0.id == id }?.name ?? id },
                                     compact: true, chipWidth: 68)
                separator
                Button(L("editor.toolbar.find"), action: onFind)
                    .help(L("editor.toolbar.find.tip"))
                Button(L("editor.toolbar.replace"), action: onReplace)
                    .help(L("editor.toolbar.replace.tip"))
                separator
                toggle(L("editor.toolbar.wordWrap"), isOn: $options.wordWrap)
                FCXLDialogMenuPicker(items: Array(EditorViewOptions.whitespaceModes.indices),
                                     selection: $options.whitespace,
                                     title: { EditorViewOptions.whitespaceTitle($0) }, compact: true)
                toggle(L("editor.toolbar.minimap"), isOn: $options.minimap)
                FCXLDialogMenuPicker(items: Array(EditorViewOptions.lineHighlightModes.indices),
                                     selection: $options.lineHighlight,
                                     title: { EditorViewOptions.lineHighlightTitle($0) }, compact: true)
                separator
                FCXLDialogMenuPicker(items: MonacoEditorController.editorLanguages.map(\.id),
                                     selection: $options.language,
                                     title: { MonacoEditorController.languageName(for: $0) },
                                     compact: true, chipWidth: 72)
            }
            .buttonStyle(FCXLChipButtonStyle(compact: true))
            .padding(.horizontal, 6)
        }
        .frame(height: 30)
    }

    private var separator: some View {
        Divider().frame(height: 16)
    }

    /// Включено — плашка залита акцентом, как нажатая кнопка; выключено — обычная.
    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button(title) { isOn.wrappedValue.toggle() }
            .buttonStyle(FCXLChipButtonStyle(compact: true, fill: isOn.wrappedValue ? accent : nil))
    }
}
