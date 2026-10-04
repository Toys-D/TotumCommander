import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Текст в просмотрщике — NSTextView с номерами строк. Раньше был список строк SwiftUI: на
/// файле с длинными строками он проседал и отставал от трекпада.
@MainActor
final class NumberedTextViewTests: XCTestCase {

    func test_началаСтрок() {
        XCTAssertEqual(NumberedTextView.lineStarts(of: ""), [0], "пустой файл — одна пустая строка")
        XCTAssertEqual(NumberedTextView.lineStarts(of: "a"), [0])
        XCTAssertEqual(NumberedTextView.lineStarts(of: "a\n"), [0, 2], "перевод строки в конце — пустая последняя строка")
        XCTAssertEqual(NumberedTextView.lineStarts(of: "a\nb"), [0, 2])
        XCTAssertEqual(NumberedTextView.lineStarts(of: "\n\n"), [0, 1, 2])
        XCTAssertEqual(NumberedTextView.lineStarts(of: "a\r\nb\rc"), [0, 3, 5], "\\r\\n и одиночный \\r — тоже концы строк")
        XCTAssertEqual(NumberedTextView.lineStarts(of: "ё😀\nж"), [0, 4], "смещения в UTF-16, как у раскладки")
    }

    func test_строкаПоСмещению() {
        let starts = [0, 2, 10, 11]
        XCTAssertEqual(NumberedTextView.lineIndex(at: 0, in: starts), 0)
        XCTAssertEqual(NumberedTextView.lineIndex(at: 1, in: starts), 0)
        XCTAssertEqual(NumberedTextView.lineIndex(at: 2, in: starts), 1)
        XCTAssertEqual(NumberedTextView.lineIndex(at: 9, in: starts), 1)
        XCTAssertEqual(NumberedTextView.lineIndex(at: 10, in: starts), 2)
        XCTAssertEqual(NumberedTextView.lineIndex(at: 500, in: starts), 3)
        XCTAssertEqual(NumberedTextView.lineIndex(at: 0, in: [0]), 0)
    }

    /// Длинная строка переносится на несколько экранных, а номер у неё один — у первой.
    /// Следующая строка файла получает следующий номер, ниже всего переноса.
    func test_номерУПервойЭкраннойСтрокиКаждойСтрокиФайла() throws {
        let scroll = NumberedTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 3000)
        let view = try XCTUnwrap(scroll.documentView as? NumberedTextView)
        view.show("первая\n" + String(repeating: "длинная строка ", count: 60) + "\nтретья\n")
        scroll.layoutSubtreeIfNeeded()

        let labels = view.numberLabels(in: view.bounds)
        XCTAssertEqual(labels.map(\.number), [1, 2, 3, 4], "у пустой последней строки тоже номер")
        let line = NumberedTextView.textFont.boundingRectForFont.height
        XCTAssertLessThan(labels[1].baseline - labels[0].baseline, line * 2, "соседние короткие строки — рядом")
        XCTAssertGreaterThan(labels[2].baseline - labels[1].baseline, line * 5, "третья — ниже всего переноса второй")
    }

    /// Текст начинается правее колонки номеров и укладывается в ширину вида — при любой ширине.
    func test_текстПравееНомеровИВШиринуВида() throws {
        let scroll = NumberedTextView.makeScrollView()
        let view = try XCTUnwrap(scroll.documentView as? NumberedTextView)
        for width in [CGFloat(300), 900, 520] {
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.textContainerOrigin.x, NumberedTextView.textLeft)
            XCTAssertEqual(view.frame.width, scroll.contentSize.width, "вид во всю ширину прокрутки (\(width))")
            XCTAssertEqual(view.textContainer?.size.width,
                           view.frame.width - NumberedTextView.textLeft - NumberedTextView.rightPadding)
        }
    }

    /// Номера правда видны. NSTextView оставляет после себя обрезку по полю текста, и
    /// номера, нарисованные после него без сохранённого состояния, срезались целиком.
    func test_номераВидныВПолеСлева() throws {
        let scroll = NumberedTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let view = try XCTUnwrap(scroll.documentView as? NumberedTextView)
        view.show((1...20).map { "строка \($0)" }.joined(separator: "\n"))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()

        let visible = view.visibleRect
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: visible))
        view.cacheDisplay(in: visible, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / visible.width
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<Int(NumberedTextView.leftPadding + NumberedTextView.numberColumn) * Int(scale)
            where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                ink += 1
            }
        }
        XCTAssertGreaterThan(ink, 50, "в поле слева нарисованы номера строк")
    }

    // MARK: - В просмотрщике

    private var cleanup: [() -> Void] = []

    override func tearDown() {
        cleanup.reversed().forEach { $0() }
        cleanup = []
        super.tearDown()
    }

    private func find(_ view: NSView) -> NumberedTextView? {
        if let found = view as? NumberedTextView { return found }
        for sub in view.subviews { if let found = find(sub) { return found } }
        return nil
    }

    /// Просмотрщик с одним текстовым файлом под курсором — в окне в углу экрана, прозрачном и
    /// сквозном: у синтетического события прокрутки точка экранная, и в окне с началом в (0,0)
    /// она совпадает с точкой окна. Человек это окно не видит, его мышь в него не попадает.
    private func viewer(showing text: String) throws -> (window: NSWindow, view: NumberedTextView) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fcxl-text-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append { try? fm.removeItem(at: root) }
        try text.write(to: root.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)

        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: root.path,
                                pathDefaultsKey: "text.\(UUID().uuidString)",
                                viewModeDefaultsKey: "textm.\(UUID().uuidString)", showHiddenFiles: true)
        let listed = Date().addingTimeInterval(5)
        while !vm.items.contains(where: { $0.name == "log.txt" }), Date() < listed {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        vm.setCursor(index: try XCTUnwrap(vm.items.firstIndex { $0.name == "log.txt" }))

        let host = NSHostingView(rootView: UnifiedFileViewer(viewModel: vm, onClose: nil, operations: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(.zero)
        window.orderFrontRegardless()
        cleanup.append { window.orderOut(nil) }

        let loaded = Date().addingTimeInterval(10)
        var view: NumberedTextView?
        while view?.shownText.isEmpty != false, Date() < loaded {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view = find(host)
        }
        return (window, try XCTUnwrap(view, "текст показан видом с номерами строк, а не списком SwiftUI"))
    }

    /// Похоже на журнал сбоя, на котором список SwiftUI тормозил: сотни строк, среди них
    /// несколько очень длинных.
    private func crashLogLikeText() -> String {
        (1...409).map { number -> String in
            switch number {
            case 145: return String(repeating: "x", count: 402)
            case 197: return String(repeating: "0x00000001a2b3c4d5 ", count: 200)
            case 200: return String(repeating: "frame ", count: 133)
            case 366: return String(repeating: "\"key\": \"value\", ", count: 110)
            default: return "Thread \(number % 7) Crashed:: \(number) libsystem_kernel.dylib __pthread_kill + 8"
            }
        }.joined(separator: "\n")
    }

    func test_просмотрщикПоказываетТекстСНомерамиСтрок() throws {
        let text = crashLogLikeText()
        let shown = try viewer(showing: text).view
        XCTAssertEqual(shown.shownText, text)
        XCTAssertEqual(shown.lineStarts.count, 409)
    }

    /// Двумя пальцами на трекпаде, 120 событий в секунду по 20 точек: текст проходит весь путь.
    /// Список SwiftUI на таком файле успевал меньше половины — он «тормозил».
    func test_текстИдётЗаПальцами() throws {
        let (window, view) = try viewer(showing: crashLogLikeText())
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        let middle = window.convertPoint(toScreen: scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? 0

        func send(_ dy: Int32, phase: Int64) {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.location = CGPoint(x: middle.x, y: top - middle.y)
            window.sendEvent(NSEvent(cgEvent: cg)!)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 120))
        }
        send(-20, phase: 1)   // пальцы легли
        for _ in 0..<100 { send(-20, phase: 2) }
        send(0, phase: 4)     // пальцы сняты

        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100 * 20 * 0.9,
                             "текст проехал почти столько же, сколько пальцы")
    }
}
