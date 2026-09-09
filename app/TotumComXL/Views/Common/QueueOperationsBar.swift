import SwiftUI

/// Compact bar shown above F-key buttons when there are active background operations.
struct QueueOperationsBar: View {
    @ObservedObject var viewModel: OperationQueueViewModel
    var onShowFullPanel: () -> Void

    private var activeOps: [QueuedOperation] {
        viewModel.operations.filter(\.isActive)
    }

    var body: some View {
        if !activeOps.isEmpty {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 2) {
                    ForEach(activeOps) { op in
                        QueueOperationsBarRow(
                            operation: op,
                            onPause: { viewModel.pause(op.id) },
                            onResume: { viewModel.resume(op.id) },
                            onCancel: { viewModel.cancel(op.id) },
                            onShowPanel: onShowFullPanel
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct QueueOperationsBarRow: View {
    let operation: QueuedOperation
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onShowPanel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            kindIcon
                .frame(width: 14)

            Text(operation.displayTitle)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)

            ProgressView(value: operation.progress)
                    // Цвет программы, а не системный синий: акцент у NSProgressIndicator
                    // общесистемный, и полоска выбивалась из окна.
                    .tint(PanelAppearanceSettings.accentColor)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)

            Text("\(Int((operation.progress * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                if operation.status == .running {
                    barButton(icon: "pause.fill", help: L("queue.pause"), action: onPause)
                }
                if operation.status == .paused {
                    barButton(icon: "play.fill", help: L("queue.resume"), action: onResume)
                }
                barButton(icon: "xmark", help: L("queue.cancel"), action: onCancel)
                barButton(icon: "list.bullet", help: L("queue.title"), action: onShowPanel)
            }
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var kindIcon: some View {
        switch operation.kind {
        case .pack:
            Image(systemName: "archivebox.fill")
                .font(.system(size: 10))
                .foregroundColor(.blue)
        case .unpack:
            Image(systemName: "archivebox")
                .font(.system(size: 10))
                .foregroundColor(.green)
        case .archiveExtract:
            Image(systemName: "arrow.up.doc")
                .font(.system(size: 10))
                .foregroundColor(.green)
        case .copy:
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 10))
                .foregroundColor(.blue)
        case .move:
            Image(systemName: "arrow.right.doc.on.clipboard")
                .font(.system(size: 10))
                .foregroundColor(.orange)
        case .delete, .archiveDelete:
            Image(systemName: "trash.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
        case .archiveRename:
            Image(systemName: "pencil")
                .font(.system(size: 10))
                .foregroundColor(.purple)
        case .remoteDownload:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.cyan)
        case .remoteUpload:
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.cyan)
        case .remoteDelete:
            Image(systemName: "trash.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
        case .multiRename:
            Image(systemName: "pencil.and.list.clipboard")
                .font(.system(size: 10))
                .foregroundColor(.orange)
        }
    }

    private func barButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
