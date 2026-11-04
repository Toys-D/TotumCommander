import AppKit
import Foundation

/// App language. `.system` follows the Mac's own language list; the others force one.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case russian = "ru"
    case english = "en"

    var id: String { rawValue }

    /// Shown in Settings. The named languages are written in themselves, so the entry reads
    /// correctly whatever the interface is currently in.
    var displayName: String {
        switch self {
        case .system:  return L("settings.language.system")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    static let defaultsKey = "fcxl.appLanguage"

    /// What the user picked, or `.system` when nothing was chosen yet.
    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let value = AppLanguage(rawValue: raw) else { return .system }
        return value
    }

    /// The language code to actually load. For `.system`, the first of the user's preferred
    /// languages that we ship — anything else falls back to English rather than raw keys.
    var resolvedCode: String {
        switch self {
        case .russian: return "ru"
        case .english: return "en"
        case .system:
            for preferred in Locale.preferredLanguages {
                let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
                if base == "ru" || base == "en" { return base }
            }
            return "en"
        }
    }
}

extension AppLanguage {
    /// Locale for anything the user READS — dates, numbers. Without it Foundation formats with
    /// the SYSTEM locale, so a Russian Mac showed Russian dates inside an English UI.
    /// Parsing formatters (e.g. the WebDAV RFC-1123 one) must keep their own fixed locale.
    ///
    /// Only the LANGUAGE is overridden; the region is kept from the Mac. Forcing the bare code
    /// ("en") would also throw away the regional date order and the 24-hour-time setting, so a
    /// British user reading English would drop from "29/12/2025, 14:20" to "12/29/25, 2:20 PM"
    /// — a change nobody asked for, and one that would hit even the default `.system` setting.
    ///
    /// Resolved ONCE per launch, exactly like `localizationBundle`: `current` reads UserDefaults
    /// live, so a computed property would flip every date the moment the language changed while
    /// all the strings stayed in the old one — the half-translated UI the restart prompt exists
    /// to prevent.
    static let displayLocale: Locale = {
        guard current != .system else { return .current }
        var components = Locale.Components(locale: .current)
        components.languageComponents.languageCode = Locale.LanguageCode(current.resolvedCode)
        return Locale(components: components)
    }()
}

extension DateFormatter {
    /// Formatter for on-screen dates, in the app's language.
    static func fcxlDisplay(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.displayLocale
        f.dateStyle = date
        f.timeStyle = time
        return f
    }
}

extension AppLanguage {
    /// Quit and come back. A helper process waits for THIS process to actually exit before
    /// reopening the bundle — launching straight away races the still-running instance and
    /// macOS just re-activates the old one instead of starting the new.
    /// - Returns: false when the helper could not be started, so the caller can keep the app
    ///   alive instead of quitting into nothing.
    @MainActor
    @discardableResult
    static func relaunchApp() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path travels as an ARGUMENT, never inside the script text: sh's double quotes do
        // not disable $, backtick or backslash, and those are all legal in a folder name. An
        // interpolated path like ".../Apps $HOME/Totum Commander.app" would be mangled, `open`
        // would fail, and the app — already terminating — would simply never come back.
        task.arguments = ["-c",
            "while kill -0 \"$2\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$1\"",
            "fcxl-relaunch",
            Bundle.main.bundlePath,
            String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try task.run()
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}

/// The bundle strings are read from. Resolved ONCE per launch on purpose: the AppKit main
/// menu, already-built windows and cached strings would not pick up a mid-session swap, so
/// rather than show a half-translated UI the Settings pane asks for a restart.
private let localizationBundle: Bundle = {
    let code = AppLanguage.current.resolvedCode
    if let path = AppResources.bundle.path(forResource: code, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    if let path = AppResources.bundle.path(forResource: "ru", ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    return AppResources.bundle
}()

/// Russian is kept as a second source: while the English translation is still incomplete, a
/// key that is missing from en.lproj shows in Russian instead of leaking a raw identifier
/// like "context.copy" into the UI.
private let fallbackBundle: Bundle = {
    guard let path = AppResources.bundle.path(forResource: "ru", ofType: "lproj"),
          let bundle = Bundle(path: path) else { return AppResources.bundle }
    return bundle
}()

private func localized(_ key: String) -> String {
    let missing = "\u{0}__missing__\u{0}"
    let value = NSLocalizedString(key, tableName: nil, bundle: localizationBundle,
                                  value: missing, comment: "")
    if value != missing { return value }
    return NSLocalizedString(key, tableName: nil, bundle: fallbackBundle, value: key, comment: "")
}

func L(_ key: String) -> String {
    localized(key)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: localized(key), locale: Locale.current, arguments: args)
}
