import CryptoKit
import Foundation
import OSLog

/// Звук, которого macOS не знает, — во FLAC, который она играет.
///
/// Системный проигрыватель не открывает WMA, APE, RealAudio, DTS и VOC. Для них в программе
/// лежит маленький ffmpeg (scripts/fetch-ffmpeg.sh, собран только для звука): файл переводится
/// во FLAC — без потерь — в кэш программы, и просмотрщик играет его, как любой другой.
/// Переведённое помнится по пути, размеру и дате: тот же файл второй раз открывается сразу,
/// изменённый — переводится заново. Кэш держится в пределах гигабайта, старое уходит первым.
enum AudioTranscoder {

    /// Расширения, которые играются через перевод.
    static let foreignExtensions: Set<String> = ["wma", "ape", "ra", "dts", "voc"]

    static func needsTranscoding(_ path: String) -> Bool {
        foreignExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// ffmpeg внутри бандла. Проверки подставляют свой.
    nonisolated(unsafe) static var helperPath: () -> String? = { bundledPath }

    nonisolated static var bundledPath: String? {
        let inside = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path
        return FileManager.default.isExecutableFile(atPath: inside) ? inside : nil
    }

    nonisolated(unsafe) static var cacheDirectory: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander")
        .appendingPathComponent("Audio")

    nonisolated(unsafe) static var cacheLimit: Int64 = 1 << 30

    private static let log = Logger(subsystem: "com.fcxl", category: "Audio")

    enum Failure: LocalizedError {
        case noHelper
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noHelper: return L("viewer.audio.noDecoder")
            case .failed(let reason): return String(format: L("viewer.audio.failed"), reason)
            }
        }
    }

    /// Где лежит перевод этого файла — по пути, размеру и дате изменения.
    static func cacheURL(for source: URL) -> URL? {
        // URL помнит однажды прочитанные свойства файла — изменённый файл иначе получил бы
        // старый перевод.
        var source = source
        source.removeAllCachedResourceValues()
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        let stamp = "\(source.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(String(digest.prefix(32)) + ".flac")
    }

    /// Перевести во FLAC и отдать файл, который macOS сыграет. Отмена задачи останавливает
    /// перевод: человек перешёл к другому файлу — этот больше не нужен.
    static func transcode(_ source: URL) async throws -> URL {
        guard let target = cacheURL(for: source) else { throw Failure.failed(source.lastPathComponent) }
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            // Свежая дата — чтобы уборка считала его недавним.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        guard let helper = helperPath() else { throw Failure.noHelper }
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let partial = target.deletingPathExtension().appendingPathExtension("partial.flac")
        try? fm.removeItem(at: partial)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                             "-i", source.path, "-map", "0:a:0", "-map_metadata", "0",
                             "-c:a", "flac", "-frame_size", "4096", "-f", "flac", partial.path]
        // Размер блока — обычный. RealAudio отдаёт звук кусочками по 160 выборок, и FLAC из
        // таких блоков системный проигрыватель отвергает («fmt?»), хоть файл и верный.
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            box.terminate()
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""

        guard status == 0, !Task.isCancelled, fm.fileExists(atPath: partial.path) else {
            try? fm.removeItem(at: partial)
            if Task.isCancelled { throw CancellationError() }
            log.error("перевод \(source.lastPathComponent, privacy: .public) не удался: \(message, privacy: .public)")
            throw Failure.failed(message.isEmpty ? source.lastPathComponent : message)
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: partial, to: target)
        prune()
        return target
    }

    /// Держать кэш в пределах `cacheLimit`: новое остаётся, старое уходит.
    static func prune() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys)
        else { return }
        let dated = files.compactMap { url -> (URL, Date, Int64)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, Int64(v.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        var total: Int64 = 0
        for (url, _, size) in dated {
            total += size
            if total > cacheLimit { try? fm.removeItem(at: url) }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }
}
