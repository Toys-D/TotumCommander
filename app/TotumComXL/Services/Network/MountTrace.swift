import Foundation
import os

/// Что и когда делала программа, подключая и отключая тома — с миллисекундами.
///
/// Пишется в системный журнал уровнем notice, он сохраняется на диске. Читать вместе с тем,
/// что записали о том же diskarbitrationd и ядро: `bash scripts/mount_trace.sh` собирает всё
/// в одну ленту. Так видно, где прошли секунды: в нашем коде, в diskutil или в самой системе.
/// Строки короткие и без секретов: имя тома, шаг, миллисекунды.
enum MountTrace {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
                                    category: "MountTrace")

    static func log(_ message: String, since started: Date? = nil) {
        if let started {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.notice("\(message, privacy: .public) — \(ms, privacy: .public) ms")
        } else {
            log.notice("\(message, privacy: .public)")
        }
    }
}
