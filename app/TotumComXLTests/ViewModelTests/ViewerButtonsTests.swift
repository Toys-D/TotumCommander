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
        let point = web.convert(NSPoint(x: 100, y: 140), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            // Прямо виду: окно теста не на экране и не главное, и первый щелчок окно
            // забрало бы себе — сделать себя ключевым.
            if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
        }
        for _ in 0..<40 where opened.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(opened, ["by-hand.txt"], "щелчок человека открывает ссылку")
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

    private func waitForTitle(_ title: String, in web: WKWebView) async -> Bool {
        for _ in 0..<100 {
            if web.title == title { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
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
