import AppKit
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Правая кнопка в туннеле отвечает в ЛЮБОЙ его точке.
///
/// Жалоба: под кнопкой «Редакт.» есть мёртвая зона — меню не открывается, а ещё ниже
/// открывается. Это пустой Spacer, которым туннель отодвигает операции от низа
/// (dividerOffsetY): Spacer щелчков не ловит, и меню пропорций при щелчке в него не
/// появлялось. Здесь окно с туннелем настоящее, а щелчок — тот же вопрос «какое меню
/// показать в этой точке», который AppKit задаёт при правой кнопке.
@MainActor
final class TunnelContextMenuTests: XCTestCase {

    private var window: NSWindow!
    private var hosting: NSHostingView<CenterDividerView>!
    private var savedDefaults: [String: Any?] = [:]

    private static let keys = ["dividerOffsetY", "dividerIconSpacing", "quickLinksGap",
                               "centerDividerWidth", "dividerShowLabels", "dividerShowQuickLinks"]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.keys { savedDefaults[key] = defaults.object(forKey: key) }
        // Как у человека, который пожаловался: операции подняты на 100 пунктов,
        // между кнопками по 10 — самые широкие щели.
        defaults.set(100.0, forKey: "dividerOffsetY")
        defaults.set(10.0, forKey: "dividerIconSpacing")
        defaults.set(0.0, forKey: "quickLinksGap")
        defaults.set(80.0, forKey: "centerDividerWidth")
        defaults.set(true, forKey: "dividerShowLabels")
        defaults.set(true, forKey: "dividerShowQuickLinks")

        let view = CenterDividerView(
            activePanelPath: NSHomeDirectory(), isLeftPanelActive: true, splitRatio: 0.5,
            onSwap: {}, onCopy: {}, onMove: {}, onDelete: {},
            onMkdir: {}, onView: {}, onEdit: {}, onQuickLink: { _ in })
        hosting = TunnelDropHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 760),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = window.contentView!.bounds
        hosting.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        hosting = nil
        let defaults = UserDefaults.standard
        for key in Self.keys {
            if let value = savedDefaults[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    /// Какое меню AppKit покажет при правой кнопке в этой точке (координаты окна).
    private func menu(atY y: CGFloat) -> NSMenu? {
        let point = NSPoint(x: hosting.bounds.midX, y: y)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        // Как AppKit: у вида под курсором, а нет своего — у родителя, и так до окна.
        var view: NSView? = hosting.hitTest(point) ?? hosting
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    /// Меню туннеля — со значками у каждого пункта, как было всегда: SwiftUI-меню их
    /// теряло, и меню пропорций стало голым текстом.
    func test_уКаждогоПунктаМенюЕстьЗначок() throws {
        var bare: [String] = []
        var seen = 0
        for y in stride(from: CGFloat(2), to: hosting.bounds.height, by: 4) {
            guard let menu = menu(atY: y) else { continue }
            for item in menu.items where !item.isSeparatorItem {
                seen += 1
                if item.image == nil { bare.append(item.title) }
            }
        }
        XCTAssertGreaterThan(seen, 0)
        XCTAssertTrue(bare.isEmpty, "без значка: \(Set(bare))")
        let titles = stride(from: CGFloat(2), to: hosting.bounds.height, by: 4)
            .compactMap { menu(atY: $0) }.flatMap { $0.items.map(\.title) }
        XCTAssertTrue(titles.contains(L("divider.center")), "меню пропорций на пустом месте")
        XCTAssertTrue(titles.contains(L("tunnel.menu.removeFolder")), "меню папки")
        XCTAssertTrue(titles.contains(L("tunnel.menu.removeAction")), "меню операции")
    }

    func test_кнопкаТуннеляОтвечаетСвоимМеню() throws {
        // Кнопки нарисованы — значит, у какой-то точки есть меню операции или папки.
        let titles = stride(from: CGFloat(2), to: hosting.bounds.height, by: 4)
            .compactMap { menu(atY: $0) }
            .flatMap { $0.items.map(\.title) }
        XCTAssertTrue(titles.contains(L("tunnel.menu.changeIcon")),
                      "по кнопке операции — её меню: \(Set(titles))")
    }

    func test_правыйЩелчокОтвечаетВЛюбойТочкеТуннеля() throws {
        var silent: [CGFloat] = []
        for y in stride(from: CGFloat(2), to: hosting.bounds.height, by: 4)
        where menu(atY: y) == nil {
            silent.append(y)
        }
        XCTAssertTrue(silent.isEmpty,
                      "мёртвые зоны (y от низа окна): \(silent.map { Int($0) })")
    }
}
