import Combine
import Foundation

/// Non-observable data store for file list data.
///
/// Holds items, cursor position, selection, sort state, and column widths —
/// properties that change frequently (cursor movement, selection changes,
/// folder size updates). By NOT conforming to ObservableObject, SwiftUI
/// re-renders are avoided. PanelViewController subscribes to the Combine
/// subjects below and calls NSTableView.reloadData() / refreshRowStates()
/// directly.
@MainActor
final class PanelData {

    // MARK: - Combine Subjects

    let dataDidChange = PassthroughSubject<Void, Never>()
    let cursorDidChange = PassthroughSubject<Void, Never>()
    let selectionDidChange = PassthroughSubject<Void, Never>()
    let scrollResetRequested = PassthroughSubject<Void, Never>()
    let columnVisibilityDidChange = PassthroughSubject<Void, Never>()
    /// "Reset column widths" was chosen — PanelViewController redistributes.
    let columnWidthsDidReset = PassthroughSubject<Void, Never>()
    /// "Auto-fit all columns" was chosen — PanelViewController measures content.
    let autoFitAllColumnsRequested = PassthroughSubject<Void, Never>()
    /// Branch-view walk progress ticks. Its own quiet channel: dataDidChange rebuilds the
    /// whole table, and a counter updating a few times a second must not do that.
    let branchScanDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Data Properties

    /// The folder as loaded and sorted — every file in it, whatever the quick filter is showing.
    ///
    /// Everything that reasons about the FOLDER reads this: the directory cache, the selection
    /// rebuild after a reload, the tag scan, the metadata write-back. Caching or writing back a
    /// narrowed array would make the folder come back truncated, which looks exactly like data loss.
    var allItems: [FileItem] = []

    /// Root of the flattened subtree while the panel is in branch view (Ctrl+B);
    /// nil = an ordinary folder listing.
    var branchViewRoot: String? = nil

    /// What the panel actually shows: `allItems` narrowed by the quick filter.
    ///
    /// Every index in the app — cursorIndex, anchorIndex, the three renderers, selection ranges —
    /// is an index into THIS array, so narrowing keeps them all consistent with what is on screen.
    /// Only PanelViewModel.applyQuickFilter may assign it; that is what keeps the two in step.
    private(set) var items: [FileItem] = [] {
        didSet { dataDidChange.send() }
    }

    /// Publish a new visible set. The ONLY caller is PanelViewModel.applyQuickFilter — going
    /// through it is what keeps `items` a projection of `allItems` instead of a second source of
    /// truth that can drift from it.
    func publishDisplayItems(_ newItems: [FileItem]) {
        items = newItems
    }

    var cursorIndex: Int = 0 {
        didSet {
            guard cursorIndex != oldValue else { return }
            cursorDidChange.send()
        }
    }

    var selectedPaths: Set<String> = [] {
        didSet {
            guard selectedPaths != oldValue else { return }
            selectionDidChange.send()
        }
    }

    var sortField: PanelSortField = .name
    var sortAscending: Bool = true
    var sortToken: UInt64 = 0

    var scrollResetToken: UInt64 = 0 {
        didSet { scrollResetRequested.send() }
    }

    var visibleColumns: Set<PanelColumn> = [.name, .type, .size, .dateModified] {
        didSet {
            guard visibleColumns != oldValue else { return }
            columnVisibilityDidChange.send()
        }
    }
    var detailedColumnWidths: [PanelColumn: CGFloat] = [:]
    var detailedIconColumnWidth: CGFloat = 24
    /// User-set column widths (identifier → width). When non-empty these
    /// override the proportional auto-distribution so dragging a column
    /// divider persists. Empty = use auto-distribution.
    var userColumnWidths: [String: CGFloat] = [:]

    // MARK: - Convenience

    var cursorItem: FileItem? {
        guard cursorIndex >= 0, cursorIndex < items.count else { return nil }
        return items[cursorIndex]
    }
}
