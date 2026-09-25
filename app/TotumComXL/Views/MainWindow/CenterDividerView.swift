import SwiftUI

// MARK: - Quick Link model

struct QuickLink {
    let icon: String
    let label: String
    let short: String
    let path: String
}

// Прошитого списка больше нет: папки туннеля живут в TunnelStore, и человек
// правит их сам — правой кнопкой и перетаскиванием.

// MARK: - DividerButtonView

struct DividerButtonView: View {

    /// Что кнопка сообщает туннелю, когда её тащат: где мышь (по вертикали, в координатах
    /// туннеля) и что отпустили.
    enum ReorderPhase {
        case moved(CGFloat)
        case ended
    }

    let icon: String
    let tooltip: String
    var subtitle: String? = nil
    var isActive: Bool = false
    /// A wide tunnel reads as a list: icon and name side by side, like a menu row. A narrow
    /// one stacks them, the way it always has. The tunnel decides — it knows its own width.
    var horizontal: Bool = false
    /// Кнопку можно тащить: зажал и повёл — она едет. nil — кнопка стоит на месте.
    var onReorder: ((ReorderPhase) -> Void)? = nil
    /// Призрак под курсором: цветом акцента, крупнее, с тенью — видно, что взято в руку.
    var lifted: Bool = false
    let action: () -> Void
    @State private var isHovered = false
    @State private var isDragging = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    /// Нажатие — свой жест, а не Button: у Button на macOS щелчок и перетаскивание не
    /// уживаются (после протяжки он всё равно срабатывает, как будто щёлкнули).
    /// Отпустили, не сдвинув, — щелчок; повели — перетаскивание, и щелчка не будет.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CenterDividerView.spaceName))
            .onChanged { value in
                guard onReorder != nil else { return }
                if !isDragging, abs(value.translation.height) > 5 { isDragging = true }
                if isDragging { onReorder?(.moved(value.location.y)) }
            }
            .onEnded { value in
                if isDragging {
                    isDragging = false
                    onReorder?(.ended)
                    return
                }
                if abs(value.translation.width) < 6, abs(value.translation.height) < 6 {
                    action()
                }
            }
    }

    /// «Вы здесь» — значок жирнее и чуть крупнее, без рамок и плашек. Одним цветом не
    /// обойтись: у серо-синего акцента значок в нём неотличим от обычного серого.
    private var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: isActive ? 13 : 11, weight: isActive ? .bold : .medium))
            .frame(width: 18, height: 14)
    }

    var body: some View {
        Group {
            Group {
                if horizontal, let subtitle {
                    HStack(spacing: 6) {
                        iconView
                        Text(subtitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                } else {
                    VStack(spacing: 1) {
                        iconView
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 8))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 22)
            // Где человек стоит сейчас — подпись акцентом и чуть крупнее, но слабее, чем под
            // мышью: подсказка «вы здесь», а не вторая кнопка.
            .foregroundStyle(isHovered || lifted || isActive ? accent : Color.secondary)
            .scaleEffect(isHovered || lifted ? 1.15 : 1.0)
            .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 4, y: 2)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .gesture(press)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// Высота, которую туннелю дал контейнер.
private struct TunnelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Рамки кнопок туннеля в его координатах — чтобы знать, где чьё место.
private struct TunnelFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private extension View {
    /// Кнопка отчитывается о своей рамке в координатах туннеля.
    func reportsTunnelFrame(id: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: TunnelFramesKey.self,
                                   value: [id: geo.frame(in: .named(CenterDividerView.spaceName))])
        })
    }
}

// MARK: - CenterDividerView

struct CenterDividerView: View {
    @State private var showNetworkMenu = false
    /// The queue drops out of its own button — the same popover manner as the network menu.
    /// A separate floating window was one more window to find, move and lose.
    @State private var showQueuePopover = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var dividerAccentHex: String = ""
    private var dividerAccent: Color {
        PanelAppearanceSettings.swiftUIColor(from: dividerAccentHex, fallback: .purple)
    }
    let activePanelPath: String
    let isLeftPanelActive: Bool
    let splitRatio: CGFloat
    let onSwap: () -> Void
    let onCopy: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    let onMkdir: () -> Void
    let onView: () -> Void
    let onEdit: () -> Void
    let onQuickLink: (String) -> Void
    var onNetwork: (() -> Void)? = nil
    var onLocalNetwork: (() -> Void)? = nil
    /// Finder-style "Connect to Server" — same entry the drive bar's globe offers.
    /// Declared last so the existing call site's argument order stays valid.
    var onConnectNetworkDriveAction: (() -> Void)? = nil
    var queueVM: OperationQueueViewModel? = nil
    var onShowQueuePanel: (() -> Void)? = nil
    /// Меню туннеля (пропорции, обмен панелей) — теперь общее контекстное меню вида,
    /// а не перехват правого клика на подлёте: перехват съедал и меню папок с операциями.
    var onSetRatio: ((CGFloat) -> Void)? = nil
    var onSyncLeftToRight: (() -> Void)? = nil
    var onSyncRightToLeft: (() -> Void)? = nil
    /// Показать меню «Ещё» — AppKit-меню со значками, всплывающее у курсора.
    var onPopUpMenu: ((NSMenu) -> Void)? = nil

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    @ObservedObject private var tunnel = TunnelStore.shared

    /// Имя координатного пространства туннеля: в нём меряются рамки кнопок и движение мыши.
    static let spaceName = "tunnel"
    @State private var frames: [String: CGRect] = [:]
    @State private var reorder: TunnelReorder?
    /// Высота, которую туннелю дал контейнер, — от неё считается, сколько кнопок влезает.
    @State private var tunnelHeight: CGFloat = 0
    /// Бросок папки извне: AppKit ведёт точку, вид рисует черту там, куда она встанет.
    @ObservedObject private var drop = TunnelDropState.shared

    @AppStorage("centerDividerWidth") private var centerDividerWidth: Double = 36
    @AppStorage("dividerShowLabels") private var dividerShowLabels: Bool = true
    @AppStorage("dividerIconSpacing") private var dividerIconSpacing: Double = 2
    @AppStorage("dividerOffsetY") private var dividerOffsetY: Double = 0
    @AppStorage("dividerShowQuickLinks") private var dividerShowQuickLinks: Bool = true
    @AppStorage("dividerBorderOpacity") private var dividerBorderOpacity: Double = 0.15
    @AppStorage("dividerBorderWidth") private var dividerBorderWidth: Double = 1
    @AppStorage("quickLinksGap") private var quickLinksGap: Double = 12

    private enum LabelMode {
        case full, short, none
    }

    private var effectiveLabelMode: LabelMode {
        guard dividerShowLabels else { return .none }
        if centerDividerWidth >= 46 { return .full }
        if centerDividerWidth >= 40 { return .short }
        return .none
    }

    /// Wide enough for "icon — name" in one line: the row layout. The threshold is where the
    /// longest full label ("Рабочий стол") plus the icon stops being cramped.
    private var rowLayout: Bool {
        dividerShowLabels && centerDividerWidth >= 100
    }

    private func labelText(_ full: String, short: String, mode: LabelMode) -> String? {
        switch mode {
        case .full: return full
        case .short: return short
        case .none: return nil
        }
    }

    /// Пропорции и обмен панелей — то, что раньше жило в перехваченном правом клике.
    // MARK: - Туннель: операции

    /// Стрелка «переместить» смотрит в сторону соседней панели — как смотрела всегда.
    private func actionIcon(for action: TunnelStore.Action) -> String {
        guard action.key == "builtin:move" else { return action.icon }
        return isLeftPanelActive ? "arrow.right" : "arrow.left"
    }

    private func actionTooltip(for action: TunnelStore.Action) -> String {
        if let builtin = TunnelStore.builtinActions[action.key] { return L(builtin.help) }
        return action.label
    }

    private func run(_ action: TunnelStore.Action) {
        switch action.key {
        case "builtin:copy": onCopy()
        case "builtin:move": onMove()
        case "builtin:delete": onDelete()
        case "builtin:mkdir": onMkdir()
        case "builtin:view": onView()
        case "builtin:edit": onEdit()
        default:
            // Команда меню — исполняется ровно так, как выбор её в меню: тем же пунктом,
            // с теми же проверками. Ключ — «Группа▸Название», как её знает палитра.
            let body = String(action.key.dropFirst("menu:".count))
            guard let split = body.range(of: "▸") else { return }
            let group = String(body[..<split.lowerBound])
            let title = String(body[split.upperBound...])
            if let command = CommandRegistry.commands()
                .first(where: { $0.group == group && $0.title == title }) {
                CommandRegistry.run(command)
            }
        }
    }

    var body: some View {
        let labelMode = effectiveLabelMode

        // Туннель никогда не выходит за свои границы: основа — пустой прямоугольник ровно в
        // размер, который дал контейнер; кнопки лежат поверх него от верхнего края, а что не
        // влезло — уходит в «Ещё» и в крайнем случае режется по рамке. Раньше высоту задавала
        // сама стопка кнопок, и при низком окне она рисовалась поверх панели инструментов.
        Color.clear
            .background(GeometryReader { geo in
                Color.clear.preference(key: TunnelHeightKey.self, value: geo.size.height)
            })
            .overlay(alignment: .top) { stack(labelMode: labelMode) }
            .frame(width: CGFloat(centerDividerWidth))
            .overlay(alignment: .leading) {
                Color.white.opacity(dividerBorderOpacity).frame(width: dividerBorderWidth)
            }
            .overlay(alignment: .trailing) {
                Color.white.opacity(dividerBorderOpacity).frame(width: dividerBorderWidth)
            }
            // Правая кнопка — у AppKit (TunnelDropHostingView.menu(for:)): SwiftUI-меню на
            // macOS значков не рисует, а меню туннеля со значками были всегда. Кто под
            // курсором — папка, операция или пустое место — решается по рамкам кнопок ниже.
            .contentShape(Rectangle())
            // OPAQUE: the tunnel used to be 0.5-translucent over the window background,
            // which looked identical while the window bg WAS the interface colour — but a
            // custom titlebar colour now owns the window bg and bled through. An opaque
            // interface fill renders exactly the same colour, independent of the window.
            .interfaceBackground()
            .clipped()
            .coordinateSpace(name: Self.spaceName)
            .onPreferenceChange(TunnelHeightKey.self) { tunnelHeight = $0 }
            .onPreferenceChange(TunnelFramesKey.self) { value in
                frames = value
                drop.folderSlots = visibleFolders.compactMap { value[$0.path] }
                drop.actionSlots = visibleActions.compactMap { value[$0.key] }
                drop.gap = CGFloat(dividerIconSpacing)
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let reorder { ghost(reorder, labelMode: labelMode) }
                    if let index = drop.insertionIndex,
                       let y = TunnelDrop.lineY(index: index, slots: drop.folderSlots, gap: drop.gap) {
                        Capsule().fill(accent)
                            .frame(width: max(CGFloat(centerDividerWidth) - 12, 8), height: 3)
                            .position(x: CGFloat(centerDividerWidth) / 2, y: y)
                            .allowsHitTesting(false)
                    }
                }
            }
    }

    /// Стопка кнопок: шапка, папки, разделитель, операции — с «Ещё» там, где не влезло.
    @ViewBuilder
    private func stack(labelMode: LabelMode) -> some View {
        let spacing = CGFloat(dividerIconSpacing)
        VStack(spacing: spacing) {
            VStack(spacing: spacing) {
                Spacer().frame(maxHeight: 8)

                DividerButtonView(icon: "arrow.left.arrow.right", tooltip: L("divider.swap")) {
                    onSwap()
                }
                .accessibilityLabel(L("accessibility.swap_panels"))

                Text(String(format: "%.1f / %.1f", splitRatio * 100, (1 - splitRatio) * 100))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // The queue's own door, always in the tunnel. Two circling arrows with a clock
                // inside; when something is queued, the CLOCK gives its place to the count —
                // the icon itself answers "how many", no separate badge anywhere. Drawn a step
                // larger than the other tunnel buttons so the digit is legible at a glance.
                QueueTunnelButton(queueVM: queueVM, accent: accent) {
                    showQueuePopover.toggle()
                }
                .popover(isPresented: $showQueuePopover, arrowEdge: .bottom) {
                    if let queueVM {
                        OperationQueuePanelContent(viewModel: queueVM)
                            .frame(width: 440, height: 340)
                            .modifier(EscapeClosesPopover { showQueuePopover = false })
                    }
                }
                .accessibilityLabel(L("queue.title"))

                // MARK: - Queue mini progress bars
                if let queueVM {
                    QueueMiniProgressView(queueVM: queueVM) {
                        showQueuePopover = true
                    }
                }
            }
            .reportsTunnelFrame(id: Self.topBlockID)

            Rectangle().fill(Color.clear).frame(maxHeight: .infinity).contentShape(Rectangle())

            if dividerOffsetY < 0 {
                Spacer().frame(maxHeight: max(-stackOffset, 0))
            }

            if dividerShowQuickLinks {
                VStack(spacing: spacing) {
                    ForEach(visibleFolders) { folder in
                        DividerButtonView(
                            icon: folder.icon,
                            tooltip: folder.label,
                            subtitle: labelText(folder.label, short: folder.shortLabel,
                                                mode: labelMode),
                            isActive: TunnelStore.marksCurrent(folder: folder.path,
                                                             panel: activePanelPath),
                            horizontal: rowLayout,
                            onReorder: { drag($0, section: .folders, id: folder.path) }
                        ) {
                            onQuickLink(folder.path)
                        }
                        .accessibilityLabel(folder.label)
                        .opacity(reorder?.id == folder.path ? 0.25 : 1)
                        .reportsTunnelFrame(id: folder.path)
                    }

                    if plan.foldersHidden {
                        moreButton(labelMode: labelMode) { showMoreFolders() }
                    }

                    // Same LAN / FTP choice the drive bar's network icon offers — this
                    // button used to jump straight to FTP, silently dropping half the options.
                    if networkVisible {
                        DividerButtonView(icon: "network", tooltip: L("network.connectToServer"),
                                          subtitle: labelText(L("quickLink.network"), short: L("quickLink.short.network"), mode: labelMode),
                                          horizontal: rowLayout) {
                            showNetworkMenu = true
                        }
                        .popover(isPresented: $showNetworkMenu, arrowEdge: .trailing) {
                            // Shared with the drive bar's globe button — see NetworkMenuContent.
                            NetworkMenuContent(
                                accent: dividerAccent,
                                onLocalNetwork: onLocalNetwork,
                                onConnectNetworkDrive: onConnectNetworkDriveAction,
                                onFTPDisk: onNetwork,
                                onDismiss: { showNetworkMenu = false }
                            )
                        }
                    }
                }
                VStack(spacing: 0) {
                    Spacer().frame(maxHeight: CGFloat(quickLinksGap))
                    Divider().padding(.horizontal, 4)
                    Spacer().frame(maxHeight: 4)
                }
                .reportsTunnelFrame(id: Self.midBlockID)
            } else {
                Spacer().frame(maxHeight: 4)
            }

            ForEach(visibleActions) { action in
                DividerButtonView(icon: actionIcon(for: action),
                                  tooltip: actionTooltip(for: action),
                                  subtitle: labelText(action.label, short: action.shortLabel,
                                                      mode: labelMode),
                                  horizontal: rowLayout,
                                  onReorder: { drag($0, section: .actions, id: action.key) }) {
                    run(action)
                }
                .accessibilityLabel(action.label)
                .opacity(reorder?.id == action.key ? 0.25 : 1)
                .reportsTunnelFrame(id: action.key)
            }

            if plan.actionsHidden {
                moreButton(labelMode: labelMode) { showMoreActions() }
            }

            if dividerOffsetY > 0 {
                Spacer().frame(maxHeight: max(stackOffset, 0))
            }

            Rectangle().fill(Color.clear).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .frame(width: CGFloat(centerDividerWidth))
    }

    // MARK: - Когда не влезает

    static let topBlockID = "tunnel.top"
    static let midBlockID = "tunnel.mid"

    /// Сколько кнопок показать и на сколько сдвинуть стопку. И то и другое — из одной и
    /// той же измеренной высоты, поэтому между собой они не спорят: сначала место кнопкам,
    /// остаток — сдвигу.
    ///
    /// Считается из высоты контейнера и измеренных рамок: шапки, разделителя и одной
    /// кнопки — ни одна из них от самого расчёта не зависит, поэтому перерасчёт не
    /// зацикливается.
    private var measured: (plan: TunnelOverflow.Plan, offsetY: CGFloat) {
        let foldersNeed = dividerShowQuickLinks ? tunnel.folders.count + 1 : 0   // + «Сеть»
        let actionsNeed = tunnel.actions.count
        let wanted = CGFloat(dividerOffsetY)
        guard tunnelHeight > 0 else {
            return (.all(folders: foldersNeed, actions: actionsNeed), wanted)
        }
        let spacing = CGFloat(dividerIconSpacing)
        let top = frames[Self.topBlockID]?.height ?? 80
        let mid = dividerShowQuickLinks ? (frames[Self.midBlockID]?.height ?? 20) : 4
        let buttons = frames.filter { $0.key != Self.topBlockID && $0.key != Self.midBlockID }
        let item = TunnelOverflow.itemHeight(measured: buttons.values.map(\.height),
                                             showsLabels: dividerShowLabels)
        let available = TunnelOverflow.available(tunnelHeight: tunnelHeight, topBlock: top,
                                                 midBlock: mid, hasOffset: wanted != 0,
                                                 spacing: spacing)
        let plan = TunnelOverflow.plan(available: available, itemHeight: item, spacing: spacing,
                                       folders: foldersNeed, actions: actionsNeed)
        let left = TunnelOverflow.leftover(available: available,
                                           shown: plan.folders + plan.actions,
                                           itemHeight: item, spacing: spacing)
        return (plan, TunnelOverflow.usableOffset(wanted, leftover: left))
    }

    private var plan: TunnelOverflow.Plan { measured.plan }

    /// Сдвиг стопки после проверки на место.
    private var stackOffset: CGFloat { measured.offsetY }

    private var visibleFolders: [TunnelStore.Folder] {
        guard plan.foldersHidden else { return tunnel.folders }
        // Одно место — «Ещё», одно — «Сеть»: папкам достаётся остальное.
        return Array(tunnel.folders.prefix(max(0, plan.folders - 2)))
    }

    private var networkVisible: Bool {
        dividerShowQuickLinks && (!plan.foldersHidden || plan.folders >= 2)
    }

    private var visibleActions: [TunnelStore.Action] {
        guard plan.actionsHidden else { return tunnel.actions }
        return Array(tunnel.actions.prefix(max(0, plan.actions - 1)))
    }

    private func moreButton(labelMode: LabelMode, action: @escaping () -> Void) -> some View {
        DividerButtonView(icon: "ellipsis.circle", tooltip: L("tunnel.more"),
                          subtitle: labelText(L("tunnel.more"), short: L("tunnel.more"), mode: labelMode),
                          horizontal: rowLayout, action: action)
            .accessibilityLabel(L("tunnel.more"))
    }

    /// Спрятанные папки — списком; «Сеть», если не влезла, — тремя её пунктами.
    private func showMoreFolders() {
        let menu = NSMenu(title: "")
        for folder in tunnel.folders.dropFirst(visibleFolders.count) {
            menu.addStyledItem(title: folder.label, symbolName: folder.icon) { onQuickLink(folder.path) }
        }
        if !networkVisible {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addStyledItem(title: L("network.localNetwork"), symbolName: "network") { onLocalNetwork?() }
            menu.addStyledItem(title: L("network.connectDrive"), symbolName: "externaldrive.connected.to.line.below") {
                onConnectNetworkDriveAction?()
            }
            menu.addStyledItem(title: L("network.connectToServer"), symbolName: "globe") { onNetwork?() }
        }
        menu.applyAccentStyle()
        onPopUpMenu?(menu)
    }

    private func showMoreActions() {
        let menu = NSMenu(title: "")
        for action in tunnel.actions.dropFirst(visibleActions.count) {
            menu.addStyledItem(title: action.label, symbolName: actionIcon(for: action)) { run(action) }
        }
        menu.applyAccentStyle()
        onPopUpMenu?(menu)
    }

    // MARK: - Перетаскивание кнопок

    /// Кнопку тащат. Первый сдвиг — захват: снимок мест части; дальше призрак идёт за
    /// мышью, а кнопка переставляется к ближайшему месту, соседи съезжают с анимацией.
    private func drag(_ phase: DividerButtonView.ReorderPhase,
                      section: TunnelReorder.Section, id: String) {
        switch phase {
        case .moved(let y):
            if reorder?.id != id {
                let ids = section == .folders ? visibleFolders.map(\.path)
                                              : visibleActions.map(\.key)
                reorder = TunnelReorder(section: section, id: id, ids: ids,
                                        frames: frames, mouseY: y)
            }
            guard var current = reorder else { return }
            current.follow(mouseY: y)
            reorder = current
            let target = current.targetIndex
            switch section {
            case .folders:
                guard tunnel.folders.firstIndex(where: { $0.path == id }) != target else { return }
                withAnimation(.easeInOut(duration: 0.15)) { tunnel.moveFolder(path: id, to: target) }
            case .actions:
                guard tunnel.actions.firstIndex(where: { $0.key == id }) != target else { return }
                withAnimation(.easeInOut(duration: 0.15)) { tunnel.moveAction(key: id, to: target) }
            }
        case .ended:
            withAnimation(.easeOut(duration: 0.15)) { reorder = nil }
        }
    }

    /// Призрак взятой кнопки: та же кнопка, только поднятая, и мышь сквозь неё проходит.
    @ViewBuilder
    private func ghost(_ reorder: TunnelReorder, labelMode: LabelMode) -> some View {
        let look: (icon: String, label: String, short: String)? = {
            switch reorder.section {
            case .folders:
                return tunnel.folders.first { $0.path == reorder.id }
                    .map { ($0.icon, $0.label, $0.shortLabel) }
            case .actions:
                return tunnel.actions.first { $0.key == reorder.id }
                    .map { (actionIcon(for: $0), $0.label, $0.shortLabel) }
            }
        }()
        if let look {
            DividerButtonView(icon: look.icon, tooltip: "",
                              subtitle: labelText(look.label, short: look.short, mode: labelMode),
                              horizontal: rowLayout, lifted: true) {}
                .frame(width: CGFloat(centerDividerWidth), height: reorder.slotHeight)
                .position(x: CGFloat(centerDividerWidth) / 2, y: reorder.ghostCenter)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Escape closes the queue popover

/// Escape takes the popover down. The panels own several key monitors of their own, and
/// NSPopover's built-in Esc handling loses to them — so the popover carries its OWN
/// listener, installed while it is open and removed with it: one owner, one removal, the
/// app-wide monitor lesson.
private struct EscapeClosesPopover: ViewModifier {
    let close: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 {   // Escape
                        close()
                        return nil
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }
    }
}

// MARK: - Queue Tunnel Button

/// The queue's icon, after the user's own sketch: two arrows chasing each other in a
/// circle, a clock in the middle — "operations going around, waiting their turn". While
/// the queue holds something, the clock steps aside and the COUNT takes the centre, in the
/// accent colour; it breathes only while bytes actually move. Styled by hand to match
/// DividerButtonView (hover accent, gentle grow) — a stock control here would be a
/// stranger among the tunnel's own buttons.
private struct QueueTunnelButton: View {
    var queueVM: OperationQueueViewModel?
    let accent: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if let queueVM {
                    QueueTunnelArrows(queueVM: queueVM, accent: accent)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 19, weight: .semibold))
                }
                if let queueVM {
                    QueueTunnelCentre(queueVM: queueVM, accent: accent)
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .foregroundStyle(isHovered ? accent : Color.secondary)
            .scaleEffect(isHovered ? 1.15 : 1.0)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L("queue.title"))
    }
}

/// В каком настроении очередь — и как выглядит её значок.
///
/// Три состояния, потому что «есть задачи» и «задачи идут» — разные вещи: очередь, стоящая
/// на паузе, не должна выглядеть работающей. Чистое перечисление, чтобы правило можно было
/// проверить без экрана.
enum QueueIconState: Equatable {
    /// Пусто — значок как был, серый и неподвижный.
    case idle
    /// Задачи есть, но ничего не движется: пауза или ожидание очереди.
    case waiting
    /// Байты идут прямо сейчас.
    case working

    static func of(activeCount: Int, isProcessing: Bool) -> QueueIconState {
        guard activeCount > 0 else { return .idle }
        return isProcessing ? .working : .waiting
    }

    var spins: Bool { self == .working }
}

/// Кружащие стрелки: пока очередь работает — крутятся и зеленеют, пока стоит с задачами —
/// янтарные и неподвижные, пусто — как были. Свой вид, потому что только он смотрит за
/// очередью: наведение на кнопку не должно зависеть от неё.
private struct QueueTunnelArrows: View {
    @ObservedObject var queueVM: OperationQueueViewModel
    let accent: Color
    @State private var spin = false
    /// Цвет имени под курсором — тот же, что горит на файле, когда на нём стоишь.
    /// Через @AppStorage, чтобы значок перекрасился сразу, как только его поменяли в
    /// настройках, и по теме: у светлой и тёмной он свой.
    @AppStorage(PanelAppearanceSettings.cursorNameColorHexKey) private var cursorNameHex: String = ""

    private var state: QueueIconState {
        QueueIconState.of(activeCount: queueVM.operations.filter(\.isActive).count,
                          isProcessing: queueVM.isProcessing)
    }

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(state.spins
                       ? .linear(duration: 1.6).repeatForever(autoreverses: false)
                       : .easeOut(duration: 0.25),
                       value: spin)
            .animation(.easeInOut(duration: 0.3), value: state)
            .onAppear { spin = state.spins }
            .onChange(of: state) { newState in spin = newState.spins }
    }

    /// Цвет говорит сам: работа идёт — цветом имени под курсором, задачи ждут — янтарный,
    /// пусто — обычный серый.
    private var tint: Color {
        switch state {
        case .working: return accent
        case .waiting: return .orange
        case .idle:    return .secondary
        }
    }
}

/// The centre of the circling arrows: a clock while the queue is empty, the count while it
/// is not. Split out because only THIS part observes the view model — hovering the button
/// must not depend on the queue, and the queue must repaint only its own middle.
private struct QueueTunnelCentre: View {
    @ObservedObject var queueVM: OperationQueueViewModel
    let accent: Color
    @State private var pulse = false

    var body: some View {
        let count = queueVM.operations.filter(\.isActive).count
        if count > 0 {
            let working = queueVM.isProcessing
            Text("\(count)")
                .font(.system(size: count > 9 ? 8 : 10, weight: .heavy))
                .foregroundStyle(accent)
                .opacity(working && pulse ? 0.5 : 1.0)
                .help(String(format: L(working ? "queue.badge.tooltip" : "queue.badge.tooltip.idle"), count))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        } else {
            Image(systemName: "clock")
                .font(.system(size: 8, weight: .bold))
        }
    }
}

// MARK: - Queue Mini Progress Bars

private struct QueueMiniProgressView: View {
    @ObservedObject var queueVM: OperationQueueViewModel
    let onTap: () -> Void

    private static let maxVisible = 5

    var body: some View {
        let active = queueVM.operations.filter(\.isActive)

        if !active.isEmpty {
            let visible = Array(active.prefix(Self.maxVisible))
            let extra = active.count - visible.count

            VStack(spacing: 2) {
                ForEach(visible) { op in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.white.opacity(0.1))
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(opColor(op.kind))
                                .frame(width: geo.size.width * max(0.02, op.progress))
                                .animation(.linear(duration: 0.3), value: op.progress)
                        }
                    }
                    .frame(height: 3)
                    .help("\(op.displayTitle) — \(Int(op.progress * 100))%")
                }
                if extra > 0 {
                    Text("+\(extra)")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
    }

    private func opColor(_ kind: OperationKind) -> Color {
        switch kind {
        case .copy:           return .blue
        case .move:           return .orange
        case .delete:         return .red
        case .pack:           return .purple
        case .unpack:         return .green
        case .archiveDelete:  return .red
        case .archiveRename:  return .yellow
        case .archiveExtract: return .green
        case .remoteDownload: return .cyan
        case .remoteUpload:   return .cyan
        case .remoteDelete:   return .red
        case .multiRename:    return .orange
        }
    }
}
