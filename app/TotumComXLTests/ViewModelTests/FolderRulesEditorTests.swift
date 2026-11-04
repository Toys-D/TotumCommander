import AppKit
import SwiftUI
import XCTest

@testable import TotumComXLApp

/// Редактор правил папок: список слева живёт в прокрутке только когда есть что прокручивать.
/// С системной настройкой «полосы прокрутки: всегда» пустая прокрутка рисовала полосу во всю
/// высоту над пустым списком.
@MainActor
final class FolderRulesEditorTests: XCTestCase {

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { sub -> [NSScrollView] in
            ((sub as? NSScrollView).map { [$0] } ?? []) + scrollViews(in: sub)
        }
    }

    private func hosted(rules: [FolderRule]) -> NSHostingView<FolderRulesEditorView> {
        let host = NSHostingView(rootView: FolderRulesEditorView(session: FCXLDialogSession<[FolderRule]>(),
                                                                 rules: rules))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func test_пустойСписокБезПрокрутки() {
        XCTAssertTrue(scrollViews(in: hosted(rules: [])).isEmpty,
                      "над пустым списком нечего прокручивать — и нечему рисовать полосу")
    }

    func test_сПравиламиСписокПрокручивается() {
        var rule = FolderRule(name: "Фото")
        rule.conditions = [RuleCondition()]
        XCTAssertFalse(scrollViews(in: hosted(rules: [rule])).isEmpty, "список правил — в прокрутке")
    }
}
