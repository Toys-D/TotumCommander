import XCTest
@testable import TotumComXLApp

/// Мультипереименование не затирает файлы и не бросает их под временными именами: имя, которое
/// держит остающийся на месте файл выделения, занято; исполнитель никогда не переименовывает
/// поверх существующего; после отмены или сбоя скрытых временных имён не остаётся.
@MainActor
final class MultiRenameSafetyTests: XCTestCase {

    private typealias Step = RenameExecutionPlanner.Step

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mrt-safe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Имя держит файл, который остаётся

    func test_имяФайлаКоторыйОстаётсяНаМестеЗанято() {
        let copy = makeFile("report copy.txt", "копия")
        let original = makeFile("report.txt", "оригинал")
        let vm = makeVM([copy, original])
        vm.rule.search = " copy"; vm.rule.replace = ""
        vm.recomputeNow()

        XCTAssertEqual(plan(vm, copy)?.newName, "report.txt")
        XCTAssertEqual(plan(vm, original)?.status, .unchanged)
        XCTAssertEqual(plan(vm, copy)?.status, .collidesOnDisk, "имя держит файл, который никуда не уезжает")
        XCTAssertFalse(vm.canExecute)
    }

    func test_заменаВИмениНеЗатираетСоседаПоВыделению() async throws {
        let copy = makeFile("report copy.txt", "копия")
        let original = makeFile("report.txt", "оригинал")
        let vm = makeVM([copy, original])
        vm.rule.search = " copy"; vm.rule.replace = ""
        vm.recomputeNow()

        try? await run(vm.plannedSteps())

        XCTAssertEqual(read("report.txt"), "оригинал")
        XCTAssertEqual(read("report copy.txt"), "копия")
    }

    func test_цепочкаУпёршаясяВЗанятоеИмяОстанавливаетсяЦеликом() {
        let a = makeFile("a.txt", "A")
        let b = makeFile("b.txt", "B")
        makeFile("c.txt", "C")   // лежит рядом, в выделение не входит
        let vm = makeVM([a, b])
        vm.setManualName("b.txt", for: a.path)
        vm.setManualName("c.txt", for: b.path)

        XCTAssertEqual(plan(vm, b)?.status, .collidesOnDisk)
        XCTAssertEqual(plan(vm, a)?.status, .collidesOnDisk, "b.txt остаётся на месте — его имя занято")
        XCTAssertFalse(vm.canExecute)
    }

    func test_имяФайлаСОшибкойТожеЗанято() {
        let a = makeFile("a.txt", "A")
        let b = makeFile("b.txt", "B")
        let vm = makeVM([a, b])
        vm.setManualName("b.txt", for: a.path)
        vm.setManualName("плохое:имя", for: b.path)

        XCTAssertEqual(plan(vm, b)?.status, .error("illegal"))
        XCTAssertEqual(plan(vm, a)?.status, .collidesOnDisk)
    }

    func test_цепочкаСоСвободнымКонцомВыполняется() async throws {
        let a = makeFile("a.txt", "A")
        let b = makeFile("b.txt", "B")
        let vm = makeVM([a, b])
        vm.setManualName("b.txt", for: a.path)
        vm.setManualName("c.txt", for: b.path)

        XCTAssertEqual(plan(vm, a)?.status, .ok)
        XCTAssertEqual(plan(vm, b)?.status, .ok)
        try await run(vm.plannedSteps())

        XCTAssertEqual(try namesOnDisk(), ["b.txt", "c.txt"])
        XCTAssertEqual(read("b.txt"), "A")
        XCTAssertEqual(read("c.txt"), "B")
    }

    // MARK: - Исполнитель не затирает

    func test_исполнительНеПереименовываетПоверхСуществующегоФайла() async {
        makeFile("x.txt", "икс")
        makeFile("y.txt", "игрек")

        do {
            try await run([Step(from: path("x.txt"), to: path("y.txt"))])
            XCTFail("занятое имя — ошибка")
        } catch {}

        XCTAssertEqual(read("x.txt"), "икс")
        XCTAssertEqual(read("y.txt"), "игрек")
    }

    // MARK: - Временных имён не остаётся

    func test_отменаПослеПервогоШагаВозвращаетИсходноеИмя() async throws {
        makeFile("a.txt", "A"); makeFile("b.txt", "B")

        try await run(swapSteps(), reporter: CancellingReporter(after: 1))

        XCTAssertEqual(try namesOnDisk(), ["a.txt", "b.txt"])
        XCTAssertEqual(read("a.txt"), "A")
        XCTAssertEqual(read("b.txt"), "B")
    }

    func test_отменаМеждуЭтапамиВозвращаетИсходныеИмена() async throws {
        makeFile("a.txt", "A"); makeFile("b.txt", "B")

        try await run(swapSteps(), reporter: CancellingReporter(after: 2))

        XCTAssertEqual(try namesOnDisk(), ["a.txt", "b.txt"])
        XCTAssertEqual(read("a.txt"), "A")
        XCTAssertEqual(read("b.txt"), "B")
    }

    /// Первый файл уже занял имя второго — второму вернуться некуда, остаётся его новое имя.
    func test_отменаПосредиВторогоЭтапаДоводитОбменДоКонца() async throws {
        makeFile("a.txt", "A"); makeFile("b.txt", "B")

        try await run(swapSteps(), reporter: CancellingReporter(after: 3))

        XCTAssertEqual(try namesOnDisk(), ["a.txt", "b.txt"])
        XCTAssertEqual(read("a.txt"), "B")
        XCTAssertEqual(read("b.txt"), "A")
    }

    func test_сбойВторогоЭтапаВозвращаетФайлНаИсходноеИмя() async {
        makeFile("a.txt", "A")
        makeFile("преграда", "это файл, а не папка")
        let temp = path(".fcxl-mrt-test-0")
        let steps = [Step(from: path("a.txt"), to: temp),
                     Step(from: temp, to: path("преграда/a.txt"))]

        var message = ""
        do {
            try await run(steps)
            XCTFail("ожидалась ошибка: папку на месте файла не создать")
        } catch {
            message = error.localizedDescription
        }

        XCTAssertEqual(try? namesOnDisk(), ["a.txt", "преграда"])
        XCTAssertEqual(read("a.txt"), "A")
        XCTAssertTrue(message.contains("a.txt"), "ошибка называет файл его настоящим именем: \(message)")
        XCTAssertFalse(message.contains(".fcxl-mrt-test-0"), "а не временным: \(message)")
    }

    func test_несостоявшийсяПервыйШагНеДаётВторойОшибкиПоТомуЖеФайлу() async {
        makeFile("b.txt", "B")
        let temp = path(".fcxl-mrt-test-0")
        let steps = [Step(from: path("нет такого.txt"), to: temp),
                     Step(from: temp, to: path("новое.txt")),
                     Step(from: path("b.txt"), to: path("c.txt"))]

        var message = ""
        do {
            try await run(steps)
            XCTFail("ожидалась ошибка: источника нет")
        } catch {
            message = error.localizedDescription
        }

        XCTAssertEqual(message.components(separatedBy: "\n").count, 1, "одна строка на один файл: \(message)")
        XCTAssertEqual(try? namesOnDisk(), ["c.txt"], "остальные шаги выполнены")
    }

    // MARK: - На сервере

    func test_наСервереОтменаМеждуЭтапамиВозвращаетИсходныеИмена() async throws {
        let server = MemoryServer(["/d/a.txt": "A", "/d/b.txt": "B"])
        let (queue, reporter) = makeQueueReporter()
        server.afterMove = { count in if count == 2 { reporter.markCancelled() } }

        try await queue.runRemoteMultiRename(session: session(server), steps: remoteSwapSteps(), reporter: reporter)

        XCTAssertEqual(server.files, ["/d/a.txt": "A", "/d/b.txt": "B"])
    }

    func test_наСервереОтменаПосредиВторогоЭтапаДоводитОбменДоКонца() async throws {
        let server = MemoryServer(["/d/a.txt": "A", "/d/b.txt": "B"])
        let (queue, reporter) = makeQueueReporter()
        server.afterMove = { count in if count == 3 { reporter.markCancelled() } }

        try await queue.runRemoteMultiRename(session: session(server), steps: remoteSwapSteps(), reporter: reporter)

        XCTAssertEqual(server.files, ["/d/a.txt": "B", "/d/b.txt": "A"])
    }

    func test_наСервереСбойВторогоЭтапаВозвращаетФайлНаИсходноеИмя() async {
        let server = MemoryServer(["/d/a.txt": "A"])
        server.refused = ["/d/нельзя/a.txt"]
        let (queue, reporter) = makeQueueReporter()
        let steps = [Step(from: "/d/a.txt", to: "/d/.fcxl-mrt-test-0"),
                     Step(from: "/d/.fcxl-mrt-test-0", to: "/d/нельзя/a.txt")]

        var message = ""
        do {
            try await queue.runRemoteMultiRename(session: session(server), steps: steps, reporter: reporter)
            XCTFail("ожидалась ошибка: сервер отказал")
        } catch {
            message = error.localizedDescription
        }

        XCTAssertEqual(server.files, ["/d/a.txt": "A"])
        XCTAssertTrue(message.contains("a.txt"), message)
        XCTAssertFalse(message.contains(".fcxl-mrt-test-0"), message)
    }

    // MARK: - Очередь

    /// «Отмена» — ещё не конец пакета: исполнитель возвращает файлы с временных имён. О конце
    /// (по нему окно обновляет панель и снова разрешает «Переименовать») очередь сообщает,
    /// когда он действительно остановился.
    func test_оКонцеОтменённогоПакетаОчередьСообщаетКогдаИсполнительОстановился() async {
        let a = makeFile("a.txt", "A"), b = makeFile("b.txt", "B")
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        let stopped = expectation(description: "исполнитель остановился")
        var completed = false
        let id = queue.enqueueMultiRename(items: [a, b], params: MultiRenameParams(steps: swapSteps()),
                                          onCompletion: { completed = true; stopped.fulfill() })

        queue.cancel(id)

        XCTAssertFalse(completed, "исполнитель ещё не остановился — о конце сообщать рано")
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(try? namesOnDisk(), ["a.txt", "b.txt"])
    }

    /// Строку отменённого пакета можно убрать из списка раньше, чем исполнитель до неё дошёл.
    /// Окно переименования всё равно узнаёт о конце — иначе «Переименовать» в нём не оживёт.
    func test_оКонцеОтменённогоПакетаОчередьСообщаетДажеЕслиСтрокуУжеУбрали() async {
        let a = makeFile("a.txt", "A"), b = makeFile("b.txt", "B")
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        let stopped = expectation(description: "о конце сообщили")
        let id = queue.enqueueMultiRename(items: [a, b], params: MultiRenameParams(steps: swapSteps()),
                                          onCompletion: { stopped.fulfill() })

        queue.cancel(id)
        queue.removeCompleted()

        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(try? namesOnDisk(), ["a.txt", "b.txt"])
    }

    /// Отменённый пакет не молчит о том, что пошло не так: файл, который не удалось вернуть с
    /// временного имени, иначе остался бы под скрытым именем без единого слова.
    func test_отменённыйПакетСОшибкойПоказываетОшибкуАНеПростоОтменён() {
        XCTAssertEqual(OperationQueueService.statusAfterError(kind: .multiRename, cancelledByUser: false,
                                                              rowCancelled: true), .failed)
        XCTAssertEqual(OperationQueueService.statusAfterError(kind: .multiRename, cancelledByUser: true,
                                                              rowCancelled: true), .cancelled)
        XCTAssertEqual(OperationQueueService.statusAfterError(kind: .copy, cancelledByUser: false,
                                                              rowCancelled: true), .cancelled,
                       "у остальных операций отмена по-прежнему главнее ошибки")
        XCTAssertEqual(OperationQueueService.statusAfterError(kind: .copy, cancelledByUser: false,
                                                              rowCancelled: false), .failed)
    }

    private func makeQueueReporter() -> (OperationQueueService, QueueOperationReporter) {
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        return (queue, QueueOperationReporter(operationId: UUID(), queueService: queue))
    }

    private func session(_ server: MemoryServer) -> RemoteSession {
        RemoteSession(connection: RemoteConnection(proto: .sftp, host: "х"), fileSystem: server)
    }

    private func remoteSwapSteps() -> [Step] {
        let moves = [RenameExecutionPlanner.Move(source: "/d/a.txt", final: "/d/b.txt"),
                     RenameExecutionPlanner.Move(source: "/d/b.txt", final: "/d/a.txt")]
        return RenameExecutionPlanner().plan(moves) { ".fcxl-mrt-test-\($0)" }
    }

    // MARK: - Подспорье

    @discardableResult
    private func makeFile(_ name: String, _ text: String = "x") -> FileItem {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        return FileItem(path: path, name: name, fileExtension: (name as NSString).pathExtension,
                        size: UInt64(text.utf8.count), isDirectory: false, isHidden: false, isSymlink: false,
                        permissions: "rw-r--r--", dateModified: Date())
    }

    private func makeVM(_ items: [FileItem]) -> MultiRenameViewModel {
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        return MultiRenameViewModel(items: items, rootPath: dir.path, session: nil, queue: queue)
    }

    private func plan(_ vm: MultiRenameViewModel, _ item: FileItem) -> RenamePlan? {
        vm.plans.first { $0.sourcePath == item.path }
    }

    private func path(_ name: String) -> String {
        dir.appendingPathComponent(name).path
    }

    private func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: path(name)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func namesOnDisk() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// Обмен именами a.txt ↔ b.txt, как его раскладывает планировщик: оба на временные, потом оба
    /// на конечные.
    private func swapSteps() -> [Step] {
        let moves = [RenameExecutionPlanner.Move(source: path("a.txt"), final: path("b.txt")),
                     RenameExecutionPlanner.Move(source: path("b.txt"), final: path("a.txt"))]
        return RenameExecutionPlanner().plan(moves) { ".fcxl-mrt-test-\($0)" }
    }

    private func run(_ steps: [Step], reporter: OperationProgressReporter = CancellingReporter(after: .max)) async throws {
        let fileOps = FileOperationsService(bridgeService: CoreBridgeService())
        try await fileOps.executeRenameSteps(steps, reporter: reporter)
    }
}

/// Даёт выполнить заданное число шагов и «нажимает Отмену» перед следующим.
private final class CancellingReporter: OperationProgressReporter {
    private let allowed: Int
    private let lock = NSLock()
    private var asked = 0

    init(after allowed: Int) { self.allowed = allowed }

    nonisolated var isCancelled: Bool { false }
    nonisolated var isPaused: Bool { false }
    nonisolated var isSentToQueue: Bool { false }
    nonisolated func waitWhilePaused() -> Bool {
        lock.lock(); defer { lock.unlock() }
        asked += 1
        return asked > allowed
    }
    func update(currentFile: String, progress: Double, bytesDone: Int64, bytesTotal: Int64,
                filesDone: Int, filesTotal: Int) {}
    func close() {}
}

/// Сервер в памяти. Переименование поверх существующего имени затирает молча — как худший из
/// настоящих серверов; тем заметнее, если программа назовёт занятое имя.
private final class MemoryServer: RemoteFileSystemProtocol, @unchecked Sendable {
    var isConnected = true
    let protocolDisplayName = "ПАМЯТЬ"
    var files: [String: String]
    var refused: Set<String> = []
    var afterMove: ((Int) -> Void)?
    private var moves = 0

    init(_ files: [String: String]) { self.files = files }

    func connect() async throws {}
    func disconnect() {}
    func listDirectory(at path: String) async throws -> [FileItem] { [] }
    func createDirectory(at path: String, name: String) async throws {}
    func deleteItem(at path: String, isDirectory: Bool) async throws {}
    func rename(at path: String, to newName: String) async throws {}
    func moveItem(from sourcePath: String, to destinationPath: String) async throws {
        guard let content = files[sourcePath], !refused.contains(destinationPath) else {
            throw NSError(domain: "MemoryServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "отказ"])
        }
        files[sourcePath] = nil
        files[destinationPath] = content
        moves += 1
        afterMove?(moves)
    }
    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {}
    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {}
}
