import SwiftUI

/// Live system monitor shown inside a panel, modelled on macOS Activity Monitor: five tabs
/// (CPU / Memory / Energy / Disk / Network), a process search field, quit / inspect / options
/// toolbar buttons, row selection and live history graphs. Reads a SystemMonitorService that
/// samples once per its update interval. Styled to match the app (flat cards, accent tint).
struct SystemMonitorView: View {
    @ObservedObject var service: SystemMonitorService
    /// Esc closes the monitor and returns to the file list. Routed through the panel's
    /// toggleMonitor() so it follows exactly the same path as the toolbar button.
    var onClose: (() -> Void)?
    /// Called after an action that ran through a menu or popover, so the panel can take keyboard
    /// focus back — otherwise Esc stops closing the monitor once the user has used the menu.
    var onRestoreFocus: (() -> Void)?

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    @State private var showInspector = false
    @FocusState private var searchFocused: Bool

    private var snap: SystemSnapshot { service.snapshot }

    /// Row cap comes from the user's "Rows" choice (0 = all).

    private var filteredProcesses: [ProcessSample] {
        let me = getuid()
        var list = snap.processes
        switch service.processFilter {
        case .all:    break
        case .mine:   list = list.filter { $0.uid == me }
        case .system: list = list.filter { $0.uid == 0 }
        case .active: list = list.filter { $0.cpuPercent > 0.1 }
        }
        let q = service.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || String($0.pid).contains(q) }
        }
        let limit = service.rowLimit
        return limit == 0 ? list : Array(list.prefix(limit))
    }

    private var selectedProcess: ProcessSample? {
        guard let pid = service.selectedPID else { return nil }
        return snap.processes.first { $0.pid == pid }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch service.tab {
                    case .cpu:     cpuTab
                    case .memory:  memoryTab
                    case .energy:  energyTab
                    case .disk:    diskTab
                    case .network: networkTab
                    }
                }
                .padding(14)
            }
        }
        .onAppear { service.start() }
        .onDisappear { service.stop() }
        .background(shortcuts)
    }

    /// ⌘F focuses the search field. Deliberately the ONLY key equivalent registered here: SwiftUI
    /// key equivalents are resolved window-wide via performKeyEquivalent, so anything bound here
    /// also fires while the user is working in the OTHER panel. Esc is handled by the panel's own
    /// key handler instead (scoped to the active panel, and routed through toggleMonitor()), and
    /// ⌘1–⌘5 are omitted rather than stealing those keys from the rest of the window.
    private var shortcuts: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0)
    }

    // MARK: - Header (title, action buttons, search, tabs)

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("monitor.title")).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actionButtons
                searchField
            }
            Picker("", selection: $service.tab) {
                Text(L("monitor.tab.cpu")).tag(SystemMonitorService.Tab.cpu)
                Text(L("monitor.tab.memory")).tag(SystemMonitorService.Tab.memory)
                Text(L("monitor.tab.energy")).tag(SystemMonitorService.Tab.energy)
                Text(L("monitor.tab.disk")).tag(SystemMonitorService.Tab.disk)
                Text(L("monitor.tab.network")).tag(SystemMonitorService.Tab.network)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        let q = service.searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return "\(L("monitor.allProcesses")) · \(snap.processes.count)" }
        return "\(L("monitor.found")): \(filteredProcesses.count)"
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            // Quit selected process.
            // Uses selectedProcess (still in the latest snapshot), never a bare stored pid: a pid
            // whose process has exited can be recycled by macOS, and signalling it would hit an
            // unrelated new process.
            Button {
                if let p = selectedProcess { service.terminate(pid: p.pid, force: false); onRestoreFocus?() }
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(selectedProcess == nil)
            .help(L("monitor.process.quit"))

            // Inspect selected process.
            Button { showInspector.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(selectedProcess == nil)
            .help(L("monitor.inspect"))
            .popover(isPresented: $showInspector, arrowEdge: .bottom) {
                if let p = selectedProcess {
                    inspector(p)
                } else {
                    // The inspected process exited — say so rather than showing an empty box.
                    Text(L("monitor.processGone")).font(.system(size: 11))
                        .foregroundStyle(.secondary).padding(12)
                }
            }

            // Options menu (force quit + filter + rows + update frequency). Presented as the
            // app's own accent-styled NSMenu — this was the one dropdown in the monitor still
            // drawn by the system, highlight and all.
            FCXLMenuAnchor(present: { anchor in
                let menu = NSMenu()
                if let p = selectedProcess {
                    menu.addStyledItem(title: L("monitor.process.quit"), symbolName: "xmark.circle") {
                        service.terminate(pid: p.pid, force: false); onRestoreFocus?()
                    }
                    menu.addStyledItem(title: L("monitor.process.forceQuit"), symbolName: "bolt.circle",
                                       isDestructive: true) {
                        service.terminate(pid: p.pid, force: true); onRestoreFocus?()
                    }
                    menu.addStyledItem(title: L("monitor.copyRow"), symbolName: "doc.on.doc") {
                        copyRow(p); onRestoreFocus?()
                    }
                    menu.addItem(.separator())
                }

                func submenu<Value: Equatable>(_ title: String, options: [(String, Value)],
                                               current: Value, apply: @escaping (Value) -> Void) {
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let sub = NSMenu(title: title)
                    for (label, value) in options {
                        sub.addStyledItem(title: label,
                                          symbolName: value == current ? "checkmark" : "") {
                            apply(value)
                        }
                    }
                    item.submenu = sub
                    menu.addItem(item)
                }

                submenu(L("monitor.filter"), options: [
                    (L("monitor.filter.all"), SystemMonitorService.ProcessFilter.all),
                    (L("monitor.filter.mine"), .mine),
                    (L("monitor.filter.system"), .system),
                    (L("monitor.filter.active"), .active),
                ], current: service.processFilter) { service.processFilter = $0 }

                submenu(L("monitor.rows"), options: SystemMonitorService.rowLimitChoices.map {
                    ($0 == 0 ? L("monitor.rows.all") : "\($0)", $0)
                }, current: service.rowLimit) { service.rowLimit = $0 }

                submenu(L("monitor.updateFrequency"), options: [
                    (L("monitor.freq.fast"), TimeInterval(1)),
                    (L("monitor.freq.normal"), TimeInterval(2)),
                    (L("monitor.freq.slow"), TimeInterval(5)),
                ], current: service.updateInterval) { service.updateInterval = $0 }

                menu.applyAccentStyle()
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
            }) {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
                    .contentShape(Rectangle())
            }
            .fixedSize()
        }
        .foregroundStyle(.secondary)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(L("monitor.search"), text: $service.searchText)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($searchFocused)
            if !service.searchText.isEmpty {
                Button { service.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .frame(maxWidth: 170)
    }

    // MARK: - Tabs

    private var cpuTab: some View {
        Group {
            cpuCard
            processSection
        }
    }

    private var memoryTab: some View {
        Group {
            memoryCard
            processSection
        }
    }

    private var energyTab: some View {
        Group {
            energyCard
            gpuCard
            processSection
        }
    }

    private var gpuCard: some View {
        card(L("monitor.gpu")) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(snap.gpuUtilization.rounded()))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent).monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    if snap.gpuCoreCount > 0 {
                        Text("\(snap.gpuCoreCount) \(L("monitor.gpu.cores"))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if snap.gpuInUseMemBytes > 0 {
                        Text("\(L("monitor.gpu.memory")): \(bytes(snap.gpuInUseMemBytes))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Sparkline(values: service.gpuHistory, maxValue: 100, color: accent)
                    .frame(width: 120, height: 34)
            }
            bar(fraction: snap.gpuUtilization / 100, color: accent)
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").foregroundStyle(thermalColor(snap.thermalState))
                Text("\(L("monitor.thermal")): \(thermalName(snap.thermalState))").font(.system(size: 11))
                Spacer()
            }
        }
    }

    private func thermalName(_ s: Int) -> String {
        switch s {
        case 1: return L("monitor.thermal.fair")
        case 2: return L("monitor.thermal.serious")
        case 3: return L("monitor.thermal.critical")
        default: return L("monitor.thermal.nominal")
        }
    }

    private func thermalColor(_ s: Int) -> Color {
        switch s { case 1: return .yellow; case 2: return .orange; case 3: return .red; default: return .green }
    }

    private var diskTab: some View {
        Group {
            diskIOCard
            if !snap.disks.isEmpty { disksCard }
            processSection
        }
    }

    private var networkTab: some View {
        Group {
            networkCard
            processSection
        }
    }

    // MARK: - CPU card

    private var cpuCard: some View {
        card(L("monitor.cpu")) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(snap.cpuTotal.rounded()))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent).monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    legend(L("monitor.cpu.user"), snap.cpuUser, .blue)
                    legend(L("monitor.cpu.system"), snap.cpuSystem, .red)
                    legend(L("monitor.cpu.idle"), snap.cpuIdle, .secondary)
                }
                Spacer()
                // Stacked User (blue) over System (red) history, like Activity Monitor's CPU LOAD.
                ZStack {
                    Sparkline(values: service.cpuHistory, maxValue: 100, color: accent)
                    Sparkline(values: service.cpuUserHistory, maxValue: 100, color: .blue)
                    Sparkline(values: service.cpuSystemHistory, maxValue: 100, color: .red)
                }
                .frame(width: 140, height: 34)
            }
            HStack {
                Text(L("monitor.cpu.cores")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(L("monitor.processCount")): \(snap.processes.count)   \(L("monitor.threadCount")): \(totalThreads)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: min(8, max(1, snap.cpuPerCore.count)))
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(Array(snap.cpuPerCore.enumerated()), id: \.offset) { i, v in coreBar(v, index: i) }
            }
        }
    }

    /// Sum of threads over the rows we enriched (the rest report 0) — a lower bound, labelled as such.
    private var totalThreads: Int {
        snap.processes.reduce(0) { $0 + $1.threads }
    }

    /// Per-core cell: a live bar plus that core's own rolling history behind it (AM's CPU History).
    private func coreBar(_ percent: Double, index: Int) -> some View {
        VStack(spacing: 1) {
            ZStack {
                if service.coreHistory.indices.contains(index) {
                    Sparkline(values: service.coreHistory[index], maxValue: 100, color: accent.opacity(0.55))
                }
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(accent)
                            .frame(width: 4, height: max(1, geo.size.height * percent / 100))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .frame(height: 26)
            Text("\(Int(percent.rounded()))").font(.system(size: 8)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: - Memory card

    private var memoryCard: some View {
        card(L("monitor.memory")) {
            HStack {
                Text("\(bytes(snap.memUsedBytes)) / \(bytes(snap.memTotalBytes))")
                    .font(.system(size: 14, weight: .medium)).monospacedDigit()
                Spacer()
                Text("\(Int((snap.memPressure * 100).rounded()))%")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            bar(fraction: snap.memTotalBytes == 0 ? 0 : Double(snap.memUsedBytes) / Double(snap.memTotalBytes),
                color: pressureColor(level: snap.memPressureLevel))
            Sparkline(values: service.memPressureHistory, maxValue: 100,
                      color: pressureColor(level: snap.memPressureLevel))
                .frame(height: 26)
            HStack(spacing: 14) {
                metric(L("monitor.memory.app"), bytes(snap.memAppBytes))
                metric(L("monitor.memory.wired"), bytes(snap.memWiredBytes))
                metric(L("monitor.memory.compressed"), bytes(snap.memCompressedBytes))
                metric(L("monitor.memory.cached"), bytes(snap.memCachedBytes))
                if snap.swapUsedBytes > 0 { metric(L("monitor.memory.swap"), bytes(snap.swapUsedBytes)) }
                Spacer()
            }
        }
    }

    // MARK: - Energy card

    private var energyCard: some View {
        card(L("monitor.tab.energy")) {
            if let b = snap.battery {
                HStack(spacing: 10) {
                    Image(systemName: batterySymbol(b))
                        .font(.system(size: 22)).foregroundStyle(b.isCharging ? .green : accent)
                    Text("\(Int(b.percent.rounded()))%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.isCharging ? L("monitor.battery.charging")
                                          : (b.isPluggedIn ? L("monitor.battery.pluggedIn") : L("monitor.battery.onBattery")))
                            .font(.system(size: 11))
                        if b.minutesRemaining > 0 {
                            Text("\(L("monitor.battery.remaining")): \(b.minutesRemaining / 60):\(String(format: "%02d", b.minutesRemaining % 60))")
                                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer()
                }
            }
            Divider()
            Toggle(L("monitor.power.enable"), isOn: $service.powerMetricsEnabled)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            if service.powerMetricsDenied {
                Text(L("monitor.power.needsRights")).font(.system(size: 10))
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if service.powerMetricsEnabled {
                if snap.powerAvailable {
                    HStack(spacing: 14) {
                        metric(L("monitor.power.cpu"), String(format: "%.2f W", snap.powerCPUWatts))
                        metric(L("monitor.power.gpu"), String(format: "%.2f W", snap.powerGPUWatts))
                        metric(L("monitor.power.total"), String(format: "%.2f W", snap.powerTotalWatts))
                        Spacer()
                    }
                }
            }
            Text(L("monitor.energy.note")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func batterySymbol(_ b: BatteryInfo) -> String {
        if b.isCharging { return "battery.100.bolt" }
        switch b.percent {
        case ..<15:  return "battery.0"
        case ..<40:  return "battery.25"
        case ..<70:  return "battery.50"
        case ..<90:  return "battery.75"
        default:     return "battery.100"
        }
    }

    // MARK: - Disk cards

    private var diskIOCard: some View {
        card(L("monitor.disk.io")) {
            HStack(spacing: 24) {
                ioStat(systemImage: "arrow.down.circle", title: L("monitor.disk.read"),
                       bytesPerSec: snap.diskReadBytesPerSec, ops: snap.diskReadsPerSec, tint: .blue)
                ioStat(systemImage: "arrow.up.circle", title: L("monitor.disk.written"),
                       bytesPerSec: snap.diskWriteBytesPerSec, ops: snap.diskWritesPerSec, tint: .orange)
                Spacer()
            }
            HStack(spacing: 8) {
                Sparkline(values: service.diskReadHistory, color: .blue).frame(height: 26)
                Sparkline(values: service.diskWriteHistory, color: .orange).frame(height: 26)
            }
        }
    }

    private var disksCard: some View {
        card(L("monitor.disks")) {
            ForEach(snap.disks) { disk in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(disk.name).font(.system(size: 12))
                        Spacer()
                        Text("\(bytes(disk.freeBytes)) \(L("monitor.disk.free")) \(bytes(disk.totalBytes))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    bar(fraction: disk.fraction, color: disk.fraction > 0.9 ? .red : accent)
                }
            }
        }
    }

    // MARK: - Network card

    private var networkCard: some View {
        card(L("monitor.network")) {
            HStack(spacing: 24) {
                netStat(systemImage: "arrow.down", title: L("monitor.network.down"),
                        bytesPerSec: snap.netInBytesPerSec, total: snap.netInBytesTotal, tint: .green)
                netStat(systemImage: "arrow.up", title: L("monitor.network.up"),
                        bytesPerSec: snap.netOutBytesPerSec, total: snap.netOutBytesTotal, tint: .blue)
                Spacer()
            }
            HStack(spacing: 24) {
                pktStat(title: L("monitor.network.packetsIn"),
                        rate: snap.netInPacketsPerSec, total: snap.netInPacketsTotal, tint: .green)
                pktStat(title: L("monitor.network.packetsOut"),
                        rate: snap.netOutPacketsPerSec, total: snap.netOutPacketsTotal, tint: .blue)
                Spacer()
            }
            HStack(spacing: 8) {
                Sparkline(values: service.netInHistory, color: .green).frame(height: 30)
                Sparkline(values: service.netOutHistory, color: .blue).frame(height: 30)
            }
        }
    }

    private func pktStat(title: String, rate: Double, total: UInt64, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox").foregroundStyle(tint).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text("\(whole(rate))/s")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text(count(total)).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func count(_ v: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
    }

    // MARK: - Process table (selection + per-tab columns)

    private var processSection: some View {
        card(L("monitor.processes")) {
            processHeader
            Divider()
            if filteredProcesses.isEmpty {
                Text(L("monitor.noResults")).font(.system(size: 12))
                    .foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                // Lazy: an unfiltered search (e.g. "1", which matches most pids) can match hundreds
                // of rows, and a plain VStack would build every one of them on each sample.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredProcesses) { p in processRow(p) }
                }
            }
        }
    }

    private var processHeader: some View {
        HStack(spacing: 8) {
            sortHeader(columnTitle(.name), .name)
            ForEach(service.visibleColumns.filter { $0 != .name }, id: \.self) { col in
                sortHeader(columnTitle(col), col, width: columnWidth(col))
            }
        }
        .font(.system(size: 10))
        .frame(height: 14)            // one text line — no column may make the header row grow
        .contextMenu { columnMenu }   // right-click the header to choose columns, like Activity Monitor
    }

    /// The column chooser: every available column with a checkmark, plus "reset".
    @ViewBuilder private var columnMenu: some View {
        // Toggle (not Button+Label): AppKit draws a real checkmark for a menu Toggle, so the user
        // can see at a glance which columns are on. A Label's systemImage is not rendered here.
        ForEach(SystemMonitorService.ProcessColumn.allCases.filter { $0 != .name }, id: \.self) { col in
            Toggle(columnTitle(col), isOn: Binding(
                get: { service.visibleColumns.contains(col) },
                set: { _ in service.toggleColumn(col) }
            ))
        }
        Divider()
        Button(L("monitor.columns.reset")) { service.resetColumns() }
    }

    private func columnTitle(_ c: SystemMonitorService.ProcessColumn) -> String {
        switch c {
        case .name:            return L("monitor.process.name")
        case .pid:             return L("monitor.process.pid")
        case .parentPID:       return L("monitor.inspect.parent")
        case .user:            return L("monitor.inspect.user")
        case .kind:            return L("monitor.col.kind")
        case .cpu:             return L("monitor.process.cpu")
        case .cpuTime:         return L("monitor.stat.cpuTime")
        case .threads:         return L("monitor.process.threads")
        case .idleWakeups:     return L("monitor.stat.idleWakeups")
        case .energy:          return L("monitor.process.energy")
        case .preventingSleep: return L("monitor.col.preventingSleep")
        case .memory:          return L("monitor.process.mem")
        case .realMemory:      return L("monitor.stat.realMem")
        case .wired:           return L("monitor.memory.wired")
        case .pageins:         return L("monitor.stat.pageins")
        case .diskRead:        return L("monitor.process.diskRead")
        case .diskWrite:       return L("monitor.process.diskWrite")
        case .bytesRead:       return L("monitor.stat.bytesRead")
        case .bytesWritten:    return L("monitor.stat.bytesWritten")
        case .netIn:           return L("monitor.process.netIn")
        case .netOut:          return L("monitor.process.netOut")
        case .sentBytes:       return L("monitor.col.sentBytes")
        case .rcvdBytes:       return L("monitor.col.rcvdBytes")
        case .sentPackets:     return L("monitor.col.sentPackets")
        case .rcvdPackets:     return L("monitor.col.rcvdPackets")
        }
    }

    /// Width a column's DATA needs. The final width also accounts for the header title, so a long
    /// localised label ("Предотвращение сна") widens its column instead of being cut to "Предот…".
    private func columnDataWidth(_ c: SystemMonitorService.ProcessColumn) -> CGFloat {
        switch c {
        case .name:                             return 0
        case .cpu, .threads:                    return 54
        case .pid, .parentPID:                  return 58
        case .kind, .preventingSleep:           return 58
        case .energy, .idleWakeups:             return 62
        case .user:                             return 76
        case .cpuTime:                          return 72
        case .sentPackets, .rcvdPackets:        return 74
        default:                                return 80
        }
    }

    /// Widest a single column may grow to. Past this the title truncates (with a tooltip), so one
    /// verbose label cannot push every other column off the panel.
    private static let columnMaxWidth: CGFloat = 132

    private func columnWidth(_ c: SystemMonitorService.ProcessColumn) -> CGFloat {
        let needed = Self.headerTextWidth(columnTitle(c)) + 14   // sort arrow + breathing room
        return min(Self.columnMaxWidth, max(columnDataWidth(c), needed))
    }

    /// Measured width of a header label in the header font, memoised — the header is rebuilt on
    /// every sample, and re-measuring the same handful of strings each time would be wasteful.
    private static var headerWidthCache: [String: CGFloat] = [:]
    private static func headerTextWidth(_ title: String) -> CGFloat {
        if let w = headerWidthCache[title] { return w }
        let font = NSFont.systemFont(ofSize: 10)
        let w = (title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        headerWidthCache[title] = w
        return w
    }

    /// Cell text for a column, and whether it should be de-emphasised.
    private func columnText(_ c: SystemMonitorService.ProcessColumn, _ p: ProcessSample) -> String {
        // Root- and other-user-owned processes are listed, but the kernel denies their metrics to
        // an unprivileged app; show "—" rather than a misleading 0.
        if !p.metricsAvailable {
            switch c {
            case .name, .pid, .parentPID, .user, .kind: break   // these ARE known
            default: return "—"
            }
        }
        switch c {
        case .name:            return p.name
        case .pid:             return "\(p.pid)"
        case .parentPID:       return "\(p.parentPID)"
        case .user:            return service.userName(p.uid)
        case .kind:            return p.isTranslated ? "Intel" : "Apple"
        case .cpu:             return String(format: "%.1f", p.cpuPercent)
        case .cpuTime:         return cpuTimeString(p.cpuTimeSeconds)
        case .threads:         return p.threads > 0 ? "\(p.threads)" : "—"
        case .idleWakeups:     return "\(whole(p.idleWakeupsPerSec))"
        case .energy:          return String(format: "%.1f", p.energyImpact)
        case .preventingSleep: return p.preventingSleep ? L("monitor.yes") : L("monitor.no")
        case .memory:          return bytes(p.memBytes)
        case .realMemory:      return bytes(p.residentBytes)
        case .wired:           return bytes(p.wiredBytes)
        case .pageins:         return count(p.pageins)
        case .diskRead:        return rate(p.diskReadBytesPerSec)
        case .diskWrite:       return rate(p.diskWriteBytesPerSec)
        case .bytesRead:       return bytes(p.diskReadTotal)
        case .bytesWritten:    return bytes(p.diskWriteTotal)
        case .netIn:           return rate(p.netInBytesPerSec)
        case .netOut:          return rate(p.netOutBytesPerSec)
        case .sentBytes:       return bytes(p.netOutBytesTotal)
        case .rcvdBytes:       return bytes(p.netInBytesTotal)
        case .sentPackets:     return count(p.netOutPacketsTotal)
        case .rcvdPackets:     return count(p.netInPacketsTotal)
        }
    }

    /// Highlight colour for a cell (nil = default), so hot values still stand out.
    private func columnColor(_ c: SystemMonitorService.ProcessColumn, _ p: ProcessSample) -> Color? {
        switch c {
        case .cpu:             return p.cpuPercent > 50 ? .red : nil
        case .energy:          return p.energyImpact > 50 ? .orange : nil
        case .netIn:           return p.netInBytesPerSec > 1 ? .green : nil
        case .preventingSleep: return p.preventingSleep ? .orange : nil
        default:               return nil
        }
    }

    /// Clickable sort header: click to sort by this column, click again to reverse. An arrow marks
    /// the active column. Fixed width for the metric columns, flexible (leading) for the name.
    @ViewBuilder
    private func sortHeader(_ title: String, _ column: SystemMonitorService.ProcessColumn,
                            width: CGFloat? = nil) -> some View {
        let leading = (width == nil)
        let button = Button { service.sort(by: column) } label: {
            HStack(spacing: 2) {
                if !leading { Spacer(minLength: 0) }
                // Headers stay on ONE line: a long localised title (e.g. "Пробуждения") would
                // otherwise wrap and make the header row twice as tall. Ellipsise instead.
                Text(title).lineLimit(1).truncationMode(.tail)
                if service.sortColumn == column {
                    Image(systemName: service.sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7, weight: .bold))
                }
                if leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(service.sortColumn == column ? accent : Color.secondary)
        .help(title)   // hovering shows the full label even when it is cut to "Предот…"

        if leading {
            button.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            button.frame(width: width, alignment: .trailing)
        }
    }

    private func processRow(_ p: ProcessSample) -> some View {
        HStack(spacing: 8) {
            Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(p.name) — PID \(p.pid)")
            ForEach(service.visibleColumns.filter { $0 != .name }, id: \.self) { col in
                Text(columnText(col, p))
                    .font(.system(size: 12)).monospacedDigit().lineLimit(1)
                    .frame(width: columnWidth(col), alignment: .trailing)
                    .foregroundStyle(columnColor(col, p) ?? (col == service.sortColumn ? .primary : .secondary))
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(service.selectedPID == p.pid ? accent.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        // Одновременные жесты: иначе выделение процесса отстаёт на интервал двойного
        // нажатия — одиночный щелчок ждёт, не последует ли второй.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            service.selectedPID = p.pid
            openInspectorWindow(p.pid)
        })
        .simultaneousGesture(TapGesture().onEnded {
            service.selectedPID = (service.selectedPID == p.pid ? nil : p.pid)
        })
        .contextMenu {
            Button(L("monitor.process.quit")) { service.terminate(pid: p.pid, force: false); onRestoreFocus?() }
            Button(L("monitor.process.forceQuit"), role: .destructive) { service.terminate(pid: p.pid, force: true); onRestoreFocus?() }
            Divider()
            Button(L("monitor.inspect")) { service.selectedPID = p.pid; showInspector = true }
        }
    }


    // MARK: - Inspector popover

    private func inspector(_ p: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    inspectorRow(L("monitor.process.pid"), "\(p.pid)")
                    inspectorRow(L("monitor.inspect.parent"), "\(p.parentPID)")
                    inspectorRow(L("monitor.inspect.user"), service.userName(p.uid))
                    inspectorRow(L("monitor.process.threads"), "\(p.threads)")
                    inspectorRow(L("monitor.process.cpu"), String(format: "%.1f%%", p.cpuPercent))
                    inspectorRow(L("monitor.stat.cpuTime"), cpuTimeString(p.cpuTimeSeconds))
                    inspectorRow(L("monitor.stat.idleWakeups"), "\(whole(p.idleWakeupsPerSec))/s")
                    inspectorRow(L("monitor.process.mem"), bytes(p.memBytes))
                    inspectorRow(L("monitor.stat.realMem"), bytes(p.residentBytes))
                    inspectorRow(L("monitor.stat.bytesRead"), bytes(p.diskReadTotal))
                    inspectorRow(L("monitor.stat.bytesWritten"), bytes(p.diskWriteTotal))
                    inspectorRow(L("monitor.process.energy"), String(format: "%.1f", p.energyImpact))
                    Divider()
                    ForEach(service.processStatistics(pid: p.pid)) { st in
                        inspectorRow(st.label, st.value)
                    }
                }
            }
            .frame(maxHeight: 320)
            Divider()
            HStack {
                Button(L("monitor.process.quit")) { service.terminate(pid: p.pid, force: false); showInspector = false }
                Button(L("monitor.process.forceQuit"), role: .destructive) { service.terminate(pid: p.pid, force: true); showInspector = false }
            }
            .font(.system(size: 11))
        }
        .padding(12).frame(width: 260)
    }

    /// Copy the selected process's row as tab-delimited text (Activity Monitor's Copy).
    /// Double-click opens the full process window (Activity Monitor's Inspect equivalent).
    private func openInspectorWindow(_ pid: Int32) {
        showInspector = false          // the popover and the window must not fight over focus
        let service = self.service
        // Run after the click settles, so the modal session does not start inside the gesture.
        DispatchQueue.main.async {
            _ = FCXLDialog.runModal(size: NSSize(width: 560, height: 560)) { session in
                ProcessInspectorDialogView(session: session, service: service, pid: pid)
            }
            onRestoreFocus?()
        }
    }

    private func copyRow(_ p: ProcessSample) {
        let line = [p.name, "\(p.pid)", String(format: "%.1f%%", p.cpuPercent),
                    bytes(p.memBytes), "\(p.threads)", cpuTimeString(p.cpuTimeSeconds)]
            .joined(separator: "\t")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    private func inspectorRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
        }
    }

    // MARK: - Bits

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
    }

    private func legend(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(Int(value.rounded()))%").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    private func netStat(systemImage: String, title: String, bytesPerSec: Double, total: UInt64, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(bytesPerSec < 1 ? "0" : rate(bytesPerSec))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text(bytes(total)).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func ioStat(systemImage: String, title: String, bytesPerSec: Double, ops: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(bytesPerSec < 1 ? "0" : rate(bytesPerSec))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text("\(whole(ops)) \(L("monitor.disk.ops"))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func pressureColor(_ p: Double) -> Color {
        p > 0.85 ? .red : (p > 0.6 ? .orange : accent)
    }

    // Colour from the real kernel pressure signal (1 normal / 2 warning / 4 critical).
    private func pressureColor(level: Int) -> Color {
        switch level { case 4: return .red; case 2: return .orange; default: return accent }
    }

    /// Format cumulative CPU time like Activity Monitor: H:MM:SS over an hour, else M:SS.cc.
    private func cpuTimeString(_ secs: Double) -> String {
        let total = Int(secs)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        let cs = Int((secs - Double(total)) * 100)
        return String(format: "%d:%02d.%02d", m, s, cs)
    }

    // Formatters clamp before converting: Int64(UInt64) and Int(Double) TRAP on overflow, which
    // would crash the app outright. Never let a bad counter reading take the process down.
    private func bytes(_ v: UInt64) -> String {
        ByteText.memory(Int64(min(v, UInt64(Int64.max))))
    }

    private func rate(_ v: Double) -> String {
        guard v.isFinite, v >= 1 else { return "—" }
        return bytes(UInt64(min(v, Double(UInt64(Int64.max))))) + "/s"
    }

    /// Whole-number formatting for packet/page counts, overflow-safe.
    private func whole(_ v: Double) -> Int {
        guard v.isFinite, v > 0 else { return 0 }
        return Int(min(v, Double(Int.max / 2)).rounded())
    }
}

/// A tiny filled line chart for a rolling series (most-recent last).
private struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let vs = values
            let n = vs.count
            let maxV = Swift.max(maxValue ?? (vs.max() ?? 1), 0.0001)
            let pts: [CGPoint] = vs.enumerated().map { i, v in
                CGPoint(x: n <= 1 ? 0 : geo.size.width * CGFloat(i) / CGFloat(n - 1),
                        y: geo.size.height * (1 - CGFloat(Swift.min(1, Swift.max(0, v / maxV)))))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }.fill(color.opacity(0.15))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }
}
