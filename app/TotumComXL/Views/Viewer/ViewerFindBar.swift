import SwiftUI

/// Полоса поиска в просмотре с разделителем под ней — или ничего, пока поиск закрыт. Стоит
/// между шапкой просмотра и содержимым, как полоса поиска редактора F4.
struct ViewerFindBarHost: View {
    @ObservedObject var model: ViewerFindModel

    var body: some View {
        if model.isVisible {
            VStack(spacing: 0) {
                ViewerFindBar(model: model)
                Divider()
            }
        }
    }
}

/// Поиск по тексту в просмотре: поле, счётчик, «Назад» и «Дальше», регистр и «слово целиком».
/// Вид тот же, что у полосы редактора (её кнопки и поле), только без замены и выражений —
/// просмотр ничего не правит.
struct ViewerFindBar: View {
    @ObservedObject var model: ViewerFindModel

    private static let fieldWidth: CGFloat = 240

    var body: some View {
        // Узкое место (панель в половину окна) не обрезает кнопки: полоса едет вбок.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                field
                    .id(model.focusToken)
                Text(model.counterText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isMiss ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 64, alignment: .leading)
                    .padding(.horizontal, 4)
                Button { model.previous() } label: {
                    FCXLBarLabel(title: L("editor.find.previous"), symbol: "chevron.up")
                }
                .help(L("editor.find.previous.tip"))
                .disabled(!model.canStep)
                Button { model.next() } label: {
                    FCXLBarLabel(title: L("editor.find.next"), symbol: "chevron.down")
                }
                .help(L("editor.find.next.tip"))
                .disabled(!model.canStep)
                separator
                option(L("editor.find.matchCase"), symbol: "textformat.alt", isOn: $model.matchCase)
                    .help(L("editor.find.matchCase.tip"))
                option(L("editor.find.wholeWord"), symbol: "character.textbox", isOn: $model.wholeWord)
                    .help(L("editor.find.wholeWord.tip"))
                separator
                Button { model.close() } label: {
                    FCXLBarLabel(title: L("common.close"), symbol: "xmark")
                }
                .help(L("editor.find.close.tip"))
            }
            .buttonStyle(FCXLBarButtonStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    /// Красным — только настоящее «не найдено», а не «ищу» и не причина, по которой искать нечем.
    private var isMiss: Bool {
        !model.query.isEmpty && !model.isSearching && model.result.count == 0
            && model.result.note == nil && !model.result.more
    }

    private var field: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            FCXLDialogTextField(text: $model.query, placeholder: L("editor.find.label"),
                                focusOnAppear: true, initialSelection: .all,
                                onSubmit: {
                                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                                        model.previous()
                                    } else {
                                        model.next()
                                    }
                                },
                                onCancel: { model.close() },
                                fontSize: 12)
        }
        .padding(.horizontal, 7)
        .frame(width: Self.fieldWidth, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
        .padding(.trailing, 2)
    }

    /// Переключатель поиска: значок и подпись, включённый — на подложке акцента.
    private func option(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            FCXLBarLabel(title: title, symbol: symbol)
        }
        .buttonStyle(FCXLBarButtonStyle(isOn: isOn.wrappedValue))
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }
}
