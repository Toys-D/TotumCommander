import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One line of the results list: a found file, or the header of a duplicate group.
enum SearchResultRow {
    case group(title: String, size: UInt64)
    case file(SearchHit)

    var path: String? {
        if case .file(let hit) = self { return hit.path }
        return nil
    }
}

/// Flattening the two shapes of results into one list of lines. Pure, so the grouping can be
/// tested without a window.
enum SearchResultRows {
    static func build(mode: SearchMode,
                      results: [SearchHit],
                      duplicates: [DuplicateGroup]) -> [SearchResultRow] {
        guard mode == .duplicates else { return results.map { .file($0) } }
        var rows: [SearchResultRow] = []
        rows.reserveCapacity(duplicates.reduce(0) { $0 + $1.files.count + 1 })
        for group in duplicates {
            rows.append(.group(title: "\(group.files.count) \(L("search.dup.files"))",
                               size: group.size))
            for file in group.files {
                rows.append(.file(SearchHit(path: file,
                                            name: (file as NSString).lastPathComponent,
                                            lineNumber: nil, column: nil, lineContent: nil,
                                            dateModified: nil, size: nil, isDirectory: false)))
            }
        }
        return rows
    }
}

/// The results list, drawn by AppKit.
///
/// It used to be a SwiftUI `List`, which builds its whole item tree up front: a duplicates run
/// answering with 662 821 files hung the app inside that tree. A table view creates views only
/// for the rows on screen and reuses them as you scroll, which is the same reason the panels
/// themselves are AppKit — the list size stops mattering.
///
/// Selection is painted in the app's accent colour rather than the system's blue: this was the
/// one place in the program where a stock macOS highlight showed through.
struct SearchResultsTable: NSViewRepresentable {
    let rows: [SearchResultRow]
    /// Bumped by the view model whenever the results change — the table reloads on this alone,
    /// never on the ordinary SwiftUI update that arrives with every keystroke in the form.
    let revision: Int
    @Binding var selection: Set<String>
    let folderSizes: [String: UInt64]
    let accent: NSColor
    /// Bumped to ask for the keyboard, so arrows work right after a search.
    let focusRequest: Int
    let onActivate: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let table = SearchTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .none      // painted by SearchResultRowView instead
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.target = context.coordinator
        table.owner = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.revision != revision {
            coordinator.revision = revision
            coordinator.rows = rows
            coordinator.indexByPath = [:]
            for (index, row) in rows.enumerated() {
                if let path = row.path { coordinator.indexByPath[path] = index }
            }
            coordinator.table?.reloadData()
            coordinator.applySelectionFromBinding()
        } else if coordinator.lastAppliedSelection != selection {
            coordinator.applySelectionFromBinding()
        }
        coordinator.folderSizes = folderSizes
        coordinator.accent = accent

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            coordinator.takeKeyboard()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SearchResultsTable
        weak var table: SearchTableView?
        var rows: [SearchResultRow] = []
        var indexByPath: [String: Int] = [:]
        var folderSizes: [String: UInt64] = [:]
        var accent: NSColor = .controlAccentColor
        var revision: Int = -1
        var focusRequest: Int = 0
        var lastAppliedSelection: Set<String> = []
        private var syncing = false

        init(_ parent: SearchResultsTable) {
            self.parent = parent
            super.init()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 20 }
            if case .group = rows[row] { return 24 }
            return 40
        }

        /// A group header is a caption, not a result — it cannot be selected, so "select all"
        /// and the arrow keys never land on one.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows.indices.contains(row) && rows[row].path != nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: .init("resultRow"), owner: self)
                as? SearchResultRowView ?? {
                    let fresh = SearchResultRowView()
                    fresh.identifier = .init("resultRow")
                    return fresh
                }()
            view.accent = accent
            view.isGroupCaption = rows.indices.contains(row) && rows[row].path == nil
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case .group(let title, let size):
                let cell = tableView.makeView(withIdentifier: .init("groupCell"), owner: self)
                    as? GroupCaptionCell ?? {
                        let fresh = GroupCaptionCell()
                        fresh.identifier = .init("groupCell")
                        return fresh
                    }()
                cell.fill(title: title, size: size)
                return cell
            case .file(let hit):
                let cell = tableView.makeView(withIdentifier: .init("fileCell"), owner: self)
                    as? ResultCell ?? {
                        let fresh = ResultCell()
                        fresh.identifier = .init("fileCell")
                        return fresh
                    }()
                cell.fill(hit: hit, folderSize: folderSizes[hit.path])
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            var picked = Set<String>()
            for row in table.selectedRowIndexes where rows.indices.contains(row) {
                if let path = rows[row].path { picked.insert(path) }
            }
            lastAppliedSelection = picked
            parent.selection = picked
        }

        func applySelectionFromBinding() {
            guard let table else { return }
            var indexes = IndexSet()
            for path in parent.selection {
                if let index = indexByPath[path] { indexes.insert(index) }
            }
            lastAppliedSelection = parent.selection
            syncing = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            syncing = false
            if let first = indexes.first { table.scrollRowToVisible(first) }
        }

        func takeKeyboard() {
            guard let table else { return }
            DispatchQueue.main.async {
                table.window?.makeFirstResponder(table)
                if table.selectedRow < 0, let first = self.rows.firstIndex(where: { $0.path != nil }) {
                    table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
                    table.scrollRowToVisible(first)
                }
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, rows.indices.contains(table.clickedRow),
                  let path = rows[table.clickedRow].path else { return }
            parent.onActivate(path)
        }

        // Called by the table for keys it does not handle itself.
        func activateSelection() {
            guard let table, rows.indices.contains(table.selectedRow),
                  let path = rows[table.selectedRow].path else { return }
            parent.onActivate(path)
        }

        var selectableRows: IndexSet {
            var set = IndexSet()
            for (index, row) in rows.enumerated() where row.path != nil { set.insert(index) }
            return set
        }
    }
}

/// The table itself — only to own the keys the dialog promises.
final class SearchTableView: NSTableView {
    weak var owner: SearchResultsTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 36 {                       // Enter — go to the result
            owner?.activateSelection()
            return
        }
        if command, event.charactersIgnoringModifiers == "d" {
            selectRowIndexes(IndexSet(), byExtendingSelection: false)
            return
        }
        if command, event.charactersIgnoringModifiers == "i", let owner {
            let inverted = owner.selectableRows.subtracting(selectedRowIndexes)
            selectRowIndexes(inverted, byExtendingSelection: false)
            return
        }
        super.keyDown(with: event)
    }

    /// Cmd+A — every result, never a group caption (shouldSelectRow already refuses those,
    /// but AppKit's own selectAll ignores it).
    override func selectAll(_ sender: Any?) {
        guard let owner else { return super.selectAll(sender) }
        selectRowIndexes(owner.selectableRows, byExtendingSelection: false)
    }
}

/// Selection painted in the app's own colour instead of the system highlight.
///
/// The painting lives in `drawBackground`, not in `drawSelection`: the table is set to
/// `selectionHighlightStyle = .none` so AppKit draws no blue bar of its own, and with that
/// setting AppKit never calls `drawSelection` either — a row would look untouched however it
/// was clicked. The panels solve it the same way, in the same method.
final class SearchResultRowView: NSTableRowView {
    var accent: NSColor = .controlAccentColor
    var isGroupCaption = false

    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        get { true }          // the colour must not fade when the form field has the keyboard
        set { _ = newValue }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard isSelected, !isGroupCaption else { return }
        accent.withAlphaComponent(0.32).setFill()
        bounds.fill()
        accent.withAlphaComponent(0.60).setStroke()
        let edges = NSBezierPath()
        edges.move(to: NSPoint(x: 0, y: 0.5))
        edges.line(to: NSPoint(x: bounds.width, y: 0.5))
        edges.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        edges.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        edges.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Painted in drawBackground — see above.
    }
}

/// The header of a duplicate group.
final class GroupCaptionCell: NSTableCellView {
    private let caption = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func fill(title: String, size: UInt64) {
        caption.stringValue = size > 0
            ? "\(title)  (\(ByteText.file(Int64(size))))"
            : title
        caption.textColor = .secondaryLabelColor
    }
}

/// One found file: icon, name, the folder it sits in, and its size.
final class ResultCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    /// One icon per file KIND, remembered — asking LaunchServices per row was what made
    /// scrolling crawl.
    private enum Icons {
        nonisolated(unsafe) static var byExtension: [String: NSImage] = [:]
        static let lock = NSLock()
        static let folder = NSWorkspace.shared.icon(for: .folder)
        static let plain = NSWorkspace.shared.icon(for: .data)
    }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        folder.font = .systemFont(ofSize: 10)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        line.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        line.textColor = .systemOrange
        line.lineBreakMode = .byTruncatingTail
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right

        for view in [icon, name, folder, line, sizeLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            name.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8),

            folder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            folder.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),

            line.leadingAnchor.constraint(equalTo: folder.trailingAnchor, constant: 8),
            line.centerYAnchor.constraint(equalTo: folder.centerYAnchor),
            line.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8),

            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func fill(hit: SearchHit, folderSize: UInt64?) {
        icon.image = Self.image(for: hit)
        name.stringValue = hit.name
        folder.stringValue = (hit.path as NSString).deletingLastPathComponent
        line.stringValue = hit.lineContent ?? ""
        line.isHidden = hit.lineContent == nil
        let bytes = hit.isDirectory ? folderSize : hit.size
        sizeLabel.stringValue = bytes.map {
            ByteText.file(Int64($0))
        } ?? ""
    }

    private static func image(for hit: SearchHit) -> NSImage {
        if hit.isDirectory {
            guard hit.path.hasSuffix(".app") else { return Icons.folder }
            return NSWorkspace.shared.icon(forFile: hit.path)
        }
        var ext = (hit.path as NSString).pathExtension.lowercased()
        if ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
        guard !ext.isEmpty else { return Icons.plain }

        Icons.lock.lock()
        if let cached = Icons.byExtension[ext] {
            Icons.lock.unlock()
            return cached
        }
        Icons.lock.unlock()
        let resolved = UTType(filenameExtension: ext)
            .map { NSWorkspace.shared.icon(for: $0) } ?? Icons.plain
        Icons.lock.lock()
        Icons.byExtension[ext] = resolved
        Icons.lock.unlock()
        return resolved
    }
}
