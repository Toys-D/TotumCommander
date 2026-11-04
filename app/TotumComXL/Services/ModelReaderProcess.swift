import FCXLBridgeObjC
import Foundation

/// Чтение модели ОТДЕЛЬНЫМ процессом.
///
/// Библиотека чтения моделей падает на некоторых файлах — и не только на нарочно битых.
/// Проверено на её же наборе образцов (1021 файл): падение с сигналом 11 дают
/// `malformed_sparse.gltf`, `malformed_zero_numvertices.md2`, три файла MD5 с
/// переполнением номеров, `malformed_property_index_oob.3mf` — и, что важнее,
/// совершенно обычный `camera.ogex`, обычный куб со светом и камерой.
///
/// В файловом менеджере такое недопустимо: человек листает папку с моделями, нажимает
/// F3 — и программа исчезает вместе со всей очередью работ. Поэтому читает модель не
/// сама программа, а её же исполняемый файл, запущенный отдельно со служебным ключом:
/// упадёт он — мы увидим это как «не прочитано» и останемся жить.
enum ModelReaderProcess {

    /// Служебный ключ. Тот же приём, что и у `--fcxl-resource-check`.
    static let flag = "--fcxl-read-model"

    /// Дольше этого не ждём: разбор бывает не только падучим, но и зависающим.
    static let deadline: TimeInterval = 90

    enum Failure: Error {
        /// Процесс упал (сигнал) или вышел с ошибкой.
        case died(String)
        /// Не дождались.
        case timedOut
        /// Ответ пришёл, но разобрать его не удалось.
        case damagedAnswer
        /// Нечем читать: не нашли собственный исполняемый файл.
        case noReader
    }

    // MARK: - Сторона программы

    /// Имя нашего исполняемого файла. Служебный ключ понимает только он.
    static let executableName = "TotumComXL"

    /// Годится ли этот исполняемый файл на роль читателя.
    ///
    /// В тестах и в отладочных запусках рядом оказывается `xctest` — он про наш ключ
    /// ничего не знает и просто выйдет с ошибкой. В таком случае читаем на месте: защита
    /// от падения нужна человеку за файловым менеджером, а не тесту.
    static func canServe(executablePath: String) -> Bool {
        (executablePath as NSString).lastPathComponent == executableName
    }

    static func read(path: String) throws -> [Model3DMesh] {
        guard let executable = AppResources.liveExecutablePath() else { throw Failure.noReader }
        guard canServe(executablePath: executable) else { return try readHere(path: path) }
        let answer = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-model-\(UUID().uuidString).blob")
        defer { try? FileManager.default.removeItem(at: answer) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [flag, path, answer.path]
        // Ни окна, ни звука: это тот же самый исполняемый файл, и запускается он как
        // обычная служебная программа.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let waited = waitFor(process, until: Date().addingTimeInterval(deadline))
        guard waited else {
            process.terminate()
            throw Failure.timedOut
        }
        guard process.terminationStatus == 0, process.terminationReason == .exit else {
            throw Failure.died(describe(process))
        }
        guard let data = try? Data(contentsOf: answer), let meshes = ModelBlob.decode(data) else {
            throw Failure.damagedAnswer
        }
        return meshes
    }

    /// Чтение в этом же процессе — запасной путь (см. canServe).
    private static func readHere(path: String) throws -> [Model3DMesh] {
        guard let loaded = try? FCXLModelBridge.loadModel(atPath: path) else {
            throw Failure.died("в этом же процессе")
        }
        return loaded.meshes.map(Model3DMesh.init(bridge:))
    }

    private static func waitFor(_ process: Process, until end: Date) -> Bool {
        while process.isRunning {
            if Date() > end { return false }
            usleep(20_000)
        }
        return true
    }

    static func describe(_ process: Process) -> String {
        process.terminationReason == .uncaughtSignal
            ? "сигнал \(process.terminationStatus)"
            : "код \(process.terminationStatus)"
    }

    // MARK: - Сторона читающего процесса

    /// Разобрать служебные доводы. nil — ключа нет, программа запускается как обычно.
    static func request(in arguments: [String]) -> (input: String, output: String)? {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 2 else {
            return nil
        }
        return (arguments[index + 1], arguments[index + 2])
    }

    /// То, чем занят отдельный процесс: прочитать и записать ответ. Код выхода — наружу.
    static func serve(input: String, output: String) -> Int32 {
        guard let loaded = try? FCXLModelBridge.loadModel(atPath: input) else { return 2 }
        let meshes = loaded.meshes.map(Model3DMesh.init(bridge:))
        guard !meshes.isEmpty else { return 3 }
        do {
            try ModelBlob.encode(meshes).write(to: URL(fileURLWithPath: output))
            return 0
        } catch {
            return 4
        }
    }
}
