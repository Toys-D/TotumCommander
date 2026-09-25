import AppKit
import SwiftUI

private extension Notification.Name {
    static let volumeBarNeedsRefresh = Notification.Name("com.fcxl.volumeBarNeedsRefresh")
}

/// Volume buttons bar + view mode toggle, embedded via NSHostingView in PanelViewController.
/// Один размер для ВСЕХ значков полосы дисков.
///
/// Один кегль ещё не значит один вид: у «arrow.up.arrow.down.circle» рисунок сидит внутри
/// кольца и выглядит мельче, чем открытый «network», — в строке это читалось как разнобой.
/// Поэтому кегль общий, и каждый значок стоит в одной и той же квадратной рамке: тогда они
/// занимают одинаковое место и держат строку ровно.
private enum BarGlyph {
    static let size: CGFloat = 10
    static let box: CGFloat = 14
}

struct PanelVolumeBar: View {
    @ObservedObject var viewModel: PanelViewModel
    /// Observes the connect-time parallel-transfer probe so the remote badge turns green live.
    @ObservedObject private var connectionMgr = ConnectionManagerService.shared
    /// Подключения обеих панелей: чужое показывается тоже, как любой примонтированный том.
    @ObservedObject private var sessionRegistry = RemoteSessionRegistry.shared
    var onNetwork: (() -> Void)?
    /// Finder-style "Connect to Server": mount a network drive by typing its address.
    var onConnectNetworkDrive: (() -> Void)?
    var onLocalNetwork: (() -> Void)?
    var onSwitchToRemoteTab: (() -> Void)?
    var onDisconnectRemote: (() -> Void)?
    /// Сетевой том живёт в своей вкладке — и с полосы дисков тоже: щелчок по чипу открывает
    /// или находит вкладку этого тома, а папка текущей вкладки остаётся на месте.
    var onOpenNetworkVolume: ((String) -> Void)?
    /// Чип сессии другой панели: открыть то же подключение здесь / закрыть его там.
    var onOpenForeignRemote: ((RemoteConnection) -> Void)?
    var onDisconnectForeignRemote: ((RemoteSession) -> Void)?
    @State private var mountedVolumesRevision: Int = 0
    @State private var showNetworkMenu = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.beautyModeEnabledKey) private var beautyModeEnabled: Bool = false
    /// Есть ли iCloud Drive. Сначала дешёвая примета (папка на месте), а настоящий ответ
    /// — один раз после появления полосы: он поднимает CloudDocs, и та обходит Рабочий стол
    /// и Документы. Из отрисовки такое спрашивать нельзя.
    @State private var icloudAvailable = CloudStatusService.isAvailableFast
    @AppStorage(PanelAppearanceSettings.cursorUsesCustomColorKey) private var cursorUsesCustomColor: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorBackgroundColorHexKey) private var cursorBackgroundColorHex: String = ""
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    // MARK: - Active-disk cursor styling
    //
    // The active (selected) disk always gets a slightly larger name (see the font
    // sizes below). With beauty mode ON it also sits UNDER the panel's feathered
    // cursor — the very same FeatheredCursor the file list uses — so a selected disk
    // reads like the file under the cursor: soft glowing frame + recoloured name.

    private var isDark: Bool { colorScheme == .dark }

    /// Colour of the feathered cursor frame around a disk. Local disks use the panel
    /// cursor colour (custom or accent) so it matches the file cursor exactly; network
    /// keeps its red tint.
    private func cursorFrameColor(_ vol: VolumeButtonModel) -> Color {
        if vol.isNetwork { return .red }
        return Color(nsColor: PanelAppearanceSettings.resolvedCursorBackground())
    }

    /// Name colour of the ACTIVE disk: the colour a name has under the panel cursor, because
    /// the disk now SITS on that cursor. Falls back to black-or-white against the chip when the
    /// user has no colour of their own — a tinted name on a tinted chip was the light theme's
    /// whole problem.
    private func activeDiskTextColor(_ vol: VolumeButtonModel) -> Color {
        Color(nsColor: PanelVolumeBar.activeLabelColor(
            isNetwork: vol.isNetwork,
            onChip: PanelVolumeBar.showsChip(beauty: beautyModeEnabled, isDark: isDark)))
    }

    /// Whether the active disk gets the solid cursor chip.
    ///
    /// Not in the DARK theme with beauty mode on: there the feathered glow already says which
    /// disk is selected, and it looks better than a solid block. The light theme is where the
    /// glow washes out — that is the case the chip exists for, and the case beauty mode off
    /// leaves with no marker at all.
    static func showsChip(beauty: Bool, isDark: Bool) -> Bool { !(beauty && isDark) }

    /// The two colours of the active disk — the chip it sits on and the name on top of it.
    /// A plain function so the choice can be tested in both themes without a view.
    static func activeChipColors(isNetwork: Bool) -> (fill: NSColor, label: NSColor) {
        (activeFillColor(isNetwork: isNetwork),
         activeLabelColor(isNetwork: isNetwork, onChip: true))
    }

    static func activeFillColor(isNetwork: Bool) -> NSColor {
        isNetwork ? .systemRed : PanelAppearanceSettings.resolvedCursorBackground()
    }

    static func activeLabelColor(isNetwork: Bool, onChip: Bool = true) -> NSColor {
        // On the dark theme's glow the name has always been white, and it reads there.
        guard onChip else { return .white }
        let fill = activeFillColor(isNetwork: isNetwork)
        // Black or white on the chip comes from the app-wide helper, which measures the WCAG
        // ratio for both inks and keeps the winner — the bar used to carry its own copy of that
        // maths back when the shared one still decided by a brightness threshold.
        if isNetwork { return PanelAppearanceSettings.contrastingTextColor(on: fill) }
        // The name under the cursor, whatever the user set it to — but only while it actually
        // READS on the chip. The bar's label is 10pt in a 20pt strip, far smaller than a file
        // row, so a pairing the list gets away with (orange on white: ratio 2.2) is exactly the
        // "can't see which disk is selected" complaint. Below the readable-text ratio, black or
        // white takes over — in the bar only; the file list keeps the user's colours untouched.
        let name = PanelAppearanceSettings.resolvedCursorNameColor()
        return PanelAppearanceSettings.contrast(between: name, and: fill) < 4.5
            ? PanelAppearanceSettings.contrastingTextColor(on: fill) : name
    }

    /// Soft accent glow behind the active disk (beauty mode only). An ELLIPTICAL bloom
    /// whose geometry follows the disk's content: it spans the button width (icon + name)
    /// and stays within the short bar height — so "C:" gets a small round glow while a
    /// wide "D: SERVER_SO: E" gets a long one that runs the length of the label. It fades
    /// ALL the way to transparent (no shape edge → never a "bounded pill", and it dies out
    /// before the panel border, so the container's clip has nothing hard to slice).
    /// Colour matches the panel cursor (custom or accent); network/remote keep their tint.
    @ViewBuilder
    private func cursorGlow(active: Bool, color: Color) -> some View {
        if active && beautyModeEnabled {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    // Body of light spanning the WHOLE disk (icon → last char): a capsule
                    // that's bright evenly along its length, so the glow reaches both ends
                    // instead of dying out in the middle. Blurred edges keep it feathered
                    // (no hard boundary); kept short vertically so the blur fades before the
                    // panel border (no clip).
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.42))
                        .frame(width: w + 6, height: h * 0.46)
                        .blur(radius: 4)
                    // Brighter neon core down the centre line.
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.55))
                        .frame(width: w * 0.7, height: h * 0.40)
                        .blur(radius: 3)
                }
                .position(x: w / 2, y: h / 2)
            }
        }
    }

    /// Спросить систему по-настоящему и поправить чип, если дешёвая примета обманула.
    @MainActor
    private func refineCloudAvailability() async {
        let real = await Task.detached(priority: .utility) {
            CloudStatusService.refreshAvailability()
        }.value
        if real != icloudAvailable {
            icloudAvailable = real
            mountedVolumesRevision &+= 1
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(volumeButtons, id: \.label) { vol in
                volumeButtonView(vol)
            }

            // Remote session buttons — before network icon. Every live session, not only
            // this panel's: a connection is a place files live, and it was invisible from
            // the other panel until it had been opened there a second time.
            ForEach(RemoteSessionRegistry.chips(own: viewModel.remoteSession,
                                                all: sessionRegistry.sessions)) { chip in
                remoteSessionButton(chip.session, foreign: chip.foreign)
            }

            // Network connect button — popup menu with LAN / FTP options
            // Custom popover (not a native Menu) so the highlight uses the app accent.
            Button {
                showNetworkMenu = true
            } label: {
                Image(systemName: "network")
                    .font(.system(size: BarGlyph.size))
                    .frame(width: BarGlyph.box, height: BarGlyph.box)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("network.connectToServer"))
            .popover(isPresented: $showNetworkMenu, arrowEdge: .bottom) {
                // Shared with the centre divider's "Сеть" button — see NetworkMenuContent.
                NetworkMenuContent(
                    accent: accent,
                    onLocalNetwork: onLocalNetwork,
                    onConnectNetworkDrive: onConnectNetworkDrive,
                    onFTPDisk: onNetwork,
                    onDismiss: { showNetworkMenu = false }
                )
            }

            Spacer(minLength: 0)

            // View mode buttons
            viewModeGroup
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        // Unified with the breadcrumb + tab bars (same interface tint). No bottom
        // divider: the single separator lives under the window titlebar, so the
        // volume/tab bars read as one unified header.
        .interfaceBackground()
        // Volume events come through NSWorkspace's own notification center —
        // NOT NotificationCenter.default. Using the default center means these
        // never fire, so a disk ejected in the other panel stays in this one.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            mountedVolumesRevision &+= 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            mountedVolumesRevision &+= 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            mountedVolumesRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .volumeBarNeedsRefresh)) { _ in
            mountedVolumesRevision &+= 1
        }
        // Switching iCloud Drive on or off in System Settings mounts nothing, so none of the
        // volume notifications above ever fire for it — without this the entry would linger
        // (or stay missing) until the program was restarted.
        .onReceive(NotificationCenter.default.publisher(
            for: .NSUbiquityIdentityDidChange)) { _ in
            CloudStatusService.forgetAvailability()
            icloudAvailable = CloudStatusService.isAvailableFast
            mountedVolumesRevision &+= 1
            Task { await refineCloudAvailability() }
        }
        // Настоящий ответ про iCloud — здесь, после появления полосы, и не на главном
        // потоке: он поднимает службу CloudDocs, а та в ответ обходит Рабочий стол и
        // Документы. Раньше этот вопрос задавался прямо из отрисовки и потому случался
        // ДО первого окна программы.
        .task { await refineCloudAvailability() }
        // The same question is worth re-asking whenever the window comes back to the front:
        // that is when the person returns from System Settings having changed it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            mountedVolumesRevision &+= 1
        }
    }

    // MARK: - Volume Button View

    /// Диск на полосе: значок, имя и, если диск извлекаемый, кнопка извлечения — всё на одном
    /// чипе. Раньше чип обнимал только имя, а кнопка извлечения торчала снаружи отдельным
    /// квадратиком — на светлой теме это читалось как обрубок.
    /// `forceActive` — для проверок, которые рисуют чип без настоящего тома под курсором.
    @ViewBuilder
    func volumeButtonView(_ vol: VolumeButtonModel, forceActive: Bool? = nil) -> some View {
        let active = forceActive ?? isCurrentVolume(vol)
        HStack(spacing: 0) {
            Button {
                if vol.isNetwork, let onOpenNetworkVolume {
                    onOpenNetworkVolume(vol.path)
                } else {
                    viewModel.loadDirectory(at: vol.path)
                }
            } label: {
                HStack(spacing: 2) {
                    if !vol.icon.isEmpty {
                        Image(systemName: vol.icon)
                            .font(.system(size: BarGlyph.size))
                            .frame(width: BarGlyph.box, height: BarGlyph.box)
                    }
                    Text(vol.label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    if vol.isReadOnlyNTFS {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7))
                            .foregroundColor(.orange)
                            .help("NTFS — read only")
                    }
                }
                .foregroundColor(
                    active
                    ? activeDiskTextColor(vol)
                    : (vol.isNetwork ? .red.opacity(0.6) : .secondary)
                )
                .frame(minWidth: 34, minHeight: 20)
                .padding(.leading, 5)
                .padding(.trailing, vol.isEjectable ? 1 : 5)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vol.path)
            .contentShape(Rectangle())
            .contextMenu {
                if vol.isEjectable {
                    Button {
                        showVolumeInfo(for: vol)
                    } label: {
                        Label(L("volume.info.menu"), systemImage: "info.circle")
                    }
                    Divider()
                    Button {
                        ejectVolume(path: vol.path, label: vol.label)
                    } label: {
                        Label("Eject", systemImage: "eject")
                    }
                }
            }

            if vol.isEjectable {
                Button {
                    ejectVolume(path: vol.path, label: vol.label)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: BarGlyph.size, weight: .medium))
                        .frame(width: BarGlyph.box, height: BarGlyph.box)
                        // На чипе — тем же цветом, что имя: кнопка часть диска, а не сосед.
                        .foregroundColor(active ? activeDiskTextColor(vol) : .secondary)
                        .frame(width: 16, height: 20)
                        .padding(.trailing, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("volume.eject.tooltip"))
                .contentShape(Rectangle())
            }
        }
        .background {
            // The disk sits on the panel's cursor: a chip in the cursor colour, rounded the
            // way the cursor is, под всей кнопкой — от значка до кнопки извлечения. In beauty
            // mode the soft bloom stays BEHIND it, so the disk still glows but no longer
            // depends on that glow to be visible — which is what made the light theme unreadable.
            ZStack {
                cursorGlow(active: active, color: cursorFrameColor(vol))
                if active, PanelVolumeBar.showsChip(beauty: beautyModeEnabled, isDark: isDark) {
                    RoundedRectangle(cornerRadius: min(8, PanelAppearanceSettings.resolvedCursorCorner),
                                     style: .continuous)
                        .fill(Color(nsColor: PanelVolumeBar.activeFillColor(isNetwork: vol.isNetwork)))
                }
            }
        }
    }

    // MARK: - Remote Session Button

    @ViewBuilder
    private func remoteSessionButton(_ session: RemoteSession, foreign: Bool = false) -> some View {
        HStack(spacing: 2) {
            Button {
                if foreign {
                    onOpenForeignRemote?(session.connection)
                } else {
                    onSwitchToRemoteTab?()
                }
            } label: {
                let active = !foreign && viewModel.insideRemote
                let iconTint: Color = active
                    ? (beautyModeEnabled && isDark ? .white : .orange)
                    : .orange.opacity(0.6)
                let parallel = connectionMgr.parallelSupport(for: session.connection.id) == true
                // System green washes out on a thin light rim — use a deep green in light mode,
                // a bright one in dark mode, and thicken the glyph so the rim actually reads.
                let parallelGreen: Color = isDark
                    ? Color(red: 0.34, green: 0.86, blue: 0.44)
                    : Color(red: 0.10, green: 0.52, blue: 0.15)
                HStack(spacing: 2) {
                    // Same familiar transfer icon; when the server allows parallel transfers its
                    // circle rim turns green (palette keeps the arrows in the normal tint).
                    Image(systemName: session.connection.proto.iconName)
                        .font(.system(size: BarGlyph.size, weight: parallel ? .bold : .regular))
                        .frame(width: BarGlyph.box, height: BarGlyph.box)
                        .symbolRenderingMode(parallel ? .palette : .monochrome)
                        .foregroundStyle(iconTint, parallel ? parallelGreen : iconTint)
                        .help(parallel ? L("network.parallel.supported") : "")
                    Text(session.connection.label.isEmpty
                         ? session.connection.host
                         : session.connection.label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                }
                .foregroundColor(active
                                 ? (beautyModeEnabled && isDark ? .white : .orange)
                                 : .orange.opacity(0.6))
                .frame(minWidth: 34, minHeight: 20)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
                if foreign {
                    onDisconnectForeignRemote?(session)
                } else if let onDisconnectRemote {
                    onDisconnectRemote()
                } else {
                    viewModel.exitRemote()
                }
            } label: {
                Image(systemName: "eject.fill")
                    .font(.system(size: BarGlyph.size, weight: .medium))
                    .frame(width: BarGlyph.box, height: BarGlyph.box)
                    .foregroundColor(.orange)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Disconnect")
            .contentShape(Rectangle())
        }
        .background { cursorGlow(active: viewModel.insideRemote, color: .orange) }
    }

    // MARK: - View Mode Buttons

    private var viewModeGroup: some View {
        HStack(spacing: 2) {
            viewModeButton(icon: "rectangle.grid.1x2", mode: .brief, tooltip: "Brief")
            viewModeButton(icon: "list.bullet", mode: .detailed, tooltip: "Detailed")
            viewModeButton(icon: "photo.on.rectangle", mode: .thumbnails, tooltip: "Thumbnails")
        }
    }

    private func viewModeButton(icon: String, mode: ViewMode, tooltip: String) -> some View {
        Button {
            viewModel.viewMode = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .foregroundColor(viewModel.viewMode == mode ? accent : .secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    // MARK: - Volume Computation

    /// "System: Macintosh HD" — the letter, then the disk the Mac actually booted from.
    /// Falls back to the bare word when the volume has no name to show.
    static func systemLabel(bootVolumeName: String? = bootVolumeName()) -> String {
        decorate("System:", with: bootVolumeName)
    }

    /// "C: dimas" — the letter, then whose home it opens. The SHORT name, because that is what
    /// the home folder is actually called on disk.
    static func homeLabel(userName: String = NSUserName()) -> String {
        decorate("C:", with: userName)
    }

    /// Longer names are cut rather than allowed to push the other disks off the bar; the full
    /// name stays available in the tooltip.
    static func decorate(_ letter: String, with name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return letter }
        let short = trimmed.count > 16 ? trimmed.prefix(15) + "…" : trimmed[...]
        return "\(letter) \(short)"
    }

    static func bootVolumeName() -> String? {
        try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    private var volumeButtons: [VolumeButtonModel] {
        _ = mountedVolumesRevision
        var buttons: [VolumeButtonModel] = []
        let homePath = normalizePath(NSHomeDirectory())

        // Both built-in buttons follow the same rule the external disks already do — the letter,
        // then WHAT it is ("D: DATA"). A bare "C:" said nothing about whose home it opens, and a
        // bare "System:" nothing about which disk the Mac booted from.
        buttons.append(VolumeButtonModel(
            label: Self.systemLabel(), path: "/",
            icon: "internaldrive", isEjectable: false
        ))
        buttons.append(VolumeButtonModel(
            label: Self.homeLabel(), path: homePath,
            icon: "internaldrive", isEjectable: false
        ))

        // iCloud Drive right after the two built-ins: it is a place files live, and reaching
        // it meant typing a path through a hidden Library folder. Shown only while iCloud
        // Drive is actually switched on — an entry that opens nothing is worse than none.
        if icloudAvailable {
            buttons.append(VolumeButtonModel(
                label: L("volume.icloud"), path: CloudStatusService.cloudDriveRoot,
                icon: "icloud", isEjectable: false
            ))
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isVolumeKey, .volumeIsInternalKey,
            .volumeNameKey, .volumeIsLocalKey
        ]

        if let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) {
            let externalVolumes = mountedVolumes
                .compactMap { url -> (url: URL, name: String, isNetwork: Bool)? in
                    guard let values = try? url.resourceValues(forKeys: resourceKeys),
                          values.isVolume == true,
                          values.volumeIsInternal != true
                    else { return nil }

                    let standardized = url.standardizedFileURL
                    let normalized = normalizePath(standardized.path)
                    guard normalized != "/", normalized != homePath else { return nil }

                    let name = values.volumeName ?? standardized.lastPathComponent
                    let isNetwork = values.volumeIsLocal == false
                    return (standardized, name, isNetwork)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Drive letters go to LOCAL disks only, consecutively (D, E, F…). Network
            // shares are identified by "computer:share", so they don't consume a letter —
            // and skipping them keeps the local letters gap-free (a USB stays D:, it can't
            // become E: just because a network mount sorted ahead of it).
            var localLetterIndex = 3 // A=0, B=1, C=2, D=3
            for volume in externalVolumes {
                let trimmedName = volume.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let isNTFS = VolumeInterfaceDetector.isNTFSReadOnly(path: volume.url.path)
                let networkHost = volume.isNetwork ? Self.resolveNetworkHost(for: volume.url) : ""

                let displayLabel: String
                if volume.isNetwork {
                    // "COMPUTER:share" (e.g. "SERVER_SO:E") — no invented drive letter.
                    let net = NetworkMountInfo.info(forPath: volume.url.path)
                    let computer = net?.computer ?? (networkHost.isEmpty ? trimmedName : networkHost)
                    let share = net?.share ?? trimmedName
                    displayLabel = share.isEmpty ? computer : "\(computer):\(share)"
                } else {
                    let letter = driveLabel(for: localLetterIndex)
                    localLetterIndex += 1
                    displayLabel = trimmedName.isEmpty ? letter : "\(letter) \(trimmedName)"
                }

                let icon = volume.isNetwork ? "externaldrive.connected.to.line.below" : "externaldrive"
                buttons.append(VolumeButtonModel(
                    label: displayLabel, path: volume.url.path, icon: icon,
                    isEjectable: true, isReadOnlyNTFS: isNTFS,
                    isNetwork: volume.isNetwork, networkHost: networkHost
                ))
            }
        }

        // Where the panel is standing when that place is on the network: the list of computers,
        // or one computer's shares. Neither is a path on any disk, so with no entry of its own
        // the bar fell back to lighting up "System:" — the boot disk — which is simply untrue.
        // The entry lives only while the panel is there; opening a share replaces it with the
        // mounted volume, which already reads "COMPUTER:share".
        if NetworkBrowserService.isNetworkPath(viewModel.currentPath) {
            let computer = NetworkBrowserService.computerName(from: viewModel.currentPath)
            buttons.append(VolumeButtonModel(
                label: computer ?? L("network.localNetwork"),
                path: computer.map { NetworkBrowserService.networkRoot + "/" + $0 }
                    ?? NetworkBrowserService.networkRoot,
                icon: "network", isEjectable: false, isNetwork: true))
        }

        // The Trash used to sit here, last, the way it does in the Dock — it lives in the
        // window toolbar now: one Trash for the window instead of one per panel bar.
        return buttons
    }

    // MARK: - Active Volume Detection

    private func isCurrentVolume(_ vol: VolumeButtonModel) -> Bool {
        guard !viewModel.insideRemote else { return false }
        return vol.label == activeVolumeLabel
    }

    private var activeVolumeLabel: String {
        var bestLabel = "System:"
        var bestPathLength = -1
        let currentPath = normalizePath(viewModel.currentPath)
        for button in volumeButtons {
            let normalizedPath = normalizePath(button.path)
            guard isSameOrDescendant(currentPath, basePath: normalizedPath) else { continue }
            if normalizedPath.count > bestPathLength {
                bestPathLength = normalizedPath.count
                bestLabel = button.label
            }
        }
        return bestLabel
    }

    // MARK: - Actions

    private func ejectVolume(path: String, label: String) {
        let volumeRoot = normalizePath(path)
        let isNetwork = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        )?.first(where: { normalizePath($0.path) == volumeRoot })
            .flatMap { try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal }
            == false

        let controller = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first

        // Actually start the eject: stop watchers, navigate both panels away, then unmount after
        // a short delay so file handles close first. Network volumes need a longer delay.
        let startEject = {
            controller?.prepareForVolumeEject(volumeRoot)
            let delay: Double = isNetwork ? 1.0 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if isNetwork {
                    // Network volumes: use diskutil unmount (more reliable for SMB/AFP)
                    self.unmountNetworkVolume(path: volumeRoot, label: label)
                } else {
                    self.ejectLocalVolume(volumeRoot: volumeRoot, label: label)
                }
            }
        }

        // Pre-flight: is OUR OWN app holding this volume? An active copy/move touching it, or an
        // unsaved editor backed by a file on it. Force-unmounting mid-write corrupts data, and
        // ejecting orphans an unsaved editor (its Save would then fail). Warn before proceeding.
        let busyOps = controller?.activeOperationTitles(onVolume: volumeRoot) ?? []
        let unsavedDocs = controller?.unsavedEditorPaths(onVolume: volumeRoot) ?? []
        guard !busyOps.isEmpty || !unsavedDocs.isEmpty else {
            startEject()
            return
        }

        var lines: [String] = []
        if !busyOps.isEmpty {
            lines.append(L("volume.eject.busy.operations"))
            lines.append(contentsOf: busyOps.map { "  • " + $0 })
        }
        if !unsavedDocs.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(L("volume.eject.busy.unsaved"))
            lines.append(contentsOf: unsavedDocs.map { "  • " + URL(fileURLWithPath: $0).lastPathComponent })
        }
        let detail = lines.joined(separator: "\n")

        fcxlPresentModal {
            if DialogService.shared.showDestructiveConfirmation(
                title: L("volume.eject.busy.title"),
                message: L("volume.eject.busy.message", label, detail),
                confirmTitle: L("volume.eject.busy.forceButton")) {
                startEject()
            }
        }
    }

    /// Eject a local disk. If it's busy, identify the blocking apps and offer
    /// a force eject instead of failing with a raw system error.
    private func ejectLocalVolume(volumeRoot: String, label: String) {
        // A disk image's volume: detach the IMAGE, as Finder does. NSWorkspace's eject leaves
        // the image attached with no volume, and macOS then refuses to open it a second time.
        if let image = FileOperationsService.imagePath(forMountPoint: volumeRoot,
                                                        info: FileOperationsService.hdiutilInfoPlist()) {
            detachImage(image, volumeRoot: volumeRoot, label: label, force: false)
            return
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volumeRoot))
            NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
        } catch {
            // Most likely "disk in use". Find what's holding it open.
            let procs = Self.blockingProcessNames(volumeRoot: volumeRoot)
            let detail = procs.isEmpty
                ? L("volume.eject.inUse.unknown")
                : procs.joined(separator: ", ")
            // This runs inside an asyncAfter (main-queue) block, which parks the queue and
            // would kill the FCXLDialog's buttons — enter the confirmation via a runloop
            // callout. The result is used right here, so no need to return it.
            fcxlPresentModal {
                if DialogService.shared.showDestructiveConfirmation(
                    title: L("volume.eject.inUse.title"),
                    message: L("volume.eject.inUse.message", label, detail),
                    confirmTitle: L("volume.eject.forceButton")) {
                    Self.forceEject(volumeRoot: volumeRoot, label: label)
                }
            }
        }
    }

    /// What is holding the volume: each blocker as "App — file", or just the app when the file
    /// cannot be told. Ourselves included — being told "Totum Commander is holding it" is worth
    /// far more than being told nothing.
    ///
    /// NB: lsof lives in /usr/sbin on macOS. It was being run from /usr/bin, which does not
    /// exist, so the launch threw and every disk reported "could not determine the processes".
    static func blockingProcessNames(volumeRoot: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // +c0 = full command names; -Fcn = field output (c=command, n=name).
        // -b avoids kernel calls that can block on a stalled network mount.
        proc.arguments = ["-w", "-b", "+c0", "-Fcn"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak proc] in if proc?.isRunning == true { proc?.terminate() } }
        timer.resume()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timer.cancel()

        return parseBlockers(lsofOutput: String(data: data, encoding: .utf8) ?? "",
                             volumeRoot: volumeRoot)
    }

    /// Turn lsof's field output into one readable line per blocker.
    nonisolated static func parseBlockers(lsofOutput: String, volumeRoot: String) -> [String] {
        let prefix = volumeRoot.hasSuffix("/") ? volumeRoot : volumeRoot + "/"
        // First file seen per process — one line each, so a process with 40 open files does not
        // fill the dialog.
        var firstFile: [String: String] = [:]
        var order: [String] = []
        var current = ""
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("c") {
                current = String(line.dropFirst())
            } else if line.hasPrefix("n"), !current.isEmpty {
                let path = String(line.dropFirst())
                guard path == volumeRoot || path.hasPrefix(prefix) else { continue }
                let app = current == "TotumComXL" ? "Totum Commander" : current
                if firstFile[app] == nil {
                    order.append(app)
                    // The volume root itself is just "somebody is standing in it" — no file to name.
                    firstFile[app] = path == volumeRoot ? "" : String(path.dropFirst(prefix.count))
                }
            }
        }
        return order.sorted().prefix(12).map { app in
            let file = firstFile[app] ?? ""
            return file.isEmpty ? app : "\(app) — \(file)"
        }
    }

    /// Detach a mounted image OFF the main thread: diskarbitrationd asks this very app to
    /// approve the unmount, on the main run loop — waiting for hdiutil there is a 14 s stall
    /// (see VaultService.lockOffMain). A busy image asks before being forced, like a disk.
    private func detachImage(_ image: String, volumeRoot: String, label: String, force: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try FileOperationsService.detachImage(at: image, force: force) } catch { failure = error }
            DispatchQueue.main.async {
                guard let failure else {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                    return
                }
                guard !force else {
                    DialogService.shared.showOperationError(title: L("volume.eject.failed.title"),
                                                            error: failure)
                    return
                }
                let procs = Self.blockingProcessNames(volumeRoot: volumeRoot)
                let detail = procs.isEmpty ? L("volume.eject.inUse.unknown")
                                           : procs.joined(separator: ", ")
                fcxlPresentModal {
                    if DialogService.shared.showDestructiveConfirmation(
                        title: L("volume.eject.inUse.title"),
                        message: L("volume.eject.inUse.message", label, detail),
                        confirmTitle: L("volume.eject.forceButton")) {
                        self.detachImage(image, volumeRoot: volumeRoot, label: label, force: true)
                    }
                }
            }
        }
    }

    /// Force-unmount then eject via diskutil.
    private static func forceEject(volumeRoot: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            func run(_ args: [String]) -> Int32 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                p.arguments = args
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
                catch { return -1 }
            }
            _ = run(["unmount", "force", volumeRoot])
            let ejectStatus = run(["eject", volumeRoot])
            DispatchQueue.main.async {
                if ejectStatus == 0 || !FileManager.default.fileExists(atPath: volumeRoot) {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                } else {
                    DialogService.shared.showError(
                        title: L("volume.eject.failed.title"),
                        message: L("volume.eject.forceFailed", label))
                }
            }
        }
    }

    /// Unmount a network volume using diskutil (more reliable than NSWorkspace for SMB/AFP).
    /// If the graceful unmount fails (the share is busy), ASK before force-unmounting — a silent
    /// force can tear the share out from under an in-flight transfer and corrupt data.
    private func unmountNetworkVolume(path: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runDiskutil(["unmount", path])
            if result.code == 0 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                }
                return
            }

            // Graceful unmount failed — the share is busy. Name the blocking apps and ask for
            // confirmation (same flow as a local disk) instead of forcing silently.
            let procs = Self.blockingProcessNames(volumeRoot: path)
            let detail = procs.isEmpty
                ? L("volume.eject.inUse.unknown")
                : procs.joined(separator: ", ")
            DispatchQueue.main.async {
                fcxlPresentModal {
                    guard DialogService.shared.showDestructiveConfirmation(
                        title: L("volume.eject.inUse.title"),
                        message: L("volume.eject.inUse.message", label, detail),
                        confirmTitle: L("volume.eject.forceButton")) else { return }
                    Self.forceUnmountNetwork(path: path, label: label)
                }
            }
        }
    }

    /// Force-unmount a busy network share (no `diskutil eject` — network mounts aren't ejected).
    private static func forceUnmountNetwork(path: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runDiskutil(["unmount", "force", path])
            DispatchQueue.main.async {
                if result.code == 0 || !FileManager.default.fileExists(atPath: path) {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                } else {
                    DialogService.shared.showError(
                        title: L("volume.eject.failed.title"),
                        message: result.err.isEmpty ? L("volume.eject.forceFailed", label) : result.err)
                }
            }
        }
    }

    /// Run diskutil with the given arguments; returns the exit code and trimmed stderr.
    private static func runDiskutil(_ args: [String]) -> (code: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let err = (String(data: errData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus, err)
    }

    private func showVolumeInfo(for vol: VolumeButtonModel) {
        let url = URL(fileURLWithPath: vol.path)
        let info = VolumeInterfaceDetector.detect(forPath: vol.path)

        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let name = values?.volumeName ?? vol.label
        let fs = values?.volumeLocalizedFormatDescription ?? "Unknown"
        let total = values?.volumeTotalCapacity ?? 0
        let free = values?.volumeAvailableCapacity ?? 0
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file

        let data = VolumeInfoSheetData(
            name: name,
            icon: NSWorkspace.shared.icon(forFile: vol.path),
            interface: info.displayName,
            filesystem: fs,
            totalSpace: fmt.string(fromByteCount: Int64(total)),
            freeSpace: fmt.string(fromByteCount: Int64(free)),
            isFast: info.isFast,
            mode: info.modeDescription
        )

        // A context-menu action runs as a main-QUEUE block: opening the modal straight
        // from here would park the queue and starve the dialog's own OK button.
        fcxlPresentModal {
            _ = FCXLDialog.runModal(size: NSSize(width: 420, height: 380)) { (session: FCXLDialogSession<Bool>) in
                VolumeInfoDialogView(info: data, session: session)
            }
        }
    }

    // MARK: - Helpers

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isSameOrDescendant(_ path: String, basePath: String) -> Bool {
        let normalized = normalizePath(basePath)
        return path == normalized || path.hasPrefix(normalized + "/")
    }

    private func driveLabel(for index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = index
        var symbols: [Character] = []
        repeat {
            let remainder = value % 26
            symbols.append(letters[remainder])
            value = (value / 26) - 1
        } while value >= 0
        return String(symbols.reversed()) + ":"
    }

    private static func resolveNetworkHost(for volumeURL: URL) -> String {
        guard let values = try? volumeURL.resourceValues(forKeys: [.volumeURLForRemountingKey]),
              let remountURL = values.volumeURLForRemounting,
              let host = remountURL.host else {
            return ""
        }
        return host
    }
}

// MARK: - Models

struct VolumeButtonModel {
    let label: String
    let path: String
    let icon: String
    let isEjectable: Bool
    var isReadOnlyNTFS: Bool = false
    var isNetwork: Bool = false
    var networkHost: String = ""
}

// MARK: - Volume Info dialog

private struct VolumeInfoSheetData {
    let name: String
    /// The volume's real Finder icon — an actual USB stick / network globe / Macintosh HD,
    /// whatever the system already draws for this disk.
    let icon: NSImage
    let interface: String
    let filesystem: String
    let totalSpace: String
    let freeSpace: String
    let isFast: Bool
    let mode: String
}

/// Disk info in the app's dialog style (FCXLDialog kit): icon + name in the header, the
/// facts in a form card, and the speed policy as the card's footnote — the footnote keeps
/// the ✓/⚠ badge because that's the one thing here that must read at a glance, and it now
/// sits next to the text it actually describes.
private struct VolumeInfoDialogView: View {
    let info: VolumeInfoSheetData
    let session: FCXLDialogSession<Bool>

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: info.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                Text(info.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            FCXLFormCard {
                valueRow(L("volume.info.interface"), info.interface)
                valueRow(L("volume.info.filesystem"), info.filesystem)
                valueRow(L("volume.info.total"), info.totalSpace)
                valueRow(L("volume.info.free"), info.freeSpace, showDivider: false)
            }
            .padding(.horizontal, 20)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: info.isFast ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(info.isFast ? Color.green : Color.orange)
                Text(info.mode)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.top, 10)

            Spacer(minLength: 12)

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("button.ok"), role: .primary) { session.finish(true) }
            ])
        }
    }

    private func valueRow(_ label: String, _ value: String, showDivider: Bool = true) -> some View {
        FCXLFormRow(label: label, showDivider: showDivider) {
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
