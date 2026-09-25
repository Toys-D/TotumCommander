import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Как выглядит полоса вкладок в обеих темах. Рисуется в картинку — и это же проверка,
/// что вид собирается. Картинки — в FCXL_LOOK_DIR, чтобы посмотреть глазами.
@MainActor
final class TabsBarLookTests: XCTestCase {

    func test_полосаВкладокРисуетсяВОбеихТемах() throws {
        let tabsVM = PanelTabsViewModel(panelKey: "look.tabs.\(UUID().uuidString)",
                                        initialPath: NSHomeDirectory())
        tabsVM.newTab(path: NSHomeDirectory() + "/Documents")
        for (name, scheme) in [("вкладки-светлая", ColorScheme.light), ("вкладки-тёмная", .dark)] {
            let view = PanelTabsBarView(tabsVM: tabsVM, isPanelActive: true,
                                        onNewTab: {}, onSelectTab: { _ in }, onCloseTab: { _ in })
                .frame(width: 520)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "полоса вкладок нарисовалась (\(name))")
            XCTAssertGreaterThan(image.size.width, 100)
            if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
               let data = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            }
        }
    }
}
