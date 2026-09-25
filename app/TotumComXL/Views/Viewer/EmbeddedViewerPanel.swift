import SwiftUI
import Quartz

/// Safe container that manages QLPreviewView lifecycle manually.
/// QLPreviewView crashes if you call setPreviewItem after deactivation,
/// so we create a fresh instance for each new file instead of reusing.
private final class QLPreviewContainer: NSView {
    private var previewView: QLPreviewView?
    private var currentPath: String?

    func showFile(at path: String?) {
        guard path != currentPath else { return }
        currentPath = path

        // Remove old preview — avoids deactivated state crash
        previewView?.removeFromSuperview()
        previewView = nil

        guard let path, !path.isEmpty else { return }

        let pv = QLPreviewView(frame: bounds, style: .compact)!
        pv.autoresizingMask = [.width, .height]
        pv.previewItem = URL(fileURLWithPath: path) as QLPreviewItem
        addSubview(pv)
        previewView = pv
    }

    override func layout() {
        super.layout()
        previewView?.frame = bounds
    }
}

/// NSViewRepresentable wrapper — only passes file path, never touches QLPreviewView directly in updateNSView.
private struct EmbeddedQLPreview: NSViewRepresentable {
    let filePath: String?

    func makeNSView(context: Context) -> QLPreviewContainer {
        let container = QLPreviewContainer()
        container.showFile(at: filePath)
        return container
    }

    func updateNSView(_ nsView: QLPreviewContainer, context: Context) {
        nsView.showFile(at: filePath)
    }
}

/// Embedded file viewer that replaces the opposite panel.
/// Uses native Apple QLPreviewView — supports all file formats.
/// Dynamically tracks viewModel.cursorItem — updates as cursor moves.
struct EmbeddedViewerPanel: View {
    @ObservedObject var viewModel: PanelViewModel
    let onClose: () -> Void
    /// Needed to extract the file under the cursor when previewing inside an archive.
    var operations: FileOperationsService?

    /// On-disk temp path of the archived file under the cursor. Refreshed as the cursor moves
    /// so the preview follows the cursor inside an archive, just like on the file system.
    @State private var archiveTempPath: String?
    /// A drawing we read ourselves. Quick Look has no idea what a DXF is and answers with a
    /// grey icon, which is exactly what this panel showed before.
    @State private var drawing: DXFDocument?
    @State private var drawingPath: String?

    /// The cursor item (for name/size in the header), independent of where its bytes live.
    private var cursorFile: FileItem? {
        guard let item = viewModel.cursorItem, !item.isDirectory, item.name != ".." else { return nil }
        return item
    }

    /// The on-disk path to preview: the extracted temp inside an archive, the real path outside.
    private var displayPath: String? {
        if viewModel.insideArchive { return archiveTempPath }
        return cursorFile?.path
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye")
                    .foregroundColor(.secondary)
                Text(cursorFile?.name ?? "—")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let file = cursorFile {
                    Text(ByteText.file(Int64(file.size)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            if let path = displayPath,
               fileCategory(extension: (path as NSString).pathExtension) == .drawing {
                if let drawing, drawingPath == path {
                    if drawing.isBinary {
                        message(L("viewer.dxf.binary"))
                    } else if drawing.isEmpty {
                        message(L("viewer.dxf.empty"))
                    } else {
                        DXFView(document: drawing, ink: .primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                EmbeddedQLPreview(filePath: displayPath)
            }
        }
        .onAppear { refreshArchiveTemp(); refreshDrawing() }
        .onChange(of: viewModel.cursorItem?.path) { _ in
            refreshArchiveTemp()
            refreshDrawing()
        }
    }

    @ViewBuilder
    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Read the drawing under the cursor, off the main thread — a big one is megabytes of text
    /// and this panel follows the cursor, so it must never make the cursor wait.
    private func refreshDrawing() {
        guard let path = displayPath,
              fileCategory(extension: (path as NSString).pathExtension) == .drawing else {
            drawing = nil
            drawingPath = nil
            return
        }
        guard path != drawingPath else { return }
        drawing = nil
        Task.detached(priority: .userInitiated) {
            let parsed = (try? Data(contentsOf: URL(fileURLWithPath: path)))
                .map(DXFDocument.read(data:))
            await MainActor.run {
                // The cursor may have moved on while this was read.
                guard displayPath == path else { return }
                drawing = parsed
                drawingPath = path
            }
        }
    }

    /// Extract the archived file under the cursor to a temp file (no-op outside an archive).
    private func refreshArchiveTemp() {
        guard viewModel.insideArchive,
              let item = cursorFile,
              let archivePath = viewModel.archivePath,
              let operations else {
            archiveTempPath = nil
            return
        }
        archiveTempPath = operations.extractArchiveEntryForPreview(
            archivePath: archivePath, entryPath: item.path)
    }
}
