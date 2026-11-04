import AppKit
import XCTest
@testable import TotumComXLApp

/// Значок под курсором поднимается растяжкой слоя; чтобы он не мылился, в нём на время подъёма
/// лежит растр под поднятый размер, а опустившемуся возвращается обычная картинка.
@MainActor
final class LiftRasterTests: XCTestCase {

    private let size: CGFloat = 30
    private let zoom: CGFloat = 1.31

    private func view(with image: NSImage) -> NSImageView {
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.image = image
        return view
    }

    private func widestRep(_ image: NSImage?) -> Int {
        image?.representations.map(\.pixelsWide).max() ?? 0
    }

    /// Сколько точек нужно поднятому значку на экране Retina.
    private var needed: Int { Int((size * 2 * zoom).rounded(.up)) }

    func test_свойЗначокПодКурсором_растрПодПоднятыйРазмер_иОбратно() {
        let icon = FileIcons.icon(forExtension: "pdf", size: size,
                                  look: FileIconLook(style: .totum, backgrounds: [.white]))
        let view = view(with: icon)
        LiftRaster.prepare(view, scale: zoom)
        XCTAssertGreaterThanOrEqual(widestRep(view.image), needed, "поднятый — крупным растром")
        XCTAssertEqual(view.image?.size, icon.size, "в точках тот же размер — ячейка не перестраивается")

        LiftRaster.prepare(view, scale: 1)
        XCTAssertTrue(view.image === icon, "опустился — обычная картинка")
    }

    /// Крупный растр своего значка нарисован заново в поднятом размере — край листа целыми
    /// точками, а не растянут из обычного.
    func test_крупныйРастрСвоегоЗначка_чёткий() throws {
        let icon = FileIcons.icon(forExtension: "zip", size: size,
                                  look: FileIconLook(style: .totum, backgrounds: [.white]))
        let big = try XCTUnwrap(LiftRaster.sharpImage(for: icon, zoom: zoom, backing: 2))
        let rep = try XCTUnwrap(big.representations.first as? NSBitmapImageRep)
        let row = rep.pixelsHigh / 2
        let left = (0..<rep.pixelsWide / 2).map { rep.colorAt(x: $0, y: row)?.alphaComponent ?? 0 }
        XCTAssertEqual(left.filter { $0 > 0.02 && $0 < 0.98 }.count, 0, "\(left.prefix(14))")
    }

    func test_значокMacOS_тожеКрупнымРастром() {
        let system = AppIconCache.icon(path: "/System/Applications/Calculator.app", size: size)
        let view = view(with: system)
        LiftRaster.prepare(view, scale: zoom)
        XCTAssertGreaterThanOrEqual(widestRep(view.image), needed)
        LiftRaster.prepare(view, scale: 1)
        XCTAssertTrue(view.image === system)
    }

    /// Ячейку отдали другой строке, пока значок был поднят: новая картинка — её, старую не
    /// возвращать.
    func test_ячейкуОтдалиДругойСтроке_новуюКартинкуНеТрогать() {
        let look = FileIconLook(style: .totum, backgrounds: [.white])
        let first = FileIcons.icon(forExtension: "pdf", size: size, look: look)
        let second = FileIcons.icon(forExtension: "mp3", size: size, look: look)
        let view = view(with: first)
        LiftRaster.prepare(view, scale: zoom)
        view.image = second
        LiftRaster.prepare(view, scale: 1)
        XCTAssertTrue(view.image === second)
    }

    /// Стрелка «наверх» красится цветом строки — её не подменяют.
    func test_шаблонНеТрогают() {
        let arrow = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)!
        XCTAssertTrue(arrow.isTemplate)
        let view = view(with: arrow)
        LiftRaster.prepare(view, scale: zoom)
        XCTAssertTrue(view.image === arrow)
    }

    /// То, что видно на экране: в слое поднятого значка лежит растр под поднятый размер, а не
    /// под обычный, — иначе растяжка слоя мылит его, как раньше.
    func test_вСлоеПоднятогоЗначка_крупныйРастр() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let icon = FileIcons.icon(forExtension: "pdf", size: size,
                                  look: FileIconLook(style: .totum, backgrounds: [.white]))
        let view = view(with: icon)
        view.imageScaling = .scaleProportionallyDown
        window.contentView?.addSubview(view)
        window.orderFront(nil)
        CursorIconZoom.apply(to: view, scale: zoom)
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard window.backingScaleFactor == 2 else { throw XCTSkip("проверка для экрана Retina") }

        func widest(_ layer: CALayer) -> Int {
            var best = 0
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                best = (contents as! CGImage).width
            }
            for sub in layer.sublayers ?? [] { best = max(best, widest(sub)) }
            return best
        }
        XCTAssertGreaterThanOrEqual(widest(try XCTUnwrap(view.layer)), needed)
    }
}
