import AppKit
import XCTest

@testable import TotumComXLApp

/// The SHAPE of the file context menu: which captions stand over which groups, what sits next
/// to what, and what folds into submenus. This is what the reorganisation was — so this is what
/// the test holds onto.
@MainActor
final class ContextMenuShapeTests: XCTestCase {

    /// Панель стоит в своей подпапке, а не в самой общей временной.
    private func makePanel(in dir: String) -> PanelViewController {
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: dir,
            pathDefaultsKey: "menu.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "menu.mode.\(UUID().uuidString)",
            showHiddenFiles: true)
        // Слежка уходит раньше папки (уборка идёт с конца): модель, потеряв папку, уходит в
        // общую временную и перечитывает её до конца прогона.
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        let tabsVM = PanelTabsViewModel(panelKey: "menu.tabs.\(UUID().uuidString)",
                                        initialPath: dir)
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()
        return vc
    }

    private func menu(for name: String, contents: Data = Data("x".utf8),
                      nestedOpenWith: Bool = false) throws -> NSMenu {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let vc = makePanel(in: dir)
        let path = (dir as NSString).appendingPathComponent(name)
        try contents.write(to: URL(fileURLWithPath: path))
        vc.viewModel.loadDirectory(at: dir)

        let item = FileItem(path: path, name: name,
                            fileExtension: (name as NSString).pathExtension,
                            size: UInt64(contents.count), isDirectory: false, isHidden: false,
                            isSymlink: false, permissions: "-rw-r--r--", dateModified: Date())
        let menu = NSMenu()
        vc.makeFileContextMenu(for: item, into: menu, nestedOpenWith: nestedOpenWith)
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    /// "Open with" stands right under "Open" — the two answer the same question, and hunting
    /// for the submenu halfway down the menu was the complaint.
    func testOpenWithStandsRightUnderOpen() throws {
        let menu = try menu(for: "записка.txt")
        let rows = titles(menu)
        guard let open = rows.firstIndex(of: L("context.open")) else {
            return XCTFail("нет пункта «Открыть»")
        }
        XCTAssertEqual(rows[open + 1], L("context.openWith"))
    }

    /// The view/edit and rename pairs are ONE group now: no separator between them.
    func testViewEditAndRenameAreOneGroup() throws {
        let menu = try menu(for: "записка.txt")
        let items = menu.items
        guard let view = items.firstIndex(where: { $0.title == L("context.view") }),
              let rename = items.firstIndex(where: { $0.title == L("context.rename") }) else {
            return XCTFail("нет пунктов просмотра или переименования")
        }
        let between = items[view..<rename]
        XCTAssertFalse(between.contains(where: \.isSeparatorItem),
                       "между «Просмотр» и «Переименовать» не должно быть черты")
    }

    /// The file-type tools fold into one submenu instead of piling up as top-level rows.
    func testTheTypeToolsFoldIntoOneSubmenu() throws {
        let menu = try menu(for: "договор.pdf", contents: Data("%PDF-1.4".utf8))
        let rows = titles(menu)
        XCTAssertTrue(rows.contains(L("context.fileTools.pdf")),
                      "на PDF строка зовётся «Инструменты PDF»")
        XCTAssertFalse(rows.contains(L("context.pdfSplit")),
                       "разделение PDF живёт в подменю, не в корне")
        let tools = menu.items.first { $0.title == L("context.fileTools.pdf") }?.submenu
        let inside = tools?.items.map(\.title) ?? []
        XCTAssertTrue(inside.contains(L("context.pdfSplit")))
        XCTAssertTrue(inside.contains(L("context.pdfRotate")))

        // And on a plain text file there is nothing to offer — so no row at all.
        let plain = try self.menu(for: "записка.txt")
        for name in [L("context.fileTools"), L("context.fileTools.pdf"),
                     L("context.fileTools.image")] {
            XCTAssertFalse(titles(plain).contains(name), "пустое подменю хуже, чем никакого")
        }
    }

    // MARK: - «Открыть с помощью» с Shift

    private func openWithRow(_ menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == "context.openWith" }
    }

    /// Без Shift — по-прежнему одна строка, которая открывает окно выбора.
    func test_безShift_открытьСПомощью_окно() throws {
        let row = try XCTUnwrap(openWithRow(try menu(for: "записка.txt")))
        XCTAssertEqual(row.title, L("context.openWith"))
        XCTAssertNil(row.submenu, "без Shift подменю нет — открывается окно")
    }

    /// С Shift — подменю: программы, которые система называет для этого файла, черта
    /// и «Другое…», ведущее в то самое окно.
    func test_сShift_открытьСПомощью_подменюПрограмм() throws {
        let row = try XCTUnwrap(openWithRow(try menu(for: "записка.txt", nestedOpenWith: true)))
        XCTAssertEqual(row.title, L("context.openWith.nested"))
        let sub = try XCTUnwrap(row.submenu, "с Shift — подменю")
        let items = sub.items
        XCTAssertEqual(items.last?.title, L("context.openWith.other"), "последним — «Другое…»")
        let apps = items.prefix { !$0.isSeparatorItem }
        let probe = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x.txt")
        if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: probe) {
            let name = PanelViewController.applicationDisplayName(defaultApp)
            XCTAssertEqual(apps.first?.title, String(format: L("context.openWith.default"), name),
                           "первой — программа по умолчанию, с пометкой")
            XCTAssertNotNil(apps.first?.image, "у программы — её значок")
        }
        XCTAssertEqual(row.image != nil, true)
    }

    /// Порядок: программа по умолчанию первой, остальные по имени, без повтора.
    func test_порядокПрограмм_поУмолчаниюПервой() {
        let a = URL(fileURLWithPath: "/Applications/Яблоко.app")
        let b = URL(fileURLWithPath: "/Applications/Банан.app")
        let c = URL(fileURLWithPath: "/Applications/Апельсин.app")
        XCTAssertEqual(PanelViewController.orderedOpenWithApplications([a, b, c], defaultApp: b),
                       [b, c, a])
        XCTAssertEqual(PanelViewController.orderedOpenWithApplications([a, c], defaultApp: nil),
                       [c, a])
        XCTAssertEqual(PanelViewController.orderedOpenWithApplications([a], defaultApp: b), [b, a],
                       "программа по умолчанию первой, даже если её нет в списке системы")
    }
}
