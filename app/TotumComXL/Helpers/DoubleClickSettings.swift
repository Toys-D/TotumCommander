import AppKit
import Foundation

enum DoubleClickSettings {
    static let intervalKey = "doubleClickIntervalSeconds"
    static let minimumIntervalSeconds: Double = 0.15
    static let maximumIntervalSeconds: Double = 1.20

    static var defaultIntervalSeconds: Double {
        clamp(NSEvent.doubleClickInterval, fallback: 0.5)
    }

    static func normalizedIntervalSeconds(_ rawValue: Double) -> Double {
        clamp(rawValue, fallback: defaultIntervalSeconds)
    }

    /// Current user-configured interval (reads from UserDefaults).
    static var currentInterval: Double {
        let raw = UserDefaults.standard.double(forKey: intervalKey)
        return raw > 0 ? normalizedIntervalSeconds(raw) : defaultIntervalSeconds
    }

    private static func clamp(_ value: Double, fallback: Double) -> Double {
        let candidate = value.isFinite ? value : fallback
        return min(max(candidate, minimumIntervalSeconds), maximumIntervalSeconds)
    }
}
