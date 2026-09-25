import AppKit
import SwiftUI

@MainActor
struct SortBarView: View {
    @ObservedObject var viewModel: PanelViewModel
    let backgroundColor: Color
    /// Horizontal scroll offset of the detailed table — shifts the headers so
    /// they track the data when columns overflow the panel width.
    var horizontalScrollOffset: CGFloat = 0
    /// Live resize callback — straight into PanelViewController, which owns
    /// the NSTableView (single authority for clamping and applying widths).
    var onColumnResize: ((PanelColumn, CGFloat) -> Void)?
    /// Drag ended — persist once.
    var onColumnResizeCommit: (() -> Void)?
    /// Double-click on a divider — auto-fit that column to its content.
    var onAutoFitColumn: ((PanelColumn) -> Void)?
    /// The header being dragged to a new place; nil when nothing is in flight.
    @State private var draggingColumn: PanelColumn?
    /// The header under the pointer — it wears the little grip that says "this travels".
    @State private var hoveredColumn: PanelColumn?

    private struct SortItem: Identifiable {
        let column: PanelColumn
        let sortField: PanelSortField
        var id: String { column.rawValue }
    }

    private static let allItems: [SortItem] = [
        SortItem(column: .name, sortField: .name),
        SortItem(column: .type, sortField: .type),
        SortItem(column: .size, sortField: .size),
        SortItem(column: .dateCreated, sortField: .dateCreated),
        SortItem(column: .dateModified, sortField: .dateModified),
        SortItem(column: .dateAdded, sortField: .dateAdded),
        SortItem(column: .permissions, sortField: .permissions),
        SortItem(column: .owner, sortField: .owner),
        SortItem(column: .origin, sortField: .origin)
    ]

    private var visibleItems: [SortItem] {
        // The same set AND ORDER the table draws — a header standing over a column that is
        // not there (or somewhere else) puts every header after it one column off.
        let sortFieldByColumn = Dictionary(
            uniqueKeysWithValues: Self.allItems.map { ($0.column, $0.sortField) })
        return viewModel.orderedVisibleColumns.compactMap { column in
            sortFieldByColumn[column].map { SortItem(column: column, sortField: $0) }
        }
    }

    private var isDetailed: Bool {
        viewModel.viewMode == .detailed && !viewModel.detailedColumnWidths.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if isDetailed {
                    Color.clear.frame(width: viewModel.detailedIconColumnWidth)
                }
                ForEach(visibleItems) { item in
                    let w = isDetailed
                        ? (viewModel.detailedColumnWidths[item.column] ?? 80)
                        : evenWidth(available: geo.size.width)
                    if item.column == .name {
                        // The anchor everything is read against — it does not travel; the
                        // metadata columns reorder among themselves.
                        sortButton(for: item, width: w)
                    } else {
                        // NOT a Button and NOT .onDrag: a macOS Button swallows the
                        // mouse-down, so an NSItemProvider drag never even starts. A plain
                        // view with a tap (sort) and a hand-rolled DragGesture (reorder)
                        // is what actually works under the resize overlay.
                        headerLabel(for: item, width: w,
                                    showsGrip: hoveredColumn == item.column && draggingColumn == nil)
                            .opacity(draggingColumn == item.column ? 0.4 : 1.0)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                // The grip plus an open hand say "this travels" BEFORE the
                                // first drag ever happens; the divider overlay re-asserts
                                // its own resize cursor near the borders on its own.
                                hoveredColumn = inside ? item.column : nil
                                if inside { NSCursor.openHand.set() }
                                else if draggingColumn == nil { NSCursor.arrow.set() }
                            }
                            .onTapGesture { viewModel.toggleSort(by: item.sortField) }
                            .gesture(
                                DragGesture(minimumDistance: 6,
                                            coordinateSpace: .named("fcxl.sortbar"))
                                    .onChanged { value in
                                        if draggingColumn == nil {
                                            draggingColumn = item.column
                                            NSCursor.closedHand.set()
                                        }
                                        reorder(toPointerX: value.location.x)
                                    }
                                    .onEnded { _ in
                                        draggingColumn = nil
                                        NSCursor.arrow.set()
                                    }
                            )
                    }
                }
                if !isDetailed {
                    Spacer(minLength: 0)
                }
            }
            // Scroll headers with the data (detailed mode only).
            .offset(x: isDetailed ? -horizontalScrollOffset : 0)
        }
        .frame(height: 22)
        .clipped()
        .coordinateSpace(name: "fcxl.sortbar")
        .background(backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .overlay {
            SortBarRightClickArea(viewModel: viewModel)
        }
        // Single full-width resize layer on top — handles cursor + drag for all
        // column dividers; passes non-divider clicks through to the buttons.
        .overlay {
            if isDetailed {
                ColumnResizeOverlay(
                    dividers: resizeDividers(),
                    onResize: { column, width in onColumnResize?(column, width) },
                    onCommit: { onColumnResizeCommit?() },
                    onAutoFit: { column in onAutoFitColumn?(column) }
                )
            }
        }
        // Column names, the line beneath and the menu read on the panel's colour: a dark
        // panel under the light theme gets light header text — the rule every chrome
        // surface follows. Last in the chain, so the overlays are inside it too.
        .environment(\.colorScheme, PanelAppearanceSettings.colorScheme(on: NSColor(backgroundColor)))
    }

    /// Divider x-positions (from the bar's left edge) matching the visual
    /// header layout: icon spacer + cumulative column widths (same max(56,…)
    /// the sort buttons use). Each divider resizes the column to its left.
    private func resizeDividers() -> [ColumnResizeOverlay.Divider] {
        guard isDetailed else { return [] }
        var result: [ColumnResizeOverlay.Divider] = []
        var x = viewModel.detailedIconColumnWidth
        for item in visibleItems {
            let w = max(56, viewModel.detailedColumnWidths[item.column] ?? 80)
            x += w
            // Match the on-screen divider position after the header scroll.
            result.append(.init(x: x - horizontalScrollOffset, column: item.column, currentWidth: w))
        }
        return result
    }

    private func sortButton(for item: SortItem, width: CGFloat) -> some View {
        Button {
            viewModel.toggleSort(by: item.sortField)
        } label: {
            headerLabel(for: item, width: width)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The header's face, shared by the name's Button and the metadata drag-views.
    /// `showsGrip` puts the little ≡ at the leading edge — the "you can carry this" sign.
    private func headerLabel(for item: SortItem, width: CGFloat,
                             showsGrip: Bool = false) -> some View {
        let isActive = viewModel.sortField == item.sortField
        return HStack(spacing: 4) {
            Text(localizedTitle(item.column))
                .lineLimit(1)
            if isActive {
                Text(viewModel.sortAscending ? "↑" : "↓")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .font(.system(size: 10, weight: .thin))
        .foregroundStyle(Color(nsColor: .headerTextColor))
        .padding(.horizontal, 6)
        .frame(width: max(56, width), height: 20, alignment: .center)
        .overlay(alignment: .leading) {
            if showsGrip {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .headerTextColor).opacity(0.45))
                    .padding(.leading, 3)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(width: 1)
                .padding(.vertical, 3)
        }
    }

    /// Live reorder while the pointer travels: the dragged column slides in front of the
    /// first header whose midpoint lies right of the pointer — the standard rule that keeps
    /// a reorder stable while the spans themselves shift under it.
    private func reorder(toPointerX pointerX: CGFloat) {
        guard let dragging = draggingColumn else { return }
        var x = isDetailed ? viewModel.detailedIconColumnWidth : 0
        if isDetailed { x -= horizontalScrollOffset }
        var target: PanelColumn?
        for item in visibleItems {
            let w = isDetailed
                ? max(56, viewModel.detailedColumnWidths[item.column] ?? 80)
                : max(56, evenWidthCached)
            let mid = x + w / 2
            x += w
            guard item.column != .name, item.column != dragging else { continue }
            if mid > pointerX { target = item.column; break }
        }
        let current = viewModel.columnOrder
        let moved = PanelViewModel.columnOrder(current, moving: dragging, before: target)
        if moved != current { viewModel.columnOrder = moved }
    }

    /// The even width the non-detailed bar used at the last layout — cached by body via
    /// `evenWidth(available:)`; the reorder math needs the same number outside GeometryReader.
    @State private var evenWidthCached: CGFloat = 80

    private func evenWidth(available: CGFloat) -> CGFloat {
        let count = max(visibleItems.count, 1)
        let width = max(80, available / CGFloat(count))
        if abs(evenWidthCached - width) > 0.5 {
            DispatchQueue.main.async { evenWidthCached = width }
        }
        return width
    }

    private func localizedTitle(_ column: PanelColumn) -> String {
        column.localizedTitle(insideTrash: viewModel.state.insideTrash)
    }
}

// MARK: - Native NSMenu for right-click with attributedTitle support

@MainActor
private struct SortBarRightClickArea: NSViewRepresentable {
    @ObservedObject var viewModel: PanelViewModel

    func makeNSView(context: Context) -> SortBarRightClickView {
        let view = SortBarRightClickView()
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: SortBarRightClickView, context: Context) {
        nsView.viewModel = viewModel
    }
}

@MainActor
final class SortBarRightClickView: NSView {
    var viewModel: PanelViewModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept right-clicks; let left-clicks pass through to SwiftUI buttons
        guard let event = NSApp.currentEvent, event.type == .rightMouseDown else {
            return nil
        }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let viewModel else { return }
        let menu = buildMenu(viewModel: viewModel)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func buildMenu(viewModel: PanelViewModel) -> NSMenu {
        let menu = NSMenu(title: "")
        // Manual isEnabled control (reset item is conditional) — otherwise
        // NSMenu's auto-enabling overrides it for items with target/action.
        menu.autoenablesItems = false

        let columns: [(PanelColumn, String, String)] = [
            (.name, L("column.name"), "textformat"),
            (.type, L("properties.type"), "doc"),
            (.size, L("column.size"), "internaldrive"),
            (.dateCreated, L("properties.createdDate"), "calendar.badge.plus"),
            (.dateModified, L("column.date"), "calendar.badge.clock"),
            (.dateAdded, PanelColumn.dateAdded.localizedTitle(insideTrash: viewModel.state.insideTrash),
             "calendar.badge.exclamationmark"),
            (.permissions, L("properties.permissions"), "lock.shield"),
            (.owner, L("properties.owner"), "person")
        ]

        // Inside the Trash the set is fixed, so the toggles are shown greyed rather than left
        // looking live and doing nothing. The user's own set is untouched underneath and comes
        // back on leaving.
        let insideTrash = viewModel.state.insideTrash

        for (column, title, iconName) in columns {
            let isVisible = viewModel.effectiveVisibleColumns.contains(column)
            let item = NSMenuItem()

            // Attributed title: white for visible, gray for hidden
            let textColor: NSColor = isVisible ? .labelColor : .tertiaryLabelColor
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: textColor
            ]
            item.attributedTitle = NSAttributedString(string: title, attributes: attrs)

            // SF Symbol icon
            if let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                item.image = icon.withSymbolConfiguration(config)
            }

            // Checkmark for visible columns
            item.state = isVisible ? .on : .off

            // Name is always enabled but not toggleable
            if column == .name || insideTrash {
                item.isEnabled = false
            } else {
                item.target = self
                item.action = #selector(toggleColumn(_:))
                item.representedObject = column.rawValue
            }

            menu.addItem(item)
        }

        // Reset user-set column widths → back to proportional auto-fill.
        // Only meaningful (and enabled) when the user has resized something.
        menu.addItem(.separator())
        let resetItem = NSMenuItem(
            title: L("sortbar.resetColumnWidths"),
            action: #selector(resetColumnWidths(_:)),
            keyEquivalent: ""
        )
        if let icon = NSImage(systemSymbolName: "arrow.uturn.backward",
                              accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            resetItem.image = icon.withSymbolConfiguration(config)
        }
        resetItem.target = self
        resetItem.isEnabled = !viewModel.userColumnWidths.isEmpty
        menu.addItem(resetItem)

        // Auto-fit every column to the width of its longest value.
        let autoFitItem = NSMenuItem(
            title: L("sortbar.autoFitColumns"),
            action: #selector(autoFitColumns(_:)),
            keyEquivalent: ""
        )
        if let icon = NSImage(systemSymbolName: "arrow.left.and.right.text.vertical",
                              accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            autoFitItem.image = icon.withSymbolConfiguration(config)
        }
        autoFitItem.target = self
        menu.addItem(autoFitItem)

        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let column = PanelColumn(rawValue: rawValue),
              let viewModel
        else { return }
        viewModel.setColumnVisibility(column, isVisible: !viewModel.isColumnVisible(column))
    }

    @objc private func resetColumnWidths(_ sender: NSMenuItem) {
        viewModel?.resetUserColumnWidths()
    }

    @objc private func autoFitColumns(_ sender: NSMenuItem) {
        viewModel?.requestAutoFitAllColumns()
    }
}

