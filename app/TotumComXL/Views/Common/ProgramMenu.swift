import AppKit
import SwiftUI

/// Правый щелчок по виду SwiftUI — меню программы, в её собственном окне.
///
/// `.contextMenu {}` у SwiftUI показывает системное меню: свой вид, своё появление, подменю
/// по наведению. Все меню программы идут через `ContextPopupMenuController`, и это — дорога
/// туда от вида SwiftUI. Прозрачная накладка ловит только правый щелчок и щелчок с Control
/// (остальное проходит насквозь к кнопкам под ней), меню собирается в миг щелчка, а не при
/// каждой перерисовке. Нет меню (`nil` или пустое) — щелчок ничего не открывает.
///
///     row.overlay { RightClickMenu { buildMenu() } }
struct RightClickMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu?

    init(_ makeMenu: @escaping () -> NSMenu?) { self.makeMenu = makeMenu }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.makeMenu = makeMenu
        // Без своего меню AppKit не доводит правый щелчок до menu(for:); настоящее
        // собирается там и уходит в окно меню программы.
        view.menu = NSMenu()
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.makeMenu = makeMenu }

    final class CatcherView: NSView {
        var makeMenu: (() -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let wantsMenu = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return wantsMenu ? super.hitTest(point) : nil
        }

        /// Своё окно меню — и nil системе, чтобы она не открыла ещё и своё.
        override func menu(for event: NSEvent) -> NSMenu? {
            if let menu = makeMenu?(), !menu.items.isEmpty {
                ContextPopupMenuController.shared.show(menu, for: event, in: self)
            }
            return nil
        }

        /// Щелчок с Control открыл меню (см. menu(for:)) — к кнопке под накладкой он не идёт,
        /// иначе вместе с меню сработала бы и она.
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }
}

/// Кнопка, которая открывает меню программы под собой, — вместо `Menu {}` SwiftUI, чьё меню
/// системное. Сама кнопка обычная, SwiftUI: выключается `.disabled`, подсказка — `.help`.
///
///     ProgramMenuButton(makeMenu: { saveMenu() }) { Text("Сохранить") }
struct ProgramMenuButton<Label: View>: View {
    var edge: NSRectEdge = .minY
    let makeMenu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button {
            ContextPopupMenuController.shared.show(makeMenu(), anchoredTo: anchor.view, edge: edge)
        } label: {
            label()
        }
        // Без рамки — как системный `Menu` в стиле borderlessButton, который она заменяет.
        .buttonStyle(.borderless)
        // Без синего кольца фокуса — как всё в программе.
        .focusEffectDisabled()
        .background(MenuAnchorProbe(anchor))
    }
}

/// Значок выпадающего списка у подписи кнопки — тот, что рисовал системный `Menu`.
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .opacity(0.7)
    }
}

extension NSMenu {
    /// Пункт без значка и с галочкой по желанию — для списков выбора, где значок ни о чём
    /// не говорит, а важно, что выбрано.
    func addChoiceItem(title: String, checked: Bool = false, enabled: Bool = true,
                       isDestructive: Bool = false, action: @escaping () -> Void) {
        addStyledItem(title: title, symbolName: "", isDestructive: isDestructive, action: action)
        items.last?.state = checked ? .on : .off
        items.last?.isEnabled = enabled
    }

    /// Строка-пояснение, которую нельзя выбрать («Закладок нет»).
    func addNote(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
