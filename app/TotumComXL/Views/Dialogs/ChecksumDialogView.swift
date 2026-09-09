import AppKit
import SwiftUI
import FCXLBridgeObjC

/// One file's computed hash, or the error that stopped it.
struct ChecksumResult: Identifiable {
    let path: String
    var hash: String = ""
    var failed = false
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Algorithms the core exposes. Raw values double as the segmented control's labels.
enum ChecksumAlgorithm: String, CaseIterable, Identifiable {
    case md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256"
    var id: String { rawValue }
    /// Key used by the bridge's single-pass dictionary.
    var bridgeKey: String {
        switch self {
        case .md5:    return "md5"
        case .sha1:   return "sha1"
        case .sha256: return "sha256"
        }
    }
}

/// Checksum window: computes MD5 / SHA-1 / SHA-256 for the selected files, lets the user copy them
/// or save a checksum file, and verifies one file against a hash pasted from elsewhere.
///
/// All three digests come from a single pass over each file (the bridge reads the file once), so
/// switching algorithm in the UI never re-reads anything from disk.
struct ChecksumDialogView: View {
    let session: FCXLDialogSession<Bool>
    let paths: [String]

    @State private var algorithm: ChecksumAlgorithm = .sha256
    /// path → algorithm key → hash. Filled once, in the background.
    @State private var digests: [String: [String: String]] = [:]
    @State private var failedPaths: Set<String> = []
    @State private var progress: Int = 0
    @State private var finished = false
    @State private var expected = ""
    @State private var copiedPath: String?

    private var results: [ChecksumResult] {
        paths.map { path in
            ChecksumResult(path: path,
                           hash: digests[path]?[algorithm.bridgeKey] ?? "",
                           failed: failedPaths.contains(path))
        }
    }

    /// Verification is only meaningful against a single file.
    private var verifyTarget: ChecksumResult? {
        paths.count == 1 ? results.first : nil
    }

    /// Compare the pasted hash with every algorithm we computed, so the user can paste an MD5 while
    /// the SHA-256 tab is showing and still get an answer.
    private var verifyMatches: Bool? {
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty, let target = verifyTarget,
              let all = digests[target.path] else { return nil }
        return all.values.contains { $0.lowercased() == wanted }
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("checksum.title"),
                             subtitle: paths.count == 1
                                 ? (paths[0] as NSString).lastPathComponent
                                 : String(format: L("checksum.filesCount"), paths.count))

            ScrollView {
                VStack(spacing: 16) {
                    algorithmPicker
                    resultsCard
                    if verifyTarget != nil { verifyCard }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("checksum.copyAll"), role: .normal,
                                    enabled: finished) { copyAll() },
                FCXLDialogBarButton(title: L("checksum.save"), role: .normal,
                                    enabled: finished) { saveToFile() },
                FCXLDialogBarButton(title: L("button.close"), role: .primary) { session.finish(true) }
            ])
        }
        .task { await compute() }
    }

    // MARK: - Cards

    private var algorithmPicker: some View {
        Picker("", selection: $algorithm) {
            ForEach(ChecksumAlgorithm.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var resultsCard: some View {
        FCXLFormCard {
            if !finished {
                FCXLFormRow(showDivider: false) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(format: L("checksum.computing"), progress, paths.count))
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                    }
                }
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, r in
                    FCXLFormRow(showDivider: index < results.count - 1) {
                        VStack(alignment: .leading, spacing: 2) {
                            if paths.count > 1 {
                                Text(r.name).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Text(r.failed ? L("checksum.unreadable") : r.hash)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(r.failed ? .secondary : .primary)
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                                .help(r.failed ? "" : r.hash)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !r.failed {
                            Button {
                                copy(r.hash)
                                copiedPath = r.path
                            } label: {
                                Image(systemName: copiedPath == r.path ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help(L("checksum.copy"))
                        }
                    }
                }
            }
        }
    }

    private var verifyCard: some View {
        FCXLFormCard {
            FCXLFormRow(label: L("checksum.verify"), showDivider: false) {
                FCXLDialogTextField(text: $expected, placeholder: L("checksum.verify.placeholder"))
                    .frame(maxWidth: .infinity)
                switch verifyMatches {
                case .some(true):
                    Label(L("checksum.match"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.green).fixedSize()
                case .some(false):
                    Label(L("checksum.mismatch"), systemImage: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.red).fixedSize()
                case .none:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Work

    /// Hashes every file off the main thread; the dialog is modal and must stay responsive.
    private func compute() async {
        let targets = paths
        for path in targets {
            // Closing the dialog cancels this task, but a detached child does not inherit that —
            // without the check the app kept reading and hashing every remaining file in the
            // background after the user had walked away.
            if Task.isCancelled { return }
            let computed = await Task.detached(priority: .userInitiated) {
                // NSError** makes this throwing in Swift; a failure just marks the row unreadable.
                let bridge = FCXLToolsBridge()
                return try? bridge.allChecksumsForFile(atPath: path) as? [String: String]
            }.value
            if let computed { digests[path] = computed } else { failedPaths.insert(path) }
            progress += 1
        }
        finished = true
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One "hash  filename" line per file — the layout md5sum/shasum expect, so the output can be
    /// checked with the standard command-line tools.
    private var manifest: String {
        results.filter { !$0.failed }
            .map { "\($0.hash)  \($0.name)" }
            .joined(separator: "\n")
    }

    private func copyAll() {
        copy(manifest)
    }

    private func saveToFile() {
        let ext = algorithm == .md5 ? "md5" : (algorithm == .sha1 ? "sha1" : "sha256")
        let suggested = (paths.count == 1
            ? (paths[0] as NSString).lastPathComponent
            : (paths[0] as NSString).deletingLastPathComponent.components(separatedBy: "/").last
                ?? "checksums") + "." + ext
        guard let chosen = DialogService.shared.showSavePanel(title: L("checksum.title"),
                                                             defaultName: suggested,
                                                             allowedTypes: [ext]) else { return }
        let url = URL(fileURLWithPath: chosen)
        do {
            try (manifest + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // A read-only stick or a vanished volume: without this the dialog closed as if saved
            // and the user walked away believing the manifest exists.
            DialogService.shared.showError(title: L("checksum.saveFailedTitle"),
                                           message: error.localizedDescription)
        }
    }
}
