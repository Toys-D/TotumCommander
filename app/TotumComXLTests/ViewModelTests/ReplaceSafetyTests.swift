import XCTest
@testable import TotumComXLApp

/// «Заменить» при копировании и перемещении.
///
/// Прежний файл в приёмнике трогают только тогда, когда новая копия готова целиком: сам ответ
/// на вопрос ничего не удаляет, и отмена, нехватка места или ошибка чтения оставляют всё как
/// было. И одна и та же запись каталога под другой строкой пути (симлинк, другой регистр,
/// `/var` вместо `/private/var`) — не конфликт: раньше «Заменить» удаляло в таком случае сам
/// источник.
///
/// Всё происходит в своей подпапке временной папки и на своих образах дисков.
@MainActor
final class ReplaceSafetyTests: XCTestCase {

    private var ops: FileOperationsService!
    private var tmp: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UndoJournal.shared.reset()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-replace-test-\(UUID().uuidString)")
        try makeFolder("a")
        try makeFolder("b")
    }

    override func tearDownWithError() throws {
        UndoJournal.shared.reset()
        if let tmp {
            Self.unlock(tmp)
            try? FileManager.default.removeItem(atPath: tmp)
        }
        ops = nil
        tmp = nil
        try super.tearDownWithError()
    }

    // MARK: - Помощники

    /// Ответы на вопрос о замене — по порядку. Запоминает, про что спросили. Когда ответы
    /// кончились, отвечает «Отмена»: ничего разрушительного по умолчанию.
    private final class Answers {
        private var queue: [ConflictResolution]
        private(set) var asked: [String] = []
        init(_ answers: ConflictResolution...) { queue = answers }
        func next(_ destination: String) -> ConflictResolution {
            asked.append(destination)
            return queue.isEmpty ? .cancel : queue.removeFirst()
        }
    }

    private func path(_ parts: String...) -> String {
        parts.reduce(tmp) { ($0 as NSString).appendingPathComponent($1) }
    }

    @discardableResult
    private func write(_ relative: String..., text: String = "содержимое") throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    @discardableResult
    private func makeFolder(_ relative: String...) throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func read(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }

    private func names(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    /// Временные имена, под которыми готовится замена. После операции их быть не должно.
    private func leftovers(in folder: String) -> [String] {
        names(in: folder).filter { $0.hasPrefix(".fcxl-replace-") }
    }

    private func isLocked(_ p: String) -> Bool {
        var info = stat()
        return lstat(p, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    /// Путь без симлинков и сокращений — как его видит ядро.
    private func canonical(_ p: String) -> String {
        guard let resolved = realpath(p, nil) else { return p }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func item(at p: String) -> FileItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: p)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        let name = (p as NSString).lastPathComponent
        return FileItem(path: p, name: name, fileExtension: (name as NSString).pathExtension,
                        size: (attrs?[.size] as? UInt64) ?? 0, isDirectory: isDir,
                        isHidden: false, isSymlink: false, permissions: "-rw-r--r--",
                        dateModified: Date())
    }

    private func hasAccessList(_ p: String) -> Bool {
        guard let list = acl_get_link_np(p, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(list))
        return true
    }

    /// Выполнить и вернуть ошибку, не обрывая тест: после неё ещё нужно посмотреть на диск.
    private func attempt(_ work: () async throws -> Void) async -> NSError? {
        do {
            try await work()
            return nil
        } catch {
            return error as NSError
        }
    }

    /// Снять запреты со всего дерева, иначе временную папку не убрать.
    private static func unlock(_ root: String) {
        var pending = [root]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_flags != 0 { _ = lchflags(path, 0) }
            // Список доступа с «запретить удаление» не даёт убрать объект даже владельцу.
            if let list = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
                acl_free(UnsafeMutableRawPointer(list))
                if let empty = acl_init(0) {
                    _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
                    acl_free(UnsafeMutableRawPointer(empty))
                }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                if (info.st_mode & S_IFMT) == S_IFREG { chmod(path, 0o644) }
                continue
            }
            chmod(path, 0o755)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                pending.append(path + "/" + name)
            }
        }
    }

    // MARK: - Ответ «Заменить» сам ничего не удаляет

    func test_заменитьИОтменаНаСледующемВопросеОставляютОбаПрежнихФайла() async throws {
        let first = try write("a", "один.txt", text: "новое-1")
        let second = try write("a", "два.txt", text: "новое-2")
        try write("b", "один.txt", text: "прежнее-1")
        try write("b", "два.txt", text: "прежнее-2")
        let answers = Answers(.replace, .cancel)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: first), self.item(at: second)],
                                         to: self.path("b"), onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "«Отмена» должна остановить операцию")
        XCTAssertEqual(answers.asked.count, 2)
        XCTAssertEqual(read(path("b", "один.txt")), "прежнее-1",
                       "на «Заменить» ответили, но операцию отменили — файл обязан уцелеть")
        XCTAssertEqual(read(path("b", "два.txt")), "прежнее-2")
    }

    func test_заменитьИОтменаВнутриСлиянияПапокОставляютОбаПрежнихФайла() async throws {
        try makeFolder("a", "Папка")
        try makeFolder("b", "Папка")
        try write("a", "Папка", "один.txt", text: "новое-1")
        try write("a", "Папка", "два.txt", text: "новое-2")
        try write("b", "Папка", "один.txt", text: "прежнее-1")
        try write("b", "Папка", "два.txt", text: "прежнее-2")
        let answers = Answers(.replace, .cancel)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: self.path("a", "Папка"))],
                                         to: self.path("b"), onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "«Отмена» должна остановить операцию")
        XCTAssertEqual(answers.asked.count, 2)
        XCTAssertEqual(read(path("b", "Папка", "один.txt")), "прежнее-1")
        XCTAssertEqual(read(path("b", "Папка", "два.txt")), "прежнее-2")
    }

    // MARK: - Неудавшаяся замена оставляет прежнее

    func test_неудавшаясяЗаменаВнутриПапкиОставляетПрежнийФайл() async throws {
        try makeFolder("a", "Папка")
        try makeFolder("b", "Папка")
        let secret = try write("a", "Папка", "секрет.txt", text: "не прочитать")
        try write("b", "Папка", "секрет.txt", text: "прежнее")
        XCTAssertEqual(chmod(secret, 0), 0)
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: self.path("a", "Папка"))],
                                         to: self.path("b"), onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "нечитаемый файл скопировать нельзя — об этом надо сказать")
        XCTAssertEqual(read(path("b", "Папка", "секрет.txt")), "прежнее",
                       "новая копия не получилась — прежний файл обязан остаться")
        XCTAssertEqual(names(in: path("b", "Папка")), ["секрет.txt"], "после сбоя не должно остаться временных имён")
    }

    func test_заменаБезМестаНаДискеОставляетПрежнийФайл() async throws {
        let disk = try TestDiskImage(megabytes: 2)
        defer { disk.detach() }
        let source = path("a", "большой.bin")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: source, contents: Data(repeating: 0x5A, count: 6 * 1024 * 1024)))
        let old = disk.mountPoint + "/большой.bin"
        try "прежнее".write(toFile: old, atomically: true, encoding: .utf8)
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: source)], to: disk.mountPoint,
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "шесть мегабайт на двухмегабайтный том не помещаются")
        XCTAssertEqual(read(old), "прежнее", "места не хватило — прежний файл обязан остаться")
        XCTAssertEqual(leftovers(in: disk.mountPoint), [], "недописанная копия должна быть убрана")
    }

    // MARK: - Та же запись каталога под другой строкой пути — не конфликт

    /// «Копировать сюда же» по другому названию той же папки обязано дать дубль. Ответ
    /// «Заменить» здесь заготовлен нарочно: если о замене всё-таки спросят, источник погибнет.
    private func assertCopyIntoSameFolderMakesDuplicate(via destination: String,
                                                        file: StaticString = #filePath,
                                                        line: UInt = #line) async throws {
        let source = try write("a", "файл.txt", text: "единственный")
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: source)], to: destination,
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNil(error, file: file, line: line)
        XCTAssertTrue(answers.asked.isEmpty, "о замене файла им самим не спрашивают", file: file, line: line)
        XCTAssertEqual(read(source), "единственный", "источник удалён: его приняли за чужой файл",
                       file: file, line: line)
        XCTAssertEqual(names(in: path("a")), ["файл (1).txt", "файл.txt"], file: file, line: line)
        XCTAssertEqual(read(path("a", "файл (1).txt")), "единственный", file: file, line: line)
    }

    func test_копированиеВТуЖеПапкуЧерезСимлинкДаётДубль() async throws {
        try FileManager.default.createSymbolicLink(atPath: path("ссылка"), withDestinationPath: path("a"))
        try await assertCopyIntoSameFolderMakesDuplicate(via: path("ссылка"))
    }

    func test_копированиеВТуЖеПапкуПодДругимРегистромПутиДаётДубль() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path("A")), "том различает регистр")
        try await assertCopyIntoSameFolderMakesDuplicate(via: path("A"))
    }

    func test_копированиеВТуЖеПапкуПодДругимНаписаниемПутиДаётДубль() async throws {
        let other = canonical(path("a"))
        try XCTSkipIf(other == path("a"), "у временной папки одно написание пути")
        try await assertCopyIntoSameFolderMakesDuplicate(via: other)
    }

    func test_перемещениеВТуЖеПапкуЧерезСимлинкНичегоНеДелает() async throws {
        let source = try write("a", "файл.txt", text: "единственный")
        try FileManager.default.createSymbolicLink(atPath: path("ссылка"), withDestinationPath: path("a"))
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.moveItems([self.item(at: source)], to: self.path("ссылка"),
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNil(error)
        XCTAssertTrue(answers.asked.isEmpty, "о замене файла им самим не спрашивают")
        XCTAssertEqual(read(source), "единственный", "файл удалён: его приняли за чужой и «заменили»")
        XCTAssertEqual(names(in: path("a")), ["файл.txt"])
    }

    func test_копированиеПапкиВТуЖеПапкуЧерезСимлинкДаётДубльАНеСлияниеССобой() async throws {
        try makeFolder("a", "Папка")
        let inner = try write("a", "Папка", "внутри.txt", text: "единственный")
        try FileManager.default.createSymbolicLink(atPath: path("ссылка"), withDestinationPath: path("a"))
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: self.path("a", "Папка"))],
                                         to: self.path("ссылка"), onConflict: { answers.next($0) })
        }

        XCTAssertNil(error)
        XCTAssertTrue(answers.asked.isEmpty, "папку не сливают саму с собой")
        XCTAssertEqual(read(inner), "единственный", "файл удалён: папку слили саму с собой")
        XCTAssertEqual(names(in: path("a")), ["Папка", "Папка (1)"])
        XCTAssertEqual(read(path("a", "Папка (1)", "внутри.txt")), "единственный")
    }

    // MARK: - Папку нельзя копировать в саму себя — и по другому названию тоже

    func test_папкуНельзяКопироватьВСебяПоПрямомуПути() throws {
        let folder = try makeFolder("a", "Папка")
        try makeFolder("a", "Папка", "внутри")

        XCTAssertThrowsError(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: folder))
        XCTAssertThrowsError(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: path("a", "Папка", "внутри")))
    }

    func test_папкуНельзяКопироватьВСебяЧерезСимлинк() throws {
        let folder = try makeFolder("a", "Папка")
        try makeFolder("a", "Папка", "внутри")
        try FileManager.default.createSymbolicLink(atPath: path("ссылка"), withDestinationPath: folder)

        XCTAssertThrowsError(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: path("ссылка"))) { error in
            XCTAssertEqual((error as NSError).domain, "FileOperationsService")
        }
        XCTAssertThrowsError(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: path("ссылка", "внутри")))
    }

    func test_папкуНельзяКопироватьВСебяПодДругимРегистромПути() throws {
        let folder = try makeFolder("a", "Папка")
        try makeFolder("a", "Папка", "внутри")
        let other = path("A", "Папка", "внутри")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: other), "том различает регистр")

        XCTAssertThrowsError(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: other))
    }

    func test_папкуНельзяКопироватьВСебяПодДругимНаписаниемПути() throws {
        let folder = try makeFolder("a", "Папка")
        let inner = try makeFolder("a", "Папка", "внутри")
        let other = canonical(inner)
        try XCTSkipIf(other == inner, "у временной папки одно написание пути")

        XCTAssertThrowsError(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: other))
    }

    /// Страховка: проверка «в себя» не должна мешать обычным случаям.
    func test_папкуМожноКопироватьРядомИВСоседнююПапку() throws {
        let folder = try makeFolder("a", "Папка")
        let neighbour = try makeFolder("a", "Папка2")
        try FileManager.default.createSymbolicLink(atPath: path("ссылка"), withDestinationPath: path("b"))

        XCTAssertNoThrow(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: path("b")))
        XCTAssertNoThrow(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: path("a")), "в свою же папку — это дубль рядом")
        XCTAssertNoThrow(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: neighbour), "имя лишь начинается так же")
        XCTAssertNoThrow(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: path("ссылка")))
        XCTAssertNoThrow(try ops.validateNotCopyingIntoSelf(
            items: [item(at: folder)], destinationPath: path("нет-такой-папки")))
    }

    // MARK: - Страховка: замена по-прежнему заменяет

    func test_заменаФайлаСтавитНовоеСодержимое() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        try write("b", "файл.txt", text: "прежнее")
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(answers.asked.count, 1)
        XCTAssertEqual(read(path("b", "файл.txt")), "новое")
        XCTAssertEqual(read(source), "новое", "при копировании источник остаётся")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"], "временных имён не остаётся")
    }

    func test_заменаВнутриСлиянияПапок() async throws {
        try makeFolder("a", "Папка")
        try makeFolder("b", "Папка")
        try write("a", "Папка", "файл.txt", text: "новое")
        try write("a", "Папка", "новый.txt", text: "добавлен")
        try write("b", "Папка", "файл.txt", text: "прежнее")
        try write("b", "Папка", "другой.txt", text: "сосед")
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: path("a", "Папка"))], to: path("b"),
                                onConflict: { answers.next($0) })

        XCTAssertEqual(answers.asked.count, 1)
        XCTAssertEqual(read(path("b", "Папка", "файл.txt")), "новое")
        XCTAssertEqual(read(path("b", "Папка", "другой.txt")), "сосед")
        XCTAssertEqual(read(path("b", "Папка", "новый.txt")), "добавлен")
        XCTAssertEqual(names(in: path("b", "Папка")), ["другой.txt", "новый.txt", "файл.txt"])
    }

    func test_файлЗаменяетПапкуСТемЖеИменем() async throws {
        let source = try write("a", "имя", text: "новое")
        try makeFolder("b", "имя")
        try write("b", "имя", "старое.txt")
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(read(path("b", "имя")), "новое")
        XCTAssertEqual(names(in: path("b")), ["имя"])
    }

    func test_папкаЗаменяетФайлСТемЖеИменем() async throws {
        try makeFolder("a", "имя")
        try write("a", "имя", "внутри.txt", text: "новое")
        try write("b", "имя", text: "прежнее")
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: path("a", "имя"))], to: path("b"),
                                onConflict: { answers.next($0) })

        XCTAssertEqual(read(path("b", "имя", "внутри.txt")), "новое")
        XCTAssertEqual(names(in: path("b")), ["имя"])
    }

    func test_симлинкВПриёмникеЗаменяетсяСамАЕгоЦельНеТрогается() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let target = try write("цель.txt", text: "цель")
        try FileManager.default.createSymbolicLink(atPath: path("b", "файл.txt"), withDestinationPath: target)
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(read(target), "цель", "цель симлинка — чужой файл")
        XCTAssertEqual(read(path("b", "файл.txt")), "новое")
        let attributes = try FileManager.default.attributesOfItem(atPath: path("b", "файл.txt"))
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
    }

    func test_заменаФайлаСДругимРегистромИмениДаётИмяИсточника() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        try write("b", "ФАЙЛ.TXT", text: "прежнее")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path("b", "файл.txt")), "том различает регистр")
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(names(in: path("b")), ["файл.txt"])
        XCTAssertEqual(read(path("b", "файл.txt")), "новое")
    }

    func test_перемещениеСЗаменойФайлаСДругимРегистромИмениДаётИмяИсточника() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        try write("b", "ФАЙЛ.TXT", text: "прежнее")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path("b", "файл.txt")), "том различает регистр")
        let answers = Answers(.replace)

        try await ops.moveItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(names(in: path("b")), ["файл.txt"])
        XCTAssertEqual(read(path("b", "файл.txt")), "новое")
        XCTAssertEqual(names(in: path("a")), [])
    }

    func test_ответОставитьОбаКладётНовыйФайлРядом() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        try write("b", "файл.txt", text: "прежнее")
        let answers = Answers(.copy)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(read(path("b", "файл.txt")), "прежнее")
        XCTAssertEqual(read(path("b", "файл (1).txt")), "новое")
        XCTAssertEqual(names(in: path("b")), ["файл (1).txt", "файл.txt"])
    }

    func test_ответПропуститьНичегоНеМеняет() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        try write("b", "файл.txt", text: "прежнее")
        let answers = Answers(.skip)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(read(path("b", "файл.txt")), "прежнее")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"])
    }

    func test_перемещениеСЗаменойНаОдномТоме() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        try write("b", "файл.txt", text: "прежнее")
        let answers = Answers(.replace)

        try await ops.moveItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(read(path("b", "файл.txt")), "новое")
        XCTAssertEqual(names(in: path("a")), [], "при перемещении источник уходит")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"])
    }

    func test_заменаМеждуТомамиПриКопированииИПеремещении() async throws {
        let disk = try TestDiskImage(megabytes: 4)
        defer { disk.detach() }
        let copied = try write("a", "копия.txt", text: "новое-1")
        let moved = try write("a", "перенос.txt", text: "новое-2")
        try "прежнее-1".write(toFile: disk.mountPoint + "/копия.txt", atomically: true, encoding: .utf8)
        try "прежнее-2".write(toFile: disk.mountPoint + "/перенос.txt", atomically: true, encoding: .utf8)
        let answers = Answers(.replace, .replace)

        try await ops.copyItems([item(at: copied)], to: disk.mountPoint, onConflict: { answers.next($0) })
        try await ops.moveItems([item(at: moved)], to: disk.mountPoint, onConflict: { answers.next($0) })

        XCTAssertEqual(answers.asked.count, 2)
        XCTAssertEqual(read(disk.mountPoint + "/копия.txt"), "новое-1")
        XCTAssertEqual(read(copied), "новое-1", "при копировании источник остаётся")
        XCTAssertEqual(read(disk.mountPoint + "/перенос.txt"), "новое-2")
        XCTAssertNil(read(moved), "при перемещении источник уходит")
        XCTAssertEqual(leftovers(in: disk.mountPoint), [])
    }

    func test_перемещениеСЗаменойМеждуЖёсткимиСсылкамиУбираетИсточник() async throws {
        let source = try write("a", "файл.txt", text: "одно и то же")
        try FileManager.default.linkItem(atPath: source, toPath: path("b", "файл.txt"))
        let answers = Answers(.replace)

        try await ops.moveItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(names(in: path("a")), [], "источник должен уйти")
        XCTAssertEqual(read(path("b", "файл.txt")), "одно и то же")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"])
    }

    // MARK: - Страховка: блокировка

    func test_заблокированныйПриёмникНеЗаменяетсяПриКопировании() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let old = try write("b", "файл.txt", text: "прежнее")
        XCTAssertEqual(chflags(old, UInt32(UF_IMMUTABLE)), 0)
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: source)], to: self.path("b"),
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "заблокированный файл заменить нельзя — об этом надо сказать")
        XCTAssertEqual(read(old), "прежнее")
        XCTAssertEqual(read(source), "новое")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"], "временных имён не остаётся")
    }

    func test_заблокированныйПриёмникНеЗаменяетсяПриПеремещении() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let old = try write("b", "файл.txt", text: "прежнее")
        XCTAssertEqual(chflags(old, UInt32(UF_IMMUTABLE)), 0)
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.moveItems([self.item(at: source)], to: self.path("b"),
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "заблокированный файл заменить нельзя — об этом надо сказать")
        XCTAssertEqual(read(old), "прежнее")
        XCTAssertEqual(read(source), "новое", "перемещение не состоялось — источник на месте")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"], "временных имён не остаётся")
    }

    func test_заблокированныйИсточникКопируетсяСЗаменойВместеСБлокировкой() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let old = try write("b", "файл.txt", text: "прежнее")
        XCTAssertEqual(chflags(source, UInt32(UF_IMMUTABLE)), 0)
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(read(old), "новое")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"], "временных имён не остаётся")
        XCTAssertTrue(isLocked(old), "блокировка переходит на копию")
    }

    // MARK: - Отмена, остаток прежней папки, список доступа

    func test_отменаПосредиЗаменыМеждуТомамиОставляетПрежнееИУбираетНачатуюКопию() throws {
        let disk = try TestDiskImage(megabytes: 4)
        defer { disk.detach() }
        try makeFolder("a", "Набор")
        try write("a", "Набор", "один.txt", text: "новое-1")
        try write("a", "Набор", "два.txt", text: "новое-2")
        let old = disk.mountPoint + "/Набор"
        try "прежнее".write(toFile: old, atomically: true, encoding: .utf8)
        var calls = 0

        XCTAssertThrowsError(try DarwinFileOperations.replace(
            from: path("a", "Набор"), to: old, move: false,
            // Не с первого вопроса: к отмене временная папка уже создана — её и надо убрать.
            shouldCancel: { calls += 1; return calls > 3 })) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.code, CocoaError.userCancelled.rawValue,
                           "отмена остаётся отменой, а не ошибкой замены")
        }

        XCTAssertGreaterThan(calls, 3, "до отмены дело дошло")
        XCTAssertEqual(read(old), "прежнее", "замена отменена — прежний файл на месте")
        XCTAssertEqual(leftovers(in: disk.mountPoint), [], "начатая копия убрана")
        XCTAssertEqual(names(in: path("a", "Набор")), ["два.txt", "один.txt"], "источник не тронут")
    }

    func test_заменаПапкиФайломНазываетОстатокКоторыйНеУдалился() async throws {
        let source = try write("a", "имя", text: "новое")
        try makeFolder("b", "имя")
        let locked = try write("b", "имя", "замок.txt", text: "прежнее")
        XCTAssertEqual(chflags(locked, UInt32(UF_IMMUTABLE)), 0)
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.copyItems([self.item(at: source)], to: self.path("b"),
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "прежняя папка удалена не целиком — об этом надо сказать")
        XCTAssertEqual(read(path("b", "имя")), "новое", "замена состоялась")
        let rest = leftovers(in: path("b"))
        XCTAssertEqual(rest.count, 1, "то, что не удалилось, лежит рядом под временным именем")
        if let name = rest.first {
            XCTAssertEqual(read(path("b", name, "замок.txt")), "прежнее", "заблокированный файл цел")
            XCTAssertTrue(error?.localizedDescription.contains(name) == true,
                          "ошибка называет, где лежит остаток: \(error?.localizedDescription ?? "")")
        }
    }

    func test_файлСЗапретомУдаленияВСпискеДоступаЗаменяетПрежнийИСохраняетЗапрет() async throws {
        // Источник на другом томе: туда копия идёт через copyfile и несёт список доступа с собой.
        let disk = try TestDiskImage(megabytes: 4)
        defer { disk.detach() }
        let source = disk.mountPoint + "/файл.txt"
        try "новое".write(toFile: source, atomically: true, encoding: .utf8)
        _ = TestDiskImage.run("/bin/chmod", ["+a", "everyone deny delete", source])
        guard hasAccessList(source) else { throw XCTSkip("на томе образа списки доступа не ставятся") }
        let old = try write("b", "файл.txt", text: "прежнее")
        let answers = Answers(.replace)

        try await ops.copyItems([item(at: source)], to: path("b"), onConflict: { answers.next($0) })

        XCTAssertEqual(read(old), "новое")
        XCTAssertEqual(names(in: path("b")), ["файл.txt"], "временных имён не остаётся")
        XCTAssertTrue(hasAccessList(old), "запрет из списка доступа переходит на копию")
    }

    // MARK: - Архивы: «Заменить» при копировании из архива и при упаковке

    /// Архив zip с одним файлом внутри.
    private func makeZip(_ archive: String, containing name: String, text: String) throws {
        let folder = try makeFolder("zip-\(UUID().uuidString.prefix(6))")
        let file = (folder as NSString).appendingPathComponent(name)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        let made = TestDiskImage.run("/usr/bin/zip", ["-q", "-j", archive, file])
        XCTAssertEqual(made.status, 0, made.output)
    }

    /// Объект по пути, которого может и не быть на диске: запись архива (путь внутри
    /// архива) либо пропавший источник упаковки.
    private func entry(_ path: String) -> FileItem {
        let name = (path as NSString).lastPathComponent
        return FileItem(path: path, name: name, fileExtension: (name as NSString).pathExtension,
                        size: 0, isDirectory: false, isHidden: false, isSymlink: false,
                        permissions: "-rw-r--r--", dateModified: Date())
    }

    private func entryNames(of archive: String) -> [String] {
        ((try? CoreBridgeService().listArchiveEntries(archivePath: archive)) ?? [])
            .map(\.path).sorted()
    }

    func test_копированиеИзАрхива_ЗаписьНеИзвлекласьПрежнийФайлОстаётся() throws {
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: "есть.txt", text: "из архива")
        let old = try write("b", "нет.txt", text: "прежнее")
        let answers = Answers(.replace)

        XCTAssertThrowsError(try ops.copyItemsFromArchive(
            [entry("нет.txt")], archivePath: archive, to: path("b"),
            onConflict: { answers.next($0) }))

        XCTAssertEqual(answers.asked.count, 1, "о замене спросили")
        XCTAssertEqual(read(old), "прежнее", "новой копии нет — прежний файл должен остаться")
        XCTAssertEqual(leftovers(in: path("b")), [])
    }

    func test_копированиеИзАрхива_ЗаменаСтавитЗаписьНаМестоПрежнегоФайла() throws {
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: "запись.txt", text: "из архива")
        let old = try write("b", "запись.txt", text: "прежнее")
        let answers = Answers(.replace)

        try ops.copyItemsFromArchive([entry("запись.txt")], archivePath: archive, to: path("b"),
                                     onConflict: { answers.next($0) })

        XCTAssertEqual(read(old), "из архива")
        XCTAssertEqual(names(in: path("b")), ["запись.txt"], "временных имён не остаётся")
    }

    func test_упаковка_НеУдаласьПрежнийАрхивОстаётся() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let archive = path("b", "архив.zip")
        try makeZip(archive, containing: "старое.txt", text: "прежнее")
        let before = try Data(contentsOf: URL(fileURLWithPath: archive))
        // Второго источника нет на диске — упаковка на нём остановится.
        let missing = entry(path("a", "пропал.txt"))
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.packItems([self.item(at: source), missing], to: archive, format: .zip,
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "упаковка не удалась — об этом сказано")
        XCTAssertEqual(answers.asked.count, 1, "о замене спросили")
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: archive)), before,
                       "новый архив не получился — прежний должен остаться как был")
        XCTAssertEqual(leftovers(in: path("b")), [], "недописанный архив убран")
    }

    func test_упаковка_ЗаменаСтавитНовыйАрхивНаМестоПрежнего() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let archive = path("b", "архив.zip")
        try makeZip(archive, containing: "старое.txt", text: "прежнее")
        let answers = Answers(.replace)

        try await ops.packItems([item(at: source)], to: archive, format: .zip,
                                onConflict: { answers.next($0) })

        XCTAssertEqual(entryNames(of: archive), ["файл.txt"], "в архиве новое содержимое")
        XCTAssertEqual(names(in: path("b")), ["архив.zip"], "временных имён не остаётся")
    }

    func test_упаковкаПоОтдельности_НеУдаласьПрежнийАрхивОстаётся() async throws {
        // Архив называется по объекту: «пропал.zip» рядом с назначением уже есть.
        let archive = path("b", "пропал.zip")
        try makeZip(archive, containing: "старое.txt", text: "прежнее")
        let before = try Data(contentsOf: URL(fileURLWithPath: archive))
        let missing = entry(path("a", "пропал.txt"))
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.packItems([missing], to: self.path("b", "общий.zip"), format: .zip,
                                         separateArchives: true,
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error)
        XCTAssertEqual(answers.asked.count, 1, "о замене спросили")
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: archive)), before)
        XCTAssertEqual(leftovers(in: path("b")), [])
    }

    /// Файл, который есть, но читать его нельзя: упаковка его сосчитает, откроет выходной
    /// архив, начнёт писать — и на нём встанет.
    private func writeUnreadable(_ relative: String...) throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try "тайна".write(toFile: p, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: p)
        return p
    }

    /// Отчёт о ходе в никуда — для упаковки без окна, как её ведёт очередь.
    private final class QuietReporter: OperationProgressReporter, @unchecked Sendable {
        nonisolated var isCancelled: Bool { false }
        nonisolated var isPaused: Bool { false }
        nonisolated var isSentToQueue: Bool { false }
        func update(currentFile: String, progress: Double, bytesDone: Int64, bytesTotal: Int64,
                    filesDone: Int, filesTotal: Int) {}
        func close() {}
    }

    func test_упаковка_ИсточникНеЧитаетсяПрежнийАрхивОстаётся() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let closed = try writeUnreadable("a", "закрыт.txt")
        let archive = path("b", "архив.zip")
        try makeZip(archive, containing: "старое.txt", text: "прежнее")
        let before = try Data(contentsOf: URL(fileURLWithPath: archive))
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.packItems([self.item(at: source), self.item(at: closed)],
                                         to: archive, format: .zip,
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "упаковка не удалась — об этом сказано")
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: archive)), before,
                       "новый архив не получился — прежний должен остаться как был")
        XCTAssertEqual(names(in: path("b")), ["архив.zip"], "недописанный архив убран")
    }

    func test_упаковка_НеУдаласьНедописанныйАрхивНеОстаётся() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let closed = try writeUnreadable("a", "закрыт.txt")
        let archive = path("b", "архив.zip")

        let error = await attempt {
            try await self.ops.packItems([self.item(at: source), self.item(at: closed)],
                                         to: archive, format: .zip,
                                         onConflict: { _ in .cancel })
        }

        XCTAssertNotNil(error, "упаковка не удалась — об этом сказано")
        XCTAssertEqual(names(in: path("b")), [], "половины архива после неудачи не остаётся")
    }

    func test_упаковкаБезОкна_ИсточникНеЧитаетсяПрежнийАрхивОстаётся() throws {
        let source = try write("a", "файл.txt", text: "новое")
        let closed = try writeUnreadable("a", "закрыт.txt")
        let archive = path("b", "архив.zip")
        try makeZip(archive, containing: "старое.txt", text: "прежнее")
        let before = try Data(contentsOf: URL(fileURLWithPath: archive))

        XCTAssertThrowsError(try ops.packSingleArchiveBackground(
            [item(at: source), item(at: closed)], to: archive, format: .zip,
            compressionLevel: 6, preservePaths: true, includeSubfolders: true,
            links: .stored, reporter: QuietReporter()))

        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: archive)), before,
                       "новый архив не получился — прежний должен остаться как был")
        XCTAssertEqual(names(in: path("b")), ["архив.zip"], "недописанный архив убран")
    }

    func test_упаковкаБезОкна_НовыйАрхивВстаётНаМестоПрежнего() throws {
        let source = try write("a", "файл.txt", text: "новое")
        let archive = path("b", "архив.zip")
        try makeZip(archive, containing: "старое.txt", text: "прежнее")

        try ops.packSingleArchiveBackground(
            [item(at: source)], to: archive, format: .zip,
            compressionLevel: 6, preservePaths: true, includeSubfolders: true,
            links: .stored, reporter: QuietReporter())

        XCTAssertEqual(entryNames(of: archive), ["файл.txt"], "в архиве новое содержимое")
        XCTAssertEqual(names(in: path("b")), ["архив.zip"], "временных имён не остаётся")
    }

    // Образ диска собирает hdiutil, а не ядро: дорога своя, а прежний образ беречь так же.

    /// Имя тома подключённого образа и текст файла в его корне.
    private func mounted(_ image: String, file: String) throws -> (volume: String?, text: String?) {
        let mountPoint = path("mnt")
        let attach = TestDiskImage.run("/usr/bin/hdiutil",
                                       ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint, image])
        guard attach.status == 0 else {
            XCTFail("образ не подключается: \(attach.output)")
            return (nil, nil)
        }
        defer { _ = TestDiskImage.run("/usr/bin/hdiutil", ["detach", "-force", mountPoint]) }
        let volume = try URL(fileURLWithPath: mountPoint)
            .resourceValues(forKeys: [.volumeNameKey]).volumeName
        return (volume, read((mountPoint as NSString).appendingPathComponent(file)))
    }

    func test_упаковкаВОбраз_НеУдаласьПрежнийОбразОстаётся() async throws {
        let image = try write("b", "образ.dmg", text: "прежний образ")
        // Источника нет на диске — hdiutil на нём остановится.
        let missing = entry(path("a", "пропал.txt"))
        let answers = Answers(.replace)

        let error = await attempt {
            try await self.ops.packItems([missing], to: image, format: .dmg,
                                         onConflict: { answers.next($0) })
        }

        XCTAssertNotNil(error, "образ не собрался — об этом сказано")
        XCTAssertEqual(answers.asked.count, 1, "о замене спросили")
        XCTAssertEqual(read(image), "прежний образ",
                       "новый образ не получился — прежний должен остаться как был")
        XCTAssertEqual(names(in: path("b")), ["образ.dmg"], "недописанный образ убран")
    }

    func test_упаковкаВОбраз_ЗаменаСтавитОбразСТомомПоИмениАрхива() async throws {
        let source = try write("a", "файл.txt", text: "новое")
        let image = try write("b", "образ.dmg", text: "прежний образ")
        let answers = Answers(.replace)

        try await ops.packItems([item(at: source)], to: image, format: .dmg,
                                onConflict: { answers.next($0) })

        XCTAssertEqual(names(in: path("b")), ["образ.dmg"], "временных имён не остаётся")
        let result = try mounted(image, file: "файл.txt")
        XCTAssertEqual(result.text, "новое", "в образе новое содержимое")
        XCTAssertEqual(result.volume, "образ", "том назван по имени образа, а не по временному")
    }

    func test_упаковкаВОбразБезОкна_ЗаменаСтавитОбразСТомомПоИмениАрхива() throws {
        let source = try write("a", "файл.txt", text: "новое")
        let image = try write("b", "образ.dmg", text: "прежний образ")

        try ops.packSingleArchiveBackground(
            [item(at: source)], to: image, format: .dmg,
            compressionLevel: 6, preservePaths: true, includeSubfolders: true,
            links: .stored, reporter: QuietReporter())

        XCTAssertEqual(names(in: path("b")), ["образ.dmg"], "временных имён не остаётся")
        let result = try mounted(image, file: "файл.txt")
        XCTAssertEqual(result.text, "новое", "в образе новое содержимое")
        XCTAssertEqual(result.volume, "образ", "том назван по имени образа, а не по временному")
    }
}
