import AppKit
import SwiftUI
import XCTest

@testable import TotumComXLApp

/// The message window is sized to its text — but not without limit: a message longer than
/// the tallest window used to be cut off at the bottom, buttons and all. Past the limit the
/// text scrolls; below it nothing scrolls and nothing shows a bar.
@MainActor
final class MessageDialogLayoutTests: XCTestCase {

    func test_короткийТекстНеПрокручивается() {
        let layout = FCXLMessageDialog.layout(contentHeight: 40)
        XCTAssertEqual(layout.windowHeight, FCXLMessageDialog.minWindowHeight)
        XCTAssertFalse(layout.messageScrolls)

        let fits = FCXLMessageDialog.layout(contentHeight: 300)
        XCTAssertEqual(fits.windowHeight, 300 + FCXLMessageDialog.barHeight + 8)
        XCTAssertFalse(fits.messageScrolls)
    }

    func test_прокруткаРовноТамГдеОкноУжеНеРастёт() {
        let edge = FCXLMessageDialog.maxWindowHeight - FCXLMessageDialog.barHeight - 8
        XCTAssertFalse(FCXLMessageDialog.layout(contentHeight: edge).messageScrolls,
                       "текст, который ещё помещается, прокрутки не получает")
        let over = FCXLMessageDialog.layout(contentHeight: edge + 1)
        XCTAssertTrue(over.messageScrolls)
        XCTAssertEqual(over.windowHeight, FCXLMessageDialog.maxWindowHeight,
                       "окно выше самого высокого не растёт")
    }

    /// The real measurement: a stack-trace-sized message hits the ceiling and scrolls, a
    /// two-line one does not.
    func test_настоящийДлинныйТекстУпираетсяВПотолокИПрокручивается() {
        let long = (1...120).map { "строка \($0) — сообщение об ошибке, которое никто не сокращал" }
            .joined(separator: "\n")
        let tall = FCXLMessageDialog.layout(for: FCXLMessageConfig(
            title: "Ошибка", message: long, buttons: [FCXLMessageButton(title: "OK", kind: .primary)]))
        XCTAssertEqual(tall.windowHeight, FCXLMessageDialog.maxWindowHeight)
        XCTAssertTrue(tall.messageScrolls)

        let short = FCXLMessageDialog.layout(for: FCXLMessageConfig(
            title: "Готово", message: "Файл скопирован.",
            buttons: [FCXLMessageButton(title: "OK", kind: .primary)]))
        XCTAssertLessThan(short.windowHeight, FCXLMessageDialog.maxWindowHeight)
        XCTAssertFalse(short.messageScrolls)
    }

    /// The scrolling window in both themes — into FCXL_LOOK_DIR, to be looked at by eye.
    func test_снимокДиалогаСПрокруткойВОбеихТемах() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let long = (1...80).map { "строка \($0): не удалось прочитать атрибуты файла, код ошибки \($0 * 7)" }
            .joined(separator: "\n")
        let config = FCXLMessageConfig(title: "Ошибка чтения", message: long, icon: "xmark.octagon.fill",
                                       iconColor: .red, buttons: [FCXLMessageButton(title: "OK", kind: .primary)])
        let layout = FCXLMessageDialog.layout(for: config)
        for (name, appearance) in [("диалог-светлая", NSAppearance.Name.aqua), ("диалог-тёмная", .darkAqua)] {
            let view = VStack(spacing: 0) {
                ScrollView(.vertical) {
                    FCXLMessageBody(config: config, checkboxOn: .constant(false), text: .constant(""),
                                    isMeasuring: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                FCXLDialogMultiButtonBar(buttons: [FCXLDialogBarButton(title: "OK", role: .primary) {}])
            }
            .frame(width: config.width, height: layout.windowHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: config.width, height: layout.windowHeight)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }
}
