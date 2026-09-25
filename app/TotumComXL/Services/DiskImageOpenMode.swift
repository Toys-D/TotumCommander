import Foundation

/// Which road a `.dmg` takes when it is activated.
///
/// Both roads mount the image and both leave the volume in the drive bar — the difference is
/// who shows it. The system route hands the file to DiskImageMounter, whose documented default
/// for a read-only image is to open the volume in a Finder window: that is where a vendor's
/// "drag the app onto Applications" poster comes from — the background picture and the icon
/// positions live in the volume's own `.DS_Store`, and only Finder draws them. The panel route
/// attaches quietly with `hdiutil -noautoopen` and steps into the volume in place, which is
/// what a commander is for when the image holds files rather than an installer.
///
/// Neither is right for everyone, so this is a setting rather than a verdict; Shift+Enter and
/// the context menu always offer the road that is not the default.
enum DiskImageOpenMode: String, CaseIterable {
    /// Hand the image to the system — it mounts it and shows the image's own window.
    case finder
    /// Mount it ourselves and enter the volume in the panel.
    case panel

    static let defaultsKey = "fcxl.diskImageOpen"

    /// Finder's way is the default: a disk image is nearly always an installer, and its window
    /// is the instruction sheet for it.
    static let fallback: DiskImageOpenMode = .finder

    var titleKey: String {
        switch self {
        case .finder: return "settings.diskImageOpen.finder"
        case .panel: return "settings.diskImageOpen.panel"
        }
    }

    /// The road offered by Shift+Enter and the context menu — always the other one.
    var opposite: DiskImageOpenMode {
        self == .finder ? .panel : .finder
    }

    static var chosen: DiskImageOpenMode {
        chosen(savedRawValue: UserDefaults.standard.string(forKey: defaultsKey))
    }

    /// The decision alone, testable without touching the defaults database.
    nonisolated static func chosen(savedRawValue: String?) -> DiskImageOpenMode {
        guard let savedRawValue, let mode = DiskImageOpenMode(rawValue: savedRawValue) else {
            return fallback
        }
        return mode
    }

    /// True for a path this setting governs.
    ///
    /// `.dmg`, `.cdr`, `.toast`, `.sparseimage` — по расширению: файл может и не существовать,
    /// а слишком битый образ идёт той же дорогой. `.iso` — по содержимому: под этим именем
    /// нередко лежит обыкновенный DMG (UDIF с подписью «koly» в хвосте) — так раздают
    /// программы, — и libarchive его не читает, а DiskImageMounter монтирует. Настоящий
    /// ISO9660 остаётся архивом: его удобнее листать, не монтируя.
    nonisolated static func isDiskImage(_ path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "dmg", "cdr", "toast", "sparseimage": return true
        case "iso": return hasUDIFTrailer(path)
        default: return false
        }
    }

    /// Хвост образа UDIF: последние 512 байт — блок «koly». Читаются только они.
    nonisolated static func hasUDIFTrailer(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 512 else { return false }
        try? handle.seek(toOffset: size - 512)
        guard let tail = try? handle.read(upToCount: 4) else { return false }
        return tail == Data("koly".utf8)
    }
}
