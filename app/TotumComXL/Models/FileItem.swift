import Foundation

struct FileItem: Identifiable, Hashable {
    /// Relative subpath shown instead of the bare name while the panel is in branch view
    /// (Ctrl+B). Display-only: every operation keeps using `name` and `path`.
    var branchPath: String? = nil

    let path: String
    let name: String
    let fileExtension: String
    let size: UInt64
    let isDirectory: Bool
    let isHidden: Bool
    let isSymlink: Bool
    /// A Finder alias: a small file holding a bookmark to another one. Unlike a symlink it keeps
    /// working after its target is renamed or moved — and unlike a symlink, only Finder and Mac
    /// apps understand it.
    let isAlias: Bool
    let symlinkTarget: String?
    /// Names this file answers to. 0 means the listing never measured it — a names-only
    /// pass, a remote or a virtual entry — which is NOT the same as "one name".
    let hardlinkCount: UInt
    let permissions: String
    let dateModified: Date
    let dateCreated: Date?
    let dateAdded: Date?
    let owner: String
    /// Direct children of a directory, `.` and `..` excluded; -1 when the filesystem was never
    /// asked. Only the bulk listing fills it, so remote and virtual listings leave it unknown.
    let entryCount: Int

    var id: String { path }

    /// A directory the filesystem confirmed holds nothing. Distinct from "size not computed yet":
    /// both carry `size == 0`, and only this one may be shown as a size.
    var isEmptyDirectory: Bool { isDirectory && entryCount == 0 }

    /// File has more than one hard link (not a directory, not a symlink)
    var isHardlink: Bool { !isDirectory && !isSymlink && hardlinkCount > 1 }

    /// A `.app` application bundle (a directory whose name ends in `.app`).
    /// NB: `fileExtension` is empty for directories, so derive it from the name.
    var isAppBundle: Bool { isDirectory && (name as NSString).pathExtension.lowercased() == "app" }

    init(path: String,
         name: String,
         fileExtension: String,
         size: UInt64,
         isDirectory: Bool,
         isHidden: Bool,
         isSymlink: Bool,
         isAlias: Bool = false,
         symlinkTarget: String? = nil,
         hardlinkCount: UInt = 0,
         permissions: String,
         dateModified: Date,
         dateCreated: Date? = nil,
         dateAdded: Date? = nil,
         owner: String = "",
         entryCount: Int = -1) {
        self.path = path
        self.name = name
        self.fileExtension = fileExtension
        self.size = size
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isAlias = isAlias
        self.symlinkTarget = symlinkTarget
        self.hardlinkCount = hardlinkCount
        self.permissions = permissions
        self.dateModified = dateModified
        self.dateCreated = dateCreated
        self.dateAdded = dateAdded
        self.owner = owner
        self.entryCount = entryCount
    }

    /// Create a FileItem from a filesystem path by reading attributes.
    /// Returns nil if the path does not exist.
    static func fromPath(_ path: String) -> FileItem? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let isLink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
        let size = (attrs[.size] as? UInt64) ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date()
        let created = attrs[.creationDate] as? Date
        let added: Date? = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
        let ownerName = (attrs[.ownerAccountName] as? String) ?? ""
        let perms = String(format: "%o", (attrs[.posixPermissions] as? Int) ?? 0)
        let name = url.lastPathComponent
        let ext = isDir ? "" : url.pathExtension
        let isHidden = name.hasPrefix(".")
        var linkTarget: String?
        if isLink {
            if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
                if dest.hasPrefix("/") {
                    linkTarget = dest
                } else {
                    linkTarget = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardized.path
                }
            }
        }
        let nlink = (attrs[.referenceCount] as? UInt) ?? 1
        // isAliasFile is true for symlinks as well — only a non-symlink carrying it is an alias.
        let isAlias = !isLink && ((try? url.resourceValues(forKeys: [.isAliasFileKey]))?
            .isAliasFile ?? false)
        return FileItem(
            path: path, name: name, fileExtension: ext,
            size: size, isDirectory: isDir, isHidden: isHidden,
            isSymlink: isLink, isAlias: isAlias, symlinkTarget: linkTarget,
            hardlinkCount: nlink, permissions: perms,
            dateModified: modified, dateCreated: created, dateAdded: added, owner: ownerName
        )
    }

    /// What the Type column says: the extension in capitals, or a word — in the program's
    /// language, not English on a Russian screen.
    var typeDisplayName: String {
        if name == ".." {
            return L("type.parent")
        }
        if isDirectory {
            return L("type.folder")
        }
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedExtension.isEmpty {
            return L("type.file")
        }
        return normalizedExtension.uppercased()
    }

    var typeSortKey: String {
        if isDirectory {
            return "0_folder"
        }
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedExtension.isEmpty {
            return "1_file"
        }
        return "2_\(normalizedExtension)"
    }

    var colorCategoryKey: String {
        if isDirectory {
            return "directory"
        }
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedExtension.isEmpty {
            return "file"
        }
        return normalizedExtension
    }

    func withSize(_ newSize: UInt64) -> FileItem {
        FileItem(
            path: path,
            name: name,
            fileExtension: fileExtension,
            size: newSize,
            isDirectory: isDirectory,
            isHidden: isHidden,
            isSymlink: isSymlink,
            symlinkTarget: symlinkTarget,
            hardlinkCount: hardlinkCount,
            permissions: permissions,
            dateModified: dateModified,
            dateCreated: dateCreated,
            dateAdded: dateAdded,
            owner: owner,
            entryCount: entryCount
        )
    }
}
