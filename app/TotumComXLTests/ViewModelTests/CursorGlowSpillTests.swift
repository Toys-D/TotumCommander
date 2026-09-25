import AppKit
import XCTest
@testable import TotumComXLApp

/// Размытый курсор светится ЗА пределами своей строки.
///
/// Жалоба: с размытием курсор должен светиться и не ограничиваться рамками строки. Свечение
/// печётся с запасом по краям и кладётся в фон таблицы, под прозрачные строки, — значит,
/// обязано выходить на соседние строки. Здесь это меряется по пикселям: сначала испечённая
/// картинка, потом настоящая таблица подробного режима.
@MainActor
final class CursorGlowSpillTests: XCTestCase {

    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "cursor.glow.tests.\(UUID().uuidString)"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CursorMaskStore.storageOverride = .init(directory: directory,
                                                defaults: UserDefaults(suiteName: suiteName)!)
        FeatheredCursor.dropCache()
    }

    override func tearDown() async throws {
        if let directory = CursorMaskStore.storageOverride?.directory {
            try? FileManager.default.removeItem(at: directory)
        }
        CursorMaskStore.storageOverride = nil
        FeatheredCursor.dropCache()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Помощники

    /// Сплошная белая маска: тело курсора во всю площадь, края резкие.
    private func solidMask() -> NSBitmapImageRep {
        let size = CursorMaskStore.maskSize
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                   pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func enableMask(_ rep: NSBitmapImageRep) {
        XCTAssertTrue(CursorMaskStore.save(rep))
        CursorMaskStore.setEnabled(true)
        XCTAssertNotNil(CursorMaskStore.activeMask(), "маска включена и читается")
    }

    /// Альфа в точке (в пунктах, от верхнего края) — через NSBitmapImageRep, чтобы не
    /// зависеть от раскладки байтов, которая у испечённой и у составной картинки разная.
    private func alpha(of image: NSImage, x: Int, y: Int) -> CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scaleX = CGFloat(cg.width) / image.size.width
        let scaleY = CGFloat(cg.height) / image.size.height
        let px = Int(CGFloat(x) * scaleX), py = Int(CGFloat(y) * scaleY)
        guard px >= 0, py >= 0, px < cg.width, py < cg.height else { return -1 }
        return rep.colorAt(x: px, y: py)?.alphaComponent ?? -1
    }

    // MARK: - Испечённая картинка

    /// С маской и размытием свечение есть выше и ниже полосы; без размытия — нет.
    func test_испечённыйКурсорСветитсяЗаПолосой() {
        enableMask(solidMask())
        let bar = NSSize(width: 600, height: 24)
        let blur: CGFloat = 12
        let pad = FeatheredCursor.padding(for: blur)
        let glow = FeatheredCursor.image(barSize: bar, color: .green, blur: blur, corner: 4)
        XCTAssertEqual(glow.size.width, bar.width + pad * 2, accuracy: 1)
        XCTAssertEqual(glow.size.height, bar.height + pad * 2, accuracy: 1)

        let midX = Int(glow.size.width / 2)
        let above = alpha(of: glow, x: midX, y: Int(pad) - 6)          // 6 пт над полосой
        let below = alpha(of: glow, x: midX, y: Int(pad + bar.height) + 6)
        let far = alpha(of: glow, x: midX, y: Int(pad) - 12)           // 12 пт — одна сигма
        let edge = alpha(of: glow, x: midX, y: Int(pad))                // самый край полосы
        let inside = alpha(of: glow, x: midX, y: Int(pad + bar.height / 2))
        XCTAssertGreaterThan(inside, 0.85, "середина остаётся плотной: \(inside)")
        XCTAssertLessThan(edge, 0.9, "край размыт, а не обрезан по строке: \(edge)")
        XCTAssertGreaterThan(above, 0.3, "мягкий край выходит над строкой: \(above)")
        XCTAssertGreaterThan(below, 0.3, "и под строкой: \(below)")
        // Размытое тело над своим ореолом: на одной сигме от края гауссиана даёт 0.16,
        // вместе 2g−g² ≈ 0.29. Сигма в пикселях 2x-битмапа давала бы вдвое короче.
        XCTAssertEqual(far, 0.29, accuracy: 0.08, "сила размытия отвечает ползунку: \(far)")

        let sharp = FeatheredCursor.image(barSize: bar, color: .green, blur: 0, corner: 4)
        let padSharp = FeatheredCursor.padding(for: 0)
        XCTAssertEqual(alpha(of: sharp, x: midX, y: Int(padSharp) - 2), 0, accuracy: 0.01,
                       "без размытия за полосой пусто")
    }

    // MARK: - Настоящая таблица подробного режима

    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// Как в программе: картинка под курсором — слой (CursorIconZoom), а значит слоями
        /// становятся и строка, и таблица.
        var layerBackedCells = false
        func numberOfRows(in tableView: NSTableView) -> Int { 7 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            FileListRowView()
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            let view = NSView()
            if layerBackedCells { view.wantsLayer = true }
            return view
        }
    }

    private func renderedTable(blur: CGFloat) throws -> (rep: NSBitmapImageRep, row: NSRect,
                                                        scale: CGFloat) {
        let rowHeight: CGFloat = 24
        let frame = NSRect(x: 0, y: 0, width: 600, height: rowHeight * 7)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let table = PanelNSTableView(frame: frame)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .black
        let column = NSTableColumn(identifier: .init("name"))
        column.width = frame.width
        table.addTableColumn(column)
        let rows = Rows()
        table.dataSource = rows
        table.delegate = rows
        window.contentView = table
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        table.cursorGlowRow = 3
        table.cursorGlowColor = .green
        table.cursorGlowBlur = blur
        table.cursorGlowHeightFraction = 1
        table.cursorGlowWidthFraction = 1
        table.cursorGlowCorner = 4

        let rep = try XCTUnwrap(table.bitmapImageRepForCachingDisplay(in: table.bounds))
        table.cacheDisplay(in: table.bounds, to: rep)
        withExtendedLifetime(rows) {}
        return (rep, table.rect(ofRow: 3), CGFloat(rep.pixelsWide) / frame.width)
    }

    private func green(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, scale: CGFloat) -> CGFloat {
        let colour = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?
            .usingColorSpace(.deviceRGB)
        return colour?.greenComponent ?? -1
    }

    /// В подробном режиме свечение размытого курсора видно на строках выше и ниже.
    func test_вТаблицеСвечениеВыходитНаСоседниеСтроки() throws {
        enableMask(solidMask())
        let sharp = try renderedTable(blur: 0)
        let soft = try renderedTable(blur: 12)
        let x: CGFloat = 300
        // Таблица перевёрнута; строку берём у самой таблицы — у неё есть отступ сверху.
        // Меряем на 8 пт выше и ниже строки: заметно внутри соседних строк.
        let yAbove = sharp.row.minY - 8
        let yBelow = sharp.row.maxY + 8
        let yInside = sharp.row.midY

        XCTAssertGreaterThan(green(soft.rep, x: x, y: yInside, scale: soft.scale), 0.8,
                             "курсор нарисован и остался плотным")
        XCTAssertLessThan(green(sharp.rep, x: x, y: yAbove, scale: sharp.scale), 0.02,
                          "без размытия соседняя строка чёрная")
        XCTAssertGreaterThan(green(soft.rep, x: x, y: yAbove, scale: soft.scale), 0.15,
                             "с размытием свечение выше строки")
        XCTAssertGreaterThan(green(soft.rep, x: x, y: yBelow, scale: soft.scale), 0.15,
                             "с размытием свечение ниже строки")
    }

    /// Замер на СВОЕЙ маске: FCXL_CURSOR_MASK=путь к cursor-mask.png, FCXL_CURSOR_SHOT=куда
    /// положить картинку. Ничего не проверяет — печатает профиль альфы по вертикали.
    func test_профильСвоейМаски() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FCXL_CURSOR_MASK"] else { throw XCTSkip("FCXL_CURSOR_MASK не задан") }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        enableMask(rep)
        for blur: CGFloat in [7, 12] {
            let bar = NSSize(width: 900, height: 24)
            let pad = FeatheredCursor.padding(for: blur)
            let glow = FeatheredCursor.image(barSize: bar, color: .green, blur: blur, corner: 4.8)
            var profile: [String] = []
            for y in stride(from: 0, through: Int(glow.size.height), by: 4) {
                profile.append("\(y - Int(pad)):\(String(format: "%.2f", alpha(of: glow, x: Int(glow.size.width * 0.3), y: y)))")
            }
            print("PROFILE blur=\(blur) pad=\(pad) " + profile.joined(separator: " "))
            if let shot = env["FCXL_CURSOR_SHOT"] {
                let canvas = NSImage(size: NSSize(width: glow.size.width, height: glow.size.height * 3), flipped: false) { rect in
                    NSColor.black.setFill(); rect.fill()
                    glow.draw(in: NSRect(x: 0, y: glow.size.height, width: glow.size.width, height: glow.size.height))
                    return true
                }
                if let tiff = canvas.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: shot + "/glow-\(Int(blur)).png"))
                }
            }
        }
    }
}
