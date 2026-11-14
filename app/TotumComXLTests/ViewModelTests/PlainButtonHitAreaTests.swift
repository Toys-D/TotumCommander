import AppKit
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Плоская кнопка (`.buttonStyle(.plain)`) нажимается только там, где нарисована её метка:
/// у значка 10×9 точек это сам значок, и щелчок на пару точек в сторону уходит мимо. Каждой
/// такой кнопке нужна своя область нажатия, а кнопкам строки очереди — ещё и рамка 18×18.
@MainActor
final class PlainButtonHitAreaTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MouseLikeAPerson.setAccessibility(true)
    }

    override func tearDown() {
        MouseLikeAPerson.setAccessibility(false)
        super.tearDown()
    }

    // MARK: - Все плоские кнопки программы

    /// У каждой плоской кнопки в её выражении — от `Button(` до конца цепочки модификаторов —
    /// есть `.contentShape(…)`.
    func test_уКаждойПлоскойКнопкиСвояОбластьНажатия() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewModelTests
            .deletingLastPathComponent()   // TotumComXLTests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("TotumComXL")
        let pattern = #"\.buttonStyle\(\s*(\.plain|PlainButtonStyle\(\))\s*\)"#
        var total = 0
        var bare: [String] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.range(of: pattern, options: .regularExpression) != nil {
                total += 1
                if !Self.expression(around: index, in: lines).contains(".contentShape(") {
                    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    bare.append("\(relative):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(total, 30, "плоские кнопки не найдены — поиск смотрит не туда")
        XCTAssertTrue(bare.isEmpty,
                      "плоские кнопки без своей области нажатия (\(bare.count)): "
                        + bare.sorted().joined(separator: ", "))
    }

    /// Строки выражения, которому принадлежит модификатор в строке `index`: от его начала
    /// (первая строка выше с отступом не больше, не начинающаяся с точки или закрывающей
    /// скобки) до конца цепочки модификаторов ниже.
    private static func expression(around index: Int, in lines: [String]) -> String {
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        let own = indent(lines[index])
        var start = index
        if trimmed(lines[index]).hasPrefix(".") {
            start = index - 1
            while start >= 0 {
                let text = trimmed(lines[start])
                if !text.isEmpty, indent(lines[start]) <= own,
                   !text.hasPrefix("."), !text.hasPrefix("}"), !text.hasPrefix(")"), !text.hasPrefix("//") {
                    break
                }
                start -= 1
            }
        }
        var end = index + 1
        while end < lines.count {
            let text = trimmed(lines[end])
            if text.isEmpty || text.hasPrefix("//") { end += 1; continue }
            if text.hasPrefix("."), indent(lines[end]) >= own { end += 1; continue }
            if indent(lines[end]) > own { end += 1; continue }
            break
        }
        return lines[max(start, 0)..<end].joined(separator: "\n")
    }

    // MARK: - Кнопки строки очереди

    private final class Presses { var log: [String] = [] }

    /// Подсказка кнопки и сколько таких кнопок в трёх строках.
    private static let rowButtons: [(key: String, count: Int)] = [
        ("queue.pause", 1), ("queue.resume", 1), ("queue.cancel", 2),
        ("queue.continueTransfer", 1), ("queue.dismiss", 1),
    ]

    private func file(_ name: String) -> FileItem {
        FileItem(path: "/tmp/источник/" + name, name: name, fileExtension: "", size: 0,
                 isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "rw-r--r--", dateModified: Date(timeIntervalSince1970: 0))
    }

    private func operation(_ kind: OperationKind, _ name: String, _ status: OperationStatus,
                           error: String? = nil) -> QueuedOperation {
        var op = QueuedOperation(id: UUID(), kind: kind, items: [file(name)],
                                 destinationPath: "/tmp/приёмник", createdAt: Date())
        op.status = status
        op.error = error
        op.progress = 0.4
        return op
    }

    private func row(_ mark: String, _ op: QueuedOperation, _ presses: Presses) -> OperationRowView {
        OperationRowView(operation: op,
                         onPause: { presses.log.append(mark + ".пауза") },
                         onResume: { presses.log.append(mark + ".дальше") },
                         onCancel: { presses.log.append(mark + ".отмена") },
                         onRemove: { presses.log.append(mark + ".убрать") },
                         onContinue: { presses.log.append(mark + ".повтор") })
    }

    /// Три строки очереди: А идёт (пауза, отмена), Б на паузе (продолжить, отмена),
    /// В сорвалась (повторить, убрать) — все пять кнопок строки.
    private func makeWindow(_ presses: Presses, appearance: NSAppearance.Name? = nil) -> NSWindow {
        let rows = VStack(spacing: 0) {
            row("А", operation(.copy, "идёт.bin", .running), presses)
            row("Б", operation(.copy, "стоит.bin", .paused), presses)
            row("В", operation(.remoteDownload, "сорвалась.bin", .failed, error: "связь оборвана"), presses)
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        window.contentView = NSHostingView(rootView: rows)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return window
    }

    /// Рамки кнопок с такой подсказкой, сверху вниз. Рамку кнопки и рамку её же значка
    /// считаем одной.
    private func buttons(_ key: String, count: Int, in window: NSWindow,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [NSRect] {
        var found: [NSRect] = []
        for frame in MouseLikeAPerson.elements(withHelp: L(key), in: window) {
            if let twin = found.firstIndex(where: { $0.intersects(frame) }) {
                found[twin] = found[twin].union(frame)
            } else {
                found.append(frame)
            }
        }
        found.sort { $0.midY > $1.midY }
        return try XCTUnwrap(found.count == count ? found : nil,
                             "кнопок «\(L(key))» нашлось \(found.count), а не \(count)",
                             file: file, line: line)
    }

    private func snapshot(_ window: NSWindow, as name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let host = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// Кнопки строки очереди — не меньше 18×18 точек, в обеих темах.
    func test_кнопкиСтрокиОчереди_неМеньше18Точек() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = name == .aqua ? "светлая" : "тёмная"
            let window = makeWindow(Presses(), appearance: name)
            defer { window.orderOut(nil) }
            for (key, count) in Self.rowButtons {
                for frame in try buttons(key, count: count, in: window) {
                    XCTAssertGreaterThanOrEqual(frame.width, 18,
                                                "«\(L(key))» у́же 18 точек (\(theme)): \(frame.size)")
                    XCTAssertGreaterThanOrEqual(frame.height, 18,
                                                "«\(L(key))» ниже 18 точек (\(theme)): \(frame.size)")
                }
            }
            try snapshot(window, as: "очередь-\(theme)")
        }
    }

    /// Щелчок рядом со значком — в семи точках от его середины, с любой стороны — нажимает
    /// эту кнопку, и только её.
    func test_кнопкиСтрокиОчереди_нажимаютсяРядомСоЗначком() throws {
        let presses = Presses()
        let window = makeWindow(presses)
        defer { window.orderOut(nil) }
        let targets: [(key: String, row: Int, of: Int, mark: String)] = [
            ("queue.pause", 0, 1, "А.пауза"), ("queue.cancel", 0, 2, "А.отмена"),
            ("queue.resume", 0, 1, "Б.дальше"), ("queue.cancel", 1, 2, "Б.отмена"),
            ("queue.continueTransfer", 0, 1, "В.повтор"), ("queue.dismiss", 0, 1, "В.убрать"),
        ]
        for target in targets {
            let frame = try buttons(target.key, count: target.of, in: window)[target.row]
            presses.log = []
            for (dx, dy) in [(-7.0, 0.0), (7.0, 0.0), (0.0, -7.0), (0.0, 7.0)] {
                MouseLikeAPerson.click(NSRect(x: frame.midX + dx - 0.5, y: frame.midY + dy - 0.5,
                                              width: 1, height: 1), in: window)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            XCTAssertEqual(presses.log, Array(repeating: target.mark, count: 4),
                           "«\(L(target.key))» (\(target.mark)): щелчки в 7 точках от середины значка")
        }
    }
}
