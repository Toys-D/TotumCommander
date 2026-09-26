import AppKit
import XCTest
@testable import TotumComXLApp

/// Увеличенная иконка под курсором выходит за строку, а не режется её краями: строка списка
/// не клипает содержимое, а строка с курсором лежит над соседями. Рендер через слои
/// (`CALayer.render`), потому что только он честно применяет маски и трансформации.
@MainActor
final class CursorIconSpillTests: XCTestCase {

    private final class Feed: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let rowHeight: CGFloat = 30
        let iconSize: CGFloat = 26
        var rows: [FileListRowView] = []
        func numberOfRows(in tableView: NSTableView) -> Int { 5 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = FileListRowView()
            rows.append(view)
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: rowHeight))
            let icon = NSImageView(frame: NSRect(x: 4, y: (rowHeight - iconSize) / 2, width: iconSize, height: iconSize))
            icon.image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
                NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1).setFill()
                NSBezierPath(rect: rect).fill()
                return true
            }
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            return cell
        }
    }

    /// Оранжевые пиксели в полосе 4 пт над верхом строки `row` после рендера слоёв.
    private func orangeAbove(row: Int, table: NSTableView) throws -> Int {
        let bounds = table.bounds
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                                 pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        ctx.scaleBy(x: scale, y: scale)
        // слой таблицы перевёрнут относительно битмапа — рисуем в его координатах
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        try XCTUnwrap(table.layer).render(in: ctx)
        let r = table.rect(ofRow: row)
        var count = 0
        for px in Int(4 * scale)..<Int(40 * scale) {
            for py in Int((r.minY - 4) * scale)..<Int(r.minY * scale) {
                if let c = rep.colorAt(x: px, y: py), c.redComponent > 0.8, c.greenComponent > 0.3,
                   c.greenComponent < 0.7, c.blueComponent < 0.2 { count += 1 }
            }
        }
        return count
    }

    func test_иконкаПодКурсоромВыходитЗаСтроку() throws {
        let feed = Feed()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        let column = NSTableColumn(identifier: .init("name")); column.width = 220
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = feed.rowHeight
        table.dataSource = feed
        table.delegate = feed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds)
        container.wantsLayer = true
        container.addSubview(table)
        window.contentView = container
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let rowView = try XCTUnwrap(table.rowView(atRow: 2, makeIfNecessary: true) as? FileListRowView)
        let icon = try XCTUnwrap(rowView.subviews.first?.subviews.compactMap { $0 as? NSImageView }.first)
        rowView.isCursor = true
        CursorIconZoom.apply(to: icon, scale: 1.55)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(rowView.clipsToBounds, "строка списка не клипает содержимое")
        XCTAssertEqual(rowView.layer?.zPosition, 1, "строка с курсором над соседями")
        XCTAssertEqual(FileListRowView.zPosition(isCursor: false), 0)
        XCTAssertGreaterThan(try orangeAbove(row: 2, table: table), 0,
                             "увеличенная иконка видна над верхом строки")
    }
}
