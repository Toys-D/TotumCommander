import SwiftUI

// MARK: - Panel Controller

@MainActor
final class OperationQueuePanelController {
    private var panel: NSPanel?
    private var escKeyMonitor: Any?
    private let viewModel: OperationQueueViewModel

    init(viewModel: OperationQueueViewModel) {
        self.viewModel = viewModel
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let content = OperationQueuePanelContent(viewModel: viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = L("queue.title")
        newPanel.isReleasedWhenClosed = false
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior.insert(.moveToActiveSpace)
        newPanel.minSize = NSSize(width: 400, height: 200)
        newPanel.contentView = hosting
        // ESC closes the queue panel
        newPanel.isReleasedWhenClosed = false
        let escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak newPanel, weak self] event in
            if event.keyCode == 53, event.window === newPanel {
                self?.hide()
                return nil
            }
            return event
        }
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
        escKeyMonitor = escMonitor
        viewModel.isPanelVisible = true
    }

    func hide() {
        if let escKeyMonitor {
            NSEvent.removeMonitor(escKeyMonitor)
            self.escKeyMonitor = nil
        }
        panel?.orderOut(nil)
        viewModel.isPanelVisible = false
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }
}

// MARK: - SwiftUI Content

struct OperationQueuePanelContent: View {
    @ObservedObject var viewModel: OperationQueueViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.operations.isEmpty {
                emptyState
            } else {
                operationList
                Divider()
                bottomBar
            }
        }
        .frame(minWidth: 400, minHeight: 150)
        // Same ban as at the dialog kit's root: the app draws its own accents, the system
        // focus halo is a stranger — one modifier here covers every control inside.
        .focusEffectDisabled()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(L("queue.empty"))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var operationList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.operations) { op in
                    OperationRowView(
                        operation: op,
                        onPause: { viewModel.pause(op.id) },
                        onResume: { viewModel.resume(op.id) },
                        onCancel: { viewModel.cancel(op.id) },
                        onRemove: { viewModel.removeOperation(op.id) },
                        onContinue: { viewModel.continueTransfer(op.id) }
                    )
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(L("queue.clearCompleted")) {
                viewModel.clearCompleted()
            }
            .disabled(!viewModel.operations.contains(where: \.isFinished))
            .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
            .font(.caption)
            Spacer()
            Text(L("queue.summary", viewModel.operations.count, viewModel.activeCount))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Operation Row

private struct OperationRowView: View {
    let operation: QueuedOperation
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    /// Pick a broken transfer up where it stopped. Only failed remote transfers offer this.
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusIcon
                Text(operation.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                actionButtons
            }

            // Which of two same-named rows is which: when it finished and where it put
            // things. Two downloads of the same file are twins without this line.
            if let whereAndWhen {
                Text(whereAndWhen)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if operation.status == .running || operation.status == .paused {
                progressSection
            }

            if let error = operation.error, operation.status == .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            // The link went away and this row is waiting, not working. It says so where the
            // eye already looks for the current file, and in a colour that reads as "wait".
            if let trouble = operation.trouble {
                Text(trouble)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            if operation.status == .running, operation.trouble == nil,
               !operation.currentFile.isEmpty {
                Text(operation.currentFile)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
    }

    /// Seconds included on purpose: same-named files tend to be copied minutes — or
    /// seconds — apart, and the clock is what tells the rows apart.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var whereAndWhen: String? {
        var parts: [String] = []
        if let done = operation.completedAt {
            parts.append(Self.clock.string(from: done))
        }
        if let destination = operation.destinationPath, !destination.isEmpty {
            parts.append("→ " + (destination as NSString).abbreviatingWithTildeInPath)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch operation.status {
        case .queued:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .font(.caption)
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundColor(.orange)
                .font(.caption)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if operation.status == .running {
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help(L("queue.pause"))
            }

            if operation.status == .paused {
                Button(action: onResume) {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help(L("queue.resume"))
            }

            if operation.isActive {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help(L("queue.cancel"))
            }

            // A broken transfer is not a dead end: what already arrived stays in the `.part`
            // twin, so this carries on from there instead of starting the file over.
            if operation.canBeResumed {
                Button(action: onContinue) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help(L("queue.continueTransfer"))
            }

            if operation.isFinished {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help(L("queue.dismiss"))
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ProgressView(value: operation.progress)
                    // Цвет программы, а не системный синий: акцент у NSProgressIndicator
                    // общесистемный, и полоска выбивалась из окна.
                    .tint(PanelAppearanceSettings.accentColor)
                    .progressViewStyle(.linear)
                Text("\(Int((operation.progress * 100).rounded()))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            HStack {
                if operation.bytesTotal > 0 {
                    Text(progressBytesText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if operation.filesTotal > 0 {
                    Text(progressFilesText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if operation.remainingTime != nil || operation.elapsedTime > 1 {
                    Text(timeText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .help(timeTooltip)
                }
            }
        }
    }

    private var rowBackground: Color {
        switch operation.status {
        case .failed: return Color.red.opacity(0.05)
        case .cancelled: return Color.secondary.opacity(0.03)
        default: return .clear
        }
    }

    private var progressBytesText: String {
        let done = ByteText.file(operation.bytesDone)
        let total = ByteText.file(operation.bytesTotal)
        return "\(done) / \(total)"
    }

    private var progressFilesText: String {
        "\(operation.filesDone)/\(operation.filesTotal) files"
    }

    /// While transferring, show the estimated time LEFT (prefixed "≈"); while
    /// preparing or paused, fall back to elapsed time.
    private var timeText: String {
        if let remaining = operation.remainingTime {
            return "≈ " + Self.mmss(remaining)
        }
        return Self.mmss(operation.elapsedTime)
    }

    private var timeTooltip: String {
        operation.remainingTime != nil ? L("queue.timeRemaining") : L("queue.timeElapsed")
    }

    private static func mmss(_ t: TimeInterval) -> String {
        let seconds = max(0, Int(t))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
