import AppKit
import XCTest

@testable import TotumComXLApp

/// Shift + свайп двумя пальцами: влево — наверх, вправо — внутрь. Жест судится один раз, в
/// конце, по сумме движения; короткий, вертикальный или оборванный — ничего не делает.
final class SwipeNavigationTests: XCTestCase {

    private func swipe(_ deltas: [CGFloat], y: CGFloat = 0) -> SwipeNavigator.Direction? {
        var nav = SwipeNavigator()
        var result: SwipeNavigator.Direction?
        for (i, dx) in deltas.enumerated() {
            let phase: NSEvent.Phase = i == 0 ? .began : .changed
            XCTAssertNil(nav.feed(phase: phase, fingerX: dx, fingerY: y), "решение — только в конце жеста")
        }
        result = nav.feed(phase: .ended, fingerX: 0, fingerY: 0)
        XCTAssertFalse(nav.isActive)
        return result
    }

    func test_пальцыВлевоНаверхВправоВнутрь() {
        XCTAssertEqual(swipe([-15, -20, -20]), .up)
        XCTAssertEqual(swipe([15, 20, 20]), .into)
    }

    func test_короткийИВертикальныйЖестНеСчитаются() {
        XCTAssertNil(swipe([-10, -10]), "мало прошли")
        XCTAssertNil(swipe([-30, -30], y: 80), "это прокрутка вверх-вниз, а не свайп")
    }

    func test_оборванныйЖестЗабывается() {
        var nav = SwipeNavigator()
        _ = nav.feed(phase: .began, fingerX: -30, fingerY: 0)
        _ = nav.feed(phase: .cancelled, fingerX: 0, fingerY: 0)
        XCTAssertNil(nav.feed(phase: .ended, fingerX: -30, fingerY: 0), "после отмены конец ничего не значит")
        XCTAssertNil(nav.feed(phase: .changed, fingerX: -50, fingerY: 0), "движение без начала — не жест")
        XCTAssertNil(nav.feed(phase: .ended, fingerX: 0, fingerY: 0))
    }

    func test_инерцияПослеЖестаНеСчитается() {
        var nav = SwipeNavigator()
        _ = nav.feed(phase: .began, fingerX: -30, fingerY: 0)
        _ = nav.feed(phase: .changed, fingerX: -30, fingerY: 0)
        XCTAssertEqual(nav.feed(phase: .ended, fingerX: 0, fingerY: 0), .up, "конец жеста приходит с нулевой дельтой")
        XCTAssertNil(nav.feed(phase: [], fingerX: -40, fingerY: 0), "события инерции идут без фазы")
        XCTAssertNil(nav.feed(phase: .ended, fingerX: 0, fingerY: 0))
    }

    /// Направление пальцев не зависит от настройки «естественная прокрутка».
    func test_направлениеПальцевНеЗависитОтНастройкиПрокрутки() {
        // Естественная прокрутка: дельты уже идут за пальцами.
        XCTAssertEqual(SwipeNavigator.fingerMotion(deltaX: -10, invertedFromDevice: true), -10)
        // Обычная (как колесо): пальцы влево дают положительную дельту — переворачиваем.
        XCTAssertEqual(SwipeNavigator.fingerMotion(deltaX: 10, invertedFromDevice: false), -10)
    }
}

/// Свайп вправо после нескольких «наверх» ведёт обратно по тому же следу, до самой глубокой
/// папки, а не в первую попавшуюся под курсором.
@MainActor
final class SwipeTrailTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("fcxl-trail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root + "/a/b/c/d", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/a/x", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func panel(at path: String) -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(), initialPath: path,
                              pathDefaultsKey: "panel.path.trail.\(id)",
                              viewModeDefaultsKey: "panel.mode.trail.\(id)", showHiddenFiles: false)
    }

    private func wait(_ vm: PanelViewModel, until condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "не дождались: панель в \(vm.currentPath)")
    }

    private func at(_ vm: PanelViewModel, _ path: String) async throws {
        try await wait(vm) { (vm.currentPath as NSString).standardizingPath == (path as NSString).standardizingPath }
    }

    func test_триВверхТриВправоВозвращаютВГлубокуюПапку() async throws {
        let deep = root + "/a/b/c/d"
        let vm = panel(at: deep)
        try await at(vm, deep)

        vm.goUp(); try await at(vm, root + "/a/b/c")
        vm.goUp(); try await at(vm, root + "/a/b")
        vm.goUp(); try await at(vm, root + "/a")
        XCTAssertEqual(vm.trailBelow.map { ($0 as NSString).standardizingPath }, (root + "/a/b" as NSString).standardizingPath)

        XCTAssertTrue(vm.descendTrail()); try await at(vm, root + "/a/b")
        XCTAssertTrue(vm.descendTrail()); try await at(vm, root + "/a/b/c")
        XCTAssertTrue(vm.descendTrail()); try await at(vm, deep)
        XCTAssertNil(vm.trailBelow, "след пройден до конца")
        XCTAssertFalse(vm.descendTrail())
    }

    func test_уходВСторонуСтираетСлед() async throws {
        let vm = panel(at: root + "/a/b")
        try await at(vm, root + "/a/b")
        vm.goUp(); try await at(vm, root + "/a")
        XCTAssertNotNil(vm.trailBelow)
        vm.loadDirectory(at: root + "/a/x"); try await at(vm, root + "/a/x")
        XCTAssertNil(vm.trailBelow, "последний ход — не подъём, следа вниз нет")
    }
}
