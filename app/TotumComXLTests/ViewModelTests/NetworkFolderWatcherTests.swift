import XCTest
@testable import TotumComXLApp

/// Сетевая папка: файл, положенный на самом сервере, панель не показывала, пока в папку не войти
/// заново, — медленные тома не наблюдались вовсе, а журнал диска о правках на сервере молчит.
/// Слежка проверяется на местной временной папке: kqueue и сверка даты работают на ней так же.
final class NetworkFolderWatcherTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-network-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func test_режимСлежки_поМестуПапки() {
        XCTAssertEqual(FolderWatchMode.mode(insideArchive: false, slowVolume: false, networkVolume: false), .journal)
        XCTAssertEqual(FolderWatchMode.mode(insideArchive: false, slowVolume: true, networkVolume: false), .none,
                       "медленный внешний диск — экономия, как и было")
        XCTAssertEqual(FolderWatchMode.mode(insideArchive: false, slowVolume: true, networkVolume: true), .network,
                       "сетевая папка наблюдается своей слежкой")
        XCTAssertEqual(FolderWatchMode.mode(insideArchive: true, slowVolume: true, networkVolume: true), .none)
    }

    func test_новыйФайлВПапке_замеченСразу() throws {
        let noticed = expectation(description: "слежка сообщила о новом файле")
        noticed.assertForOverFulfill = false
        let watcher = NetworkFolderWatcher(path: folder.path, pollInterval: 60) { noticed.fulfill() }
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.2)   // слежка ставится на своей очереди
        try Data("новое".utf8).write(to: folder.appendingPathComponent("с сервера.txt"))
        wait(for: [noticed], timeout: 2)
    }

    func test_серверНеШлётУведомлений_сверкаДатыЗамечаетНовое() throws {
        let noticed = expectation(description: "сверка даты заметила новый файл")
        noticed.assertForOverFulfill = false
        let watcher = NetworkFolderWatcher(path: folder.path, pollInterval: 0.3, events: false) { noticed.fulfill() }
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        try Data("новое".utf8).write(to: folder.appendingPathComponent("с сервера.txt"))
        wait(for: [noticed], timeout: 3)
    }

    func test_безИзменений_тишина() {
        let quiet = expectation(description: "без изменений — ни звука")
        quiet.isInverted = true
        let watcher = NetworkFolderWatcher(path: folder.path, pollInterval: 0.2) { quiet.fulfill() }
        defer { watcher.stop() }
        wait(for: [quiet], timeout: 1)
    }

    func test_послеОстановки_тишина() throws {
        let quiet = expectation(description: "остановленная слежка молчит")
        quiet.isInverted = true
        let watcher = NetworkFolderWatcher(path: folder.path, pollInterval: 0.2) { quiet.fulfill() }
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()
        Thread.sleep(forTimeInterval: 0.1)
        try Data("новое".utf8).write(to: folder.appendingPathComponent("после.txt"))
        wait(for: [quiet], timeout: 1)
    }
}
