import AppKit
import SwiftUI

/// Поиск и замена в редакторе F4 — своей полосой, где каждая кнопка подписана словами.
///
/// Окошко Monaco рисовало вместо подписей значки (Aa, ab, .*, стрелки, квадратики замены), и
/// что они делают, приходилось угадывать. Ищет и заменяет по-прежнему сам Monaco: его состояние
/// поиска, подсветка всех совпадений, ⌘G и ⇧⌘G, «Заменить все» одним шагом отмены, $1 в
/// регулярных выражениях. Полоса только говорит ему, что искать, и показывает, сколько нашлось.
/// Страница — monaco-editor.html, объект `fcxlFind`; её окошко там спрятано.
@MainActor
final class EditorFindModel: ObservableObject {
    @Published private(set) var isVisible = false
    @Published var showsReplace = false
    @Published var query = "" { didSet { if query != oldValue { push() } } }
    @Published var replacement = "" { didSet { if replacement != oldValue { push() } } }
    @Published var matchCase = false { didSet { if matchCase != oldValue { push() } } }
    @Published var wholeWord = false { didSet { if wholeWord != oldValue { push() } } }
    @Published var isRegex = false { didSet { if isRegex != oldValue { push() } } }
    /// Сколько совпадений и которое из них текущее (0 — курсор не на совпадении).
    @Published private(set) var count = 0
    @Published private(set) var position = 0
    /// Растёт при каждом открытии: поле «Найти» создаётся заново и снова получает клавиатуру —
    /// и когда ⌘F нажали при уже открытой полосе.
    @Published private(set) var focusToken = 0

    /// Выполнить строку JavaScript на странице редактора.
    var run: ((String) -> Void)?
    /// Вернуть клавиатуру тексту — полоса закрыта.
    var onClose: (() -> Void)?
    /// Окно, где стоит полоса. Esc и в главном окне, и в окне F4 сначала закрывает её, а не
    /// весь редактор (`closeVisible(in:)`).
    var window: (() -> NSWindow?)?

    private static let shown = NSHashTable<EditorFindModel>.weakObjects()

    /// Закрыть открытые полосы этого окна. true — было что закрыть: Esc на этом и кончается.
    static func closeVisible(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        var closed = false
        for model in shown.allObjects where model.isVisible && model.window?() === window {
            model.close()
            closed = true
        }
        return closed
    }

    /// ⌘F, ⌘R, кнопки «Найти» и «Заменить»: страница берёт выделенное одной строкой и
    /// отвечает `opened(replace:seed:)` — у всех дорог один конец.
    func requestOpen(replace: Bool) {
        run?("fcxlFind.open(\(replace))")
    }

    /// Страница открыла поиск. Выделенное одной строкой — уже искомое.
    func opened(replace: Bool, seed: String) {
        if !seed.isEmpty { query = seed }
        showsReplace = replace
        isVisible = true
        Self.shown.add(self)
        focusToken &+= 1
        // Выделенное остаётся текущим совпадением: курсор не двигается.
        push(moveCursor: false)
    }

    func next() {
        guard canStep else { return }
        run?("fcxlFind.next()")
    }

    func previous() {
        guard canStep else { return }
        run?("fcxlFind.previous()")
    }

    func replaceOne() {
        guard canStep else { return }
        run?("fcxlFind.replace()")
    }

    func replaceAll() {
        guard canStep else { return }
        run?("fcxlFind.replaceAll()")
    }

    func close() {
        guard isVisible else { return }
        hide()
        run?("fcxlFind.close()")
        onClose?()
    }

    /// Ответ страницы: сколько нашлось и которое сейчас. Поиск закрыли в самом тексте — полоса
    /// уходит тоже.
    func pageState(revealed: Bool, count: Int, position: Int) {
        if self.count != count { self.count = count }
        if self.position != position { self.position = position }
        if !revealed, isVisible { hide() }
    }

    /// Переходить и заменять есть смысл, только когда что-то нашлось.
    var canStep: Bool { !query.isEmpty && count > 0 }

    var counterText: String { Self.counterText(count: count, position: position, query: query) }

    /// «3 из 8», «Найдено: 8», если курсор не на совпадении, «Не найдено» и пусто, пока не ищем.
    static func counterText(count: Int, position: Int, query: String) -> String {
        guard !query.isEmpty else { return "" }
        guard count > 0 else { return L("editor.find.none") }
        guard position > 0 else { return L("editor.find.total", count) }
        return L("editor.find.counter", position, count)
    }

    /// Что искать — на страницу. JSON, а не склейка строк: кавычки, обратная косая и переводы
    /// строки в запросе доходят как есть.
    static func setScript(query: String, replacement: String, matchCase: Bool,
                          wholeWord: Bool, isRegex: Bool, moveCursor: Bool = true) -> String? {
        let payload: [String: Any] = ["query": query, "replacement": replacement,
                                      "matchCase": matchCase, "wholeWord": wholeWord, "isRegex": isRegex]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "fcxlFind.set(\(json), \(moveCursor))"
    }

    private func push(moveCursor: Bool = true) {
        guard isVisible,
              let script = Self.setScript(query: query, replacement: replacement, matchCase: matchCase,
                                          wholeWord: wholeWord, isRegex: isRegex,
                                          moveCursor: moveCursor) else { return }
        run?(script)
    }

    private func hide() {
        isVisible = false
        Self.shown.remove(self)
    }
}

/// Полоса поиска с разделителем под ней — или ничего, пока поиск закрыт. Её ставят и окно F4,
/// и панель напротив, между панелью инструментов и текстом.
struct EditorFindBarHost: View {
    @ObservedObject var model: EditorFindModel

    var body: some View {
        if model.isVisible {
            VStack(spacing: 0) {
                EditorFindBar(model: model)
                Divider()
            }
        }
    }
}

struct EditorFindBar: View {
    @ObservedObject var model: EditorFindModel
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""

    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }
    /// Подписи полей одной ширины — поля и галочки под ними встают в одну линию.
    private static let captionWidth: CGFloat = 84
    private static let fieldWidth: CGFloat = 260

    var body: some View {
        // Узкое место (панель в половину окна) не обрезает кнопки: полоса едет вбок.
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    caption(L("editor.find.label"))
                    field($model.query, focus: true) {
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                            model.previous()
                        } else {
                            model.next()
                        }
                    }
                    .id(model.focusToken)
                    Text(model.counterText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(model.count == 0 && !model.query.isEmpty ? Color.red : Color.secondary)
                        .frame(minWidth: 80, alignment: .leading)
                    Button(L("editor.find.previous")) { model.previous() }
                        .help(L("editor.find.previous.tip"))
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(!model.canStep)
                    Button(L("editor.find.next")) { model.next() }
                        .help(L("editor.find.next.tip"))
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(!model.canStep)
                    if !model.showsReplace {
                        Button(L("editor.find.showReplace")) { model.showsReplace = true }
                    }
                    Button(L("common.close")) { model.close() }
                        .help(L("editor.find.close.tip"))
                }
                if model.showsReplace {
                    HStack(spacing: 6) {
                        caption(L("editor.find.replaceLabel"))
                        field($model.replacement, focus: false) { model.replaceOne() }
                        Button(L("editor.find.replace")) { model.replaceOne() }
                            .help(L("editor.find.replace.tip"))
                            .disabled(!model.canStep)
                        Button(L("editor.find.replaceAll")) { model.replaceAll() }
                            .help(L("editor.find.replaceAll.tip"))
                            .disabled(!model.canStep)
                    }
                }
                HStack(spacing: 6) {
                    Color.clear.frame(width: Self.captionWidth, height: 1)
                    option(L("editor.find.matchCase"), isOn: $model.matchCase)
                    option(L("editor.find.wholeWord"), isOn: $model.wholeWord)
                    option(L("editor.find.regex"), isOn: $model.isRegex)
                }
            }
            .buttonStyle(FCXLChipButtonStyle(compact: true))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: Self.captionWidth, alignment: .trailing)
    }

    private func field(_ text: Binding<String>, focus: Bool, onSubmit: @escaping () -> Void) -> some View {
        FCXLDialogTextField(text: text, focusOnAppear: focus, initialSelection: .all,
                            onSubmit: onSubmit, onCancel: { model.close() }, fontSize: 12)
            .padding(.horizontal, 6)
            .frame(width: Self.fieldWidth, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
    }

    /// Галочка словами: «Учитывать регистр», а не «Aa».
    private func option(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? accent : Color.secondary)
                Text(title)
            }
        }
    }
}
