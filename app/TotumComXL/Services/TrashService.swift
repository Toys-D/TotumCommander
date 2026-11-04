import Foundation

/// The macOS Trash, as a place the panel can open.
///
/// Deliberately the SYSTEM Trash rather than a private one of our own: a second trash would mean
/// files Finder cannot see, two places to look for the same mistake, and a slow copy instead of an
/// instant rename whenever the file lives on another disk.
///
/// macOS keeps the "put back" information — where each item came from — in the Trash folder's own
/// `.DS_Store`, in `ptbL` (the original folder) and `ptbN` (the original name) records. There is no
/// public API for it, so it is parsed here; without it "restore" could only guess, which for a file
/// the user already deleted once is exactly the wrong thing to do.
enum TrashService {

    /// Virtual path the panel navigates to, the same trick `/NETWORK` uses.
    static let trashRoot = "/TRASH"

    static func isTrashPath(_ path: String) -> Bool {
        path == trashRoot || path.hasPrefix(trashRoot + "/")
    }

    /// Настоящая папка корзины на диске: `~/.Trash` или `/Volumes/<диск>/.Trashes/<uid>`.
    ///
    /// «/TRASH» — это вид, а файлы лежат вот здесь, и человек попадает сюда сам: список корзины
    /// плоский, зашёл в лежащую в ней папку, вышел обратно «..» — и стоит на настоящем пути.
    /// Для программы это была обычная папка: обычные колонки, обычное меню, — хотя человек
    /// никуда из корзины не уходил.
    static func isTrashFolder(_ path: String) -> Bool {
        // Дешёвая отсечка: почти всякий путь не про корзину, а перечень папок ходит по /Volumes.
        guard path.contains("/.Trash") else { return false }
        let clean = normalized(path)
        return trashFolders().contains { normalized($0.path) == clean }
    }

    /// Путь лежит в корзине: сама папка корзины или что угодно внутри неё.
    static func isInsideTrashFolder(_ path: String) -> Bool {
        guard path.contains("/.Trash") else { return false }
        let clean = normalized(path)
        return trashFolders().contains {
            let folder = normalized($0.path)
            return clean == folder || clean.hasPrefix(folder + "/")
        }
    }

    /// Путь без хвостовой косой черты и без «~»: два имени одной папки должны сравниваться равными.
    private static func normalized(_ path: String) -> String {
        var clean = (path as NSString).standardizingPath
        while clean.count > 1, clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }

    struct Entry {
        /// Where the file actually sits right now, inside a .Trash folder.
        let url: URL
        /// The name it had before deletion, when that is known — otherwise its name in the Trash,
        /// which macOS may have suffixed with a timestamp to avoid a collision.
        let displayName: String
        /// Absolute folder it was deleted from, or nil when the record is gone.
        let originalFolder: String?
        let deletedAt: Date?
        let isDirectory: Bool
        let size: UInt64

        /// Where restoring would put it back.
        var restoreDestination: String? {
            guard let originalFolder else { return nil }
            return (originalFolder as NSString).appendingPathComponent(displayName)
        }
    }

    enum TrashError: LocalizedError {
        case noOriginalLocation(String)
        case destinationTaken(String)

        var errorDescription: String? {
            switch self {
            case .noOriginalLocation(let name): return L("trash.error.noOrigin", name)
            case .destinationTaken(let name):   return L("trash.error.taken", name)
            }
        }
    }

    // MARK: - Locations

    /// Every Trash folder that belongs to this user: the home one, plus one per mounted volume.
    /// A file deleted from an external disk never reaches ~/.Trash — it stays on that disk, and a
    /// trash view that only read the home folder would silently hide it.
    static func trashFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders = [home.appendingPathComponent(".Trash")]
        // Удалённое из iCloud Drive лежит в его собственной корзине, и Finder показывает
        // её вместе с общей: без неё в нашей корзине не хватало файла, который в Finder есть.
        // Записей возврата там нет — восстановить такой файл нельзя, стереть можно.
        let cloudTrash = home.appendingPathComponent("Library/Mobile Documents/.Trash")
        var cloudIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cloudTrash.path, isDirectory: &cloudIsDir),
           cloudIsDir.boolValue {
            folders.append(cloudTrash)
        }
        let uid = String(getuid())
        let volumes = (try? FileManager.default.contentsOfDirectory(
            atPath: "/Volumes")) ?? []
        for volume in volumes {
            let candidate = URL(fileURLWithPath: "/Volumes")
                .appendingPathComponent(volume)
                .appendingPathComponent(".Trashes")
                .appendingPathComponent(uid)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                folders.append(candidate)
            }
        }
        return folders
    }

    // MARK: - Listing

    static func entries() -> [Entry] {
        var result: [Entry] = []
        for folder in trashFolders() {
            let putBack = PutBackIndex.parse(folder.appendingPathComponent(".DS_Store"))
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                          .addedToDirectoryDateKey, .totalFileAllocatedSizeKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])) ?? []
            for url in contents {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let record = putBack[url.lastPathComponent]
                result.append(Entry(
                    url: url,
                    displayName: record?.name ?? url.lastPathComponent,
                    originalFolder: record.map { "/" + $0.folder.trimmingSlashes() },
                    deletedAt: values?.addedToDirectoryDate,
                    isDirectory: values?.isDirectory ?? false,
                    size: UInt64(values?.fileSize ?? 0)))
            }
        }
        // Newest first: the thing just deleted is the thing being looked for.
        return result.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// The trash as the panel understands it. `path` stays the REAL location so viewing (F3),
    /// icons and previews keep working with no special cases; only the name shown is the original.
    static func items() -> [FileItem] {
        entries().map { entry in
            FileItem(
                path: entry.url.path,
                name: entry.displayName,
                fileExtension: entry.isDirectory
                    ? "" : (entry.displayName as NSString).pathExtension,
                size: entry.size,
                isDirectory: entry.isDirectory,
                isHidden: false,
                isSymlink: false,
                permissions: entry.isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
                dateModified: (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date(),
                dateCreated: nil,
                // The panel's "Added" column is literally the deletion time here.
                dateAdded: entry.deletedAt,
                owner: entry.originalFolder ?? "")
        }
    }

    /// Origin folder for a file currently in the Trash, for the "From" column and the dialogs.
    static func originalFolder(forTrashedPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        let record = PutBackIndex.parse(folder.appendingPathComponent(".DS_Store"))[url.lastPathComponent]
        return record.map { "/" + $0.folder.trimmingSlashes() }
    }

    // MARK: - Restore

    /// Put items back where they came from. Returns the paths they now live at.
    ///
    /// Never overwrites and never invents a location: an item whose record is gone, or whose old
    /// place is occupied, is reported rather than dropped somewhere plausible.
    @discardableResult
    static func restore(_ entries: [Entry]) throws -> [String] {
        var restored: [String] = []
        for entry in entries {
            guard let destination = entry.restoreDestination else {
                throw TrashError.noOriginalLocation(entry.displayName)
            }
            guard !FileManager.default.fileExists(atPath: destination) else {
                throw TrashError.destinationTaken(entry.displayName)
            }
            let parent = (destination as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent,
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: entry.url.path, toPath: destination)
            restored.append(destination)
        }
        return restored
    }

    /// Restore by the paths the panel holds, which are the real in-Trash locations.
    @discardableResult
    static func restore(paths: [String]) throws -> [String] {
        let wanted = Set(paths)
        return try restore(entries().filter { wanted.contains($0.url.path) })
    }

    // MARK: - Leftovers

    /// Скрытые остатки после стирания видимого — прежде всего `.DS_Store`, индекс возврата:
    /// оставь его, и он помнил бы файлы, которых больше нет. Само стирание идёт через службу
    /// операций (`FileOperationsService.emptyTrash`) — с прогрессом и отменой; сюда попадает
    /// только то, чего в списке корзины не видно. Первая же неудача — наружу, а не в `try?`.
    static func removeLeftovers() throws {
        for folder in trashFolders() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in contents {
                try FileManager.default.removeItem(
                    atPath: (folder.path as NSString).appendingPathComponent(name))
            }
        }
    }

    /// Total bytes sitting in the Trash — what "Empty" is about to destroy.
    static func totalSize() -> UInt64 {
        entries().reduce(0) { $0 + $1.size }
    }

    static var isEmpty: Bool { entries().isEmpty }
}

// MARK: - .DS_Store put-back records

/// Reads the `ptbL` / `ptbN` records macOS writes into a Trash folder's `.DS_Store`.
///
/// The layout of one record is
///
///     <UInt32 nameLength><name UTF-16BE><4-byte id><4-byte type><payload>
///
/// where id is `ptbL` (original folder) or `ptbN` (original name) and type is `ustr`: a UInt32
/// length in UTF-16 code units followed by the text.
///
/// Rather than walking the B-tree this scans for the ids and recovers each record's key by
/// stepping backwards until a length prefix matches — the file is a cache macOS rewrites at will,
/// so tolerating whatever shape it is in beats insisting on a full parse that could throw the
/// whole index away over one unexpected block.
enum PutBackIndex {

    struct Record {
        let folder: String
        let name: String
    }

    /// Trash file name → where it came from.
    static func parse(_ url: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: url), data.count > 8 else { return [:] }

        var folders: [String: String] = [:]
        var names: [String: String] = [:]

        for (id, sink) in [("ptbL", 0), ("ptbN", 1)] {
            var index = 0
            let marker = Array(id.utf8)
            while let found = data.firstRange(of: marker, in: index..<data.count) {
                let at = found.lowerBound
                index = at + 4
                guard let key = keyEndingAt(at, in: data),
                      readASCII(data, at + 4, 4) == "ustr",
                      let value = readUString(data, at + 8) else { continue }
                if sink == 0 { folders[key] = value } else { names[key] = value }
            }
        }

        var result: [String: Record] = [:]
        for (key, folder) in folders {
            // A record needs both halves: a folder without a name cannot say what to call the
            // restored file, and macOS always writes the pair.
            guard let name = names[key] else { continue }
            result[key] = Record(folder: folder, name: name)
        }
        return result
    }

    // MARK: - Primitives

    /// The record key (a UTF-16BE name) that ends right where the id begins.
    private static func keyEndingAt(_ end: Int, in data: Data) -> String? {
        // 255 is the longest name any of these filesystems allows.
        for length in 1...255 {
            let start = end - 2 * length - 4
            guard start >= 0 else { return nil }
            guard readUInt32(data, start) == UInt32(length) else { continue }
            return decodeUTF16BE(data, start + 4, 2 * length)
        }
        return nil
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
             | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func readASCII(_ data: Data, _ offset: Int, _ count: Int) -> String? {
        guard offset >= 0, offset + count <= data.count else { return nil }
        let base = data.startIndex + offset
        return String(bytes: data[base..<(base + count)], encoding: .ascii)
    }

    private static func readUString(_ data: Data, _ offset: Int) -> String? {
        guard let units = readUInt32(data, offset), units > 0, units <= 4096 else { return nil }
        return decodeUTF16BE(data, offset + 4, 2 * Int(units))
    }

    private static func decodeUTF16BE(_ data: Data, _ offset: Int, _ byteCount: Int) -> String? {
        guard offset >= 0, byteCount > 0, offset + byteCount <= data.count else { return nil }
        let base = data.startIndex + offset
        return String(data: data[base..<(base + byteCount)], encoding: .utf16BigEndian)
    }
}

private extension Data {
    /// Index of `pattern` within `range`, or nil.
    func firstRange(of pattern: [UInt8], in range: Range<Int>) -> Range<Int>? {
        guard !pattern.isEmpty, range.lowerBound >= 0,
              range.upperBound <= count else { return nil }
        let limit = range.upperBound - pattern.count
        guard limit >= range.lowerBound else { return nil }
        var index = range.lowerBound
        while index <= limit {
            var matched = true
            for offset in 0..<pattern.count where self[startIndex + index + offset] != pattern[offset] {
                matched = false
                break
            }
            if matched { return index..<(index + pattern.count) }
            index += 1
        }
        return nil
    }
}

private extension String {
    /// "Users/dimas/Documents/" → "Users/dimas/Documents". The records carry a trailing slash and
    /// no leading one; callers want a plain absolute path.
    func trimmingSlashes() -> String {
        var text = self
        while text.hasSuffix("/") { text.removeLast() }
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }
}
