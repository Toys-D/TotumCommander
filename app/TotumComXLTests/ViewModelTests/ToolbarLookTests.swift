import AppKit
import XCTest
@testable import TotumComXLApp

/// Панель инструментов окна: подписи под значками и черты между группами.
///
/// Значков семь, и все они говорят иносказательно — волна это монитор, поднос это полка.
/// Подпись снимает вопрос навсегда, поэтому она должна быть короткой: длинная строка
/// растянула бы всю полосу.
@MainActor
final class ToolbarLookTests: XCTestCase {

    private var saved: (look: String?, separators: Any?)!

    override func setUp() {
        super.setUp()
        saved = (UserDefaults.standard.string(forKey: ToolbarLook.defaultsKey),
                 UserDefaults.standard.object(forKey: ToolbarLook.separatorsKey))
    }

    override func tearDown() {
        UserDefaults.standard.set(saved.look, forKey: ToolbarLook.defaultsKey)
        UserDefaults.standard.set(saved.separators, forKey: ToolbarLook.separatorsKey)
        super.tearDown()
    }

    // MARK: - Выбор

    func test_выборПереводитсяВВидКнопки() {
        XCTAssertTrue(ToolbarLook.icons.showsIcon); XCTAssertFalse(ToolbarLook.icons.showsLabel)
        XCTAssertTrue(ToolbarLook.iconsAndLabels.showsIcon); XCTAssertTrue(ToolbarLook.iconsAndLabels.showsLabel)
        XCTAssertFalse(ToolbarLook.labels.showsIcon); XCTAssertTrue(ToolbarLook.labels.showsLabel)
        for look in ToolbarLook.allCases {
            XCTAssertEqual(look.displayMode, .iconOnly, "кнопка с подписью — своё вью, панель рисует его в этом режиме")
        }
    }

    /// Подпись — справа от значка, в той же строке заголовка: одна кнопка, а не значок с
    /// подписью под ним. Без подписей — пункт панели как был.
    func test_кнопкаСПодписьюВОднуСтроку() throws {
        let image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        let iconOnly = MainWindowController.toolbarButton(label: "Полка", image: image, look: .icons)
        XCTAssertEqual(iconOnly.imagePosition, .imageOnly, "без подписей — один значок, как было")
        XCTAssertNotNil(iconOnly.image)

        let both = MainWindowController.toolbarButton(label: "Полка", image: image, look: .iconsAndLabels)
        XCTAssertEqual(both.title, "Полка")
        XCTAssertNotNil(both.image)
        XCTAssertEqual(both.imagePosition, .imageLeading, "подпись справа от значка")
        XCTAssertTrue(both.showsBorderOnlyWhileMouseInside, "рамка только под мышью, как у пункта панели")
        XCTAssertGreaterThan(both.fittingSize.width, both.fittingSize.height, "кнопка лежит, а не стоит")

        let labelOnly = MainWindowController.toolbarButton(label: "Полка", image: image, look: .labels)
        XCTAssertEqual(labelOnly.imagePosition, .noImage)
        XCTAssertEqual(labelOnly.title, "Полка")
    }

    /// Название окна рисует строка заголовка; облик, выданный ей, доходит до названия — и на
    /// тёмном цвете заголовка оно светлеет вместе с кнопками.
    func test_обликСтрокиЗаголовкаДоходитДоНазванияОкна() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Totum Commander — проба"
        // Никогда не показанное окно не закрывать: close() освободило бы его дважды.
        window.isReleasedWhenClosed = false
        let strip = try XCTUnwrap(MainWindowController.titlebarView(of: window), "строка заголовка не найдена")
        strip.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(strip.effectiveAppearance.name, .darkAqua)
        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] } + view.subviews.flatMap(fields)
        }
        for field in fields(in: strip) where field.stringValue == window.title {
            XCTAssertEqual(field.effectiveAppearance.name, .darkAqua, "название окна не взяло облик строки")
        }
        strip.appearance = nil
        XCTAssertEqual(strip.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                       window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), "без своего цвета — как окно")
    }

    /// Ряд кнопок с подписями на трёх фонах — в FCXL_LOOK_DIR, посмотреть глазами: светлая
    /// тема, тёмная тема и светлая тема с ТЁМНЫМ цветом заголовка (тот самый случай, когда
    /// подписи пропадали) — облик кнопок выбирает ContrastAppearance по цвету фона.
    func test_снимокКнопокСПодписямиНаРазныхФонах() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let items: [(String, String)] = [("tray", "Полка"), ("trash", "Корзина"), ("waveform.path.ecg", "Монитор"), ("gear", "Настройки")]
        let slate = NSColor(srgbRed: 0x5c / 255, green: 0x6b / 255, blue: 0x73 / 255, alpha: 1)
        for (name, windowAppearance, background) in [
            ("панель-светлая", NSAppearance.Name.aqua, NSColor(white: 0.93, alpha: 1)),
            ("панель-тёмная", .darkAqua, NSColor(white: 0.18, alpha: 1)),
            ("панель-светлая-тёмный-заголовок", .aqua, slate),
        ] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            for (index, (symbol, label)) in items.enumerated() {
                if index > 0 { row.addArrangedSubview(MainWindowController.separatorView()) }
                row.addArrangedSubview(MainWindowController.toolbarButton(
                    label: label, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                    look: .iconsAndLabels))
            }
            // Как в окне: кнопки берут облик по цвету, на котором стоят, а не по теме.
            row.appearance = ContrastAppearance.appearance(on: background) ?? NSAppearance(named: windowAppearance)
            row.frame = NSRect(origin: .zero, size: row.fittingSize)
            let host = NSView(frame: row.bounds.insetBy(dx: -12, dy: -10))
            host.wantsLayer = true
            host.layer?.backgroundColor = background.cgColor
            host.appearance = NSAppearance(named: windowAppearance)
            row.frame.origin = NSPoint(x: 12, y: 10)
            host.addSubview(row)
            host.frame.origin = .zero
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }

    /// Подписи видны только тогда, когда панель стоит своей строкой под заголовком: в узкой
    /// полосе заголовка macOS их не рисует, сколько ни проси.
    func test_панельВсегдаВСтрокеЗаголовка() {
        for look in ToolbarLook.allCases {
            XCTAssertEqual(look.windowStyle, .unifiedCompact,
                           "\(look): подпись справа от значка, название окна слева, окно не растёт")
        }
    }

    func test_поУмолчаниюОдниЗначки() {
        UserDefaults.standard.removeObject(forKey: ToolbarLook.defaultsKey)
        UserDefaults.standard.removeObject(forKey: ToolbarLook.separatorsKey)
        XCTAssertEqual(ToolbarLook.chosen, .icons, "одни значки — и до набора, и в наборе (DefaultStyle)")
        // Черты: без своего выбора — как в авторском наборе, если он зарегистрирован, иначе нет.
        let shipped = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(ToolbarLook.showsSeparators, shipped[ToolbarLook.separatorsKey] as? Bool ?? false)

        UserDefaults.standard.set("чепуха", forKey: ToolbarLook.defaultsKey)
        XCTAssertEqual(ToolbarLook.chosen, .icons, "непонятное значение не ломает панель")

        UserDefaults.standard.set(ToolbarLook.labels.rawValue, forKey: ToolbarLook.defaultsKey)
        UserDefaults.standard.set(true, forKey: ToolbarLook.separatorsKey)
        XCTAssertEqual(ToolbarLook.chosen, .labels)
        XCTAssertTrue(ToolbarLook.showsSeparators)
    }

    func test_уКаждогоВидаЕстьНазвание() {
        for look in ToolbarLook.allCases {
            XCTAssertNotEqual(L(look.titleKey), look.titleKey, "нет перевода \(look.titleKey)")
        }
    }

    // MARK: - Порядок кнопок

    func test_безРазделителейПорядокПрежний() {
        let order = MainWindowController.toolbarItemOrder(separators: false)
        XCTAssertEqual(order.map(\.rawValue),
                       ["openDropStack", "openTrash", "systemMonitor", "diskInfo",
                        "toggleTheme", "toggleHiddenFiles", "openSettings"])
    }

    func test_чертаМеждуКаждымиДвумяКнопками() {
        let order = MainWindowController.toolbarItemOrder(separators: true).map(\.rawValue)
        XCTAssertEqual(order,
                       ["openDropStack", "buttonSeparator1", "openTrash",
                        "buttonSeparator2", "systemMonitor", "buttonSeparator3", "diskInfo",
                        "buttonSeparator4", "toggleTheme", "buttonSeparator5", "toggleHiddenFiles",
                        "buttonSeparator6", "openSettings"],
                       "семь кнопок — шесть черт, по одной между соседями")
        XCTAssertEqual(Set(order).count, order.count,
                       "имена не повторяются — панель не пустила бы два одинаковых пункта")
    }

    // MARK: - Исполнение пункта меню

    /// Выпадающий список в настройках — это меню, нарисованное нами, и щелчок по строке
    /// обязан дойти до её замыкания. Прямой вызов — единственный, который доходит и в
    /// модальном окне настроек: `sendAction` там разбирает действия по цепочке
    /// ответственности модального окна, а обычный объект-приёмник в неё не входит.
    func test_щелчокПоСтрокеДоходитДоСвоейЦели() {
        let menu = NSMenu()
        var сработало = false
        menu.addStyledItem(title: "выбрать", symbolName: "checkmark") { сработало = true }
        menu.applyAccentStyle()

        XCTAssertTrue(MenuActionDispatch.run(menu.items[0]), "действие доставлено")
        XCTAssertTrue(сработало, "замыкание строки исполнено")
    }

    /// У пунктов строки меню цели нет — их ищут по цепочке ответственности; без окна
    /// цепочка пуста, и отказ должен быть тихим, а не падением.
    func test_командаБезЦелиИщетсяПоЦепочкеИНеРоняет() {
        let item = NSMenuItem(title: "команда", action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "")
        XCTAssertNoThrow(MenuActionDispatch.run(item))

        let пустой = NSMenuItem(title: "без действия", action: nil, keyEquivalent: "")
        XCTAssertFalse(MenuActionDispatch.run(пустой))
    }

    // MARK: - Подписи

    /// Подпись под значком должна быть словом, а не предложением: под «Показать скрытые
    /// элементы (Cmd+Shift+.)» полоса растянулась бы во всю ширину окна.
    func test_подписиКороткиеИПереведены() {
        let keys = ["toolbar.label.stack", "toolbar.label.trash", "toolbar.label.monitor",
                    "toolbar.label.disks", "toolbar.label.theme", "toolbar.label.hidden",
                    "toolbar.label.settings"]
        for key in keys {
            let title = L(key)
            XCTAssertNotEqual(title, key, "нет перевода \(key)")
            XCTAssertLessThanOrEqual(title.count, 12, "«\(title)» — не подпись, а предложение")
            XCTAssertFalse(title.contains("("), "клавиши — в подсказке, не в подписи: \(title)")
        }
    }
}
