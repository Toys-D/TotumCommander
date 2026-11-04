import AppKit
import XCTest
@testable import TotumComXLApp

/// Появление списков при запуске: лесенка задержек, откуда выезжать, один раз на панель,
/// и что ряды действительно прячутся и получают анимацию.
@MainActor
final class LaunchEntranceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LaunchEntrance.reset()
    }

    override func tearDown() {
        LaunchEntrance.reset()
        super.tearDown()
    }

    func test_лесенкаЗадержекСПотолком() {
        XCTAssertEqual(LaunchEntrance.delay(forIndex: 0), 0)
        XCTAssertEqual(LaunchEntrance.delay(forIndex: 1), LaunchEntrance.stagger, accuracy: 0.0001)
        XCTAssertEqual(LaunchEntrance.delay(forIndex: 10), LaunchEntrance.stagger * 10, accuracy: 0.0001)
        XCTAssertEqual(LaunchEntrance.delay(forIndex: 1000), LaunchEntrance.maxStagger,
                       "длинный список не выезжает секундами")
        XCTAssertLessThan(LaunchEntrance.maxStagger + LaunchEntrance.duration, 0.8, "целиком меньше секунды")
    }

    func test_откудаВыезжать() {
        XCTAssertEqual(LaunchEntrance.offset(forWidth: 500), 150)
        XCTAssertEqual(LaunchEntrance.offset(forWidth: 50), 40, "не меньше сорока")
        XCTAssertEqual(LaunchEntrance.offset(forWidth: 5000), 180, "и не через всю панель")
    }

    func test_порядокЛесенки() {
        let a = NSView(frame: NSRect(x: 0, y: 40, width: 10, height: 10))
        let b = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let c = NSView(frame: NSRect(x: 200, y: 0, width: 10, height: 10))
        XCTAssertEqual(LaunchEntrance.ordered([c, a, b]), [b, a, c], "сверху вниз, колонка за колонкой")
    }

    private func rows(_ count: Int, in window: NSWindow) -> [NSView] {
        (0..<count).map { i in
            let view = NSView(frame: NSRect(x: 0, y: CGFloat(i) * 24, width: 400, height: 24))
            window.contentView?.addSubview(view)
            return view
        }
    }

    /// Ряды сначала спрятаны за краем, а после паузы выезжают лесенкой; модель — на месте.
    func test_рядыПрячутсяИВыезжаютОдинРаз() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let views = rows(3, in: window)
        let key = ObjectIdentifier(window)
        LaunchEntrance.request(key: key, enabled: true, views: { views }, width: { 400 })
        for view in views {
            XCTAssertEqual(view.layer?.opacity, 0, "спрятан до выезда")
            XCTAssertEqual(view.layer?.transform.m41 ?? 0, 120, accuracy: 0.5, "за правым краем")
        }
        XCTAssertTrue(LaunchEntrance.isPending(key, enabled: true), "до выезда ещё в ожидании")

        RunLoop.main.run(until: Date().addingTimeInterval(LaunchEntrance.settle + 0.1))
        var begins: [CFTimeInterval] = []
        for view in views {
            let layer = try XCTUnwrap(view.layer)
            let group = try XCTUnwrap(layer.animation(forKey: LaunchEntrance.animationKey) as? CAAnimationGroup)
            XCTAssertEqual(group.duration, LaunchEntrance.duration, accuracy: 0.001)
            XCTAssertEqual(group.animations?.count, 2, "сдвиг и проявление")
            begins.append(group.beginTime)
            XCTAssertEqual(layer.opacity, 1, "модель — уже на месте")
            XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
        }
        XCTAssertEqual(begins[1] - begins[0], LaunchEntrance.stagger, accuracy: 0.002, "лесенка")
        XCTAssertEqual(begins[2] - begins[1], LaunchEntrance.stagger, accuracy: 0.002)

        XCTAssertFalse(LaunchEntrance.isPending(key, enabled: true), "показано — больше не повторится")
        // Дождаться конца выезда: пока он идёт, новые ряды его подхватывают (это отдельный тест).
        RunLoop.main.run(until: Date().addingTimeInterval(LaunchEntrance.duration + LaunchEntrance.maxStagger + 0.1))
        let later = rows(1, in: window)
        LaunchEntrance.request(key: key, enabled: true, views: { later }, width: { 400 })
        XCTAssertNil(later[0].layer, "второй раз ничего не трогается")
        withExtendedLifetime(window) {}
    }

    /// Выключено или пусто — ряды не трогаются и ничего не назначается.
    func test_выключеноИлиПусто_НичегоНеДелает() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let views = rows(2, in: window)
        let key = ObjectIdentifier(window)
        LaunchEntrance.request(key: key, enabled: false, views: { views }, width: { 400 })
        XCTAssertNil(views[0].layer, "выключено — без слоёв и без пряток")
        LaunchEntrance.request(key: key, enabled: true, views: { [] }, width: { 400 })
        XCTAssertTrue(LaunchEntrance.isPending(key, enabled: true), "пустой список — ждём наполнения")
        withExtendedLifetime(window) {}
    }

    /// Новое наполнение до выезда переназначает показ: выезжают ряды, которые есть в момент
    /// показа, а не те, что были при первом наполнении.
    func test_повторноеНаполнениеПереназначаетПоказ() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        var current = rows(2, in: window)
        let key = ObjectIdentifier(window)
        LaunchEntrance.request(key: key, enabled: true, views: { current }, width: { 400 })
        current = rows(3, in: window)
        LaunchEntrance.request(key: key, enabled: true, views: { current }, width: { 400 })
        RunLoop.main.run(until: Date().addingTimeInterval(LaunchEntrance.settle + 0.1))
        for view in current {
            XCTAssertNotNil(view.layer?.animation(forKey: LaunchEntrance.animationKey), "новые ряды выехали")
        }
        withExtendedLifetime(window) {}
    }

    // MARK: - Во время выезда

    /// Список перезагрузился посреди выезда: новые ряды подхватывают то же расписание, а не
    /// ждут и не начинают заново.
    func test_перезагрузкаВоВремяВыездаПродолжаетЕго() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let first = rows(3, in: window)
        let key = ObjectIdentifier(window)
        LaunchEntrance.request(key: key, enabled: true, views: { first }, width: { 400 })
        RunLoop.main.run(until: Date().addingTimeInterval(LaunchEntrance.settle + 0.05))
        XCTAssertTrue(LaunchEntrance.isRunning(key), "выезд идёт")
        let firstBegin = try XCTUnwrap(first[2].layer?.animation(forKey: LaunchEntrance.animationKey)?.beginTime)

        let second = rows(3, in: window)
        XCTAssertTrue(LaunchEntrance.request(key: key, enabled: true, views: { second }, width: { 400 }))
        let continued = try XCTUnwrap(second[2].layer?.animation(forKey: LaunchEntrance.animationKey) as? CAAnimationGroup)
        XCTAssertEqual(continued.beginTime, firstBegin, accuracy: 0.001, "то же расписание")
        XCTAssertEqual(second[2].layer?.opacity, 1, "не спрятан заново")

        RunLoop.main.run(until: Date().addingTimeInterval(LaunchEntrance.duration + LaunchEntrance.maxStagger + 0.1))
        XCTAssertFalse(LaunchEntrance.isRunning(key))
        XCTAssertFalse(LaunchEntrance.request(key: key, enabled: true, views: { self.rows(1, in: window) }, width: { 400 }),
                       "после выезда — ничего")
        withExtendedLifetime(window) {}
    }

    /// Спрятанные перед выездом ряды, которых в выезде не оказалось (список перезагрузился),
    /// возвращаются в видимость — иначе таблица показывала их пустыми строками.
    func test_спрятанныеБезВыездаВозвращаются() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let first = rows(2, in: window)
        let key = ObjectIdentifier(window)
        LaunchEntrance.request(key: key, enabled: true, views: { first }, width: { 400 })
        XCTAssertEqual(first[0].layer?.opacity, 0, "спрятан")
        let second = rows(2, in: window)
        LaunchEntrance.request(key: key, enabled: true, views: { second }, width: { 400 })
        XCTAssertEqual(first[0].layer?.opacity, 1, "старый ряд возвращён")
        XCTAssertTrue(CATransform3DIsIdentity(first[0].layer?.transform ?? CATransform3DMakeTranslation(1, 0, 0)))
        XCTAssertEqual(second[0].layer?.opacity, 0, "новый спрятан до выезда")
        withExtendedLifetime(window) {}
    }

    // MARK: - Подробная таблица

    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 4 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileListRowView() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSView() }
    }

    /// Ряды берутся после ЛЮБОЙ перезагрузки, не только первой: замер показал 4 после первой
    /// и 0 после второй, если полагаться на раскладку.
    func test_рядыТаблицыБерутсяПослеКаждойПерезагрузки() {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 24 * 4)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let table = PanelNSTableView(frame: frame)
        table.headerView = nil; table.rowHeight = 24
        let column = NSTableColumn(identifier: .init("name")); column.width = 500
        table.addTableColumn(column)
        let rows = Rows(); table.dataSource = rows; table.delegate = rows
        window.contentView = table
        table.reloadData()
        XCTAssertEqual(LaunchEntrance.tableRows(table).count, 4)
        table.reloadData()
        let again = LaunchEntrance.tableRows(table)
        XCTAssertEqual(again.count, 4, "и после второй перезагрузки")
        let tops = again.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "сверху вниз")
        withExtendedLifetime(rows) {}
        withExtendedLifetime(window) {}
    }
}
