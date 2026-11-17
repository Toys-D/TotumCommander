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

    var hit: SearchHit? {
        if case .file(let hit) = self { return hit }
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
            rows.append(.group(title: CountText.files(group.files.count), size: group.size))
            for file in group.files {
                // Every copy in a group has the group's size — that is what makes it a copy —
                // so the size column has something to show without another look at the disk.
                rows.append(.file(SearchHit(path: file,
                                            name: (file as NSString).lastPathComponent,
                                            lineNumber: nil, column: nil, lineContent: nil,
                                            dateModified: nil,
                                            size: group.size > 0 ? group.size : nil,
                                            isDirectory: false)))
            }
        }
        return rows
    }
}

/// The columns of the results list.
enum SearchResultColumn: String, CaseIterable {
    case name, folder, size, date

    var title: String {
        switch self {
        case .name: return L("search.col.name")
        case .folder: return L("search.col.folder")
        case .size: return L("search.col.size")
        case .date: return L("search.col.date")
        }
    }

    var sortKey: SearchSortKey {
        switch self {
        case .name: return .name
        case .folder: return .folder
        case .size: return .size
        case .date: return .date
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { .init("search.\(rawValue)") }

    /// Starting width; the name and the folder share whatever room the window gives.
    var width: CGFloat {
        switch self {
        case .name: return 260
        case .folder: return 250
        case .size: return 80
        case .date: return 122
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 140
        case .folder: return 100
        case .size: return 60
        case .date: return 90
        }
    }

    var stretches: Bool { self == .name || self == .folder }
}

/// The window that holds the list of finds: it wants to know the list, to hand it the arrow
/// keys while a preview floats over the window.
protocol SearchResultsHosting: AnyObject {
    var resultsTable: NSTableView? { get set }
}

/// The results list, drawn by AppKit.
///
/// It used to be a SwiftUI `List`, which builds its whole item tree up front: a duplicates run
/// answering with 662 821 files hung the app inside that tree. A table view creates views only
/// for the rows on screen and reuses them as you scroll, which is the same reason the panels
/// themselves are AppKit — the list size stops mattering.
///
/// A found file is a row of four columns — name, folder, size, date — and a click on a column
/// header orders the list by it, as in the panels. It used to be one column with the folder
/// squeezed under the name and nothing to sort by.
///
/// Selection is painted in the app's accent colour rather than the system's blue: this was the
/// one place in the program where a stock macOS highlight showed through.
struct SearchResultsTable: NSViewRepresentable {
    /// Called only when `revision` changes — never on the ordinary SwiftUI update that arrives
    /// with every keystroke in the form. Building a hundred thousand rows for a typed letter
    /// is the kind of work that used to make this dialog feel broken.
    let makeRows: () -> [SearchResultRow]
    /// Bumped by the view model whenever the results change.
    let revision: Int
    @Binding var selection: Set<String>
    let folderSizes: [String: UInt64]
    let accent: NSColor
    /// Bumped to ask for the keyboard, so arrows work right after a search.
    let focusRequest: Int
    /// The order the list is in — shown in the header. Nil: the list is not sortable
    /// (duplicate groups keep the order the finder gave them).
    let sort: (key: SearchSortKey, ascending: Bool)?
    /// The folder the list was looked for in — the folder column shows paths from it.
    let root: String
    let onSort: (SearchSortKey, Bool) -> Void
    let onActivate: (String) -> Void
    /// A key the list answers for: space is quick look.
    let onAction: (SearchResultAction) -> Void
    /// The right-click menu, built at the moment of the click.
    let makeMenu: () -> NSMenu?

    func makeNSView(context: Context) -> NSScrollView {
        let table = SearchTableView()
        table.headerView = NSTableHeaderView()
        table.backgroundColor = .clear
        table.style = .plain
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .none      // painted by SearchResultRowView instead
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAutomaticRowHeights = false
        table.floatsGroupRows = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        for column in SearchResultColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.resizingMask = column.stretches
                ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            // The size header stays on the left though its numbers stand on the right: a
            // right-aligned title sits under the sort arrow and loses its last letter to it.
            table.addTableColumn(tableColumn)
        }
        // The widths a person set stay set.
        table.autosaveName = "fcxl.search.results"
        table.autosaveTableColumns = true

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
        coordinator.accent = accent

        if coordinator.revision != revision {
            coordinator.revision = revision
            coordinator.rows = makeRows()
            coordinator.indexByPath = [:]
            for (index, row) in coordinator.rows.enumerated() {
                if let path = row.path { coordinator.indexByPath[path] = index }
            }
            coordinator.table?.reloadData()
            // The list changed, not the selection: the view stays where the person has it.
            // While finds are still arriving this runs several times a second.
            coordinator.applySelectionFromBinding(scrolling: false)
        } else if coordinator.lastAppliedSelection != selection {
            coordinator.applySelectionFromBinding()
        }
        coordinator.showSort(sort)
        coordinator.showFolderSizes(folderSizes)
        coordinator.fitColumnsOnce(in: scroll)

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
        private var syncingSort = false
        /// Dates looked up for rows that came without one (the copies in a duplicate group).
        private var lookedUpDates: [String: Date] = [:]

        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()

        init(_ parent: SearchResultsTable) {
            self.parent = parent
            super.init()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 24 }
            switch rows[row] {
            case .group: return 24
            // A content find shows the matching line under the name.
            case .file(let hit): return hit.lineContent == nil ? 24 : 38
            }
        }

        /// A group header spans the whole row instead of sitting in the first column.
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            rows.indices.contains(row) && rows[row].path == nil
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
                guard let tableColumn,
                      let column = SearchResultColumn.allCases
                        .first(where: { $0.identifier == tableColumn.identifier }) else { return nil }
                if column == .name {
                    let cell = tableView.makeView(withIdentifier: .init("nameCell"), owner: self)
                        as? ResultNameCell ?? {
                            let fresh = ResultNameCell()
                            fresh.identifier = .init("nameCell")
                            return fresh
                        }()
                    cell.fill(hit: hit)
                    return cell
                }
                let cell = tableView.makeView(withIdentifier: .init("textCell"), owner: self)
                    as? ResultTextCell ?? {
                        let fresh = ResultTextCell()
                        fresh.identifier = .init("textCell")
                        return fresh
                    }()
                switch column {
                case .folder:
                    cell.fill(SearchFolderText.text(itemPath: hit.path, root: parent.root),
                              alignment: .left, lineBreak: .byTruncatingHead, tip: hit.path)
                case .size:
                    let bytes = hit.isDirectory ? folderSizes[hit.path] : hit.size
                    cell.fill(bytes.map { ByteText.file(Int64($0)) } ?? "",
                              alignment: .right, lineBreak: .byClipping)
                case .date:
                    cell.fill(date(for: hit).map(Self.dateFormatter.string(from:)) ?? "",
                              alignment: .left, lineBreak: .byTruncatingTail)
                case .name:
                    break
                }
                return cell
            }
        }

        /// The date a row shows. A row that came without one is looked up when it first
        /// scrolls into view — only the rows on screen cost a look at the disk.
        private func date(for hit: SearchHit) -> Date? {
            if let known = hit.dateModified { return known }
            if let cached = lookedUpDates[hit.path] { return cached }
            var info = stat()
            guard lstat(hit.path, &info) == 0 else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            lookedUpDates[hit.path] = date
            return date
        }

        private var didFitColumns = false

        /// The starting widths are a guess; the first time the list has a real width the
        /// columns are spread over exactly that, so the last one is not cut off at the edge.
        func fitColumnsOnce(in scroll: NSScrollView) {
            guard !didFitColumns, let table, scroll.contentSize.width > 100 else { return }
            didFitColumns = true
            table.sizeToFit()
        }

        // MARK: Order

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncingSort, let first = tableView.sortDescriptors.first,
                  let key = first.key.flatMap(SearchSortKey.init(rawValue:)) else { return }
            parent.onSort(key, first.ascending)
        }

        /// Make the header say what order the list is in — or nothing, where it has none.
        func showSort(_ sort: (key: SearchSortKey, ascending: Bool)?) {
            guard let table else { return }
            syncingSort = true
            defer { syncingSort = false }
            for column in SearchResultColumn.allCases {
                guard let tableColumn = table.tableColumn(withIdentifier: column.identifier) else { continue }
                let wanted = sort == nil ? nil
                    : NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
                if tableColumn.sortDescriptorPrototype?.key != wanted?.key {
                    tableColumn.sortDescriptorPrototype = wanted
                }
            }
            let current = table.sortDescriptors.first
            if let sort {
                if current?.key != sort.key.rawValue || current?.ascending != sort.ascending {
                    table.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue,
                                                              ascending: sort.ascending)]
                }
            } else if current != nil {
                table.sortDescriptors = []
            }
        }

        /// Folder sizes arrive after the list is drawn; the rows on screen take them at once.
        func showFolderSizes(_ sizes: [String: UInt64]) {
            guard sizes.count != folderSizes.count else { return }
            folderSizes = sizes
            guard let table,
                  let column = table.tableColumns.firstIndex(where: {
                      $0.identifier == SearchResultColumn.size.identifier }) else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integer: column))
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            var picked = Set<String>()
            for row in table.selectedRowIndexes where rows.indices.contains(row) {
                if let path = rows[row].path { picked.insert(path) }
            }
            lastAppliedSelection = picked
            parent.selection = picked
        }

        func applySelectionFromBinding(scrolling: Bool = true) {
            guard let table else { return }
            var indexes = IndexSet()
            for path in parent.selection {
                if let index = indexByPath[path] { indexes.insert(index) }
            }
            lastAppliedSelection = parent.selection
            syncing = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            syncing = false
            if scrolling, let first = indexes.first { table.scrollRowToVisible(first) }
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

        /// The first selected row in list order — the same one the "Go to" button takes, so
        /// the key and the button cannot disagree when several rows are selected.
        func activateSelection() {
            guard let table, let row = table.selectedRowIndexes.first,
                  rows.indices.contains(row), let path = rows[row].path else { return }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? SearchResultsHosting)?.resultsTable = self
    }

    /// Right click: the row under the pointer joins the game first — a menu about rows that
    /// are not the one clicked is the classic way to delete the wrong file.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, delegate?.tableView?(self, shouldSelectRow: row) ?? true else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if let menu = owner?.parent.makeMenu(), !menu.items.isEmpty {
            ContextPopupMenuController.shared.show(menu, for: event, in: self)
        }
        return nil      // the program's own menu window, never the system one as well
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 36 {                       // Enter — go to the result
            owner?.activateSelection()
            return
        }
        if event.keyCode == 49, !command {             // Space — quick look
            owner?.parent.onAction(.quickLook)
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
            ? "\(title)  ·  \(ByteText.file(Int64(size)))"
            : title
        caption.textColor = .secondaryLabelColor
    }
}

/// The name column: icon and name — and, for a content find, the matching line under it.
final class ResultNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    private var nameCentered: NSLayoutConstraint!
    private var nameOnTop: NSLayoutConstraint!

    private enum Icons {
        static let folder = NSWorkspace.shared.icon(for: .folder)
    }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        line.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        line.textColor = .systemOrange
        line.lineBreakMode = .byTruncatingTail

        for view in [icon, name, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameCentered = name.centerYAnchor.constraint(equalTo: centerYAnchor)
        nameOnTop = name.topAnchor.constraint(equalTo: topAnchor, constant: 4)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),

            line.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            line.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func fill(hit: SearchHit) {
        icon.image = image(for: hit)
        name.stringValue = hit.name
        let match = SearchMatchText.text(line: hit.lineNumber, content: hit.lineContent,
                                         count: hit.matchCount)
        line.stringValue = match ?? ""
        line.isHidden = match == nil
        // One line of text sits in the middle of its row; two lines hang from the top.
        nameCentered.isActive = match == nil
        nameOnTop.isActive = match != nil
        toolTip = match == nil ? hit.name : "\(hit.name)\n\(match ?? "")"
    }

    /// Значок файла — в стиле из настроек, как на панели. Ищется один на вид файла и
    /// запоминается (FileIcons): спрашивать LaunchServices на каждую строку — это и делало
    /// прокрутку ползущей.
    private func image(for hit: SearchHit) -> NSImage {
        if hit.isDirectory {
            guard hit.path.hasSuffix(".app") else { return Icons.folder }
            return NSWorkspace.shared.icon(forFile: hit.path)
        }
        // Список прозрачный и стоит на фоне окна — по нему и решается обводка.
        var background = NSColor.white
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .white
        }
        let look = FileIconLook.current(backgrounds: [background])
        let key = FileIcons.typeKey(name: (hit.path as NSString).lastPathComponent,
                                    fileExtension: (hit.path as NSString).pathExtension, path: hit.path,
                                    style: look.style)
        return FileIcons.icon(forExtension: key, size: 16, look: look)
    }
}

/// The folder, size and date columns: one quiet line of text.
final class ResultTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func fill(_ text: String, alignment: NSTextAlignment, lineBreak: NSLineBreakMode,
              tip: String? = nil) {
        label.stringValue = text
        label.alignment = alignment
        label.lineBreakMode = lineBreak
        toolTip = tip
    }
}
