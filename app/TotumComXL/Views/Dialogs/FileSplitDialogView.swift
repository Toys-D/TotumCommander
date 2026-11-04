import AppKit
import SwiftUI
import FCXLBridgeObjC

/// What the split window hands back, or nil if the user cancelled.
struct FileSplitRequest {
    let sourcePath: String
    let chunkBytes: UInt64
    let outputDirectory: String
    /// Also write a `<name>.sha256` next to the parts, so joining can prove the result is intact.
    let writeChecksum: Bool
}

/// Split a file into numbered parts (`name.ext.001`, `.002`, …) — the naming HJSplit and Total
/// Commander use, so the parts can be rejoined by other tools too.
struct FileSplitDialogView: View {
    let session: FCXLDialogSession<FileSplitRequest>
    let sourcePath: String
    let sourceSize: UInt64
    /// The other panel's folder — where a commander would put the parts by default.
    let defaultOutputDirectory: String

    /// Sizes worth offering: the media people actually split for, plus mail-attachment limits.
    private struct Preset: Identifiable {
        let id = UUID()
        let titleKey: String
        let bytes: UInt64
    }
    private static let presets: [Preset] = [
        Preset(titleKey: "split.preset.10mb",   bytes: 10 * 1_000_000),
        Preset(titleKey: "split.preset.25mb",   bytes: 25 * 1_000_000),
        Preset(titleKey: "split.preset.100mb",  bytes: 100 * 1_000_000),
        Preset(titleKey: "split.preset.700mb",  bytes: 700 * 1_000_000),
        Preset(titleKey: "split.preset.4700mb", bytes: 4_700 * 1_000_000),
    ]

    @State private var sizeText = "100"
    @State private var unitIsMB = true
    @State private var outputDirectory: String
    @State private var writeChecksum = true

    init(session: FCXLDialogSession<FileSplitRequest>, sourcePath: String,
         sourceSize: UInt64, defaultOutputDirectory: String) {
        self.session = session
        self.sourcePath = sourcePath
        self.sourceSize = sourceSize
        self.defaultOutputDirectory = defaultOutputDirectory
        _outputDirectory = State(initialValue: defaultOutputDirectory)
    }

    private var chunkBytes: UInt64 {
        let value = Double(sizeText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let multiplier: Double = unitIsMB ? 1_000_000 : 1_000
        return UInt64(max(0, value * multiplier))
    }

    private var partCount: Int {
        guard chunkBytes > 0 else { return 0 }
        return Int((sourceSize + chunkBytes - 1) / chunkBytes)
    }

    /// A part size of zero would loop forever, and one part means nothing was split.
    private var isValid: Bool { chunkBytes > 0 && partCount >= 1 }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("split.title"),
                             subtitle: (sourcePath as NSString).lastPathComponent)

            ScrollView {
                VStack(spacing: 16) {
                    sizeCard
                    destinationCard
                    summaryCard
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }

            FCXLDialogButtonBar(
                primaryTitle: L("split.action"),
                primaryEnabled: isValid,
                primaryAction: {
                    session.finish(FileSplitRequest(sourcePath: sourcePath,
                                                    chunkBytes: chunkBytes,
                                                    outputDirectory: outputDirectory,
                                                    writeChecksum: writeChecksum))
                },
                cancelTitle: L("button.cancel"),
                cancelAction: { session.cancel() })
        }
    }

    private var sizeCard: some View {
        FCXLFormCard {
            FCXLFormRow(label: L("split.partSize")) {
                FCXLDialogTextField(text: $sizeText, placeholder: "100")
                    .frame(width: 90)
                Picker("", selection: $unitIsMB) {
                    Text("MB").tag(true)
                    Text("KB").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 96)
                Spacer()
            }
            FCXLFormRow(label: L("split.presets"), showDivider: false) {
                HStack(spacing: 6) {
                    ForEach(Self.presets) { preset in
                        Button(L(preset.titleKey)) {
                            unitIsMB = true
                            sizeText = String(preset.bytes / 1_000_000)
                        }
                        // The bar style carries a hard 48pt height — inside a 38pt form row
                        // the presets ballooned past their line. Chips are the compact kin.
                        .buttonStyle(FCXLChipButtonStyle(compact: true))
                        .focusable(false)
                    }
                    Spacer()
                }
            }
        }
    }

    private var destinationCard: some View {
        FCXLFormCard {
            FCXLFormRow(label: L("split.destination"), showDivider: false) {
                Text(outputDirectory)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(outputDirectory)
                Button(L("split.choose")) { chooseDirectory() }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                    .focusable(false)
            }
        }
    }

    private var summaryCard: some View {
        FCXLFormCard {
            FCXLFormRow(label: L("split.result")) {
                Text(isValid
                     ? String(format: L("split.resultValue"), partCount,
                              ByteText.file(Int64(min(chunkBytes, UInt64(Int64.max)))))
                     : L("split.resultInvalid"))
                    .font(.system(size: 12))
                    .foregroundStyle(isValid ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FCXLFormRow(showDivider: false) {
                FCXLSwitch(isOn: $writeChecksum)
                Text(L("split.writeChecksum")).font(.system(size: 12))
                Spacer()
            }
            FCXLFormRow(showDivider: false) {
                Text(L("split.writeChecksum.hint"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chooseDirectory() {
        // The shared picker, which also lets the user create the destination folder — the private
        // copy forgot canCreateDirectories, so there was no way to split into a new folder.
        if let chosen = DialogService.shared.showFolderPicker(title: L("split.destination"),
                                                             defaultPath: outputDirectory) {
            outputDirectory = chosen
        }
    }
}

/// Join `name.ext.001`, `.002`, … back into one file. The parts are found from whichever one the
/// cursor is on, so the user never has to select them all by hand.
enum FileJoiner {
    /// Is this file one piece of a numbered set — "archive.zip.007"?
    static func isPart(_ path: String) -> Bool {
        let suffix = (path as NSString).pathExtension
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
            && !((path as NSString).deletingPathExtension as NSString).lastPathComponent.isEmpty
    }

    /// Sort part paths by their number, so 2 comes before 10.
    static func ordered(_ paths: [String]) -> [String] {
        paths.sorted {
            ($0 as NSString).pathExtension.compare(($1 as NSString).pathExtension,
                                                   options: .numeric) == .orderedAscending
        }
    }

    /// All sibling parts of a split set, in order, given any one of them. Returns nil when the file
    /// is not part of a numbered set.
    static func parts(forPartAt path: String) -> [String]? {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        // "archive.zip.007" → base "archive.zip", provided the suffix is all digits.
        let suffix = (name as NSString).pathExtension
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        let base = (name as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return nil }
        let siblings = entries.filter {
            ($0 as NSString).deletingPathExtension == base
                && !($0 as NSString).pathExtension.isEmpty
                && ($0 as NSString).pathExtension.allSatisfy(\.isNumber)
        }
        guard siblings.count > 1 else { return nil }
        return siblings
            .sorted { ($0 as NSString).pathExtension.compare(($1 as NSString).pathExtension,
                                                             options: .numeric) == .orderedAscending }
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// The name the joined file should get: the part numbering stripped off.
    static func joinedName(forPartAt path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// A checksum file written when the set was split, if it is still there.
    static func checksumFile(forBase base: String, in directory: String) -> String? {
        let candidate = (directory as NSString).appendingPathComponent(base + ".sha256")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
}

/// What the join window hands back, or nil if the user cancelled.
struct FileJoinRequest {
    let parts: [String]
    let outputPath: String
    /// Move the parts to the Trash once the result is known to be good.
    let deletePartsAfter: Bool
}

/// Join window: shows the set that was found, where the result will go, and offers to clear the
/// parts away afterwards.
struct FileJoinDialogView: View {
    let session: FCXLDialogSession<FileJoinRequest>
    let parts: [String]
    let outputPath: String
    /// Whether a `.sha256` written at split time is sitting next to the parts.
    let hasChecksum: Bool

    @State private var deleteParts = false

    private var totalBytes: UInt64 {
        parts.reduce(into: UInt64(0)) { sum, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
            sum += size ?? 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("join.title"),
                             subtitle: (outputPath as NSString).lastPathComponent)

            ScrollView {
                VStack(spacing: 16) {
                    FCXLFormCard {
                        FCXLFormRow(label: L("join.partsFound")) {
                            Text(String(format: L("join.partsValue"), parts.count,
                                        ByteText.file(Int64(min(totalBytes, UInt64(Int64.max))))))
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        FCXLFormRow(label: L("join.result"), showDivider: false) {
                            Text(outputPath)
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(outputPath)
                        }
                    }

                    FCXLFormCard {
                        FCXLFormRow(showDivider: false) {
                            Image(systemName: hasChecksum ? "checkmark.seal" : "questionmark.circle")
                                .foregroundStyle(hasChecksum ? .green : .secondary)
                            Text(L(hasChecksum ? "join.willVerify" : "join.noChecksum"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    FCXLFormCard {
                        FCXLFormRow(showDivider: false) {
                            FCXLSwitch(isOn: $deleteParts)
                            Text(L("join.deleteParts")).font(.system(size: 12))
                            Spacer()
                        }
                        FCXLFormRow(showDivider: false) {
                            // The wording changes with the situation, because the safety of this
                            // option depends entirely on whether the result can be verified.
                            Text(L(hasChecksum ? "join.deleteParts.hint" : "join.deleteParts.hintUnverified"))
                                .font(.system(size: 11))
                                .foregroundStyle(hasChecksum ? Color.secondary : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }

            FCXLDialogButtonBar(
                primaryTitle: L("join.action"),
                primaryEnabled: true,
                primaryAction: {
                    session.finish(FileJoinRequest(parts: parts, outputPath: outputPath,
                                                   deletePartsAfter: deleteParts))
                },
                cancelTitle: L("button.cancel"),
                cancelAction: { session.cancel() })
        }
    }
}
