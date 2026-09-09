import AppKit
import SwiftUI

/// The process-inspector window, opened by double-clicking a row in the system monitor — the
/// counterpart of Activity Monitor's Inspect window. Header facts on top (executable path, parent,
/// user, process group, %CPU), then Memory / Statistics / Open Files and Ports, then Sample and
/// Quit. Built on the shared FCXLDialog kit so it looks like every other window in the app.
///
/// Values refresh once a second while the window is up, driven by the same service the monitor uses.
struct ProcessInspectorDialogView: View {
    let session: FCXLDialogSession<Bool>
    @ObservedObject var service: SystemMonitorService
    let pid: Int32

    private enum Section: String, CaseIterable { case memory, statistics, files }

    @State private var section: Section = .memory
    @State private var details: ProcessDetails?
    @State private var sampling = false
    @State private var sampleFailed = false

    /// The window keeps itself current while it is open, like Activity Monitor's inspector.
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: details.map { "\($0.name) (\($0.pid))" } ?? "\(pid)")

            ScrollView {
                VStack(spacing: 16) {
                    if let d = details {
                        factsCard(d)
                        sectionPicker
                        switch section {
                        case .memory:     memoryCard(d)
                        case .statistics: statisticsCard(d)
                        case .files:      filesCard(d)
                        }
                    } else {
                        Text(L("monitor.processGone")).font(.system(size: 12))
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: sampling ? L("monitor.inspector.sampling")
                                        : (sampleFailed ? L("monitor.inspector.sampleFailed")
                                                        : L("monitor.inspector.sample")),
                                    role: .normal,
                                    enabled: details != nil && !sampling) { runSample() },
                FCXLDialogBarButton(title: L("monitor.process.quit"), role: .normal,
                                    enabled: details != nil) {
                    service.terminate(pid: pid, force: false)
                    session.finish(true)
                },
                FCXLDialogBarButton(title: L("button.close"), role: .primary) { session.finish(true) }
            ])
        }
        .onAppear { details = service.processDetails(pid: pid) }
        .onReceive(refresh) { _ in details = service.processDetails(pid: pid) }
    }

    // MARK: - Cards

    private func factsCard(_ d: ProcessDetails) -> some View {
        FCXLFormCard {
            FCXLFormRow(label: L("monitor.inspector.path")) {
                Text(d.executablePath.isEmpty ? "—" : d.executablePath)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(d.executablePath)
            }
            FCXLFormRow(label: L("monitor.inspector.parent")) {
                Text(d.parentName).font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FCXLFormRow(label: L("monitor.inspect.user")) {
                Text(d.userName).font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FCXLFormRow(label: L("monitor.inspector.group")) {
                Text(d.processGroup > 0 ? "\(d.processGroup)" : "—").font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FCXLFormRow(label: L("monitor.process.cpu"), showDivider: false) {
                Text(d.metricsAvailable ? String(format: "%.2f", d.cpuPercent) : "—")
                    .font(.system(size: 12)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            Text(L("monitor.inspector.memory")).tag(Section.memory)
            Text(L("monitor.inspector.statistics")).tag(Section.statistics)
            Text(L("monitor.inspector.files")).tag(Section.files)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func memoryCard(_ d: ProcessDetails) -> some View {
        FCXLFormCard {
            row(L("monitor.inspector.physical"), d.metricsAvailable ? bytes(d.residentBytes) : "—")
            row(L("monitor.inspector.virtual"), d.virtualBytes > 0 ? bytes(d.virtualBytes) : "—")
            row(L("monitor.process.mem"), d.metricsAvailable ? bytes(d.footprintBytes) : "—")
            row(L("monitor.memory.wired"), d.metricsAvailable ? bytes(d.wiredBytes) : "—",
                divider: false)
        }
    }

    private func statisticsCard(_ d: ProcessDetails) -> some View {
        FCXLFormCard {
            if d.stats.isEmpty {
                FCXLFormRow(showDivider: false) {
                    Text(L("monitor.inspector.denied")).font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(d.stats.enumerated()), id: \.offset) { i, st in
                    row(st.label, st.value, divider: i < d.stats.count - 1)
                }
            }
        }
    }

    private func filesCard(_ d: ProcessDetails) -> some View {
        FCXLFormCard {
            if !d.openFilesAvailable {
                FCXLFormRow(showDivider: false) {
                    Text(L("monitor.inspector.denied")).font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if d.openFiles.isEmpty {
                FCXLFormRow(showDivider: false) {
                    Text(L("monitor.inspector.noFiles")).font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(d.openFiles.enumerated()), id: \.offset) { i, f in
                    FCXLFormRow(showDivider: i < d.openFiles.count - 1) {
                        Text(f).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(f)
                    }
                }
            }
        }
    }

    // MARK: - Bits

    private func row(_ label: String, _ value: String, divider: Bool = true) -> some View {
        FCXLFormRow(label: label, showDivider: divider) {
            Text(value).font(.system(size: 12)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func bytes(_ v: UInt64) -> String {
        ByteText.memory(Int64(min(v, UInt64(Int64.max))))
    }

    /// Run `sample` off the main thread (it blocks for several seconds), then open the report so
    /// the user actually sees a result. Delivery uses RunLoop in `.modalPanel` too — this window is
    /// modal, and a plain main-queue hop is not guaranteed to run while a modal session is up.
    private func runSample() {
        sampling = true
        sampleFailed = false
        let pid = self.pid
        let service = self.service
        DispatchQueue.global(qos: .userInitiated).async {
            let url = service.sampleProcess(pid: pid)
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                // This block genuinely runs on the main thread; assumeIsolated tells the compiler
                // so, instead of it silently turning the call into a hop that the modal loop
                // would never service (the bug that made "Sampling…" hang forever).
                MainActor.assumeIsolated {
                    sampling = false
                    guard let url else { sampleFailed = true; return }
                    session.finish(true)                 // close the inspector…
                    // Through the funnel like every other launch: a raw open skips the cooperative-activation
        // handshake and the report can land behind the app.
        ExternalOpenService.open(url)         // …and show the report
                }
            }
        }
    }
}
