import AppKit
import XCTest
@testable import TotumComXLApp

/// Значок под курсором не мигает «меньше-больше», когда панель перекрашивается: смена цвета
/// папок, перекраска раз в пятнадцать секунд. Проверяется каждый кадр, который уходит на
/// экран, — сразу после того, как Core Animation его отдал.
@MainActor
final class LiftBlinkTests: XCTestCase {

    private let zoom: CGFloat = 1.31
    private var keys: [String] {
        [PanelAppearanceSettings.cursorIconZoomEnabledKey, PanelAppearanceSettings.cursorIconZoomAmountKey,
         PanelAppearanceSettings.cursorIconZoomSpreadKey, CursorLift.enabledKey,
         FolderIconStyle.storageKey, FolderIconStyle.storageKey + "Light", FolderIconStyle.storageKey + "Dark",
         PanelAppearanceSettings.folderIconColorHexKey, PanelAppearanceSettings.folderIconColorHexLightKey,
         PanelAppearanceSettings.folderIconColorHexDarkKey, PanelAppearanceSettings.iconScaleKey]
    }
    private var saved: [String: Any] = [:]
    private var folder = ""

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        folder = NSTemporaryDirectory() + "мигание-\(UUID().uuidString)"
        for name in ["альфа", "бета", "гамма", "дельта"] {
            try FileManager.default.createDirectory(atPath: folder + "/" + name, withIntermediateDirectories: true)
        }
        let d = UserDefaults.standard
        d.set(true, forKey: PanelAppearanceSettings.cursorIconZoomEnabledKey)
        d.set(Double(zoom), forKey: PanelAppearanceSettings.cursorIconZoomAmountKey)
        d.set(0, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        d.set(true, forKey: CursorLift.enabledKey)
        for key in [FolderIconStyle.storageKey, FolderIconStyle.storageKey + "Light", FolderIconStyle.storageKey + "Dark"] {
            d.set("catalogV6", forKey: key)
        }
        setFolderColour("#FFAA5AFF")
        d.set(1.91, forKey: PanelAppearanceSettings.iconScaleKey)
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(atPath: folder)
        try await super.tearDown()
    }

    private func setFolderColour(_ hex: String) {
        for key in [PanelAppearanceSettings.folderIconColorHexKey, PanelAppearanceSettings.folderIconColorHexLightKey,
                    PanelAppearanceSettings.folderIconColorHexDarkKey] {
            UserDefaults.standard.set(hex, forKey: key)
        }
    }

    private func panel(mode: ViewMode) async throws -> (PanelViewController, NSWindow) {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.мигание.\(id)",
                                viewModeDefaultsKey: "panel.mode.мигание.\(id)",
                                showHiddenFiles: false)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        let tabs = PanelTabsViewModel(panelKey: "tabs.мигание.\(id)", initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabs, side: .left)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = vc.view
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil) }
        vm.viewMode = mode
        vm.loadDirectory(at: folder)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, vm.items.filter(\.isDirectory).count < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        vc.isActivePanel = true
        vm.cursorIndex = try XCTUnwrap(vm.items.firstIndex { $0.name == "бета" })
        try await Task.sleep(nanoseconds: 600_000_000)
        return (vc, window)
    }

    /// Значок курсорной строки сейчас.
    private func cursorIcon(_ vc: PanelViewController) -> NSImageView? {
        let row = vc.viewModel.cursorIndex
        if let table = vc.tableView, vc.viewModel.viewMode == .detailed {
            let column = table.column(withIdentifier: .init("icon"))
            return (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.imageView
        }
        func collections(_ view: NSView) -> [NSCollectionView] {
            (view as? NSCollectionView).map { [$0] } ?? view.subviews.flatMap(collections)
        }
        guard let cv = collections(vc.view).first,
              let item = cv.item(at: IndexPath(item: row, section: 0)) else { return nil }
        func images(_ view: NSView) -> [NSImageView] {
            ((view as? NSImageView).map { [$0] } ?? []) + view.subviews.flatMap(images)
        }
        return images(item.view).max { $0.frame.width < $1.frame.width }
    }

    /// Что ушло на экран: масштаб значка курсора в каждом отданном кадре.
    private func frames(of vc: PanelViewController, for seconds: TimeInterval,
                        while action: () -> Void) async throws -> [String] {
        var log: [String] = []
        var lastView: NSImageView?
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                guard let view = self.cursorIcon(vc), let layer = view.layer else { log.append("нет"); return }
                let model = layer.sublayerTransform.m11
                let shown = layer.presentation()?.sublayerTransform.m11 ?? model
                let animating = layer.animation(forKey: "fcxl.lift") != nil
                let same = view === lastView ? "" : " НОВЫЙ"
                lastView = view
                // Картинка NSImageView живёт в подслое: нет его содержимого — значок пустой.
                let drawn = layer.sublayers?.contains { $0.contents != nil } ?? false
                log.append(String(format: "%.3f/%.3f%@ b%.0f%@%@", model, shown,
                                  animating ? " anim" : "", view.bounds.width, same,
                                  drawn ? "" : " ПУСТО"))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        action()
        // Сон, а не вложенный цикл: отложенная перезагрузка стоит в главной очереди, и
        // вложенный цикл внутри её же блока до неё не доходит.
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        return log
    }

    private func assertNoDip(_ log: [String], _ title: String) {
        let scales = log.compactMap { line -> (CGFloat, CGFloat)? in
            let parts = line.split(separator: " ")[0].split(separator: "/")
            guard parts.count == 2, let m = Double(parts[0]), let p = Double(parts[1]) else { return nil }
            return (CGFloat(m), CGFloat(p))
        }
        let dipped = scales.contains { $0.0 < zoom - 0.01 || $0.1 < zoom - 0.01 }
        XCTAssertFalse(log.contains { $0.contains("ПУСТО") }, "\(title): значок не нарисован —\n"
                       + log.joined(separator: "\n"))
        XCTAssertFalse(dipped, "\(title): значок курсора опускался —\n" + log.joined(separator: "\n"))
        XCTAssertFalse(scales.isEmpty, "\(title): кадров не было")
    }

    func test_подробный_сменаЦветаПапок() async throws {
        let (vc, _) = try await panel(mode: .detailed)
        let before = vc.appearanceReloadCount
        let log = try await frames(of: vc, for: 0.6) { setFolderColour("#3366FFFF") }
        XCTAssertEqual(vc.appearanceReloadCount - before, 1, "перезагрузка была — проверялось то, что нужно")
        assertNoDip(log, "подробный, цвет папок")
    }

    func test_краткий_сменаЦветаПапок() async throws {
        let (vc, _) = try await panel(mode: .brief)
        let log = try await frames(of: vc, for: 0.6) { setFolderColour("#3366FFFF") }
        assertNoDip(log, "краткий, цвет папок")
    }

    func test_подробный_перекраскаПравил() async throws {
        let (vc, _) = try await panel(mode: .detailed)
        let log = try await frames(of: vc, for: 0.6) { vc.repaintForFreshness() }
        assertNoDip(log, "подробный, перекраска")
    }

    func test_краткий_перекраскаПравил() async throws {
        let (vc, _) = try await panel(mode: .brief)
        let log = try await frames(of: vc, for: 0.6) { vc.repaintForFreshness() }
        assertNoDip(log, "краткий, перекраска")
    }

    /// Слой держит подъём против AppKit, но не против программы: курсор ушёл — значок
    /// опустился, пришёл на новую строку — там поднялся.
    private func assertCursorMoveLowers(_ mode: ViewMode) async throws {
        let (vc, _) = try await panel(mode: mode)
        let old = try XCTUnwrap(cursorIcon(vc))
        XCTAssertEqual(old.layer?.sublayerTransform.m11 ?? 0, zoom, accuracy: 0.01)
        vc.viewModel.cursorIndex = try XCTUnwrap(vc.viewModel.items.firstIndex { $0.name == "гамма" })
        try await Task.sleep(nanoseconds: UInt64((CursorLift.duration + 0.4) * 1_000_000_000))
        let new = try XCTUnwrap(cursorIcon(vc))
        XCTAssertFalse(new === old)
        XCTAssertEqual(old.layer?.sublayerTransform.m11 ?? 0, 1, accuracy: 0.001, "прежний значок опустился")
        XCTAssertEqual(old.layer?.presentation()?.sublayerTransform.m11 ?? 1, 1, accuracy: 0.001)
        XCTAssertEqual(new.layer?.sublayerTransform.m11 ?? 0, zoom, accuracy: 0.01, "новый поднялся")
    }

    func test_подробный_курсорУшёл_значокОпустился() async throws { try await assertCursorMoveLowers(.detailed) }
    func test_краткий_курсорУшёл_значокОпустился() async throws { try await assertCursorMoveLowers(.brief) }
}
