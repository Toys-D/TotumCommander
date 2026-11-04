import AppKit
import SwiftUI

/// Где на экране стоит кнопка SwiftUI — чтобы меню программы встало рядом с ней.
///
/// Меню программы открывается в своём окне (`ContextPopupMenuController`) и просит
/// NSView, от которого отсчитать место. У кнопки SwiftUI такого вида нет; этот — есть:
/// невидимая подложка размером с кнопку, которая не ловит ни щелчков, ни наведения
/// (`hitTest` отдаёт nil), а только помнит себя.
///
///     @State private var anchor = MenuAnchorBox()
///     Button { ContextPopupMenuController.shared.show(menu, anchoredTo: anchor.view, edge: .minY) }
///         label: { … }
///         .background(MenuAnchorProbe(anchor))
final class MenuAnchorBox {
    weak var view: NSView?
}

struct MenuAnchorProbe: NSViewRepresentable {
    let box: MenuAnchorBox

    init(_ box: MenuAnchorBox) { self.box = box }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        box.view = view
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) { box.view = view }

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }
}
