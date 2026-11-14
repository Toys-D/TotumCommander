import AppKit
import Network
import WebKit
import XCTest
@testable import TotumComXLApp

/// Три кнопки просмотра: «в конец» над длинным документом, HTML страницей (и без сети),
/// «Править» — у того, что F4 открывает как текст.
@MainActor
final class ViewerButtonsTests: XCTestCase {

    // MARK: - «Править»

    func test_правитьУТекстаКодаРазметкиИSVG() {
        for name in ["заметки.txt", "README.md", "index.html", "main.swift", "письмо.rtf",
                     "logo.svg", "config.json"] {
            let ext = (name as NSString).pathExtension
            XCTAssertTrue(viewerOffersEdit(fileName: name, fileExtension: ext,
                                           isDirectory: false, insideRemote: false), name)
        }
    }

    func test_правитьНетУКартинкиВидеоДокументаИАрхива() {
        for name in ["photo.jpg", "clip.mp4", "book.pdf", "art.psd", "pack.zip", "doc.docx",
                     "notes.rtfd", "font.ttf"] {
            let ext = (name as NSString).pathExtension
            XCTAssertFalse(viewerOffersEdit(fileName: name, fileExtension: ext,
                                            isDirectory: false, insideRemote: false), name)
        }
    }

    func test_правитьНетУПапкиИУФайлаНаСервере() {
        XCTAssertFalse(viewerOffersEdit(fileName: "src.txt", fileExtension: "txt",
                                        isDirectory: true, insideRemote: false))
        XCTAssertFalse(viewerOffersEdit(fileName: "notes.txt", fileExtension: "txt",
                                        isDirectory: false, insideRemote: true),
                       "на сервере просмотр видит только временную копию")
    }

    func test_правитьИF4ОдноПравило() {
        // Кнопка не шире F4: что F4 не откроет, кнопке предлагать нельзя.
        for name in ["a.txt", "b.png", "c.md", "d.zip", "e.html", "f.svg"] {
            let ext = (name as NSString).pathExtension
            if viewerOffersEdit(fileName: name, fileExtension: ext, isDirectory: false, insideRemote: false) {
                XCTAssertTrue(FileOperationsService.isEditableTextFile(name: name, fileExtension: ext), name)
            }
        }
    }

    // MARK: - HTML

    func test_страницейПоказываютсяТолькоHTML() {
        XCTAssertTrue(HTMLPage.isPage(fileName: "index.html"))
        XCTAssertTrue(HTMLPage.isPage(fileName: "СТАРОЕ.HTM"))
        XCTAssertTrue(HTMLPage.isPage(fileName: "page.xhtml"))
        XCTAssertFalse(HTMLPage.isPage(fileName: "style.css"))
        XCTAssertFalse(HTMLPage.isPage(fileName: "README.md"))
        XCTAssertFalse(HTMLPage.isPage(fileName: "html"))
    }

    func test_якорьНаТойЖеСтраницеНеПереход() {
        let page = URL(fileURLWithPath: "/tmp/doc/index.html")
        XCTAssertTrue(HTMLPage.isSameDocument(URL(string: "file:///tmp/doc/index.html#глава-2")!, as: page))
        XCTAssertFalse(HTMLPage.isSameDocument(URL(string: "file:///tmp/doc/other.html")!, as: page))
        XCTAssertFalse(HTMLPage.isSameDocument(URL(string: "https://example.com/#a")!, as: page))
    }

    func test_ссылкаНаружуТолькоПослеЩелчкаЧеловека() {
        let now = Date()
        XCTAssertFalse(HTMLPage.isUserClick(lastClick: nil, now: now), "щелчка не было — это код страницы")
        XCTAssertTrue(HTMLPage.isUserClick(lastClick: now.addingTimeInterval(-0.3), now: now))
        XCTAssertFalse(HTMLPage.isUserClick(lastClick: now.addingTimeInterval(-5), now: now),
                       "давний щелчок не даёт странице открывать ссылки потом")
    }

    /// Главное обещание: скрипты страницы работают, а в сеть она не ходит — ни картинкой,
    /// ни запросом из кода. Сторож на 127.0.0.1 считает, сколько раз к нему постучались.
    func test_страницаРаботаетНоВСетьНеХодит() async throws {
        let listener = try LoopbackCounter()
        defer { listener.stop() }
        try await listener.ready()
        let page = try makePage(port: listener.port)

        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        HTMLNetworkBlock.makeStore = { WKContentRuleListStore(url: storeDir) }

        let coordinator = HTMLPagePreview.Coordinator(scroll: ScrollJumpController(), openLink: { _ in })
        let web = HTMLPagePreview.makeWebView(coordinator: coordinator, zoom: nil)
        let window = hostWindow(for: web)
        defer { window.close() }
        coordinator.load(page)

        let ran = await waitForTitle("ran", in: web)
        XCTAssertTrue(ran, "скрипт страницы не выполнился — страница показана без скриптов")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(listener.connections, 0, "страница достучалась до сети")
    }

    /// Без правил тот же сторож получает стук — значит, тест выше проверяет то, что обещает.
    func test_безПравилСторожСлышитСтраницу() async throws {
        let listener = try LoopbackCounter()
        defer { listener.stop() }
        try await listener.ready()
        let page = try makePage(port: listener.port)

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = hostWindow(for: web)
        defer { window.close() }
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        _ = await waitForTitle("ran", in: web)
        for _ in 0..<30 where listener.connections == 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(listener.connections, 0)
    }

    /// Книга — та же страница: её скрипты работают, листание отчитывается, а в сеть глава не
    /// ходит — ни картинкой, ни стилем, ни запросом из кода.
    func test_книгаЛистаетсяНоВСетьНеХодит() async throws {
        let listener = try LoopbackCounter()
        defer { listener.stop() }
        try await listener.ready()
        let book = try makeBook(port: listener.port)

        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        HTMLNetworkBlock.makeStore = { WKContentRuleListStore(url: storeDir) }

        let reports = ReaderReports()
        let reader = BookReaderView(document: book, state: .constant(BookReaderState()),
                                    onStateChange: { reports.states.append($0) })
        let coordinator = reader.makeCoordinator()
        let web = BookReaderView.makeWebView(coordinator: coordinator, scrolling: true)
        let window = hostWindow(for: web)
        defer {
            BookReaderView.dismantleNSView(web, coordinator: coordinator)
            window.close()
        }
        coordinator.load(chapter: 0, document: book, startAt: nil)

        let ran = await waitForTitle("ran", in: web)
        XCTAssertTrue(ran, "скрипт главы не выполнился — книга показана без скриптов")
        await settle { !reports.states.isEmpty }
        XCTAssertFalse(reports.states.isEmpty, "листание не отчиталось о страницах")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(listener.connections, 0, "книга достучалась до сети")
    }

    /// Правила не собрались — скрипты книги выключены, как у просмотра HTML: код книги не
    /// работает там, где сеть ему открыта. Листание — код программы, оно остаётся.
    func test_книгаБезПравилЧитаетсяБезСвоихСкриптов() async throws {
        let listener = try LoopbackCounter()
        defer { listener.stop() }
        try await listener.ready()
        let book = try makeBook(port: listener.port)

        let reports = ReaderReports()
        let reader = BookReaderView(document: book, state: .constant(BookReaderState()),
                                    onStateChange: { reports.states.append($0) })
        let coordinator = reader.makeCoordinator()
        coordinator.networkRules = { done in done(nil) }
        let web = BookReaderView.makeWebView(coordinator: coordinator, scrolling: true)
        let window = hostWindow(for: web)
        defer {
            BookReaderView.dismantleNSView(web, coordinator: coordinator)
            window.close()
        }
        // Место в книге запоминается со слов её страницы — значит, и оно может оказаться
        // кодом: такая «закладка» выполняться не должна.
        let forged = ReaderLocation(page: 0, chapter: 0,
                                    anchor: "\\'); document.title = String.fromCharCode(112); //")
        coordinator.load(chapter: 0, document: book, startAt: forged)

        await settle { !reports.states.isEmpty }
        XCTAssertFalse(reports.states.isEmpty, "листанию скрипты книги не нужны — оно должно отчитаться")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(web.title, "wait", "сеть не закрыта, а код книги выполнился")
    }

    /// Ссылку открывает только щелчок человека: та, что «нажал» код страницы, никуда не ведёт,
    /// иначе любой html мог бы сам открывать браузер, пока на нём стоит курсор.
    func test_ссылкуОткрываетЩелчокАНеСкрипт() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let html = """
        <!doctype html><html><head><title>wait</title></head>
        <body style="margin:0">
        <a id="auto" href="by-script.txt" style="display:block;height:40px">auto</a>
        <a id="hand" href="by-hand.txt" style="display:block;height:200px;background:#ccc">hand</a>
        <script>
          setTimeout(function () { document.getElementById('auto').click(); document.title = 'clicked'; }, 100);
        </script>
        </body></html>
        """
        let page = dir.appendingPathComponent("links.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        for name in ["by-script.txt", "by-hand.txt"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        var opened: [String] = []
        let coordinator = HTMLPagePreview.Coordinator(scroll: ScrollJumpController(),
                                                      openLink: { opened.append($0.lastPathComponent) })
        let web = HTMLPagePreview.makeWebView(coordinator: coordinator, zoom: nil)
        let window = hostWindow(for: web)
        defer { window.close() }
        coordinator.load(page)

        let scripted = await waitForTitle("clicked", in: web)
        XCTAssertTrue(scripted)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(opened, [], "ссылку «нажал» скрипт — наружу ничего не ушло")

        // Настоящий щелчок мышью посреди второй ссылки.
        try click(web, in: window, at: NSPoint(x: 100, y: 140))
        for _ in 0..<40 where opened.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(opened, ["by-hand.txt"], "щелчок человека открывает ссылку")
    }

    // MARK: - HTML: куда ведёт ссылка

    /// Файл по ссылке наружу не уходит — ни программа, ни скрипт, ни документ: вести ссылка
    /// может на любой файл диска, а написано на ней может быть что угодно.
    func test_ссылкаНаФайлНеОткрываетсяАПоказываетсяВПанели() {
        let links = ["file:///Applications/Calculator.app/": "/Applications/Calculator.app",
                     "file:///tmp/%D1%81%D1%82%D1%80/run.command": "/tmp/стр/run.command",
                     "file:///tmp/docs/../notes.txt#part": "/tmp/notes.txt",
                     "FILE:///tmp/UP.TXT": "/tmp/UP.TXT",
                     "file://localhost/tmp/a.txt": "/tmp/a.txt"]
        for (link, path) in links {
            XCTAssertEqual(HTMLPage.linkAction(for: URL(string: link)!), .showInPanel(path: path), link)
        }
    }

    func test_наружуТолькоСетьИПочта() {
        for link in ["http://example.com/a", "HTTPS://example.com/", "mailto:a@example.com"] {
            let url = URL(string: link)!
            XCTAssertEqual(HTMLPage.linkAction(for: url), .openOutside(url), link)
        }
        // Чужие схемы запускают программы и их команды; файл на чужой машине — не файл панели.
        for link in ["x-apple.systempreferences:com.apple.preference.security", "ssh://example.com",
                     "smb://example.com/share", "vnc://example.com", "tel:112", "javascript:alert(1)",
                     "ftp://example.com/f", "file://example.com/share/f.txt", "about:blank",
                     "data:text/plain,x"] {
            XCTAssertEqual(HTMLPage.linkAction(for: URL(string: link)!), .nothing, link)
        }
    }

    /// Ссылка на соседний файл: курсор панели встаёт на него (просмотр идёт за курсором и
    /// покажет его сам), и ничем он не открывается — даже если это скрипт.
    func test_ссылкаНаСоседаСтавитНаНегоКурсор() async throws {
        let folder = try linkFolder()
        let vm = try await panel(at: folder, cursorOn: "страница.html")
        var outside: [URL] = []

        HTMLPage.follow(URL(fileURLWithPath: folder + "/запуск.command"), in: vm) { outside.append($0) }

        XCTAssertEqual(vm.cursorItem?.name, "запуск.command")
        XCTAssertEqual(vm.currentPath, folder)
        XCTAssertEqual(outside, [], "файл по ссылке ничем не открывается")
    }

    func test_ссылкаВДругуюПапкуВедётПанельТуда() async throws {
        let folder = try linkFolder()
        let vm = try await panel(at: folder, cursorOn: "страница.html")
        var outside: [URL] = []

        HTMLPage.follow(URL(fileURLWithPath: folder + "/глава/вторая.html"), in: vm) { outside.append($0) }
        await settle { vm.cursorItem?.name == "вторая.html" }

        XCTAssertEqual(vm.currentPath, folder + "/глава")
        XCTAssertEqual(vm.cursorItem?.name, "вторая.html")
        XCTAssertEqual(outside, [])
    }

    /// Диск обычно не различает регистр: ссылка «СОСЕД.TXT» ведёт к файлу «сосед.txt», и
    /// курсор должен встать на него же — в своей папке и в чужой.
    func test_ссылкаВДругомРегистреНаходитТотЖеФайл() async throws {
        let folder = try linkFolder()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder + "/СОСЕД.TXT"),
                          "том различает регистр")
        let vm = try await panel(at: folder, cursorOn: "страница.html")

        HTMLPage.follow(URL(fileURLWithPath: folder + "/СОСЕД.TXT"), in: vm) { _ in }
        XCTAssertEqual(vm.cursorItem?.name, "сосед.txt")

        HTMLPage.follow(URL(fileURLWithPath: folder + "/глава/ВТОРАЯ.HTML"), in: vm) { _ in }
        await settle { vm.cursorItem?.name == "вторая.html" }
        XCTAssertEqual(vm.cursorItem?.name, "вторая.html")
        XCTAssertEqual(vm.currentPath, folder + "/глава")
    }

    /// Ссылка в никуда и ссылка на файл, который панель по своим настройкам не показывает,
    /// панель не трогают: курсор остаётся на странице.
    func test_ссылкаНаТоЧегоВПанелиНетНичегоНеМеняет() async throws {
        let folder = try linkFolder()
        let vm = try await panel(at: folder, cursorOn: "страница.html")
        var outside: [URL] = []

        for name in ["нет-такого.txt", "нет-папки/файл.txt", ".скрытый.txt"] {
            HTMLPage.follow(URL(fileURLWithPath: folder + "/" + name), in: vm) { outside.append($0) }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(vm.currentPath, folder, name)
            XCTAssertEqual(vm.cursorItem?.name, "страница.html", name)
        }
        XCTAssertEqual(outside, [])
    }

    /// В архиве и на сервере страница — временная копия: её адреса ведут во временную папку,
    /// и панель туда не уходит.
    func test_страницаИзАрхиваИССервераПанельНеУводит() async throws {
        let folder = try linkFolder()
        for place in ["архив", "сервер"] {
            let vm = try await panel(at: folder, cursorOn: "страница.html")
            if place == "архив" { vm.insideArchive = true } else { vm.isActivelyRemote = true }
            var outside: [URL] = []

            for name in ["сосед.txt", "глава/вторая.html"] {
                HTMLPage.follow(URL(fileURLWithPath: folder + "/" + name), in: vm) { outside.append($0) }
            }
            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertEqual(vm.cursorItem?.name, "страница.html", place)
            XCTAssertEqual(vm.currentPath, folder, place)
            XCTAssertEqual(outside, [], place)
            vm.insideArchive = false
            vm.isActivelyRemote = false
        }
    }

    func test_адресВСетиУходитНаружуАПанельНеТрогает() async throws {
        let folder = try linkFolder()
        let vm = try await panel(at: folder, cursorOn: "страница.html")
        var outside: [URL] = []
        let site = URL(string: "https://example.com/doc")!

        HTMLPage.follow(site, in: vm) { outside.append($0) }
        HTMLPage.follow(URL(string: "ssh://example.com")!, in: vm) { outside.append($0) }

        XCTAssertEqual(outside, [site])
        XCTAssertEqual(vm.cursorItem?.name, "страница.html")
    }

    /// То же целиком: настоящий щелчок по ссылке на скрипт рядом со страницей. Адрес ссылки
    /// приходит от WebKit, и найти файл в панели надо именно по нему.
    func test_щелчокПоСсылкеНаСкриптТолькоСтавитКурсор() async throws {
        let folder = try linkFolder()
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>ready</title></head>
        <body style="margin:0">
        <a href="запуск.command" style="display:block;height:400px;background:#ccc">Открыть отчёт</a>
        </body></html>
        """
        try html.write(toFile: folder + "/страница.html", atomically: true, encoding: .utf8)
        let vm = try await panel(at: folder, cursorOn: "страница.html")
        var outside: [URL] = []

        let coordinator = HTMLPagePreview.Coordinator(scroll: ScrollJumpController(), openLink: { url in
            MainActor.assumeIsolated { HTMLPage.follow(url, in: vm) { outside.append($0) } }
        })
        let web = HTMLPagePreview.makeWebView(coordinator: coordinator, zoom: nil)
        let window = hostWindow(for: web)
        defer { window.close() }
        coordinator.load(URL(fileURLWithPath: folder + "/страница.html"))
        let ready = await waitForTitle("ready", in: web)
        XCTAssertTrue(ready)
        try await Task.sleep(nanoseconds: 300_000_000)

        try click(web, in: window, at: NSPoint(x: 100, y: 200))
        await settle { vm.cursorItem?.name == "запуск.command" || !outside.isEmpty }

        XCTAssertEqual(vm.cursorItem?.name, "запуск.command", "курсор встал на файл по ссылке")
        XCTAssertEqual(vm.currentPath, folder, "панель осталась в своей папке")
        XCTAssertEqual(outside, [], "скрипт по ссылке ничем не открывается")
    }

    // MARK: - «В конец»

    func test_длинныйТекстКнопкаВедётВКонецИОбратно() {
        let scroll = NumberedTextView.makeScrollView()
        let window = hostWindow(for: scroll)
        defer { window.close() }
        let lines = (1...3000).map { "строка \($0)" }.joined(separator: "\n")
        (scroll.documentView as? NumberedTextView)?.show(lines)

        let controller = ScrollJumpController()
        controller.track(scroll)
        XCTAssertTrue(controller.canScroll)
        XCTAssertFalse(controller.atEnd)

        controller.jump()
        controller.refreshFromScrollView()
        XCTAssertTrue(controller.atEnd, "после прыжка — внизу")
        let text = scroll.documentView as! NumberedTextView
        let visible = text.visibleRect
        let glyphs = text.layoutManager!.glyphRange(forBoundingRect: visible, in: text.textContainer!)
        let chars = text.layoutManager!.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        XCTAssertEqual(NSMaxRange(chars), text.textStorage!.length, "видна последняя строка файла")

        controller.jump()
        controller.refreshFromScrollView()
        XCTAssertFalse(controller.atEnd, "внизу кнопка ведёт в начало")
        XCTAssertEqual(ScrollJumpController.metrics(of: scroll).offset, 0, accuracy: 1)
    }

    func test_короткийТекстБезКнопки() {
        let scroll = NumberedTextView.makeScrollView()
        let window = hostWindow(for: scroll)
        defer { window.close() }
        (scroll.documentView as? NumberedTextView)?.show("одна\nдве\nтри")
        let controller = ScrollJumpController()
        controller.track(scroll)
        XCTAssertFalse(controller.canScroll)
    }

    func test_ушедшийВидУбираетКнопкуАНеЧужую() {
        let first = NumberedTextView.makeScrollView()
        let second = NumberedTextView.makeScrollView()
        let window = hostWindow(for: second)
        defer { window.close() }
        (second.documentView as? NumberedTextView)?.show((1...3000).map(String.init).joined(separator: "\n"))
        let controller = ScrollJumpController()
        controller.track(first)
        controller.track(second)
        controller.release(owner: first)
        XCTAssertTrue(controller.canScroll, "новый вид уже на месте — старый его не гасит")
        controller.release(owner: second)
        XCTAssertFalse(controller.canScroll)
    }

    // MARK: - Помощники

    private func hostWindow(for view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        window.contentView!.layoutSubtreeIfNeeded()
        return window
    }

    /// Настоящий щелчок мышью по точке веб-вида. Прямо виду: окно теста не на экране и не
    /// главное, и первый щелчок окно забрало бы себе — сделать себя ключевым.
    private func click(_ web: PageWebView, in window: NSWindow, at spot: NSPoint) throws {
        let point = web.convert(spot, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
        }
    }

    /// Папка со страницей и тем, на что она может сослаться.
    private func linkFolder() throws -> String {
        let folder = NSTemporaryDirectory() + "fcxl-ссылки-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/глава", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        for name in ["страница.html", "запуск.command", "сосед.txt", ".скрытый.txt", "глава/вторая.html"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8)))
        }
        return folder
    }

    /// Панель, открытая в папке, с курсором на названном файле.
    private func panel(at folder: String, cursorOn name: String) async throws -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: folder,
                                pathDefaultsKey: "panel.path.htmllink.\(id)",
                                viewModeDefaultsKey: "panel.mode.htmllink.\(id)",
                                showHiddenFiles: false)
        // Раньше, чем уберут папку: живая панель на стёртой папке ушла бы искать ближайшую живую.
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        vm.loadDirectory(at: folder)
        await settle { vm.items.contains { $0.name == name } }
        // Второй проход чтения (подробности) тоже должен успеть прийти.
        try await Task.sleep(nanoseconds: 400_000_000)
        vm.setCursor(index: try XCTUnwrap(vm.items.firstIndex { $0.name == name }))
        return vm
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func makePage(port: UInt16) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let html = """
        <!doctype html><html><head><title>wait</title></head>
        <body style="height:3000px">
        <img src="http://127.0.0.1:\(port)/pixel.png">
        <script>
          fetch('http://127.0.0.1:\(port)/fetch').catch(function () {});
          document.title = 'ran';
        </script>
        </body></html>
        """
        let url = dir.appendingPathComponent("page.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Книга из одной главы, которая тянется в сеть всем, чем может.
    private func makeBook(port: UInt16) throws -> BookDocument {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let html = """
        <!doctype html><html><head><title>wait</title>
        <link rel="stylesheet" href="http://127.0.0.1:\(port)/style.css">
        </head><body>
        <p>Глава первая.</p>
        <img src="http://127.0.0.1:\(port)/pixel.png">
        <script>
          fetch('http://127.0.0.1:\(port)/fetch').catch(function () {});
          document.title = 'ran';
        </script>
        </body></html>
        """
        let file = dir.appendingPathComponent("chapter1.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        return BookDocument(sourcePath: dir.appendingPathComponent("book.epub").path, format: .epub,
                            root: dir, title: "Книга", author: "", cover: nil,
                            chapters: [BookChapter(id: "c1", title: "Глава", file: file,
                                                   fragment: nil, level: 0)])
    }

    private func waitForTitle(_ title: String, in web: WKWebView) async -> Bool {
        for _ in 0..<100 {
            if web.title == title { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

/// Что читалка сообщила наружу о страницах.
private final class ReaderReports {
    var states: [BookReaderState] = []
}

/// Слушает 127.0.0.1 и считает подключения — чтобы увидеть, ходила ли страница в сеть.
private final class LoopbackCounter: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private let queue = DispatchQueue(label: "fcxl.tests.loopback")

    var connections: Int { lock.withLock { count } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.withLock { self?.count += 1 }
            connection.cancel()
        }
    }

    func ready() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume()
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}
