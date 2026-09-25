import AppKit
import XCTest
@testable import TotumComXLApp

/// Линии сетки в подробном и кратком режимах: где стоят, какого цвета, и что они
/// действительно рисуются в таблице — по пикселям.
@MainActor
final class GridLinesTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "fcxl.gridlines.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let columns = [(id: "icon", rect: NSRect(x: 0, y: 0, width: 40, height: 10)),
                           (id: "name", rect: NSRect(x: 40, y: 0, width: 260, height: 10)),
                           (id: "size", rect: NSRect(x: 300, y: 0, width: 100, height: 10)),
                           (id: "modified", rect: NSRect(x: 400, y: 0, width: 200, height: 10))]
    private let rows = [NSRect(x: 0, y: 0, width: 600, height: 24),
                        NSRect(x: 0, y: 24, width: 600, height: 24)]
    private let bounds = NSRect(x: 0, y: 0, width: 600, height: 200)

    // MARK: - Подробный режим: где стоят

    /// Вертикальные — по правой кромке каждого столбца, кроме последнего и кроме значка:
    /// значок и имя читаются одним столбцом, линия между папкой и её именем резала глаз.
    func test_вертикальныеКромеПоследнейИЗначка() {
        let lines = GridLines.table(columns: columns, rows: rows, bounds: bounds,
                                    style: .init(vertical: true, horizontal: false))
        XCTAssertEqual(lines.map(\.minX), [299.5, 399.5])
        XCTAssertEqual(lines.map(\.height), [200, 200], "во всю высоту")
        XCTAssertTrue(GridLines.table(columns: [columns[0]], rows: rows, bounds: bounds,
                                      style: .init(vertical: true)).isEmpty, "один столбец — линий нет")
        XCTAssertTrue(GridLines.table(columns: Array(columns[0...1]), rows: rows, bounds: bounds,
                                      style: .init(vertical: true)).isEmpty, "значок и имя — без линии")
    }

    /// Горизонтальные — под каждой строкой во всю ширину, включая последнюю.
    func test_горизонтальныеПодКаждойСтрокой() {
        let lines = GridLines.table(columns: columns, rows: rows, bounds: bounds,
                                    style: .init(vertical: false, horizontal: true))
        XCTAssertEqual(lines.map(\.minY), [23.5, 47.5])
        XCTAssertEqual(lines.map(\.width), [600, 600])
        XCTAssertTrue(GridLines.table(columns: columns, rows: rows, bounds: bounds, style: .init()).isEmpty,
                      "оба выключены — ничего")
        XCTAssertEqual(GridLines.table(columns: columns, rows: rows, bounds: bounds,
                                       style: .init(vertical: true, horizontal: true)).count, 4)
    }

    // MARK: - Краткий режим

    /// Семь имён по три в колонке: три колонки (3, 3, 1). Горизонтальные — под каждым
    /// именем в ширину его колонки; вертикальные — между колонками, на полную колонку.
    func test_краткийРежим() {
        let horizontal = GridLines.brief(itemCount: 7, rowsPerColumn: 3, itemWidth: 200, itemHeight: 20,
                                         style: .init(horizontal: true))
        XCTAssertEqual(horizontal.count, 7)
        XCTAssertEqual(horizontal[0], NSRect(x: 0, y: 19.5, width: 200, height: 1))
        XCTAssertEqual(horizontal[3], NSRect(x: 200, y: 19.5, width: 200, height: 1), "четвёртое имя — верх второй колонки")
        XCTAssertEqual(horizontal[6], NSRect(x: 400, y: 19.5, width: 200, height: 1), "седьмое — одно в третьей")

        let vertical = GridLines.brief(itemCount: 7, rowsPerColumn: 3, itemWidth: 200, itemHeight: 20,
                                       style: .init(vertical: true))
        XCTAssertEqual(vertical, [NSRect(x: 199.5, y: 0, width: 1, height: 60),
                                  NSRect(x: 399.5, y: 0, width: 1, height: 60)])

        XCTAssertTrue(GridLines.brief(itemCount: 2, rowsPerColumn: 3, itemWidth: 200, itemHeight: 20,
                                      style: .init(vertical: true)).isEmpty, "одна колонка — вертикальных нет")
        XCTAssertTrue(GridLines.brief(itemCount: 0, rowsPerColumn: 3, itemWidth: 200, itemHeight: 20,
                                      style: .init(vertical: true, horizontal: true)).isEmpty, "пусто — ничего")
    }

    // MARK: - Какого цвета

    /// Прозрачность — с ползунка, а не из кода цвета; без выбранного цвета — свой на тему.
    func test_цветИПрозрачность() throws {
        let red = try XCTUnwrap(PanelAppearanceSettings.gridLineColor(hex: "#FF0000", opacity: 0.3, dark: true))
        XCTAssertEqual(red.alphaComponent, 0.3, accuracy: 0.001)
        XCTAssertEqual(red.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.01)

        let onDark = try XCTUnwrap(PanelAppearanceSettings.gridLineColor(hex: "", opacity: 0.5, dark: true))
        XCTAssertGreaterThan(onDark.usingColorSpace(.sRGB)?.brightnessComponent ?? 0, 0.9, "на тёмной — белая")
        let onLight = try XCTUnwrap(PanelAppearanceSettings.gridLineColor(hex: "", opacity: 0.5, dark: false))
        XCTAssertLessThan(onLight.usingColorSpace(.sRGB)?.brightnessComponent ?? 1, 0.1, "на светлой — чёрная")
    }

    func test_прозрачностьИВыключатели() {
        XCTAssertEqual(PanelAppearanceSettings.resolvedGridLinesOpacity(defaults),
                       PanelAppearanceSettings.defaultGridLinesOpacity, accuracy: 0.001)
        defaults.set(7.0, forKey: PanelAppearanceSettings.gridLinesOpacityKey)
        XCTAssertEqual(PanelAppearanceSettings.resolvedGridLinesOpacity(defaults), 1, "не больше единицы")
        XCTAssertFalse(PanelAppearanceSettings.resolvedGridStyle(defaults).isOn)
        defaults.set(true, forKey: PanelAppearanceSettings.gridLinesHorizontalKey)
        XCTAssertEqual(PanelAppearanceSettings.resolvedGridStyle(defaults),
                       GridLines.Style(vertical: false, horizontal: true))
    }

    // MARK: - В таблице

    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 4 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileListRowView() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSView() }
    }

    private func rendered(lineColor: NSColor?, style: GridLines.Style) throws
        -> (rep: NSBitmapImageRep, boundary: CGFloat, row0: NSRect, scale: CGFloat) {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 24 * 4 + 40)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let table = PanelNSTableView(frame: frame)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.backgroundColor = .black
        let first = NSTableColumn(identifier: .init("name")); first.width = 300
        let second = NSTableColumn(identifier: .init("size")); second.width = 200
        table.addTableColumn(first); table.addTableColumn(second)
        let rows = Rows(); table.dataSource = rows; table.delegate = rows
        window.contentView = table
        table.reloadData(); table.layoutSubtreeIfNeeded()
        table.gridLineColor = lineColor
        table.gridStyle = style
        let rep = try XCTUnwrap(table.bitmapImageRepForCachingDisplay(in: table.bounds))
        table.cacheDisplay(in: table.bounds, to: rep)
        withExtendedLifetime(rows) {}
        return (rep, table.rect(ofColumn: 0).maxX, table.rect(ofRow: 0), CGFloat(rep.pixelsWide) / frame.width)
    }

    private func red(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, scale: CGFloat) -> CGFloat {
        rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)?.redComponent ?? -1
    }

    /// Вертикальная стоит на границе столбцов и нигде больше; выключена — нет и там.
    func test_вертикальнаяРисуетсяНаГраницеСтолбцов() throws {
        let on = try rendered(lineColor: .red, style: .init(vertical: true))
        let y = on.row0.midY
        XCTAssertGreaterThan(red(on.rep, x: on.boundary - 0.5, y: y, scale: on.scale), 0.9, "на границе — линия")
        XCTAssertLessThan(red(on.rep, x: on.boundary - 6, y: y, scale: on.scale), 0.05, "в столбце — нет")
        XCTAssertLessThan(red(on.rep, x: 499, y: y, scale: on.scale), 0.05, "за последним столбцом линии нет")

        let half = try rendered(lineColor: NSColor.red.withAlphaComponent(0.5), style: .init(vertical: true))
        XCTAssertEqual(red(half.rep, x: half.boundary - 0.5, y: y, scale: half.scale), 0.5, accuracy: 0.1,
                       "прозрачность видна на чёрном")

        let off = try rendered(lineColor: nil, style: .init(vertical: true))
        XCTAssertLessThan(red(off.rep, x: off.boundary - 0.5, y: y, scale: off.scale), 0.05)
    }

    /// Горизонтальная — под строкой, во всю ширину; в середине строки и ниже последней — нет.
    func test_горизонтальнаяРисуетсяПодСтрокой() throws {
        let on = try rendered(lineColor: .red, style: .init(horizontal: true))
        let under = on.row0.maxY - 0.5
        XCTAssertGreaterThan(red(on.rep, x: 100, y: under, scale: on.scale), 0.9, "под первой строкой")
        XCTAssertGreaterThan(red(on.rep, x: 450, y: under, scale: on.scale), 0.9, "и во втором столбце")
        XCTAssertLessThan(red(on.rep, x: 100, y: on.row0.midY, scale: on.scale), 0.05, "в середине строки — нет")
        let belowLast = on.row0.maxY * 4 + 20
        XCTAssertLessThan(red(on.rep, x: 100, y: belowLast, scale: on.scale), 0.05, "ниже последней строки — нет")
        XCTAssertLessThan(red(on.rep, x: on.boundary - 0.5, y: on.row0.midY, scale: on.scale), 0.05,
                          "вертикальной без её выключателя нет")
    }
}
