import SwiftUI

struct PanelTabsBarView: View {
    @ObservedObject var tabsVM: PanelTabsViewModel
    let isPanelActive: Bool
    let onNewTab: () -> Void
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    /// The favourites, dropped from the star beside the plus.
    var onShowFavorites: () -> Void = {}
    var currentViewModeRaw: String = ""

    @AppStorage("tabBarHeight") private var tabBarHeight: Double = 32
    @AppStorage("tabBarSpacing") private var tabBarSpacing: Double = 10
    @AppStorage("tabMaxWidth") private var tabMaxWidth: Double = 200
    @AppStorage("tabMinWidth") private var tabMinWidth: Double = 80
    @AppStorage("tabAccentColor") private var tabAccentColorRaw: String = TabAccentColor.violet.rawValue
    /// Звезда и плюс — такие же вторичные, как значки режимов и карандаш пути: чёрным
    /// (или белым в тёмной теме) на полосе выделяется только то, что выбрано, а не кнопки,
    /// которые просто стоят рядом. Под мышью — цвет акцента, как у кнопок туннеля.
    @State private var hoveringStar = false
    @State private var hoveringPlus = false
    @State private var dragSourceIndex: Int?
    @State private var dragTargetIndex: Int?

    private let plusButtonWidth: CGFloat = 38
    @State private var isOverflowing: Bool = false

    private func tabWidth(availableWidth: CGFloat) -> CGFloat {
        let count = max(tabsVM.tabs.count, 1)
        let totalSpacing = tabBarSpacing * CGFloat(count - 1) + 16 // 8px padding each side
        let raw = (availableWidth - totalSpacing) / CGFloat(count)
        return min(max(raw, tabMinWidth), tabMaxWidth)
    }

    private func checkOverflow(availableWidth: CGFloat) -> Bool {
        let count = max(tabsVM.tabs.count, 1)
        let totalSpacing = tabBarSpacing * CGFloat(count - 1) + 16
        let needed = CGFloat(count) * tabMinWidth + totalSpacing
        return needed > availableWidth
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            GeometryReader { geo in
                let chipWidth = tabWidth(availableWidth: geo.size.width)
                let _ = DispatchQueue.main.async {
                    isOverflowing = checkOverflow(availableWidth: geo.size.width)
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: tabBarSpacing) {
                        ForEach(Array(tabsVM.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabChipView(
                                tab: tab,
                                index: index,
                                isActive: index == tabsVM.activeIndex,
                                isDragTarget: dragTargetIndex == index,
                                onSelect: { onSelectTab(index) },
                                onClose: canClose(tab: tab) ? { onCloseTab(index) } : nil,
                                onTogglePin: { tabsVM.togglePin(at: index) },
                                onCloseOthers: { tabsVM.closeOthers(keeping: index); reloadAfterBulkClose() },
                                onCloseAllUnpinned: { tabsVM.closeAllUnpinned(); reloadAfterBulkClose() },
                                onDragStart: { dragSourceIndex = index },
                                onSetColor: { tabsVM.setTabColor(at: index, colorHex: $0) },
                                onNewTab: { onNewTab() },
                                onRename: { tabsVM.renameTab(at: index, to: $0) },
                                onPinViewMode: { tabsVM.pinViewMode(at: index, mode: currentViewModeRaw) },
                                onUnpinViewMode: { tabsVM.unpinViewMode(at: index) },
                                isLoading: tabsVM.loadingTabIDs.contains(tab.id)
                            )
                            .frame(width: chipWidth)
                            .onDrop(of: [.text], delegate: TabDropDelegate(
                                targetIndex: index,
                                tabsVM: tabsVM,
                                dragSourceIndex: $dragSourceIndex,
                                dragTargetIndex: $dragTargetIndex,
                                onReload: { onSelectTab(tabsVM.activeIndex) }
                            ))
                        }
                    }
                    .padding(.horizontal, 8)
                }
                }
            }

            if isOverflowing {
                TabOverflowMenuButton(tabsVM: tabsVM, onSelectTab: onSelectTab)
                    .frame(height: tabBarHeight)
            }

            // The hotlist at the hand's other resting place: the same menu Cmd+D opens, from
            // the star that lives where the tabs are managed.
            Button {
                onShowFavorites()
            } label: {
                Image(systemName: "star")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hoveringStar ? PanelAppearanceSettings.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringStar = $0 }
            .frame(width: 26, height: tabBarHeight)
            .help(L("menu.favorites"))

            Button {
                onNewTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hoveringPlus ? PanelAppearanceSettings.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringPlus = $0 }
            .frame(width: plusButtonWidth, height: tabBarHeight)
        }
        .frame(height: tabBarHeight)
        // Same background as the breadcrumb (path) bar above so the path + tabs
        // read as one unified area — no separate tab-bar color, no divider.
        .interfaceBackground()
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .zIndex(21)
    }

    private func canClose(tab: PanelTab) -> Bool {
        !tab.pinned && tabsVM.tabs.count > 1
    }

    private func reloadAfterBulkClose() {
        onSelectTab(tabsVM.activeIndex)
    }
}

// MARK: - Overflow Menu Button (NSMenu, no double chevron)

private struct TabOverflowMenuButton: NSViewRepresentable {
    @ObservedObject var tabsVM: PanelTabsViewModel
    let onSelectTab: (Int) -> Void

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        btn.imagePosition = .imageOnly
        btn.isBordered = false
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: TabOverflowMenuButton

        init(_ parent: TabOverflowMenuButton) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            for (index, tab) in parent.tabsVM.tabs.enumerated() {
                let item = NSMenuItem(title: tab.title, action: #selector(selectTab(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                if index == parent.tabsVM.activeIndex {
                    item.state = .on
                }
                if tab.pinned {
                    item.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
                } else if tab.isTerminal {
                    item.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
                }
                menu.addItem(item)
            }
            let point = NSPoint(x: 0, y: sender.bounds.height + 4)
            menu.popUp(positioning: nil, at: point, in: sender)
        }

        @objc func selectTab(_ sender: NSMenuItem) {
            parent.onSelectTab(sender.tag)
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let tabsVM: PanelTabsViewModel
    @Binding var dragSourceIndex: Int?
    @Binding var dragTargetIndex: Int?
    let onReload: () -> Void

    func dropEntered(info: DropInfo) {
        guard let source = dragSourceIndex, source != targetIndex else { return }
        dragTargetIndex = targetIndex
        withAnimation(.easeInOut(duration: 0.2)) {
            tabsVM.moveTab(from: source, to: targetIndex)
        }
        dragSourceIndex = targetIndex
    }

    func dropExited(info: DropInfo) {
        if dragTargetIndex == targetIndex {
            dragTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragSourceIndex = nil
        dragTargetIndex = nil
        onReload()
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }
}
