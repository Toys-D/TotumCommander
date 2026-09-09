import Foundation
import FCXLBridgeObjC

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let size: UInt64
    let hash: String
    let files: [String]
}

struct SearchHit: Identifiable, Hashable {
    let path: String
    let name: String
    let lineNumber: UInt64?
    let column: UInt64?
    let lineContent: String?
    let dateModified: Date?
    let size: UInt64?
    let isDirectory: Bool

    var id: String {
        if let lineNumber {
            return "\(path)#\(lineNumber):\(column ?? 0)"
        }
        return path
    }
}

struct ArchiveListEntry: Hashable {
    let path: String
    let uncompressedSize: UInt64
    let compressedSize: UInt64
    let isDirectory: Bool
}

enum ArchiveCreationFormat: String, CaseIterable, Identifiable {
    case zip = "ZIP"
    case tar = "TAR"
    case tarGz = "TAR.GZ"
    case sevenZip = "7Z"
    case tarBz2 = "TAR.BZ2"
    case tarXz = "TAR.XZ"
    case tarZst = "TAR.ZST"
    case tarLz = "TAR.LZ"
    case tarLz4 = "TAR.LZ4"
    case iso = "ISO"

    var id: String { rawValue }
}

final class CoreBridgeService {
    private let fileSystemBridge = FCXLFileSystemBridge()
    private let searchBridge = FCXLSearchBridge()
    private let archiveBridge = FCXLArchiveBridge()

    func listDirectory(path: String, showHidden: Bool = false) throws -> [FileItem] {
        let rawItems = try fileSystemBridge.listDirectory(path, showHidden: showHidden)
        return convertRawFileItems(rawItems)
    }

    func listDirectoryFast(path: String, showHidden: Bool = false) throws -> [FileItem] {
        let rawItems = try fileSystemBridge.listDirectoryFast(path, showHidden: showHidden)
        return convertRawFileItems(rawItems, skipExpensiveFallback: true)
    }

    /// Ultra-fast listing via readdir() only — no stat() calls.
    /// Returns names, types, hidden flags. Size/dates/permissions/owner are empty.
    func listDirectoryNamesOnly(path: String, showHidden: Bool = false) throws -> [FileItem] {
        let rawItems = try fileSystemBridge.listDirectoryNamesOnly(path, showHidden: showHidden)
        return convertRawFileItems(rawItems, skipExpensiveFallback: true)
    }

    private func convertRawFileItems(_ rawItems: [[String: Any]], skipExpensiveFallback: Bool = false) -> [FileItem] {
        let fileManager = skipExpensiveFallback ? nil : FileManager.default
        return rawItems.compactMap { raw -> FileItem? in
            guard
                let name = raw["name"] as? String,
                let itemPath = raw["path"] as? String,
                let ext = raw["extension"] as? String,
                let isDirectory = raw["isDirectory"] as? Bool,
                let isHidden = raw["isHidden"] as? Bool,
                let isSymlink = raw["isSymlink"] as? Bool
            else {
                return nil
            }

            let sizeValue = (raw["size"] as? NSNumber)?.uint64Value ?? 0
            // -1 when the volume never reported one; only the bulk listing fills it.
            let entryCount = (raw["entryCount"] as? NSNumber)?.intValue ?? -1
            var permissions = raw["permissions"] as? String ?? ""
            var dateModified = raw["dateModified"] as? Date
            var dateCreated = raw["dateCreated"] as? Date
            var owner = raw["owner"] as? String ?? ""

            if let fileManager,
               permissions.isEmpty || dateModified == nil || dateCreated == nil || owner.isEmpty {
                if let attributes = try? fileManager.attributesOfItem(atPath: itemPath) {
                    if permissions.isEmpty {
                        let mask = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                        permissions = String(format: "%03o", mask & 0o777)
                    }
                    if dateModified == nil {
                        dateModified = attributes[.modificationDate] as? Date
                    }
                    if dateCreated == nil {
                        dateCreated = attributes[.creationDate] as? Date
                    }
                    if owner.isEmpty {
                        owner = (attributes[.ownerAccountName] as? String) ?? ""
                    }
                }
            }

            let dateAdded: Date? = try? URL(fileURLWithPath: itemPath)
                .resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate

            // Hard link count via lstat (cheap syscall, already cached by FS)
            var nlink: UInt = 1
            var statBuf = stat()
            if lstat(itemPath, &statBuf) == 0 {
                nlink = UInt(statBuf.st_nlink)
            }

            var linkTarget: String?
            if isSymlink {
                if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: itemPath) {
                    if dest.hasPrefix("/") {
                        linkTarget = dest
                    } else {
                        linkTarget = URL(fileURLWithPath: dest,
                                         relativeTo: URL(fileURLWithPath: itemPath).deletingLastPathComponent())
                            .standardized.path
                    }
                }
            }

            return FileItem(
                path: itemPath,
                name: name,
                fileExtension: ext,
                size: sizeValue,
                isDirectory: isDirectory,
                isHidden: isHidden,
                isSymlink: isSymlink,
                isAlias: (raw["isAlias"] as? Bool) ?? false,
                symlinkTarget: linkTarget,
                hardlinkCount: nlink,
                permissions: permissions,
                dateModified: dateModified ?? Date.distantPast,
                dateCreated: dateCreated,
                dateAdded: dateAdded,
                owner: owner,
                entryCount: entryCount
            )
        }
    }

    func parentPath(for path: String) throws -> String {
        let rawParent = try fileSystemBridge.parentPath(path)
        return rawParent as String
    }

    func listArchiveEntries(archivePath: String, password: String = "") throws -> [ArchiveListEntry] {
        let effective = password.isEmpty
            ? (ArchivePasswords.remembered(for: archivePath) ?? "") : password
        let rawItems = try archiveBridge.listEntries(inArchive: archivePath, password: effective)

        return rawItems.compactMap { raw in
            guard
                let entryPath = raw["path"] as? String,
                let isDirectory = raw["isDirectory"] as? Bool
            else {
                return nil
            }

            return ArchiveListEntry(
                path: entryPath,
                uncompressedSize: (raw["size"] as? NSNumber)?.uint64Value ?? 0,
                compressedSize: (raw["compressedSize"] as? NSNumber)?.uint64Value ?? 0,
                isDirectory: isDirectory
            )
        }
    }

    func extractArchiveAll(archivePath: String,
                           destinationPath: String,
                           overwriteExisting: Bool,
                           password: String = "",
                           progress: @escaping (String, Double, Int64, Int64, Int, Int) -> Void) throws {
        _ = try archiveBridge.extractAll(
            fromArchive: archivePath,
            toDestination: destinationPath,
            overwriteExisting: overwriteExisting,
            password: password.isEmpty
                ? (ArchivePasswords.remembered(for: archivePath) ?? "") : password
        ) { currentFile, progressValue, bytesDone, bytesTotal, filesDone, filesTotal in
            progress(
                currentFile,
                progressValue,
                bytesDone,
                bytesTotal,
                Int(filesDone),
                Int(filesTotal)
            )
        }
    }

    func extractArchiveEntry(archivePath: String,
                             entryPath: String,
                             destinationPath: String) throws {
        _ = try archiveBridge.extractEntry(
            inArchive: archivePath,
            entryPath: entryPath,
            destinationPath: destinationPath,
            password: ArchivePasswords.remembered(for: archivePath) ?? ""
        )
    }

    func createArchive(archivePath: String,
                       format: ArchiveCreationFormat,
                       sources: [String],
                       includeSubfolders: Bool,
                       preservePaths: Bool,
                       compressionLevel: Int,
                       password: String = "",
                       progress: ((String, Int64, Int64, Int, Int, Int64) -> Void)? = nil) throws {
        _ = try archiveBridge.createArchive(
            atPath: archivePath,
            format: format.rawValue,
            sources: sources,
            includeSubfolders: includeSubfolders,
            preservePaths: preservePaths,
            compressionLevel: compressionLevel,
            password: password,
            progressCallback: { currentFile, bytesRead, bytesTotal, filesDone, filesTotal, compressedBytes in
                progress?(
                    currentFile,
                    bytesRead,
                    bytesTotal,
                    Int(filesDone),
                    Int(filesTotal),
                    compressedBytes
                )
            }
        )
    }

    func addFilesToArchive(archivePath: String,
                           filePaths: [String],
                           basePath: String,
                           progress: ((String, Int64, Int64, Int, Int, Int64) -> Void)? = nil) throws {
        _ = try archiveBridge.addFiles(
            toArchive: archivePath,
            files: filePaths,
            basePath: basePath,
            progressCallback: { currentFile, bytesRead, bytesTotal, filesDone, filesTotal, compressedBytes in
                progress?(
                    currentFile,
                    bytesRead,
                    bytesTotal,
                    Int(filesDone),
                    Int(filesTotal),
                    compressedBytes
                )
            }
        )
    }

    func deleteEntriesFromArchive(archivePath: String,
                                  entryPaths: [String],
                                  progress: ((String, Int64, Int64, Int, Int, Int64) -> Void)? = nil) throws {
        _ = try archiveBridge.deleteEntries(
            fromArchive: archivePath,
            entries: entryPaths,
            progressCallback: { currentFile, bytesRead, bytesTotal, filesDone, filesTotal, compressedBytes in
                progress?(
                    currentFile,
                    bytesRead,
                    bytesTotal,
                    Int(filesDone),
                    Int(filesTotal),
                    compressedBytes
                )
            }
        )
    }

    func renameEntryInArchive(archivePath: String,
                              oldEntryPath: String,
                              newEntryPath: String,
                              progress: ((String, Int64, Int64, Int, Int, Int64) -> Void)? = nil) throws {
        _ = try archiveBridge.renameEntry(
            inArchive: archivePath,
            oldEntry: oldEntryPath,
            newEntry: newEntryPath,
            progressCallback: { currentFile, bytesRead, bytesTotal, filesDone, filesTotal, compressedBytes in
                progress?(
                    currentFile,
                    bytesRead,
                    bytesTotal,
                    Int(filesDone),
                    Int(filesTotal),
                    compressedBytes
                )
            }
        )
    }

    func cancelArchiveOperations() {
        archiveBridge.cancelCurrentArchiveOperation()
    }

    func copyItem(from source: String, to destination: String) throws {
        _ = try fileSystemBridge.copyItem(atPath: source, toPath: destination)
    }

    func moveItem(from source: String, to destination: String) throws {
        _ = try fileSystemBridge.moveItem(atPath: source, toPath: destination)
    }

    func trashItem(path: String) throws {
        _ = try fileSystemBridge.trashItem(atPath: path)
    }

    func createDirectory(path: String) throws {
        _ = try fileSystemBridge.createDirectory(atPath: path)
    }

    func homePath() -> String {
        NSHomeDirectory()
    }

    func searchFiles(rootPath: String,
                     pattern: String,
                     useRegex: Bool,
                     recursive: Bool = true,
                     includeHidden: Bool = false) throws -> [SearchHit] {
        let rawItems = try searchBridge.findFiles(
            atPath: rootPath,
            pattern: pattern,
            useRegex: useRegex,
            recursive: recursive,
            includeHidden: includeHidden
        )

        return rawItems.compactMap { raw in
            guard
                let path = raw["path"] as? String,
                let name = raw["name"] as? String
            else {
                return nil
            }

            return SearchHit(
                path: path,
                name: name,
                lineNumber: nil,
                column: nil,
                lineContent: nil,
                dateModified: raw["dateModified"] as? Date,
                size: (raw["size"] as? NSNumber)?.uint64Value,
                isDirectory: (raw["isDirectory"] as? NSNumber)?.boolValue ?? false
            )
        }
    }

    func advancedSearch(rootPath: String, pattern: String, useRegex: Bool,
                        recursive: Bool = true, includeHidden: Bool = false,
                        minSize: UInt64 = 0, maxSize: UInt64 = 0,
                        dateFrom: Date? = nil, dateTo: Date? = nil,
                        typeFilter: Int = 0,
                        excludePatterns: [String] = [],
                        onScanDir: ((String) -> Void)? = nil) throws -> [SearchHit] {
        let rawItems = try searchBridge.advancedSearch(
            atPath: rootPath, pattern: pattern, useRegex: useRegex,
            recursive: recursive, includeHidden: includeHidden,
            minSize: minSize, maxSize: maxSize,
            dateFrom: dateFrom?.timeIntervalSince1970 ?? 0,
            dateTo: dateTo?.timeIntervalSince1970 ?? 0,
            typeFilter: Int32(typeFilter),
            excludePatterns: excludePatterns,
            onScanDir: onScanDir
        )

        return rawItems.compactMap { raw in
            guard let path = raw["path"] as? String, let name = raw["name"] as? String else { return nil }
            return SearchHit(
                path: path, name: name,
                lineNumber: nil, column: nil, lineContent: nil,
                dateModified: raw["dateModified"] as? Date,
                size: (raw["size"] as? NSNumber)?.uint64Value,
                isDirectory: (raw["isDirectory"] as? NSNumber)?.boolValue ?? false
            )
        }
    }

    func findDuplicates(rootPath: String, mode: Int = 2, recursive: Bool = true,
                        excludePatterns: [String] = [],
                        onScanDir: ((String) -> Void)? = nil) throws -> [DuplicateGroup] {
        let rawGroups = try searchBridge.findDuplicates(atPath: rootPath, mode: Int32(mode),
                                                        recursive: recursive,
                                                        excludePatterns: excludePatterns,
                                                        onScanDir: onScanDir)

        return rawGroups.compactMap { raw in
            guard let files = raw["files"] as? [String] else { return nil }
            return DuplicateGroup(
                size: (raw["size"] as? NSNumber)?.uint64Value ?? 0,
                hash: raw["hash"] as? String ?? "",
                files: files
            )
        }
    }

    func searchContent(rootPath: String,
                       pattern: String,
                       useRegex: Bool,
                       recursive: Bool = true,
                       excludePatterns: [String] = [],
                       onScanDir: ((String) -> Void)? = nil) throws -> [SearchHit] {
        let rawItems = try searchBridge.findContent(
            atPath: rootPath,
            pattern: pattern,
            useRegex: useRegex,
            recursive: recursive,
            excludePatterns: excludePatterns,
            onScanDir: onScanDir
        )

        return rawItems.compactMap { raw in
            guard
                let path = raw["path"] as? String,
                let name = raw["name"] as? String
            else {
                return nil
            }

            return SearchHit(
                path: path,
                name: name,
                lineNumber: (raw["lineNumber"] as? NSNumber)?.uint64Value,
                column: (raw["column"] as? NSNumber)?.uint64Value,
                lineContent: raw["lineContent"] as? String,
                dateModified: nil,
                size: nil,
                isDirectory: false
            )
        }
    }

    func cancelSearch() {
        searchBridge.cancelSearch()
    }
}
