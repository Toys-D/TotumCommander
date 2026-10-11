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

    /// Активная вкладка выше соседей. Сверяется по пикселям в обеих темах; картинки — в
    /// FCXL_LOOK_DIR, чтобы посмотреть глазами.
    func test_активнаяВкладкаВышеСоседей() throws {
        let defaults = UserDefaults.standard
        let settings: [String: Double] = [
            "tabChipHeight": 32, "tabBarHeight": 36, TabLook.activeLiftKey: 4,
            "tabMaxWidth": 200, "tabMinWidth": 80, "tabBarSpacing": 10, "tabCornerRadius": 8,
        ]
        let before = settings.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in before {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }

        let tabsVM = PanelTabsViewModel(panelKey: "look.lift.\(UUID().uuidString)",
                                        initialPath: NSHomeDirectory())
        tabsVM.newTab(path: NSHomeDirectory() + "/Documents")
        XCTAssertEqual(tabsVM.activeIndex, 1)

        for (name, appearanceName) in [("подъём-светлая", NSAppearance.Name.aqua), ("подъём-тёмная", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bar = PanelTabsBarView(tabsVM: tabsVM, isPanelActive: true,
                                       onNewTab: {}, onSelectTab: { _ in }, onCloseTab: { _ in })
                .frame(width: 520)
            let host = NSHostingView(rootView: bar)
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            }

            // Полоса 36 pt, вкладки по 200 pt с шагом 10 от отступа 8: неактивная 8…208,
            // активная 218…418, правее — пустой фон полосы.
            XCTAssertEqual(host.bounds.height, 36, accuracy: 0.5, "\(name): подъём вошёл, полоса не выросла")
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                let color = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale)))
                return try XCTUnwrap(color.usingColorSpace(.sRGB))
            }
            func same(_ a: NSColor, _ b: NSColor) -> Bool {
                abs(a.redComponent - b.redComponent) <= 2.5 / 255
                    && abs(a.greenComponent - b.greenComponent) <= 2.5 / 255
                    && abs(a.blueComponent - b.blueComponent) <= 2.5 / 255
            }
            let barBackground = try pixel(440, 2)
            XCTAssertTrue(same(try pixel(8 + 60, 2), barBackground),
                          "\(name): неактивная вкладка начинается ниже — над ней фон полосы")
            XCTAssertFalse(same(try pixel(218 + 60, 2), barBackground),
                           "\(name): активная поднята — на той же высоте уже она")
            XCTAssertFalse(same(try pixel(8 + 60, 6), barBackground),
                           "\(name): чуть ниже начинается и неактивная")
        }
    }
}
