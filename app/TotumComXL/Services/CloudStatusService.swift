import Foundation

/// Where a file in iCloud Drive actually is right now.
///
/// The distinction the Finder draws with a little cloud, and the one that matters when the
/// network is gone: a file can be listed in the folder and not be on this Mac at all.
enum CloudState: Equatable {
    /// Not an iCloud file — an ordinary file on this disk.
    case local
    /// On this Mac and up to date.
    case here
    /// Only in the cloud: the name is there, the contents are not.
    case inCloudOnly
    /// Coming down right now.
    case downloading(Double?)
    /// Going up right now — until this finishes, the file cannot be removed from the disk.
    case uploading
    /// On this Mac, but the cloud has a newer version.
    case outdated

    var isCloud: Bool { self != .local }
}

/// Reading and changing what iCloud Drive keeps on this Mac.
///
/// Two commands are worth having: bring a file down so it works without the network, and put
/// one back to free space. Neither is a delete — the file stays in iCloud either way, and the
/// program says so in those words.
enum CloudStatusService {

    /// The tail macOS gives the placeholder that stands in for a file that is not downloaded:
    /// ".Документ.pdf.icloud". Shown to the person as "Документ.pdf" — the dot-file is
    /// plumbing, and a list full of them reads as garbage.
    static let placeholderSuffix = ".icloud"

    private static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsUploadedKey,
    ]

    /// Is this path inside iCloud Drive at all? Cheap enough for a whole listing: one string
    /// comparison, no disk access.
    static func isInCloudDrive(_ path: String) -> Bool {
        path.hasPrefix(cloudDriveRoot) || path.contains("/Library/Mobile Documents/")
    }

    static let cloudDriveRoot =
        NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"

    /// True when iCloud Drive is switched on for this Mac RIGHT NOW.
    ///
    /// The existence of the folder is not the answer: switching iCloud Drive off in System
    /// Settings offers to keep a local copy, and that copy stays on disk under the same name
    /// — the entry would go on pointing at a dead place. Two things have to hold: somebody is
    /// signed into iCloud (the identity token), and the folder is still an iCloud folder
    /// rather than an ordinary leftover.
    static var isAvailable: Bool {
        guard FileManager.default.ubiquityIdentityToken != nil else { return false }
        guard let values = try? URL(fileURLWithPath: cloudDriveRoot)
            .resourceValues(forKeys: [.isUbiquitousItemKey]) else { return false }
        return values.isUbiquitousItem == true
    }

    /// Ответ, посчитанный один раз. Нужен, чтобы `isAvailable` не звался из отрисовки.
    private static var cachedAvailability: Bool?

    /// Дешёвое первое мнение — для рисования полосы дисков.
    ///
    /// `isAvailable` спрашивает у системы опознавательный знак учётной записи iCloud, а тот
    /// поднимает службу CloudDocs, и она в ответ обходит Рабочий стол и Документы, проверяя,
    /// не корни ли они синхронизации. Измерено на этой машине (перехватом вызовов): это
    /// случалось через 0,2 с после старта, ДО первого окна, потому что вопрос задавался прямо
    /// из отрисовки полосы дисков. Полосе для чипа достаточно знать, что папка есть.
    static var isAvailableFast: Bool {
        if let cachedAvailability { return cachedAvailability }
        return FileManager.default.fileExists(atPath: cloudDriveRoot)
    }

    /// Спросить по-настоящему и запомнить. Звать вне отрисовки: поднимает CloudDocs.
    @discardableResult
    static func refreshAvailability() -> Bool {
        let value = isAvailable
        cachedAvailability = value
        return value
    }

    /// Забыть ответ — когда в iCloud вошли или вышли.
    static func forgetAvailability() { cachedAvailability = nil }

    static func state(of path: String) -> CloudState {
        // A placeholder IS the "only in the cloud" case: the real file has no bytes here.
        if (path as NSString).lastPathComponent.hasSuffix(placeholderSuffix),
           (path as NSString).lastPathComponent.hasPrefix(".") {
            return .inCloudOnly
        }
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return .local }

        if values.ubiquitousItemIsDownloading == true { return .downloading(nil) }
        if values.ubiquitousItemIsUploading == true { return .uploading }

        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current):       return .here
        case .some(.downloaded):    return .outdated
        case .some(.notDownloaded): return .inCloudOnly
        default:                    return .here
        }
    }

    /// Has this file reached the cloud? Until it has, taking it off the disk would destroy the
    /// only copy — which is exactly why the system refuses, and why the program must not offer.
    static func isUploaded(_ path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]) else { return false }
        return values.ubiquitousItemIsUploaded ?? false
    }

    /// The name to SHOW for a path — a placeholder gives back the real file's name.
    static func displayName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(placeholderSuffix) else { return name }
        return String(name.dropFirst().dropLast(placeholderSuffix.count))
    }

}
