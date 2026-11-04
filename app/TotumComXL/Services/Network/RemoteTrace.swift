import Foundation
import os

/// След хождения по хранилищу: что попросили, сколько ждали, что пришло.
///
/// Пишется в системный журнал уровнем notice — он сохраняется на диске, и его можно
/// прочитать после: `log show --predicate 'category == "RemoteTrace"' --last 1h`.
/// Строки короткие и без секретов: путь, число элементов, миллисекунды.
/// Ключ `fcxl.remote.trace` дополнительно включает подробный журнал самого rclone.
enum RemoteTrace {
    static let key = "fcxl.remote.trace"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
                                    category: "RemoteTrace")

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    static func log(_ message: String, since started: Date? = nil) {
        if let started {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.notice("\(message, privacy: .public) — \(ms, privacy: .public) ms")
        } else {
            log.notice("\(message, privacy: .public)")
        }
    }
}
