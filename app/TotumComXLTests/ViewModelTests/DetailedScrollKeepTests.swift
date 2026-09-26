import AppKit
import XCTest
@testable import TotumComXLApp

/// Перечитка той же папки не прокручивает подробный список к курсору: человек листает
/// трекпадом вверх, курсор внизу, а в папке что-то изменилось — список должен остаться, где он.
@MainActor
final class DetailedScrollKeepTests: XCTestCase {

    func test_перечиткаТойЖеПапкиНеПрыгаетККурсору() throws {
        let folder = NSTemporaryDirectory() + "scrollkeep-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for i in 0..<120 {
            FileManager.default.createFile(atPath: folder + String(format: "/файл-%03d.txt", i), contents: Data("x".utf8))
        }
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: folder,
                                pathDefaultsKey: "panel.path.scrollkeep.\(id)",
                                viewModeDefaultsKey: "panel.mode.scrollkeep.\(id)", showHiddenFiles: false)
        vm.viewMode = .detailed
        let tabs = PanelTabsViewModel(panelKey: "tabs.scrollkeep.\(id)", initialPath: folder)
        let vc = PanelViewController(viewModel: vm, tabsVM: tabs, side: .left)
        vc.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = vc.view
        vm.loadFileSystemDirectory(at: folder, resetCursor: true)
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, vm.items.count < 120 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
            if let t = v as? T { return t }
            for s in v.subviews { if let f = find(type, in: s) { return f } }
            return nil
        }
        let table = try XCTUnwrap(find(NSTableView.self, in: vc.view))
        let scroll = try XCTUnwrap(table.enclosingScrollView)

        // Курсор в самом низу, список прокручен к нему.
        vm.setCursor(index: vm.items.count - 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100, "к курсору внизу прокрутили")

        // Человек листает наверх.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)

        // В папке что-то изменилось — перечитка той же папки.
        vm.reloadKeepingCursor()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5,
                       "перечитка не вернула список к курсору")
        XCTAssertEqual(vm.cursorIndex, vm.items.count - 1, "курсор остался где был")
    }
}
