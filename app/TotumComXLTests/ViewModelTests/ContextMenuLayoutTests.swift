import AppKit
import ImageIO
import XCTest
@testable import TotumComXLApp

/// Раскладка контекстного меню: что видно сразу, что уходит под «Ещё».
@MainActor
final class ContextMenuLayoutTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "context.layout.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private typealias Entry = ContextMenuSplit.Entry

    // MARK: - Расчёт

    func test_ничегоНеСпрятано_МенюКакБыло() {
        let entries: [Entry] = [.item(id: "a"), .separator, .item(id: "b")]
        let split = ContextMenuSplit.split(entries: entries, extra: [])
        XCTAssertEqual(split.main, [0, 1, 2])
        XCTAssertTrue(split.extra.isEmpty)
    }

    func test_спрятанноеУходитВДополнительную_ВПорядкеЧеловека() {
        let entries: [Entry] = [.item(id: "a"), .item(id: "b"), .item(id: "c")]
        let split = ContextMenuSplit.split(entries: entries, extra: ["c", "a"])
        XCTAssertEqual(split.main, [1], "осталось только b")
        XCTAssertEqual(split.extra, [2, 0], "порядок — как разложил человек: сначала c, потом a")
    }

    func test_разделительБезСоседейСхлопывается() {
        // a | b  →  спрятали b: полоса в конце не нужна.
        let entries: [Entry] = [.item(id: "a"), .separator, .item(id: "b")]
        XCTAssertEqual(ContextMenuSplit.split(entries: entries, extra: ["b"]).main, [0])
        // a | b | c  →  спрятали b: две полосы подряд превращаются в одну.
        let three: [Entry] = [.item(id: "a"), .separator, .item(id: "b"), .separator, .item(id: "c")]
        XCTAssertEqual(ContextMenuSplit.split(entries: three, extra: ["b"]).main, [0, 1, 4])
        // Спрятали первый — полоса в начале тоже не нужна.
        let leading: [Entry] = [.item(id: "a"), .separator, .item(id: "b")]
        XCTAssertEqual(ContextMenuSplit.split(entries: leading, extra: ["a"]).main, [2])
    }

    func test_пунктыБезИмениОстаютсяВОсновной() {
        let entries: [Entry] = [.item(id: nil), .item(id: "a")]
        let split = ContextMenuSplit.split(entries: entries, extra: ["a"])
        XCTAssertEqual(split.main, [0], "безымянный не спрячешь — он и остаётся на виду")
        XCTAssertEqual(split.extra, [1])
    }

    func test_имяКоторогоНетВМеню_НичегоНеЛомает() {
        let entries: [Entry] = [.item(id: "a")]
        let split = ContextMenuSplit.split(entries: entries, extra: ["нет-такого", "a"])
        XCTAssertEqual(split.main, [])
        XCTAssertEqual(split.extra, [0])
    }

    // MARK: - Хранилище

    /// Первый же шаг правки записывает меню целиком: дальше человек хозяин списка, и
    /// программа в него больше ничего не добавляет от себя.
    func test_первыйШагПравкиЗаписываетМенюЦеликом() {
        let layout = ContextMenuLayout(defaults: defaults)
        XCTAssertFalse(layout.isCustomised, "по умолчанию меню как было")
        XCTAssertEqual(layout.shownMain, ContextMenuCatalogue.defaultOrder)

        layout.add("cmd:menuPack:", toExtra: false)

        XCTAssertTrue(layout.isExplicit)
        XCTAssertEqual(layout.main, ContextMenuCatalogue.defaultOrder + ["cmd:menuPack:"])
        XCTAssertEqual(ContextMenuLayout(defaults: defaults).main, layout.main, "переживает перезапуск")
    }

    /// Убрать можно всё до последней строки — и это состояние должно пережить перезапуск,
    /// а не притвориться «ничего не трогал».
    func test_убратьМожноВсё() {
        let layout = ContextMenuLayout(defaults: defaults)
        layout.setMain(["a", "b"])
        layout.remove(at: 1, fromExtra: false)
        layout.remove(at: 0, fromExtra: false)
        XCTAssertEqual(layout.main, [])
        XCTAssertTrue(layout.isCustomised, "пустое меню — тоже выбор человека")

        let reopened = ContextMenuLayout(defaults: defaults)
        XCTAssertTrue(reopened.isCustomised)
        XCTAssertEqual(reopened.shownMain, [], "и после перезапуска меню остаётся пустым")
    }

    func test_разделителейМожетБытьНесколько() {
        let layout = ContextMenuLayout(defaults: defaults)
        layout.setMain([])
        layout.add("context.copy", toExtra: false)
        layout.add(ContextMenuLayout.separatorID, toExtra: false)
        layout.add("context.pack", toExtra: false)
        layout.add(ContextMenuLayout.separatorID, toExtra: false)
        layout.add("context.copy", toExtra: false)
        XCTAssertEqual(layout.main, ["context.copy", ContextMenuLayout.separatorID,
                                     "context.pack", ContextMenuLayout.separatorID],
                       "разделителей сколько угодно, а пункт второй раз не встанет")
    }

    func test_порядокДвигается() {
        let layout = ContextMenuLayout(defaults: defaults)
        layout.setMain(["a", "b", "c"])
        layout.move(at: 2, up: true, inExtra: false)
        XCTAssertEqual(layout.main, ["a", "c", "b"])
        layout.move(at: 0, up: true, inExtra: false)
        XCTAssertEqual(layout.main, ["a", "c", "b"], "у края просьба не исполняется")
        layout.move(at: 0, up: false, inExtra: false)
        XCTAssertEqual(layout.main, ["c", "a", "b"])
    }

    func test_переносМеждуЧастями() {
        let layout = ContextMenuLayout(defaults: defaults)
        layout.setMain(["a", "b"])
        layout.setExtra([])
        layout.transfer(at: 0, fromExtra: false)
        XCTAssertEqual(layout.main, ["b"])
        XCTAssertEqual(layout.extra, ["a"])
        layout.transfer(at: 0, fromExtra: true)
        XCTAssertEqual(layout.main, ["b", "a"])
        XCTAssertEqual(layout.extra, [])
    }

    func test_поУмолчаниюВозвращаетПрежнееМеню() {
        let layout = ContextMenuLayout(defaults: defaults)
        layout.add("cmd:menuPack:", toExtra: true)
        layout.remove(at: 0, fromExtra: false)
        XCTAssertTrue(layout.isCustomised)

        layout.reset()

        XCTAssertFalse(layout.isCustomised)
        XCTAssertEqual(layout.main, [])
        XCTAssertEqual(layout.extra, [])
        XCTAssertEqual(layout.shownMain, ContextMenuCatalogue.defaultOrder, "меню как при установке")
        XCTAssertFalse(ContextMenuLayout(defaults: defaults).isCustomised, "и после перезапуска")
    }

    // MARK: - Каталог

    /// Каталог не расходится с меню: у каждого пункта есть строка и значок, повторов нет.
    func test_каталогПолонИБезПовторов() {
        let all = ContextMenuCatalogue.all
        XCTAssertGreaterThan(all.count, 30)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "повторов нет")
        for entry in all {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertNotEqual(entry.title, entry.id, "у «\(entry.id)» нет перевода")
            XCTAssertNotNil(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil),
                            "нет значка \(entry.symbol)")
        }
        XCTAssertTrue(ContextMenuCatalogue.defaultOrder.contains(ContextMenuLayout.separatorID),
                      "разделители в меню по умолчанию есть")
    }

    /// Каталог обязан совпадать со сборщиком меню: всё, что тот ставит верхним уровнем, должно
    /// быть в списке по умолчанию и в том же порядке — иначе человек не найдёт пункт в настройках,
    /// а нажав «По умолчанию», получит не то меню, что было.
    func test_каталогСовпадаетСоСборщикомМеню() async throws {
        let (vc, file) = try await panelWithFile()
        let saved = snapshot()
        defer { restore(saved) }
        ContextMenuLayout.shared.reset()

        let menu = NSMenu()
        vc.populateContextMenu(menu, for: file)
        let ids = menu.items.map { $0.isSeparatorItem ? ContextMenuLayout.separatorID
                                                      : ($0.identifier?.rawValue ?? "БЕЗ-ИМЕНИ") }
        XCTAssertFalse(ids.isEmpty)
        XCTAssertFalse(ids.contains("БЕЗ-ИМЕНИ"), "у каждой строки меню есть имя: \(ids)")

        // Порядок: имена меню идут подпоследовательностью списка по умолчанию.
        var rest = ContextMenuCatalogue.defaultOrder[...]
        for id in ids {
            guard let position = rest.firstIndex(of: id) else {
                XCTFail("«\(id)» нет в списке по умолчанию или он стоит не там: \(ids)")
                return
            }
            rest = rest[(position + 1)...]
        }
    }

    /// Спрятанное уходит под «Ещё», а сама кнопка появляется — и только при спрятанном.
    func test_менюФайла_ПрячетИПоказываетКнопкуЕщё() async throws {
        let (vc, file) = try await panelWithFile()
        let saved = snapshot()
        defer { restore(saved) }

        ContextMenuLayout.shared.reset()
        let plain = NSMenu()
        vc.populateContextMenu(plain, for: file)
        let plainIDs = plain.items.compactMap { $0.identifier?.rawValue }
        XCTAssertTrue(plainIDs.contains("context.properties"))
        XCTAssertFalse(plainIDs.contains("context.more"), "прятать нечего — кнопки нет")

        ContextMenuLayout.shared.setExtra(["context.properties"])
        let split = NSMenu()
        vc.populateContextMenu(split, for: file)
        let splitIDs = split.items.compactMap { $0.identifier?.rawValue }
        XCTAssertFalse(splitIDs.contains("context.properties"), "спрятанного сразу не видно")
        XCTAssertEqual(splitIDs.last, "context.more", "кнопка «Ещё» — в самом низу")

        // Спрятанное едет вместе с кнопкой: окну меню больше не нужно собирать меню заново.
        let more = try XCTUnwrap(split.items.last as? ContextMoreMenuItem)
        XCTAssertEqual(more.hiddenRows.compactMap { $0.identifier?.rawValue }, ["context.properties"])
    }

    /// «Ещё» дописывает спрятанное в ТО ЖЕ окно: меню не закрывается и не собирается
    /// заново — раньше это выглядело как мигание на месте щелчка.
    func test_ещё_ДописываетСписокВТоЖеОкно() throws {
        let menu = NSMenu()
        menu.addStyledItem(title: "Открыть", symbolName: "folder", id: "context.open") {}
        menu.addItem(ContextMoreMenuItem(hiddenRows: [row("context.properties"), row("context.copyPath")]))

        let popup = ContextPopupMenuController.shared
        addTeardownBlock { MainActor.assumeIsolated { popup.dismiss() } }
        popup.show(menu, at: NSPoint(x: 400, y: 600))
        let window = try XCTUnwrap(popup.openMenuWindow)
        let before = window.frame
        XCTAssertEqual(popup.openMenuRows.count, 2)

        popup.expandOpenMenu(try XCTUnwrap(menu.items.last as? ContextMoreMenuItem))

        XCTAssertTrue(popup.openMenuWindow === window, "окно то же самое")
        XCTAssertEqual(popup.openMenuRows.compactMap { $0.identifier?.rawValue },
                       ["context.open", "context.properties", "context.copyPath"],
                       "«Ещё» сменилось продолжением списка")
        XCTAssertGreaterThan(window.frame.height, before.height, "окно подросло вниз")
        XCTAssertEqual(window.frame.width, before.width, accuracy: 0.5,
                       "ширину меряли сразу по полному списку — вбок ничего не дёрнулось")
        XCTAssertEqual(window.frame.maxY, before.maxY, accuracy: 0.5, "верх остался на месте")

        // И само окно перерисовалось новым списком, а не осталось с прежним под растянутой рамой.
        let content = try XCTUnwrap(window.contentView)
        let срок = Date().addingTimeInterval(2)
        while Date() < срок, abs(content.fittingSize.height - window.frame.height) > 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            content.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(content.fittingSize.height, window.frame.height, accuracy: 1,
                       "содержимое встало ровно в новое окно")
    }

    /// Открылась строка меню — наше меню гаснет, как погасло бы системное. Щелчок по строке
    /// меню до мониторов не доходит, поэтому слушается само начало слежения за меню.
    func test_строкаМенюГаситКонтекстноеМеню() throws {
        let menu = NSMenu()
        menu.addStyledItem(title: "Открыть", symbolName: "folder", id: "context.open") {}
        let popup = ContextPopupMenuController.shared
        addTeardownBlock { MainActor.assumeIsolated { popup.dismiss() } }
        popup.show(menu, at: NSPoint(x: 400, y: 600))
        XCTAssertNotNil(popup.openMenuWindow)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())

        XCTAssertNil(popup.openMenuWindow, "меню погасло")
    }

    /// Все меню программы — в одном окне: выпадающее под кнопкой висит под ней, а не где
    /// курсор, и работает внутри модального окна (иначе ни одна его строка не нажмётся).
    func test_менюПодКнопкой_ВОдномОкне() throws {
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
        let anchor = NSView(frame: NSRect(x: 50, y: 200, width: 120, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let menu = NSMenu()
        menu.addStyledItem(title: "Первый", symbolName: "1.circle") {}
        menu.addStyledItem(title: "Второй", symbolName: "2.circle") {}
        let popup = ContextPopupMenuController.shared
        addTeardownBlock { MainActor.assumeIsolated { popup.dismiss() } }

        popup.show(menu, below: anchor)

        let shown = try XCTUnwrap(popup.openMenuWindow)
        let anchorOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        XCTAssertEqual(shown.frame.minX, anchorOnScreen.minX, accuracy: 0.5, "левый край — по кнопке")
        XCTAssertEqual(shown.frame.maxY, anchorOnScreen.minY - 4, accuracy: 0.5, "сразу под кнопкой")
        XCTAssertTrue(shown.worksWhenModal, "кнопки меню живы и в модальном окне")
        XCTAssertEqual(shown.animationBehavior, .none, "системной анимации появления нет")
        XCTAssertEqual(popup.openMenuRows.count, 2)
    }

    /// Страницу с живым предпросмотром меню окно настроек узнаёт по запомненному разделу:
    /// оно достаётся из кармана, и `onAppear` страницы при повторном открытии молчит.
    func test_предпросмотрПоднимаетсяТолькоНаСвоейСтранице() {
        XCTAssertTrue(SettingsSection.wantsContextMenuPreview(lastSection: "contextMenu"))
        XCTAssertFalse(SettingsSection.wantsContextMenuPreview(lastSection: "general"))
        XCTAssertFalse(SettingsSection.wantsContextMenuPreview(lastSection: nil))
        XCTAssertEqual(SettingsSection.contextMenu.rawValue, "contextMenu", "имя раздела в ключе")
    }

    private func row(_ id: String) -> NSMenuItem {
        let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        return item
    }

    /// Меню пустого места короткое: шесть строк, прятать нечего — раскладка его не трогает.
    func test_менюПустогоМеста_НеРаскладывается() throws {
        let vc = try panel()
        let saved = snapshot()
        defer { restore(saved) }
        ContextMenuLayout.shared.reset()
        ContextMenuLayout.shared.setExtra(["context.refresh", "context.copyPath"])
        let menu = NSMenu()
        vc.populateContextMenu(menu, for: nil)
        let ids = menu.items.compactMap { $0.identifier?.rawValue }
        XCTAssertTrue(ids.contains("context.refresh"), "остаётся на виду: \(ids)")
        XCTAssertTrue(ids.contains("context.copyPath"))
        XCTAssertFalse(ids.contains("context.more"), "кнопки «Ещё» здесь нет")
    }

    // MARK: - Своё меню

    /// Меню, собранное человеком: ровно его список — штатный пункт, разделитель, команда
    /// программы — и ничего сверх того.
    func test_собранноеМеню_ПоказываетРовноСписокЧеловека() async throws {
        let (vc, file) = try await panelWithFile()
        let saved = snapshot()
        defer { restore(saved) }
        let savedBar = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = savedBar }
        NSApplication.shared.mainMenu = AppDelegate.buildMainMenu()

        let command = try XCTUnwrap(CommandRegistry.commands().first, "строка меню собрана")
        ContextMenuLayout.shared.reset()
        ContextMenuLayout.shared.setMain(["context.properties", ContextMenuLayout.separatorID,
                                          command.stableID])
        ContextMenuLayout.shared.setExtra(["context.copy"])

        let menu = NSMenu()
        vc.populateContextMenu(menu, for: file)
        let ids = menu.items.map { $0.isSeparatorItem ? ContextMenuLayout.separatorID
                                                      : ($0.identifier?.rawValue ?? "?") }
        XCTAssertEqual(ids, ["context.properties", ContextMenuLayout.separatorID, command.stableID,
                             ContextMenuLayout.separatorID, ContextMenuLayout.moreID],
                       "и ни одного пункта, которого человек не просил")

        // Команда программы принесла с собой своё действие и своё название.
        let row = menu.items[2]
        XCTAssertEqual(row.title, command.title)
        XCTAssertEqual(row.action, command.item.action)

        // Спрятанное едет с кнопкой «Ещё».
        let more = try XCTUnwrap(menu.items.last as? ContextMoreMenuItem)
        XCTAssertEqual(more.hiddenRows.compactMap { $0.identifier?.rawValue }, ["context.copy"])
    }

    /// Команда приносит с собой не только действие: свежее название (проверка успевает
    /// переписать слово переключателя), галочку и подсказку.
    func test_командаПриноситСвежееНазваниеГалочкуИПодсказку() async throws {
        let (vc, file) = try await panelWithFile()
        let saved = snapshot()
        defer { restore(saved) }
        let savedBar = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = savedBar }
        NSApplication.shared.mainMenu = AppDelegate.buildMainMenu()

        let command = try XCTUnwrap(CommandRegistry.commands().first)
        // Так пункт ведёт себя после проверки доступности: слово другое, галочка стоит.
        command.item.title = "новое слово"
        command.item.state = .on
        command.item.toolTip = "почему нельзя"

        let row = PanelViewController.commandRow(command)

        XCTAssertEqual(row.title, command.prefix + "новое слово", "название сегодняшнее")
        XCTAssertEqual(row.state, .on, "галочка переключателя видна")
        XCTAssertEqual(row.toolTip, "почему нельзя", "погасшая строка объясняет себя")
        XCTAssertEqual(row.identifier?.rawValue, command.stableID)
        _ = vc
        _ = file
    }

    /// Имя команды не должно зависеть от имени учётной записи: путь в нём — с «~».
    func test_имяКомандыСПутёмБезИмениУчётки() {
        let savedBar = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = savedBar }
        NSApplication.shared.mainMenu = AppDelegate.buildMainMenu()

        let places = CommandRegistry.commands().filter { $0.stableID.contains("menuGoFolder") }
        XCTAssertGreaterThan(places.count, 5, "быстрые места на месте")
        for place in places {
            XCTAssertFalse(place.stableID.contains(NSHomeDirectory()),
                           "имя учётки внутри имени команды: \(place.stableID)")
        }
        XCTAssertTrue(places.contains { $0.stableID.hasSuffix("#~/Desktop") },
                      "путь свёрнут до «~»: \(places.map(\.stableID))")
    }

    /// Убрать можно всё: пустой список — пустое меню, а не тайный возврат к прежнему.
    func test_собранноеМеню_МожетБытьПустым() async throws {
        let (vc, file) = try await panelWithFile()
        let saved = snapshot()
        defer { restore(saved) }

        ContextMenuLayout.shared.reset()
        ContextMenuLayout.shared.setMain([])

        let menu = NSMenu()
        vc.populateContextMenu(menu, for: file)
        XCTAssertTrue(menu.items.isEmpty, "остались строки: \(menu.items.map(\.title))")
    }

    /// Имя, которому в этом меню нечего показать, просто пропускается: команда, исчезнувшая
    /// из программы, и пункт, не подходящий этому файлу, не оставляют дырок.
    func test_собранноеМеню_ПропускаетНепоказуемое() async throws {
        let (vc, file) = try await panelWithFile()
        let saved = snapshot()
        defer { restore(saved) }

        ContextMenuLayout.shared.reset()
        // «Пройти по ссылке» — только для ссылки, а файл обычный; команды с таким именем нет.
        ContextMenuLayout.shared.setMain(["context.followSymlink", "cmd:такогоНетВовсе:",
                                          "context.properties"])

        let menu = NSMenu()
        vc.populateContextMenu(menu, for: file)
        XCTAssertEqual(menu.items.compactMap { $0.identifier?.rawValue }, ["context.properties"])
    }

    /// Раскладка общая на всю программу, и проверки берут её же: снимок до и возврат после —
    /// иначе одна проверка молча меняет условия следующей.
    private func snapshot() -> (main: [String], extra: [String], explicit: Bool) {
        let layout = ContextMenuLayout.shared
        return (layout.main, layout.extra, layout.isExplicit)
    }

    private func restore(_ saved: (main: [String], extra: [String], explicit: Bool)) {
        let layout = ContextMenuLayout.shared
        layout.reset()
        if saved.explicit { layout.setMain(saved.main) }
        layout.setExtra(saved.extra)
    }

    /// Панель, стоящая в папке с настоящим файлом, и сам файл.
    /// Картинка нейросети говорит об этом сразу, верхним уровнем меню, — там, где пункт ждёт
    /// каталог. И пункт строки меню «Удалить метаданные…» для неё не серый: строка панели
    /// приходит из ядра с расширением «.png» — с точкой.
    func test_картинкаНейросети_ВидныСразу() async throws {
        let folder = NSTemporaryDirectory() + "ctx-ai-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        let png = folder + "/лиса.png"
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: png) as CFURL, "public.png" as CFString, 1, nil)
        else { throw XCTSkip("PNG не пишется") }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: png)))
        let parameters = "a fox in the snow\nSteps: 20, Sampler: Euler a, Seed: 1, Model: sd15"
        bytes.insert(contentsOf: PNGChunks.chunk("tEXt", Array("parameters\u{0}".utf8) + Array(parameters.utf8)),
                     at: 33)   // сразу за IHDR
        try Data(bytes).write(to: URL(fileURLWithPath: png))

        let vc = try panel()
        vc.viewModel.loadDirectory(at: folder)
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !vc.viewModel.items.contains(where: { $0.name == "лиса.png" }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let item = try XCTUnwrap(vc.viewModel.items.first { $0.name == "лиса.png" })
        XCTAssertEqual(item.fileExtension, ".png", "ядро отдаёт расширение с точкой")
        XCTAssertTrue(MetadataScrubber.mayClean(item), "пункт строки меню не гаснет")

        let saved = snapshot()
        defer { restore(saved) }
        ContextMenuLayout.shared.reset()
        let menu = NSMenu()
        vc.populateContextMenu(menu, for: item)
        let row = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "context.aiOrigin" })
        XCTAssertEqual(row.title, String(format: L("context.aiOrigin.named"), L("ai.headline")))
        XCTAssertFalse(row.title.contains("Stable Diffusion"), "чем сделано — в «Инфо», не в меню")
        // Живой значок: звёзды-слои в колонке значка, а не нарисованный символ.
        let mark = try XCTUnwrap(row.view?.subviews.first { $0 is AISparkleView })
        XCTAssertEqual(mark.layer?.sublayers?.first?.mask?.sublayers?.count, 3, "три звезды")
        if !AISparkleView.reduceMotion {
            XCTAssertNotNil(mark.layer?.sublayers?.first?.animation(forKey: "flow"), "цвет переливается")
        }
        let ids = menu.items.map { $0.isSeparatorItem ? ContextMenuLayout.separatorID
                                                      : ($0.identifier?.rawValue ?? "БЕЗ-ИМЕНИ") }
        var rest = ContextMenuCatalogue.defaultOrder[...]
        for id in ids {
            guard let position = rest.firstIndex(of: id) else {
                return XCTFail("«\(id)» нет в списке по умолчанию или он стоит не там: \(ids)")
            }
            rest = rest[(position + 1)...]
        }
    }

    private func panelWithFile() async throws -> (PanelViewController, FileItem) {
        let folder = NSTemporaryDirectory() + "ctx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/файл.txt", contents: Data("текст".utf8))
        // Уборка папки записана раньше, чем панель, — значит, и выполнится после её слежки.
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        let vc = try panel()
        vc.viewModel.loadDirectory(at: folder)
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !vc.viewModel.items.contains(where: { $0.name == "файл.txt" }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return (vc, try XCTUnwrap(vc.viewModel.items.first { $0.name == "файл.txt" }))
    }

    private func panel() throws -> PanelViewController {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.ctx.\(id)",
                                viewModeDefaultsKey: "panel.mode.ctx.\(id)",
                                showHiddenFiles: false)
        // Слежка уходит раньше папки (уборка идёт с конца). Модель, потеряв папку, уходит в
        // ближайшую родительскую — общую временную, на десятки тысяч записей, — и перечитывает
        // её при каждом изменении до конца прогона.
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        let tabs = PanelTabsViewModel(panelKey: "tabs.ctx.\(id)", initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabs, side: .left)
        vc.loadViewIfNeeded()
        return vc
    }

    /// Пункты настоящего меню носят свои имена — иначе раскладывать было бы нечего.
    func test_пунктыНастоящегоМенюИмеютИмена() throws {
        let vc = try panel()
        let menu = NSMenu()
        vc.populateContextMenu(menu, for: nil)          // меню пустого места
        let named = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertGreaterThan(named.count, 3)
        let nameless = named.filter { $0.identifier == nil }.map(\.title)
        XCTAssertTrue(nameless.isEmpty, "без имени: \(nameless)")
        XCTAssertTrue(named.contains { $0.identifier?.rawValue == "context.mkdir" },
                      "имена — ключи строк: \(named.compactMap { $0.identifier?.rawValue })")
    }
}
