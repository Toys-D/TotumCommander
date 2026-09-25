import AppKit
import SwiftUI

/// The text found inside the chosen files, one card per file.
///
/// The window opens straight away and fills in as the pages are read: a scan of thirty pages
/// takes the better part of a minute, and a program that shows nothing for that long looks like
/// a program that has died.
struct TextRecognitionDialogView: View {
    let session: FCXLDialogSession<Bool>
    let paths: [String]

    /// What one file gave.
    struct Result: Identifiable {
        var id: String { path }
        let path: String
        var pages: [TextRecognitionService.DocumentPage] = []
        var isDone = false
        /// The page being read right now, and how many there are.
        var progress: (Int, Int) = (0, 0)

        var name: String { (path as NSString).lastPathComponent }
        var text: String { pages.map(\.text).joined(separator: "\n\n") }
        /// True when every page came with its own text — nothing had to be recognised.
        var wholeFromTextLayer: Bool { !pages.isEmpty && pages.allSatisfy(\.fromTextLayer) }
    }

    @State private var results: [Result]
    @State private var isWorking = true
    @State private var cancelled = false
    @State private var savedNote: String?
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    init(session: FCXLDialogSession<Bool>, paths: [String]) {
        self.session = session
        self.paths = paths
        // Seeded here rather than in onAppear: the very first frame then already shows which
        // files are being read, instead of an empty box.
        _results = State(initialValue: paths.map { Result(path: $0) })
    }

    private var everything: String {
        results.filter { !$0.text.isEmpty }
            .map { results.count > 1 ? "— \($0.name) —\n\($0.text)" : $0.text }
            .joined(separator: "\n\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("ocr.dialog.title"),
                             icon: "text.viewfinder",
                             iconBusy: isWorking)

            Text(L("ocr.dialog.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { result in
                        card(result)
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.horizontal, 20)

            HStack {
                if let savedNote {
                    Text(savedNote).font(.system(size: 11)).foregroundStyle(accent)
                } else if isWorking {
                    Text(L("ocr.dialog.working")).font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: L("ocr.dialog.done"), results.count,
                                results.filter { !$0.text.isEmpty }.count))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("button.close"), role: .normal) {
                    cancelled = true
                    session.finish(true)
                },
                FCXLDialogBarButton(title: L("ocr.dialog.save"), role: .normal,
                                    enabled: !everything.isEmpty) { saveBeside() },
                FCXLDialogBarButton(title: L("viewer.ocr.copyAll"), role: .primary,
                                    enabled: !everything.isEmpty) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(everything, forType: .string)
                    savedNote = L("ocr.dialog.copied")
                },
            ])
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear(perform: read)
        .onDisappear { cancelled = true }
    }

    @ViewBuilder
    private func card(_ result: Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(result.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if result.wholeFromTextLayer {
                    // Worth saying: this text is the document's own, letter for letter, not a
                    // reading of a picture of it.
                    Text(L("ocr.dialog.textLayer")).font(.system(size: 10)).foregroundStyle(accent)
                }
                Spacer()
                if !result.isDone {
                    if result.progress.1 > 1 {
                        Text(String(format: L("ocr.dialog.page"), result.progress.0 + 1,
                                    result.progress.1))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ProgressView().controlSize(.small)
                } else if result.pages.count > 1 {
                    Text(String(format: L("ocr.dialog.pages"), result.pages.count))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if result.isDone && result.text.isEmpty {
                Text(L("viewer.ocr.nothing")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !result.text.isEmpty {
                // Selectable, so a piece can be taken without copying the whole file.
                Text(result.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Read the files one after another, off the main thread, publishing each page as it lands.
    private func read() {
        DispatchQueue.global(qos: .userInitiated).async {
            for (index, path) in paths.enumerated() {
                if cancelled { return }
                let pages = TextRecognitionService.text(
                    ofFile: path,
                    shouldCancel: { cancelled },
                    onPage: { done, total in
                        DispatchQueue.main.async {
                            guard results.indices.contains(index) else { return }
                            results[index].progress = (done, total)
                        }
                    })
                DispatchQueue.main.async {
                    guard results.indices.contains(index) else { return }
                    results[index].pages = pages
                    results[index].isDone = true
                }
            }
            DispatchQueue.main.async { isWorking = false }
        }
    }

    /// Put each file's text in a .txt beside the file itself — where the person will look for it.
    private func saveBeside() {
        var written = 0
        for result in results where !result.text.isEmpty {
            let target = (result.path as NSString).deletingPathExtension + ".txt"
            guard (try? result.text.write(toFile: target, atomically: true,
                                          encoding: .utf8)) != nil else { continue }
            written += 1
        }
        savedNote = String(format: L("ocr.dialog.saved"), written)
    }
}
