import AppKit
import Foundation

/// Archive-pack dialog: `run` presents the settings-style SwiftUI dialog
/// (PackDialogView in ArchiveDialogViews.swift); the archive-name logic lives in
/// the static helpers below (unit-tested — keep their behavior stable).
@MainActor
enum PackDialogController {

    /// Show the pack dialog modally; returns nil on Cancel/ESC.
    static func run(defaultArchivePath: String,
                    defaultFormat: ArchiveFormat,
                    selectedItemsCount: Int) -> ArchivePackDialogResult? {
        FCXLDialog.runModal(size: NSSize(width: 560, height: 620)) { session in
            PackDialogView(
                session: session,
                defaultArchivePath: defaultArchivePath,
                defaultFormat: defaultFormat,
                selectedItemsCount: selectedItemsCount
            )
        }
    }

    // MARK: - Name normalization (pure logic, unit-tested)

    nonisolated static func archiveNameSelectionRange(for name: String, format: ArchiveFormat) -> NSRange {
        let lowerName = name.lowercased()
        let targetExtension = format.fileExtension.lowercased()

        let utf16Length = (name as NSString).length
        let extensionLength = (format.fileExtension as NSString).length

        let baseLength: Int
        if lowerName.hasSuffix(targetExtension) && utf16Length > extensionLength {
            baseLength = utf16Length - extensionLength
        } else {
            baseLength = utf16Length
        }

        return NSRange(location: 0, length: max(0, baseLength))
    }

    nonisolated static func normalizedArchiveName(_ rawName: String, format: ArchiveFormat) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = trimmed.isEmpty ? L("pack.defaultName") : trimmed

        // If name already has the correct extension, return as-is
        let lower = fallbackName.lowercased()
        let targetExt = format.fileExtension.lowercased()
        if lower.hasSuffix(targetExt) && lower.count > targetExt.count {
            return fallbackName
        }

        // Strip any known archive extension
        let archiveSuffixes = [
            ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
            ".tar.zst", ".tzst", ".tar.lz4", ".tar.lz", ".tlz",
            ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z",
            ".zst", ".lz4", ".lz", ".iso", ".dmg"
        ]

        var baseName = fallbackName
        if let suffix = archiveSuffixes.first(where: { lower.hasSuffix($0) && lower.count > $0.count }) {
            baseName = String(fallbackName.dropLast(suffix.count))
        }

        // Handle partial extensions (user typed "file.zi", "file.", etc.)
        if baseName == fallbackName {
            let nsName = baseName as NSString
            let ext = nsName.pathExtension.lowercased()
            let partialArchiveExts = ["zi", "ta", "7", "bz", "xz", "tg", "zs", "l", "is", "tz", "tl", "dm"]
            if ext.isEmpty && baseName.hasSuffix(".") {
                baseName = String(baseName.dropLast())
            } else if partialArchiveExts.contains(ext) {
                baseName = nsName.deletingPathExtension
            }
        }

        if baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseName = L("pack.defaultName")
        }

        return baseName + format.fileExtension
    }
}
