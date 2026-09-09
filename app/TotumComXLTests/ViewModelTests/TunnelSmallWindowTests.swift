import AppKit
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Туннель в низком окне остаётся в своих границах.
///
/// Жалоба: при маленьком окне туннель вылезал вверх, над панелями. NSHostingView по
/// умолчанию требует под SwiftUI-содержимое минимальную высоту, а туннель прижат к верху
/// и низу контейнера — при нехватке места ограничения спорили, и вид рос за края.
@MainActor
final class TunnelSmallWindowTests: XCTestCase {

    private static let keys = ["dividerOffsetY", "dividerIconSpacing", "quickLinksGap",
                               "centerDividerWidth", "dividerShowLabels", "dividerShowQuickLinks"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        for key in Self.keys { saved[key] = d.object(forKey: key) }
        // Как у жалобщика: подписи, смещение 100, интервал 10 — самый высокий туннель.
        d.set(100.0, forKey: "dividerOffsetY"); d.set(10.0, forKey: "dividerIconSpacing")
        d.set(0.0, forKey: "quickLinksGap"); d.set(80.0, forKey: "centerDividerWidth")
        d.set(true, forKey: "dividerShowLabels"); d.set(true, forKey: "dividerShowQuickLinks")
    }

    override func tearDown() {
        let d = UserDefaults.standard
        for key in Self.keys {
            if let value = saved[key] ?? nil { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func tunnel() -> CenterDividerView {
        CenterDividerView(activePanelPath: NSHomeDirectory(), isLeftPanelActive: true, splitRatio: 0.5,
                          onSwap: {}, onCopy: {}, onMove: {}, onDelete: {},
                          onMkdir: {}, onView: {}, onEdit: {}, onQuickLink: { _ in })
    }

    /// Контейнер как в окне: туннель прижат к верху и низу ограничениями.
    private func host(height: CGFloat) -> (container: NSView, hosting: NSHostingView<CenterDividerView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = window.contentView!
        let hosting = TunnelDropHostingView(rootView: tunnel())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 160),
            hosting.widthAnchor.constraint(equalToConstant: 80),
        ])
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        container.layoutSubtreeIfNeeded()
        return (container, hosting)
    }

    /// Картинка низкого туннеля в обеих темах — в FCXL_LOOK_DIR, посмотреть глазами.
    func test_картинкаНизкогоТуннеля() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        for (name, scheme) in [("туннель-низкий-тёмный", ColorScheme.dark), ("туннель-низкий-светлый", .light)] {
            let view = tunnel().frame(height: 360)
                .background(scheme == .dark ? Color(white: 0.15) : Color(white: 0.9))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }

    func test_вНизкомОкнеТуннельНеВыходитЗаКонтейнер() {
        for height in [420.0, 300.0] {
            let (container, hosting) = host(height: height)
            XCTAssertEqual(hosting.frame.minY, 0, accuracy: 0.5, "низ у низа контейнера (\(height))")
            XCTAssertEqual(hosting.frame.maxY, container.bounds.maxY, accuracy: 0.5,
                           "верх у верха контейнера (\(height)) — а был \(hosting.frame)")
            XCTAssertEqual(hosting.intrinsicContentSize.height, NSView.noIntrinsicMetric,
                           "SwiftUI не диктует высоту туннеля — её задаёт окно")
        }
    }
}
