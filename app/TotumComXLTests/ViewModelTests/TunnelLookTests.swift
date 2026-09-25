import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Как выглядит туннель. Рисуется в картинку — это и проверка, что вид собирается:
/// SwiftUI умеет разваливаться только в работе.
@MainActor
final class TunnelLookTests: XCTestCase {

    private static var folder: String {
        ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] ?? NSTemporaryDirectory()
    }

    func test_туннельРисуетсяУзкимИШироким() throws {
        for (name, width) in [("узкий", 40.0), ("широкий", 130.0)] {
            UserDefaults.standard.set(width, forKey: "centerDividerWidth")
            let view = CenterDividerView(
                activePanelPath: NSHomeDirectory() + "/Documents",
                isLeftPanelActive: true,
                splitRatio: 0.5,
                onSwap: {}, onCopy: {}, onMove: {}, onDelete: {},
                onMkdir: {}, onView: {}, onEdit: {},
                onQuickLink: { _ in })
                .frame(height: 720)
                .background(Color(white: 0.15))
                .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "туннель нарисовался (\(name))")
            XCTAssertGreaterThan(image.size.height, 100)

            let data = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: Self.folder + "/туннель-\(name).png"))
        }
        UserDefaults.standard.removeObject(forKey: "centerDividerWidth")
    }
}
