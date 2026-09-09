import Foundation

/// The look the program ships with.
///
/// A fresh install used to open in bare system colours — white chrome, stock cursor, default
/// columns — while every screenshot and every hour of tuning happened on the author's Mac. The
/// author's own appearance settings now travel inside the program (DefaultStyle.plist) and are
/// REGISTERED as defaults on every launch: they answer wherever a person has not chosen
/// otherwise, a person's own choice always wins, and an update never overwrites it.
///
/// Registered, not written: nothing lands in the person's preferences file until they change
/// something themselves, and "reset" in the settings returns to this look, not to the void.
///
/// Everything a person could set is in the set — the theme too, so a new Mac opens light the
/// way the author's does — except what is one person's own: paths, tabs, connections, the
/// language (that follows the system), window frames. The cursor mask, a drawing, travels as
/// two PNGs beside the plist (see CursorMaskStore.shippedImage).
enum DefaultStyle {
    static let resourceName = "DefaultStyle"

    /// Keys that are one person's business and never a default, whatever the plist carries —
    /// a second line of defence behind the script that builds the file.
    static let personalPrefixes: [String] = [
        "leftPanelPath", "rightPanelPath", "panelTabs_", "fcxl.remoteConnections",
        "fcxl.appLanguage", "appLanguage", "fcxl.updates.", "fcxl.windowLaunch",
        "fcxl.windowWasFullScreen", "showHiddenFiles", "fcxl.customCursorMaskPreviewRevision",
        "fcxl.bookmarks", "fcxl.workspaces", "NSWindow Frame",
        "fcxl.folderRules", "fcxl.fileAssociations", "fcxl.externalEditor",
        "fcxl.controlServerEnabled", "fcxl.recentNetworkDrives", "fcxl.networkHostsCache",
        "fcxl.vault.", "wifiPhones", "fKeyMode", "fcxl.settingsLastSection",
        "fcxl.selectionMaskRecent", "fcxl.quickLookPanelFrame", "fcxl.dropStack",
        "fcxl.uninstallAskClaude", "monitor.", "fcxl.multiRename.presets", "fcxl.searchExclude",
        "tunnel.", "fcxl.gallery", "mainWindow.",
    ]

    static func isPersonal(_ key: String) -> Bool {
        key.hasSuffix("Migrated") || personalPrefixes.contains { key.hasPrefix($0) }
    }

    static func load(from bundle: Bundle = .module) -> [String: Any]? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return dictionary
    }

    /// Register the shipped look with `defaults`. Answers how many keys were registered —
    /// zero when the file is missing, which is a build problem, not a reason to crash.
    @discardableResult
    static func register(into defaults: UserDefaults = .standard, from bundle: Bundle = .module) -> Int {
        guard let style = load(from: bundle) else { return 0 }
        let shipped = style.filter { !isPersonal($0.key) }
        defaults.register(defaults: shipped)
        return shipped.count
    }
}
