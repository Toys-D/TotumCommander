import AppKit
import IOKit

/// Does this Mac have a trackpad that measures how hard you press — and is the user willing to
/// use it?
///
/// Asked of the system every time rather than remembered in a file: the answer changes under
/// our feet. A Magic Trackpad is plugged into a desktop Mac and the feature appears; it is
/// unplugged and it goes; the user turns "Force Click and haptic feedback" off in System
/// Settings and the hardware is still there but the answer is no. A remembered answer would be
/// wrong at exactly the moment something changed.
enum ForceTouchSupport {

    /// One trackpad, as the system describes it.
    struct Device {
        let name: String
        /// The hardware can measure pressure.
        let forceSupported: Bool
        /// The user switched force click off in System Settings.
        let forceSuppressed: Bool
        /// It can click back — the Taptic actuator.
        let actuationSupported: Bool

        var isUsable: Bool { forceSupported && !forceSuppressed }
    }

    /// Every multitouch device attached right now.
    static func devices() -> [Device] {
        var found: [Device] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleMultitouchDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            // "ForceSuppressed" lives inside the device's copy of the multitouch preferences —
            // the same switch the Trackpad page in System Settings writes.
            let preferences = property("MultitouchPreferences") as? [String: Any]
            found.append(Device(
                name: property("Product") as? String ?? "",
                forceSupported: (property("ForceSupported") as? Bool) ?? false,
                forceSuppressed: (preferences?["ForceSuppressed"] as? Bool) ?? false,
                actuationSupported: (property("ActuationSupported") as? Bool) ?? false))
        }
        return found
    }

    /// Is a deep press available at all? True when ANY attached trackpad can measure pressure
    /// and the user has not switched it off.
    static var isAvailable: Bool {
        devices().contains { $0.isUsable }
    }

    /// The hardware is there but switched off in System Settings — worth saying, because the
    /// fix is one click away in the right place, and it is not our switch to flip.
    static var isSuppressedBySystem: Bool {
        let all = devices()
        return all.contains { $0.forceSupported } && !all.contains { $0.isUsable }
    }

    // MARK: - What a deep press does

    /// Deliberately a choice, not a fixed behaviour: macOS binds force click to Look Up, and
    /// Finder binds it to Quick Look, so people arrive with different expectations.
    enum Action: String, CaseIterable {
        /// Nothing — the press is left to the system.
        case off
        /// The one activation path: enter the folder, run the app, open the file.
        case open
        /// The viewer, as F3 does.
        case view

        var titleKey: String { "settings.forceClick.\(rawValue)" }
    }

    static let actionKey = "fcxl.forceClickAction"

    static var action: Action {
        guard isAvailable else { return .off }
        let raw = UserDefaults.standard.string(forKey: actionKey) ?? Action.open.rawValue
        return Action(rawValue: raw) ?? .open
    }
}

/// The deep press, as a view can use it.
///
/// A pressure event arrives as a stream: stage 1 is the ordinary click, stage 2 is the press
/// past the second detent. Only the CROSSING into stage 2 is a command — the stream keeps
/// arriving while the finger stays down, and acting on each one would open a folder ten times.
struct DeepPressDetector {
    private var stage = 0

    /// Feed every pressureChange event here. Returns true exactly once per deep press.
    mutating func crossedIntoDeepPress(_ event: NSEvent) -> Bool {
        let previous = stage
        stage = event.stage
        return previous < 2 && stage >= 2
    }
}
