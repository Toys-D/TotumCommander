import AppKit
import Network
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Обновление в один щелчок: разбор выпуска, сверка суммы, кто может обновляться на месте
/// и сама подмена — на временных папках, настоящие «Программы» и Корзина не трогаются.
final class AppUpdaterTests: XCTestCase {

    private var root = URL(fileURLWithPath: "")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let answer = Data("""
    {"tag_name": "v1.3.1", "html_url": "https://github.com/Toys-D/TotumCommander/releases/tag/v1.3.1",
     "assets": [
       {"name": "SHA256SUMS.txt", "browser_download_url": "https://github.com/Toys-D/TotumCommander/releases/download/v1.3.1/SHA256SUMS.txt"},
       {"name": "Totum-Commander-1.3.1.dmg", "browser_download_url": "https://github.com/Toys-D/TotumCommander/releases/download/v1.3.1/Totum-Commander-1.3.1.dmg"}
     ]}
    """.utf8)

    // MARK: - Ответ GitHub

    func test_образИСуммыИзОтвета() throws {
        let assets = try XCTUnwrap(UpdatePlan.assets(from: answer))
        XCTAssertEqual(assets.dmgName, "Totum-Commander-1.3.1.dmg")
        XCTAssertEqual(assets.dmg.lastPathComponent, "Totum-Commander-1.3.1.dmg")
        XCTAssertEqual(assets.sums.lastPathComponent, "SHA256SUMS.txt")
    }

    /// Без файла сумм установки не будет: образ без проверки не ставится.
    func test_безФайлаСуммНетУстановки() {
        let noSums = Data("""
        {"tag_name": "v1.3.1", "assets": [{"name": "Totum-Commander-1.3.1.dmg",
          "browser_download_url": "https://example.com/a.dmg"}]}
        """.utf8)
        XCTAssertNil(UpdatePlan.assets(from: noSums))
        XCTAssertNil(UpdatePlan.assets(from: Data("мусор".utf8)))
    }

    func test_суммаИзФайлаСумм() {
        let sums = """
        ad3279a1caf8b46292a30eb94fc16ebefb4dc543bf9dbbbfbc6eed6d54387d74  Totum-Commander-1.3.1.dmg
        00000000000000000000000000000000000000000000000000000000000000ff *Other.dmg
        """
        XCTAssertEqual(UpdatePlan.expectedHash(in: sums, for: "Totum-Commander-1.3.1.dmg"),
                       "ad3279a1caf8b46292a30eb94fc16ebefb4dc543bf9dbbbfbc6eed6d54387d74")
        XCTAssertEqual(UpdatePlan.expectedHash(in: sums, for: "Other.dmg"),
                       "00000000000000000000000000000000000000000000000000000000000000ff",
                       "звёздочка двоичного режима не мешает")
        XCTAssertNil(UpdatePlan.expectedHash(in: sums, for: "Nope.dmg"))
    }

    func test_sha256Файла() throws {
        let file = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdatePlan.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Кому можно на месте

    private func fakeBundle(named name: String, in dir: URL, payload: String,
                            version: String? = nil) throws -> URL {
        let bundle = dir.appendingPathComponent(name)
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: macos.appendingPathComponent("TotumComXL"))
        if let version {
            try NSDictionary(dictionary: ["CFBundleShortVersionString": version])
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        return bundle
    }

    /// Корзина для проверок: запоминает, что в неё отправили, и убирает это само — настоящая
    /// Корзина человека не трогается.
    private final class RecordingTrash: FileManager {
        var trashed: [URL] = []

        override func trashItem(at url: URL,
                                resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            trashed.append(url)
            try removeItem(at: url)
        }
    }

    /// Обновить поддельную копию версии `version` и вернуть имена того, что ушло в Корзину.
    private func retiredNames(oldVersion version: String?, apps: URL) throws -> [String] {
        let old = try fakeBundle(named: "Totum Commander.app", in: apps, payload: "old", version: version)
        let fresh = try fakeBundle(named: "Totum Commander.app", in: root.appendingPathComponent("image"),
                                   payload: "new", version: "1.16")
        let trash = RecordingTrash()
        try UpdateSteps.install(from: fresh, over: old, tag: "1.16", retire: .trash, fileManager: trash)
        return trash.trashed.map(\.lastPathComponent)
    }

    func test_препятствия() throws {
        let ok = try fakeBundle(named: "Totum Commander.app", in: root, payload: "old")
        XCTAssertNil(UpdatePlan.obstacle(bundleURL: ok), "свой бандл в своей папке — можно")
        XCTAssertEqual(UpdatePlan.obstacle(bundleURL: root.appendingPathComponent("TotumComXL")),
                       .notABundle, "голый исполняемый файл — нельзя")
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Totum Commander.app")
        XCTAssertEqual(UpdatePlan.obstacle(bundleURL: translocated), .translocated)

        // Чужая папка: без права записи в родителя подмена невозможна.
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        let inside = try fakeBundle(named: "Totum Commander.app", in: locked, payload: "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(UpdatePlan.obstacle(bundleURL: inside), .notWritable)
    }

    func test_временныеИменаРядомСБандлом() {
        let bundle = URL(fileURLWithPath: "/Applications/Totum Commander.app")
        let staging = UpdatePlan.stagingURLs(for: bundle, tag: "1.3.1")
        XCTAssertEqual(staging.incoming.deletingLastPathComponent().path, "/Applications")
        XCTAssertEqual(staging.retired.deletingLastPathComponent().path, "/Applications")
        XCTAssertTrue(staging.incoming.lastPathComponent.hasPrefix("."), "скрытые, пока идёт подмена")
        XCTAssertTrue(staging.incoming.lastPathComponent.contains("1.3.1"))
        XCTAssertNotEqual(staging.incoming, staging.retired)
    }

    // MARK: - Подмена

    /// Новая копия встаёт на место старой, старая уходит, следов рядом не остаётся.
    func test_подменаБандла() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        let old = try fakeBundle(named: "Totum Commander.app", in: apps, payload: "old")
        let fresh = try fakeBundle(named: "Totum Commander.app", in: root.appendingPathComponent("image"), payload: "new")
        try UpdateSteps.install(from: fresh, over: old, tag: "1.3.1", retire: .delete)
        let payload = try String(contentsOf: old.appendingPathComponent("Contents/MacOS/TotumComXL"), encoding: .utf8)
        XCTAssertEqual(payload, "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: apps.path)
        XCTAssertEqual(leftovers, ["Totum Commander.app"], "ни входящей, ни отставленной копии")
    }

    /// Старая копия уходит в Корзину под человеческим именем с номером версии, а не скрытым
    /// «.Totum Commander.app.retired-123»: такое в Корзине не видно и не опознать.
    func test_вКорзинуСтараяКопияУходитПодВидимымИменем() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        XCTAssertEqual(try retiredNames(oldVersion: "1.15", apps: apps), ["Totum Commander 1.15.app"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Totum Commander.app"],
                       "рядом с новой копией ничего не осталось")
    }

    /// Версию старой копии прочитать не удалось — имя всё равно видимое и говорящее.
    func test_безНомераВерсииСтараяКопияТожеВидна() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        XCTAssertEqual(try retiredNames(oldVersion: nil, apps: apps),
                       ["Totum Commander (\(L("updates.previousVersion"))).app"])
    }

    /// Из номера версии в имя идут только буквы, цифры, точка, дефис и подчёркивание — косая
    /// черта увела бы копию в другую папку.
    func test_номерВерсииВИмениБезРазделителей() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        XCTAssertEqual(try retiredNames(oldVersion: "1.15/beta 2", apps: apps), ["Totum Commander 1.15beta2.app"])
    }

    /// Рядом уже лежит что-то с таким именем — оно остаётся как было, старая копия уходит под
    /// следующим свободным.
    func test_занятоеИмяСтаройКопииНеЗатирается() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        let keepsake = try fakeBundle(named: "Totum Commander 1.15.app", in: apps, payload: "памятная")
        XCTAssertEqual(try retiredNames(oldVersion: "1.15", apps: apps), ["Totum Commander 1.15 (2).app"])
        let payload = try String(contentsOf: keepsake.appendingPathComponent("Contents/MacOS/TotumComXL"),
                                 encoding: .utf8)
        XCTAssertEqual(payload, "памятная")
    }

    /// Копия без исполняемого файла на место не встаёт — старая остаётся как была.
    func test_битаяКопияНеСтавится() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        let old = try fakeBundle(named: "Totum Commander.app", in: apps, payload: "old")
        let broken = root.appendingPathComponent("image/Totum Commander.app", isDirectory: true)
        try FileManager.default.createDirectory(at: broken.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateSteps.install(from: broken, over: old, tag: "x", retire: .delete))
        let payload = try String(contentsOf: old.appendingPathComponent("Contents/MacOS/TotumComXL"), encoding: .utf8)
        XCTAssertEqual(payload, "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Totum Commander.app"])
    }

    /// Настоящий образ выпуска: FCXL_UPDATE_DMG=путь к .dmg. Подключает, копирует поверх
    /// поддельной старой копии во временной папке, отключает. По умолчанию пропускается.
    func test_настоящийОбраз() throws {
        guard let path = ProcessInfo.processInfo.environment["FCXL_UPDATE_DMG"] else {
            throw XCTSkip("FCXL_UPDATE_DMG не задан")
        }
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        let old = try fakeBundle(named: "Totum Commander.app", in: apps, payload: "old")
        let mount = try UpdateSteps.mount(dmg: URL(fileURLWithPath: path), at: root.appendingPathComponent("mnt"))
        defer { UpdateSteps.detach(mount) }
        let app = try XCTUnwrap(UpdateSteps.appInside(mount))
        try UpdateSteps.install(from: app, over: old, tag: "проверка", retire: .delete)
        let plist = old.appendingPathComponent("Contents/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        print("INSTALLED version=\(info["CFBundleShortVersionString"] ?? "?") build=\(info["CFBundleVersion"] ?? "?")")
        XCTAssertNotNil(info["CFBundleShortVersionString"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: old.appendingPathComponent("Contents/MacOS/TotumComXL").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Totum Commander.app"])
    }

    // MARK: - Как выглядит кнопка

    /// «Обновить до …» — красная плашка с белыми буквами в обеих темах. Картинки — в
    /// FCXL_LOOK_DIR, посмотреть глазами.
    @MainActor
    func test_кнопкаОбновленияКраснаяСБелымиБуквами() throws {
        for (name, scheme) in [("обновить-светлая", ColorScheme.light), ("обновить-тёмная", .dark)] {
            let view = Button("Обновить до 1.8.3") {}
                .buttonStyle(FCXLChipButtonStyle(compact: true, fill: .red))
                .padding(8)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, name)
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            // Поле плашки левее букв: 8 pt отступа вокруг, ещё 3 pt внутрь.
            let fill = try XCTUnwrap(rep.colorAt(x: 22, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(fill.redComponent, 0.85, name)
            XCTAssertLessThan(fill.greenComponent, 0.4, name)
            XCTAssertLessThan(fill.blueComponent, 0.4, name)
            // Белое — только внутри плашки, где кроме красного одни буквы.
            var white = 0
            for x in 16..<(rep.pixelsWide - 16) {
                for y in 16..<(rep.pixelsHigh - 16) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.redComponent > 0.95, c.greenComponent > 0.95, c.blueComponent > 0.95 { white += 1 }
                }
            }
            XCTAssertGreaterThan(white, 20, "белые буквы на красном — \(name)")
            if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            }
        }
    }

    // MARK: - Отмена загрузки

    /// Загрузка образа слушает отмену: задачу отменили — соединение рвётся сразу, а не тянется
    /// до конца файла или до обрыва связи.
    @MainActor
    func test_загрузкаОстанавливаетсяПоОтмене() async throws {
        let server = try StalledServer()
        try await server.ready()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/Totum-Commander-9.9.9.dmg"))
        let destination = root.appendingPathComponent("образ.dmg")
        let seen = LockedBox(0.0)
        let verdict = LockedBox<Result<Void, Error>?>(nil)

        let task = Task.detached {
            do {
                try await UpdateSteps.download(url, to: destination) { seen.value = max(seen.value, $0) }
                verdict.value = .success(())
            } catch {
                verdict.value = .failure(error)
            }
        }
        await updaterWaitUntil(10) { seen.value > 0 }
        guard seen.value > 0 else {
            task.cancel()
            server.stop()
            await task.value
            return XCTFail("загрузка не пошла")
        }

        task.cancel()
        await updaterWaitUntil(3) { verdict.value != nil }
        let stopped = verdict.value
        XCTAssertNotNil(stopped, "загрузка не остановилась по отмене")
        server.stop()
        await task.value

        if let stopped {
            switch stopped {
            case .success:
                XCTFail("отменённая загрузка сообщила об успехе")
            case .failure(let error):
                let ns = error as NSError
                XCTAssertTrue(error is CancellationError
                                || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled),
                              "ошибка отменённой загрузки — не отмена: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "от отменённой загрузки остался файл")
    }

    /// «Отмена» под полосой хода: загрузка останавливается, кнопка «Обновить» возвращается,
    /// программа на месте не тронута.
    @MainActor
    func test_отменаЗагрузкиВозвращаетВПокой() async throws {
        let server = try StalledServer()
        try await server.ready()
        defer { server.stop() }
        let app = try fakeBundle(named: "Totum Commander.app", in: root, payload: "старая", version: "1.0")
        let base = "http://127.0.0.1:\(server.port)"
        let json = Data("""
        {"tag_name": "v9.9.9", "html_url": "\(base)/release", "assets": [
          {"name": "SHA256SUMS.txt", "browser_download_url": "\(base)/SHA256SUMS.txt"},
          {"name": "Totum-Commander-9.9.9.dmg", "browser_download_url": "\(base)/Totum-Commander-9.9.9.dmg"}
        ]}
        """.utf8)
        let release = UpdateChecker.Release(version: "9.9.9",
                                            url: try XCTUnwrap(URL(string: base + "/release")))
        let updater = AppUpdater()
        func downloaded() -> Double {
            if case .downloading(let done) = updater.stage { return done }
            return 0
        }

        updater.start(release, bundle: app, fetch: { json })
        await updaterWaitUntil(10) { downloaded() > 0 }
        guard downloaded() > 0 else {
            server.stop()
            await updaterWaitUntil(5) { !updater.isBusy }
            return XCTFail("загрузка не пошла: \(updater.stage)")
        }

        updater.cancel()
        await updaterWaitUntil(3) { updater.stage == .idle }
        XCTAssertEqual(updater.stage, .idle, "загрузка не остановилась — кнопка «Обновить» не вернулась")

        server.stop()
        await updaterWaitUntil(5) { !updater.isBusy }
        XCTAssertFalse(updater.isBusy, "обновление так и не закончилось")
        let binary = app.appendingPathComponent("Contents/MacOS/TotumComXL")
        XCTAssertEqual(try String(contentsOf: binary, encoding: .utf8), "старая", "программа на месте тронута")
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-update-\(ProcessInfo.processInfo.processIdentifier)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "рабочая папка загрузки не убрана")
    }

    /// Под полосой хода загрузки стоит «Отмена», и она нажимается — в обеих темах.
    @MainActor
    func test_строкаЗагрузки_отменаПодПолосой() throws {
        MouseLikeAPerson.setAccessibility(true)
        defer { MouseLikeAPerson.setAccessibility(false) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = name == .aqua ? "светлая" : "тёмная"
            let presses = PressCounter()
            let view = UpdateDownloadRow(fraction: 0.42) { presses.count += 1 }
                .padding(16)
                .frame(width: 420, height: 90, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 90),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("загрузка-\(theme).png"))
            }

            XCTAssertTrue(MouseLikeAPerson.press(L("button.cancel"), in: window),
                          "под полосой хода нет кнопки «Отмена» (\(theme))")
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(presses.count, 1, "«Отмена» не нажалась (\(theme))")
        }
    }
}

/// Сервер на 127.0.0.1, который начинает отдавать образ и замирает: 256 КБ из обещанных 50 МБ.
/// Так выглядит загрузка на оборвавшейся связи — и на ней видно, слушает ли она отмену.
private final class StalledServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fcxl.tests.stalled-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                    + "Content-Length: 50000000\r\n\r\n"
                var body = Data(head.utf8)
                body.append(Data(count: 256 * 1024))
                connection.send(content: body, completion: .contentProcessed { _ in })
            }
        }
    }

    func ready() async throws {
        let answered = LockedBox(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                guard !answered.value else { return }
                switch state {
                case .ready:
                    answered.value = true
                    continuation.resume()
                case .failed(let error):
                    answered.value = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class PressCounter { var count = 0 }

@MainActor
private func updaterWaitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
