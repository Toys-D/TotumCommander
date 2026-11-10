import AppKit
import SwiftUI

extension Notification.Name {
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
    /// Полоса читает только место панели: путь, режим, хранилище. Наблюдается `state`, а не
    /// вся модель: та шлёт objectWillChange и на каждое движение курсора, и полоса
    /// перерисовывалась на каждое нажатие стрелки (измерено по стекам).
    @ObservedObject var state: PanelState
    var viewModel: PanelViewModel
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
    /// Местный диск: контроллер знает про вкладки и из вкладки хранилища уводит на соседнюю
    /// местную, не отключая хранилище. Без него — прямой переход панели.
    var onOpenLocalVolume: ((String) -> Void)?
    /// Чип сессии другой панели: открыть то же подключение здесь / закрыть его там.
    var onOpenForeignRemote: ((RemoteConnection) -> Void)?
    var onDisconnectForeignRemote: ((RemoteSession) -> Void)?
    @State private var mountedVolumesRevision: Int = 0
    /// Кнопки и активная метка на одну отрисовку. Раньше `volumeButtons` пересчитывался для
    /// КАЖДОЙ кнопки (через isCurrentVolume → activeVolumeLabel), с обходом смонтированных
    /// томов и обращениями к диску, и всё это на каждое движение курсора — полоса наблюдает
    /// модель панели целиком. Класс, а не @State: правится во время отрисовки без перерисовки.
    @State private var render = RenderCache()

    final class RenderCache {
        var key = ""
        var buttons: [VolumeButtonModel] = []
        var activeKey = ""
        var activeLabel = ""
    }
    @State private var networkAnchor = MenuAnchorBox()
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
                // Shared with the centre divider's "Сеть" button — see NetworkMenu.
                let menu = NetworkMenu.build(
                    onLocalNetwork: onLocalNetwork,
                    onConnectNetworkDrive: onConnectNetworkDrive,
                    onFTPDisk: onNetwork,
                    clouds: CloudPlaces.placements(icloudAvailable: icloudAvailable)
                        .filter { !$0.placement.isInBar },
                    onCloud: { provider, placement in
                        CloudPlaces.activate(provider, placement: placement)
                        mountedVolumesRevision &+= 1
                    })
                ContextPopupMenuController.shared.show(menu, anchoredTo: networkAnchor.view, edge: .minY)
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
            .background(MenuAnchorProbe(networkAnchor))

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
        // Папка поставщика облака появляется после входа в его программу — полоса узнаёт сама.
        .onAppear { CloudStorageWatcher.shared.start() }
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
        .focusEffectDisabled()
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
                } else if let onOpenLocalVolume {
                    onOpenLocalVolume(vol.path)
                } else {
                    viewModel.navigateToLocal(vol.path)
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
            // Правый щелчок — меню программы, как у вкладок и файлов, а не системное.
            .overlay { RightClickMenu { volumeMenu(for: vol) } }

            if vol.isEjectable {
                Button {
                    if let cloud = vol.cloud {
                        CloudPlaces.hide(cloud)
                        mountedVolumesRevision &+= 1
                    } else {
                        ejectVolume(path: vol.path, label: vol.label)
                    }
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
                .help(vol.cloud == nil ? L("volume.eject.tooltip") : L("volume.cloud.hide"))
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
                // Активное хранилище сидит на том же чипе, что и активный диск: на светлой
                // теме и без «красоты» — сплошной, а свечение только позади него. Иначе
                // хранилище одно светилось размытым пятном, когда диски стояли на чипах.
                let onChip = active && PanelVolumeBar.showsChip(beauty: beautyModeEnabled, isDark: isDark)
                let activeInk: Color = onChip
                    ? Color(nsColor: PanelVolumeBar.remoteChipColors().label)
                    : .white
                let iconTint: Color = active ? activeInk : .orange.opacity(0.6)
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
                .foregroundColor(active ? activeInk : .orange.opacity(0.6))
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
                // На чипе извлечение белое, как надпись: оранжевое на оранжевом пропадало.
                let onChip = !foreign && viewModel.insideRemote
                    && PanelVolumeBar.showsChip(beauty: beautyModeEnabled, isDark: isDark)
                Image(systemName: "eject.fill")
                    .font(.system(size: BarGlyph.size, weight: .medium))
                    .frame(width: BarGlyph.box, height: BarGlyph.box)
                    .foregroundColor(onChip ? Color(nsColor: PanelVolumeBar.remoteChipColors().label) : .orange)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Disconnect")
            .contentShape(Rectangle())
        }
        .background {
            let active = !foreign && viewModel.insideRemote
            ZStack {
                cursorGlow(active: active, color: .orange)
                if active, PanelVolumeBar.showsChip(beauty: beautyModeEnabled, isDark: isDark) {
                    RoundedRectangle(cornerRadius: min(8, PanelAppearanceSettings.resolvedCursorCorner),
                                     style: .continuous)
                        .fill(Color(nsColor: PanelVolumeBar.remoteChipColors().fill))
                }
            }
        }
    }

    /// Чип активного хранилища и надпись на нём: хранилища оранжевые, надпись белая — как
    /// у дисков на их чипе, по слову пользователя.
    static func remoteChipColors() -> (fill: NSColor, label: NSColor) {
        (NSColor.systemOrange, .white)
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

    /// "C: dimas" — the letter, then whose home it opens: the home folder's own name on disk
    /// (for an ordinary account that is the short user name). Taken from the folder, not from
    /// NSUserName(), so a home moved elsewhere (CFFIXED_USER_HOME) is named for what it is.
    static func homeLabel(userName: String = (NSHomeDirectory() as NSString).lastPathComponent) -> String {
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
        let key = "\(mountedVolumesRevision)|\(icloudAvailable)|\(viewModel.currentPath)|\(viewModel.state.insideNetworkBrowser)"
        if render.key == key { return render.buttons }
        let buttons = computeVolumeButtons()
        render.key = key
        render.buttons = buttons
        return buttons
    }

    private func computeVolumeButtons() -> [VolumeButtonModel] {
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
        // Облака: iCloud и подключённые их родными программами (Google Drive for desktop,
        // OneDrive, Dropbox) — обычные папки в ~/Library/CloudStorage, без rclone и квот.
        // Убранные человеком ждут в меню сети.
        let hiddenClouds = CloudPlaces.hidden
        if icloudAvailable, !hiddenClouds.contains(.icloud) {
            buttons.append(VolumeButtonModel(
                label: L("volume.icloud"), path: CloudStatusService.cloudDriveRoot,
                icon: "icloud", isEjectable: true, cloud: .icloud
            ))
        }
        let cloudFolders = CloudStorageVolumes.volumes()
        for cloud in cloudFolders {
            if let known = cloud.provider, hiddenClouds.contains(known) { continue }
            buttons.append(VolumeButtonModel(
                label: cloud.label, path: cloud.path, icon: cloud.provider?.icon ?? "cloud",
                isEjectable: cloud.provider != nil, cloud: cloud.provider
            ))
        }
        // Поставщики, которые кладут диск не в CloudStorage (Яндекс — папкой в домашней).
        // Том в /Volumes (pCloud Drive) полоса уже показывает как обычный диск — не дублируем.
        for provider in CloudProvider.allCases where !provider.extraPaths.isEmpty
            && !hiddenClouds.contains(provider)
            && !cloudFolders.contains(where: { $0.provider == provider }) {
            if let path = provider.connectedPath(cloudStorage: []), !path.hasPrefix("/Volumes/") {
                buttons.append(VolumeButtonModel(label: provider.title, path: path,
                                                 icon: provider.icon, isEjectable: true, cloud: provider))
            }
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
        let buttons = volumeButtons
        let key = render.key + "|" + viewModel.currentPath
        if render.activeKey == key { return render.activeLabel }
        let label = activeLabel(currentPath: viewModel.currentPath, buttons: buttons)
        render.activeKey = key
        render.activeLabel = label
        return label
    }

    /// Выбор активного диска: самый длинный путь кнопки, внутри которого стоит панель.
    private func activeLabel(currentPath rawPath: String, buttons: [VolumeButtonModel]) -> String {
        var bestLabel = "System:"
        var bestPathLength = -1
        let currentPath = normalizePath(rawPath)
        for button in buttons {
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
        VolumeEject.eject(path: path, label: label)
    }

    /// Меню диска по правому щелчку: сведения и извлечение — у того, что можно извлечь
    /// (облако прячется своей кнопкой на чипе). Остальным меню нет.
    private func volumeMenu(for vol: VolumeButtonModel) -> NSMenu? {
        guard vol.isEjectable, vol.cloud == nil else { return nil }
        let menu = NSMenu()
        menu.addStyledItem(title: L("volume.info.menu"), symbolName: "info.circle", id: "volume.info") {
            showVolumeInfo(for: vol)
        }
        menu.addItem(.separator())
        menu.addStyledItem(title: L("volume.eject.tooltip"), symbolName: "eject", id: "volume.eject") {
            ejectVolume(path: vol.path, label: vol.label)
        }
        return menu
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
    /// Облако: «извлечение» его не отключает, а убирает в меню сети.
    var cloud: CloudProvider? = nil
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
