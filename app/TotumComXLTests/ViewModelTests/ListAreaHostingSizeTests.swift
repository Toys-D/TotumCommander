import AppKit
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Вид SwiftUI на месте списка не задаёт размер окна.
///
/// На macOS 27 переход в подробный вид ужимал всё окно до 513×208 точек: вид краткого режима
/// ещё стоял на месте, а его содержимое уже было пустым, и NSHostingView переносил «не больше
/// нуля» в ограничения (приоритет 999,9) — AppKit подгоняла под них окно.
@MainActor
final class ListAreaHostingSizeTests: XCTestCase {

    private func panelInWindow() throws -> (PanelViewController, PanelViewModel, String) {
        let folder = NSTemporaryDirectory() + "listarea-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/a.txt", contents: Data("x".utf8))
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: folder,
                                pathDefaultsKey: "panel.path.listarea.\(id)",
                                viewModeDefaultsKey: "panel.mode.listarea.\(id)", showHiddenFiles: false)
        let vc = PanelViewController(viewModel: vm, tabsVM: PanelTabsViewModel(panelKey: "tabs.listarea.\(id)",
                                                                             initialPath: folder), side: .left)
        vc.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = vc.view
        vm.loadFileSystemDirectory(at: folder, resetCursor: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (vc, vm, folder)
    }

    private func hostingViews(in view: NSView) -> [NSHostingView<AnyView>] {
        (view.subviews.compactMap { $0 as? NSHostingView<AnyView> })
    }

    func test_краткийВидНеЗадаётРазмерОкна_иПустой() throws {
        let (vc, vm, folder) = try panelInWindow()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        vm.viewMode = .brief
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let hosting = try XCTUnwrap(hostingViews(in: vc.view).first, "вид краткого режима на месте")
        XCTAssertEqual(hosting.sizingOptions, [], "размер — от краёв области списка")

        // Миг перехода: режим уже подробный, содержимое пустое, а вид ещё стоит.
        hosting.rootView = AnyView(EmptyView())
        hosting.layoutSubtreeIfNeeded()
        let fromContent = hosting.constraints.compactMap(\.identifier).filter { $0.hasPrefix("NSHostingView.") }
        XCTAssertEqual(fromContent, [], "ни «не больше», ни «не меньше» от содержимого: \(fromContent)")
    }

    func test_мониторНеЗадаётРазмерОкна() throws {
        let (vc, _, folder) = try panelInWindow()
        defer {
            if vc.isMonitorMode { vc.toggleMonitor() }
            try? FileManager.default.removeItem(atPath: folder)
        }
        vc.toggleMonitor()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let monitor = try XCTUnwrap(hostingViews(in: vc.view).first, "монитор на месте списка")
        XCTAssertEqual(monitor.sizingOptions, [])
    }
}
