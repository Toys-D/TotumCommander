import Foundation

/// A ceiling on how fast transfers may go, so a big upload does not take the whole line with
/// it and leave nothing for a video call.
///
/// Kept as a handful of presets rather than a free number: nobody knows their line in bytes
/// per second, and a typed 1000 that meant "1 MB/s" would quietly be a thousand times slower
/// than intended. Zero means no ceiling at all, which is the default.
///
/// Read fresh at the start of every transfer instead of pushed to live connections, so a
/// change takes effect on the next file rather than on the next launch.
enum TransferSpeedLimit {

    static let key = "fcxl.transferSpeedLimitKBps"

    /// In kilobytes per second; zero is "as fast as it goes".
    static let choices: [Int] = [0, 128, 256, 512, 1024, 2048, 5120, 10240]

    static var kilobytesPerSecond: Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? 0
    }

    /// What the transfer clients want — bytes, not kilobytes.
    static var bytesPerSecond: Int64 {
        Int64(max(0, kilobytesPerSecond)) * 1024
    }

    /// "Без ограничения", "512 КБ/с", "2 МБ/с" — megabytes once the number gets unwieldy.
    static func label(forKilobytesPerSecond kbps: Int) -> String {
        guard kbps > 0 else { return L("settings.speedLimit.none") }
        if kbps >= 1024, kbps % 1024 == 0 {
            return L("settings.speedLimit.megabytes", kbps / 1024)
        }
        return L("settings.speedLimit.kilobytes", kbps)
    }
}
