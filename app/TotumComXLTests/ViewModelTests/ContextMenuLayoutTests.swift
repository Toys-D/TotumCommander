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

    /// Меню над кнопкой и справа от неё — там, где раньше висели всплывающие окна с кнопками
    /// SwiftUI (сеть, размещение терминала): macOS 27 рисовала синее кольцо фокуса вокруг
    /// первой кнопки такого окна.
    func test_менюНадКнопкойИСправаОтНеё() throws {
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
        let anchor = NSView(frame: NSRect(x: 150, y: 40, width: 28, height: 22))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let popup = ContextPopupMenuController.shared
        addTeardownBlock { MainActor.assumeIsolated { popup.dismiss() } }
        let anchorOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        popup.show(NetworkMenu.build(onLocalNetwork: {}, onConnectNetworkDrive: {}, onFTPDisk: {}),
                   anchoredTo: anchor, edge: .maxY)
        let above = try XCTUnwrap(popup.openMenuWindow)
        XCTAssertEqual(above.frame.minY, anchorOnScreen.maxY + 4, accuracy: 0.5, "низ меню над кнопкой")
        XCTAssertEqual(above.frame.minX, anchorOnScreen.minX, accuracy: 0.5)
        XCTAssertEqual(popup.openMenuRows.compactMap { $0.identifier?.rawValue },
                       ["network.localNetwork", "network.connectDrive", "network.ftpDisk"])

        popup.show(NetworkMenu.build(onLocalNetwork: nil, onConnectNetworkDrive: nil, onFTPDisk: nil),
                   anchoredTo: anchor, edge: .maxX)
        let beside = try XCTUnwrap(popup.openMenuWindow)
        XCTAssertEqual(beside.frame.minX, anchorOnScreen.maxX + 4, accuracy: 0.5, "справа от кнопки")
        XCTAssertEqual(beside.frame.maxY, anchorOnScreen.maxY, accuracy: 0.5, "верх вровень с кнопкой")

        // Без кнопки (вид ещё не в окне) — у мыши, а не нигде.
        popup.show(NSMenu(), anchoredTo: nil, edge: .minY)
        XCTAssertNotNil(popup.openMenuWindow)
    }

    /// Облака в сетевом меню: своим логотипом, не шаблонным значком, и подписью по положению.
    func test_сетевоеМеню_Облака() {
        let menu = NetworkMenu.build(onLocalNetwork: nil, onConnectNetworkDrive: nil, onFTPDisk: nil,
                                     clouds: [(CloudProvider.icloud, CloudPlacement.menuHidden(path: "/x")),
                                              (CloudProvider.dropbox, CloudPlacement.menuInstall)])
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertEqual(menu.items[4].title, CloudProvider.icloud.title)
        XCTAssertEqual(menu.items[5].title, NetworkMenu.cloudTitle(.dropbox, .menuInstall))
        XCTAssertTrue(menu.items[5].title.contains(L("cloud.menu.install")))
        if let logo = CloudProvider.dropbox.logo {
            XCTAssertTrue(menu.items[5].image === logo, "фирменный логотип как есть")
            XCTAssertFalse(logo.isTemplate)
        }
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

    private func panelWithFile(named name: String = "файл.txt",
                               isFolder: Bool = false) async throws -> (PanelViewController, FileItem) {
        let folder = NSTemporaryDirectory() + "ctx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if isFolder {
            try FileManager.default.createDirectory(atPath: folder + "/" + name + "/Contents",
                                                    withIntermediateDirectories: true)
        } else {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("текст".utf8))
        }
        // Уборка папки записана раньше, чем панель, — значит, и выполнится после её слежки.
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        let vc = try panel()
        vc.viewModel.loadDirectory(at: folder)
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !vc.viewModel.items.contains(where: { $0.name == name }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return (vc, try XCTUnwrap(vc.viewModel.items.first { $0.name == name }))
    }

    /// Программа не из «Программ» — первым пунктом «Установить». Уже установленной — нет.
    func test_программа_ПервымПунктомУстановить() async throws {
        let saved = snapshot()
        defer { restore(saved) }
        ContextMenuLayout.shared.reset()

        let (vc, app) = try await panelWithFile(named: "Голос.app", isFolder: true)
        XCTAssertTrue(app.isAppBundle)
        let menu = NSMenu()
        vc.populateContextMenu(menu, for: app)
        XCTAssertEqual(menu.items.first?.identifier?.rawValue, "context.installApp")
        XCTAssertEqual(menu.items.first?.title, L("context.installApp"))

        // Та же программа, но папка программ — её собственная: ставить некуда, пункта нет.
        let real = AppInstall.applicationsFolder
        AppInstall.applicationsFolder = (app.path as NSString).deletingLastPathComponent
        defer { AppInstall.applicationsFolder = real }
        let installed = NSMenu()
        vc.populateContextMenu(installed, for: app)
        XCTAssertFalse(installed.items.contains { $0.identifier?.rawValue == "context.installApp" })
    }

    /// Где «Установить» уместно: программа вне папок программ. Вложенная в установленную, папка
    /// без .app и файл с именем .app — нет.
    func test_установитьПредлагаетсяТолькоПрограммеВнеПрограмм() {
        func item(_ path: String, folder: Bool = true) -> FileItem {
            FileItem(path: path, name: (path as NSString).lastPathComponent,
                     fileExtension: "." + (path as NSString).pathExtension, size: 0,
                     isDirectory: folder, isHidden: false, isSymlink: false,
                     permissions: "", dateModified: Date())
        }
        XCTAssertTrue(AppInstall.canInstall(item("/Volumes/Qalam Voice 1.1.3/Qalam Voice.app")))
        XCTAssertTrue(AppInstall.canInstall(item(NSHomeDirectory() + "/Downloads/Голос.app")))
        XCTAssertFalse(AppInstall.canInstall(item("/Applications/Safari.app")))
        XCTAssertFalse(AppInstall.canInstall(item("/Applications/Utilities/Terminal.app")))
        XCTAssertFalse(AppInstall.canInstall(item("/Applications/Xcode.app/Contents/Applications/Simulator.app")))
        XCTAssertFalse(AppInstall.canInstall(item(NSHomeDirectory() + "/Applications/Своя.app")))
        XCTAssertFalse(AppInstall.canInstall(item("/System/Applications/Calculator.app")))
        XCTAssertFalse(AppInstall.canInstall(item("/Volumes/Диск/Папка")), "не программа")
        XCTAssertFalse(AppInstall.canInstall(item("/Volumes/Диск/Странный.app", folder: false)),
                       "файл с именем .app — не программа")
        XCTAssertFalse(AppInstall.canInstall(item("/Applications")), "сама папка программ")
    }

    /// У пакета установки первым пунктом — «Открыть пакет»: Enter его ставит, а войти внутрь —
    /// отсюда. У прочих файлов этого пункта нет.
    func test_пакетУстановки_ПервымПунктомОткрытьПакет() async throws {
        let saved = snapshot()
        defer { restore(saved) }
        ContextMenuLayout.shared.reset()

        let (vc, package) = try await panelWithFile(named: "Установка.pkg")
        let menu = NSMenu()
        vc.populateContextMenu(menu, for: package)
        XCTAssertEqual(menu.items.first?.identifier?.rawValue, "context.enterPackage")
        XCTAssertEqual(menu.items.first?.title, L("context.enterPackage"))

        let (other, file) = try await panelWithFile()
        let plain = NSMenu()
        other.populateContextMenu(plain, for: file)
        XCTAssertFalse(plain.items.contains { $0.identifier?.rawValue == "context.enterPackage" })
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
    /// Строки появляются на своих местах: проявляются и чуть опускаются — и всё. Раньше
    /// появление начиналось до того, как окно меню разложилось на экране, и SwiftUI вёл
    /// строки на место из предварительной раскладки (вокруг нулевой точки) — они влетали
    /// по диагонали из угла. Снимки окна во время появления: левый край строк не ходит.
    func test_строкиПоявляютсяНаМесте_НеВлетаютСбоку() throws {
        let menu = NSMenu()
        menu.addStyledItem(title: "Открыть в соседней панели", symbolName: "folder", id: "context.open") {}
        menu.addStyledItem(title: "Свойства", symbolName: "info.circle", id: "context.properties") {}
        let sub = NSMenu()
        sub.addStyledItem(title: "Вложенный пункт", symbolName: "1.circle") {}
        let tools = NSMenuItem(title: "Инструменты", action: nil, keyEquivalent: "")
        tools.submenu = sub
        menu.addItem(tools)
        let popup = ContextPopupMenuController.shared
        addTeardownBlock { MainActor.assumeIsolated { popup.dismiss() } }

        // Первое меню после запуска собирается долго и успевает разложиться — гоняем ещё два.
        popup.show(menu, at: NSPoint(x: 400, y: 600))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        for round in 0..<2 {
            popup.show(menu, at: NSPoint(x: 420, y: 620))
            let root = try XCTUnwrap(popup.openMenuWindow)
            let left = Self.leftInkEdges(of: root)
            XCTAssertGreaterThan(left.count, 3, "строки проявились (\(round))")
            XCTAssertLessThanOrEqual((left.max() ?? 0) - (left.min() ?? 0), 3,
                                     "левый край строк стоит на месте (\(round)): \(left)")

            popup.openSubmenu(ofRow: 2)
            let child = try XCTUnwrap(NSApp.windows.last { $0.isVisible && $0.level == .popUpMenu && $0 !== root })
            let childLeft = Self.leftInkEdges(of: child)
            XCTAssertGreaterThan(childLeft.count, 3, "подменю проявилось (\(round))")
            XCTAssertLessThanOrEqual((childLeft.max() ?? 0) - (childLeft.min() ?? 0), 3,
                                     "левый край подменю стоит на месте (\(round)): \(childLeft)")
        }
    }

    /// Левый край нарисованного в окне (в точках снимка) — снимок за снимком, пока идёт
    /// появление: от первого снимка, где строки уже видны, ещё треть секунды. Пустые снимки
    /// (строки ещё прозрачны) пропускаются.
    private static func leftInkEdges(of window: NSWindow) -> [Int] {
        var edges: [Int] = []
        let giveUp = Date().addingTimeInterval(2)
        var end = giveUp
        RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        while Date() < end {
            if let edge = leftInkEdge(of: window) {
                if edges.isEmpty { end = min(giveUp, Date().addingTimeInterval(0.35)) }
                edges.append(edge)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.006))
        }
        return edges
    }

    private static func leftInkEdge(of window: NSWindow) -> Int? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.samplesPerPixel >= 3 else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh, stride = rep.bytesPerRow, step = rep.samplesPerPixel
        func light(_ x: Int, _ y: Int) -> Int {
            let p = data + y * stride + x * step
            return Int(p[0]) + Int(p[1]) + Int(p[2])
        }
        let background = light(width - 8, height / 2)
        let margin = 8   // рамка меню и её обводка — не строки
        for x in margin..<(width - margin) {
            for y in margin..<(height - margin) where abs(light(x, y) - background) > 230 {
                return x
            }
        }
        return nil
    }

    /// Акцентная обводка обходит весь край меню — и подменю — на глазах. Окно доходит до экрана
    /// через 35–50 мс после начала появления; с прежней кривой (быстро в начале) к этому времени
    /// была готова четверть края, к 0,1 с — половина, и видно было, как дорисовывается только
    /// остаток. Теперь к первому видимому кадру не нарисовано почти ничего, линия выходит из
    /// левого верхнего угла, идёт по часовой стрелке и замыкает весь край.
    func test_обводкаМенюОбходитВесьКрайНаГлазах() throws {
        let key = PanelAppearanceSettings.accentColorHexKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("#FF2D55FF", forKey: key)
        let menu = NSMenu()
        menu.addStyledItem(title: "Открыть в соседней панели", symbolName: "folder", id: "context.open") {}
        menu.addStyledItem(title: "Свойства", symbolName: "info.circle", id: "context.properties") {}
        let sub = NSMenu()
        for index in 1...8 { sub.addStyledItem(title: "Вложенный пункт \(index)", symbolName: "circle") {} }
        let tools = NSMenuItem(title: "Инструменты", action: nil, keyEquivalent: "")
        tools.submenu = sub
        menu.addItem(tools)
        let popup = ContextPopupMenuController.shared
        addTeardownBlock { MainActor.assumeIsolated { popup.dismiss() } }

        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }

        popup.show(menu, at: NSPoint(x: 400, y: 600))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: theme)
            popup.show(menu, at: NSPoint(x: 420, y: 620))
            let root = try XCTUnwrap(popup.openMenuWindow)
            Self.checkOutlineTrace(Self.outlineTrace(of: root), "меню, \(theme.rawValue)")
            popup.openSubmenu(ofRow: 2)
            let child = try XCTUnwrap(NSApp.windows.last { $0.isVisible && $0.level == .popUpMenu && $0 !== root })
            Self.checkOutlineTrace(Self.outlineTrace(of: child), "подменю, \(theme.rawValue)")
        }
    }

    private static func checkOutlineTrace(_ trace: [(ms: Double, drawn: [Bool])], _ name: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        func share(_ drawn: [Bool]) -> Int { drawn.filter { $0 }.count * 100 / max(drawn.count, 1) }
        let early = trace.filter { $0.ms <= 50 }.map { share($0.drawn) }.max() ?? 0
        XCTAssertLessThanOrEqual(early, 8, "\(name): к первому видимому кадру обводка ещё в начале пути",
                                 file: file, line: line)
        let begun = trace.filter { share($0.drawn) > 0 }
        XCTAssertFalse(begun.isEmpty, "\(name): обводка нарисовалась", file: file, line: line)
        for frame in begun {
            // Нарисованное — всегда начало пути от левого верхнего угла по часовой стрелке.
            let count = frame.drawn.filter { $0 }.count
            let prefix = frame.drawn.prefix { $0 }.count
            XCTAssertGreaterThanOrEqual(prefix, count - 2,
                                        "\(name): линия идёт от левого верхнего угла по часовой (\(Int(frame.ms)) мс)",
                                        file: file, line: line)
        }
        let halfway = begun.filter { (20...80).contains(share($0.drawn)) }.count
        XCTAssertGreaterThanOrEqual(halfway, 5, "\(name): середину пути видно кадр за кадром", file: file, line: line)
        XCTAssertGreaterThanOrEqual(share(trace.last?.drawn ?? []), 97, "\(name): обводка замкнула весь край",
                                    file: file, line: line)
    }

    /// Снимки окна от этой минуты, пока обводка не замкнётся: для каждой точки края — нарисована
    /// ли там обводка. Точки идут по прямым участкам края в том порядке, в каком их проходит
    /// линия: верх слева направо, правый край сверху вниз, низ справа налево, левый край снизу вверх.
    private static func outlineTrace(of window: NSWindow) -> [(ms: Double, drawn: [Bool])] {
        let start = CACurrentMediaTime()
        var trace: [(ms: Double, drawn: [Bool])] = []
        while CACurrentMediaTime() - start < 1.2 {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            let ms = (CACurrentMediaTime() - start) * 1000
            let width = rep.pixelsWide, height = rep.pixelsHigh
            let scale = CGFloat(width) / view.bounds.width
            let corner = Int(10 * scale), edge = Int(0.4 * scale), step = Int(4 * scale)
            var points: [(Int, Int)] = []
            points += stride(from: corner, to: width - corner, by: step).map { ($0, edge) }
            points += stride(from: corner, to: height - corner, by: step).map { (width - 1 - edge, $0) }
            points += stride(from: width - corner, to: corner, by: -step).map { ($0, height - 1 - edge) }
            points += stride(from: height - corner, to: corner, by: -step).map { (edge, $0) }
            let drawn = points.map { point -> Bool in
                guard let color = rep.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB) else { return false }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                return (channels.max() ?? 0) - (channels.min() ?? 0) > 0.15
            }
            trace.append((ms, drawn))
            if drawn.allSatisfy({ $0 }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
        return trace
    }

    /// Всплывающие окна программы — только через `fcxlPopover`: голый `.popover` на macOS 27
    /// обводит первую кнопку синим кольцом фокуса (синий квадрат в окне выбора цвета).
    func test_всплывающиеОкнаБезКольцаФокуса() throws {
        let root = FileManager.default.currentDirectoryPath + "/app/TotumComXL"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root))
        let pattern = try NSRegularExpression(pattern: #"\.popover\s*\("#)
        var found: [String] = []
        var seen = 0
        while let path = enumerator.nextObject() as? String {
            guard path.hasSuffix(".swift"),
                  let text = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if code.contains(".fcxlPopover(") { seen += 1 }
                if pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    found.append("\(path):\(number + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(seen, 5, "обёрткой пользуются")
        XCTAssertTrue(found.isEmpty, "голые всплывающие окна:\n" + found.joined(separator: "\n"))
    }

    /// Синего кольца фокуса нет нигде. С включённой «Навигацией с клавиатуры» macOS обводит
    /// кольцом первую кнопку каждого окна — «Отмену» в окне хода упаковки. Запрет ставится в
    /// корень каждой вставки SwiftUI в окно: в само выражение или в `body` вставляемого вида.
    func test_вставкиSwiftUIБезКольцаФокуса() throws {
        let root = FileManager.default.currentDirectoryPath + "/app/TotumComXL"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root))
        var files: [String: [String]] = [:]
        while let path = enumerator.nextObject() as? String {
            guard path.hasSuffix(".swift"),
                  let text = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) else { continue }
            files[path] = text.components(separatedBy: "\n")
        }
        let disabled = ".focusEffectDisabled()"
        // Вид, который запрещает кольцо в собственном объявлении.
        func focuslessType(_ type: String) -> Bool {
            let declaration = #"^(final )?(struct|class) "# + type + #"\b"#
            let next = #"^(final )?(struct|class|enum|extension) "#
            for lines in files.values {
                guard let start = lines.firstIndex(where: {
                    $0.range(of: declaration, options: .regularExpression) != nil
                }) else { continue }
                let end = lines[(start + 1)...].firstIndex(where: {
                    $0.range(of: next, options: .regularExpression) != nil
                }) ?? lines.endIndex
                return lines[start..<end].contains { $0.contains(disabled) }
            }
            return false
        }
        let site = try NSRegularExpression(
            pattern: #"(NSHostingView|NSHostingController|TunnelDropHostingView)\(rootView: *([A-Za-z_][A-Za-z0-9_]*)(\()?"#)
        var checked = 0
        var found: [String] = []
        for (path, lines) in files {
            for (index, line) in lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                      let match = site.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let nameRange = Range(match.range(at: 2), in: line),
                      let callStart = Range(match.range, in: line)?.lowerBound else { continue }
                checked += 1
                // Само выражение — до парной закрывающей скобки, хоть на несколько строк.
                var statement = ""
                var depth = 0
                scan: for (offset, text) in lines[index...].enumerated() {
                    let piece = offset == 0 ? String(text[callStart...]) : text
                    for character in piece {
                        statement.append(character)
                        if character == "(" { depth += 1 }
                        if character == ")" { depth -= 1; if depth == 0 { break scan } }
                    }
                    statement.append("\n")
                }
                if statement.contains(disabled) { continue }

                let name = String(line[nameRange])
                let isCall = match.range(at: 3).location != NSNotFound
                var type: String?
                if name.first?.isUppercase == true, name != "AnyView" {
                    type = name
                } else if isCall {
                    // makeSortBarView() → тип, который функция возвращает.
                    let signature = #"func "# + name + #"\([^)]*\) *-> *([A-Za-z_][A-Za-z0-9_]*)"#
                    for text in lines {
                        if let r = text.range(of: signature, options: .regularExpression) {
                            type = text[r].components(separatedBy: "->").last?
                                .trimmingCharacters(in: .whitespaces)
                        }
                    }
                } else {
                    // Переменная: её объявление выше — тип и, может быть, запрет прямо там; а нет
                    // рядом — свойство с типом где-то в том же файле.
                    let definition = #"(let|var) "# + name + #" *(=|:) *([A-Za-z_][A-Za-z0-9_]*)"#
                    func declared(_ text: String) -> String? {
                        text.range(of: definition, options: .regularExpression).flatMap {
                            text[$0].components(separatedBy: CharacterSet(charactersIn: "=:")).last?
                                .trimmingCharacters(in: .whitespaces)
                        }
                    }
                    for back in stride(from: index - 1, through: max(0, index - 40), by: -1) {
                        guard let declaredType = declared(lines[back]) else { continue }
                        type = lines[back...index].contains(where: { $0.contains(disabled) }) ? "" : declaredType
                        break
                    }
                    if type == nil { type = lines.lazy.compactMap(declared).first }
                }
                if type == "" { continue }
                if let type, focuslessType(type) { continue }
                found.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(checked, 20, "вставки нашлись")
        XCTAssertTrue(found.isEmpty, "вставки SwiftUI с кольцом фокуса:\n" + found.sorted().joined(separator: "\n"))
    }

    /// Все меню программы — в её окне меню. Системное меню (`.contextMenu {}` и `Menu {}` у
    /// SwiftUI, NSPopUpButton и показ NSMenu самим AppKit) выглядит и появляется по-своему,
    /// а на macOS 27 ещё и влетает сбоку. Такого в исходниках быть не должно.
    func test_системныхМенюВКодеНет() throws {
        let root = FileManager.default.currentDirectoryPath + "/app/TotumComXL"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root))
        // Модификатор `.contextMenu` — в цепочке после вида или с начала строки; случай
        // перечисления (`== .contextMenu {`) и свои функции (`self?.contextMenu(for:)`) — нет.
        let patterns = [#"(^|[)\]\w])\.contextMenu\s*(\{|\(menuItems|\(forSelectionType)"#,
                        #"(^|[^A-Za-z.])Menu\s*[{(]"#,
                        #"NSPopUpButton\("#, #"popUp\(positioning"#, #"popUpContextMenu"#]
            .map { try! NSRegularExpression(pattern: $0) }
        var found: [String] = []
        while let path = enumerator.nextObject() as? String {
            guard path.hasSuffix(".swift"),
                  let text = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) else { continue }
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                if patterns.contains(where: { $0.firstMatch(in: code, range: range) != nil }) {
                    found.append("\(path):\(number + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(enumerator.level, -1)
        XCTAssertTrue(found.isEmpty, "системные меню:\n" + found.joined(separator: "\n"))
    }

}
