import AppKit
import Combine
import FCXLBridgeObjC
import Foundation
import os

enum ViewMode: String {
    case detailed
    case brief
    case thumbnails

    /// The old `icons` mode was the same grid as `thumbnails` with previews
    /// switched off and a smaller icon — two entries for one layout. It was
    /// removed; `thumbnails` is the surviving grid.
    ///
    /// The custom init keeps every reader honest: panel state, per-tab state
    /// and the shared "common view mode" all decode through here, so a saved
    /// "icons" lands on the grid the user actually had instead of falling
    /// through to `nil` and snapping the panel back to the table view.
    init?(rawValue: String) {
        switch rawValue {
        case "detailed":              self = .detailed
        case "brief":                 self = .brief
        case "thumbnails", "icons":   self = .thumbnails
        default:                      return nil
        }
    }
}

enum PanelSortField: Equatable {
    case name
    case type
    case fileExtension
    case size
    case dateCreated
    case dateModified
    case dateAdded
    case permissions
    case owner
    /// Trash only: the folder an item was deleted from.
    case origin
}

enum PanelColumn: String, CaseIterable, Hashable {
    case name
    case type
    case size
    case dateCreated
    case dateModified
    case dateAdded
    case permissions
    case owner
    /// Trash only — never part of the ordinary column set, shown by applyColumnVisibility
    /// whenever the panel is inside the Trash and hidden everywhere else.
    case origin

    /// The NSTableColumn identifier this column owns in the detailed table.
    var tableID: String {
        switch self {
        case .name: return "name"
        case .type: return "type"
        case .size: return "size"
        case .dateCreated: return "created"
        case .dateModified: return "modified"
        case .dateAdded: return "added"
        case .permissions: return "permissions"
        case .owner: return "owner"
        case .origin: return "origin"
        }
    }

    /// What the Trash shows instead of the user's own set: when something was thrown away and
    /// where it came from. Created/modified dates belong to the original file and say nothing
    /// about the deletion, so they step aside here. The user's own set is never touched — it
    /// comes back the moment the panel leaves the Trash.
    static let trashColumns: Set<PanelColumn> = [.name, .type, .size, .dateAdded, .origin]

    /// Header text. The table header, the sort bar and the column menu all read this one
    /// definition, so they cannot drift apart and leave a header standing over the wrong column.
    ///
    /// Inside the Trash the "date added" column is RENAMED rather than joined by a second date:
    /// for something sitting in the Trash, the moment it was added there is the moment it was
    /// deleted, and that is what the user is looking for.
    func localizedTitle(insideTrash: Bool = false) -> String {
        switch self {
        case .name:         return L("column.name")
        case .type:         return L("properties.type")
        case .size:         return L("column.size")
        case .dateCreated:  return L("properties.createdDate")
        case .dateModified: return L("column.date")
        case .dateAdded:    return insideTrash ? L("column.dateDeleted") : L("column.dateAdded")
        case .permissions:  return L("properties.permissions")
        case .owner:        return L("properties.owner")
        case .origin:       return L("column.origin")
        }
    }

    /// Canonical NSTableColumn identifier for this column. The ONLY place
    /// the enum↔identifier mapping lives — used by setupColumns, the sort
    /// bar resize handles, and width persistence. NOTE: not the same as
    /// rawValue for the date columns ("created" vs "dateCreated") because
    /// the identifiers are baked into existing UserDefaults data.
    var tableColumnIdentifier: String {
        switch self {
        case .name: return "name"
        case .type: return "type"
        case .size: return "size"
        case .dateCreated: return "created"
        case .dateModified: return "modified"
        case .dateAdded: return "added"
        case .permissions: return "permissions"
        case .owner: return "owner"
        case .origin: return "origin"
        }
    }

    /// Inverse of tableColumnIdentifier.
    static func from(tableColumnIdentifier id: String) -> PanelColumn? {
        allCases.first { $0.tableColumnIdentifier == id }
    }
}

@MainActor
final class PanelViewModel: ObservableObject {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
        category: "PanelViewModel"
    )

    private enum ArchiveFormat {
        case zip
        case sevenZip
        case rar
        case tar
        case tarGz
        case tgz
        case tarBz2
        case tbz2
        case tarXz
        case txz
        case gz
        case bz2
        case xz
        case tarZst
        case tarLz
        case tarLz4
        case iso
        case unknown

        var isIndexed: Bool {
            switch self {
            case .zip, .sevenZip, .rar:
                return true
            default:
                return false
            }
        }
    }

    enum PrewarmStrategy {
        case immediate
        case onCursorHover
        case onUserOpen
    }

    private struct ArchiveLoadTask {
        let requestID: UUID
        let qos: DispatchQoS.QoSClass
        let task: Task<[ArchiveListEntry], Error>
    }

    private struct ArchiveFileSignature {
        let modificationTime: TimeInterval?
        let size: UInt64?
    }

    private struct ArchiveCache {
        let entries: [ArchiveListEntry]
        let signature: ArchiveFileSignature
        var visibleItemsByRelativePath: [String: [FileItem]]
        var cachedAt: Date
        let format: ArchiveFormat
    }

    private struct DirectoryCache {
        let items: [FileItem]
        let cachedAt: Date
        let mtime: Date?
    }

    private static let fastPrewarmWorkerCount = 5
    private static let slowPrewarmWorkerCount = 3
    private static let archiveCacheLimit = 20
    private static let hoverPrewarmDelayNanoseconds: UInt64 = 2_000_000_000
    private static let smallArchiveFolderThreshold = 10
    private static let slowArchiveHardLimitBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let slowArchivePrewarmBudgetBytes: UInt64 = 3 * 1024 * 1024 * 1024
    private static let directoryCacheLimit = 10
    private static let progressiveDetailsThreshold = 100_000  // disabled: getattrlistbulk returns all needed data
    // folderSizeBudgetSeconds: unused — kept for reference if auto-calc is re-enabled with throttling
    private static let folderSizeBudgetSeconds: TimeInterval = 0

    // MARK: - Facade: PanelState + PanelData

    let state: PanelState
    let data: PanelData
    private var cancellables: Set<AnyCancellable> = []

    /// Finder colour tags of the current listing, keyed by path; only tagged files appear.
    ///
    /// It lives here rather than in a view because all three panel renderers draw it, and the rule
    /// is that a panel change lands in every mode at once. Reading a tag is an xattr call per file,
    /// so the whole listing is scanned once off the main thread and cached.
    @Published private(set) var tagsByPath: [String: [FinderTag]] = [:]
    private var tagScanTask: Task<Void, Never>?
    /// Which set of paths the running-or-finished scan covers, so the same listing is not scanned
    /// over and over.
    private var scannedPathsSignature: Int?

    /// Rescan the listing's tags.
    ///
    /// The caller is the panel's `dataDidChange` sink, which fires on ANY write to `items` — the
    /// names-only pass, the metadata pass, and once per finished folder when folder-size calculation
    /// is on. Those all carry the SAME paths, so the scan is keyed on the path set: a listing is
    /// scanned once, and the hundreds of follow-up notifications cost a hash instead of one
    /// getxattr per file each. Pass `force` when the tags themselves changed under the same paths.
    func refreshTags(force: Bool = false) {
        // Archives and remote listings have no local files to carry xattrs.
        guard !insideRemote, !insideArchive else { cancelTagScan(); return }
        // Keyed on the whole folder, so typing in the quick filter does not restart a background
        // xattr scan of the listing on every keystroke.
        let paths = allItems.filter { $0.name != ".." }.map(\.path)
        guard !paths.isEmpty else { cancelTagScan(); return }

        var hasher = Hasher()
        for path in paths { hasher.combine(path) }
        let signature = hasher.finalize()
        // Checked BEFORE cancelling: cancelling here and then skipping would leave the listing
        // permanently unscanned.
        guard force || signature != scannedPathsSignature else { return }

        tagScanTask?.cancel()
        scannedPathsSignature = signature
        tagScanTask = Task.detached(priority: .utility) {
            var found: [String: [FinderTag]] = [:]
            for path in paths {
                // Leaving a folder mid-scan must stop the syscalls, not just discard the answer.
                if Task.isCancelled { return }
                let tags = FinderTagService.colorTags(at: path)
                if !tags.isEmpty { found[path] = tags }
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.tagsByPath != found else { return }
                self.tagsByPath = found
                // A filter by tag ("#красный") may already be typed while the scan was running —
                // its answer just changed.
                if self.isQuickFiltering, MaskExpression(self.quickFilterText).usesTags {
                    self.applyQuickFilter()
                }
            }
        }
    }

    /// What Git says about the current listing, keyed by path; only entries with something to
    /// say appear. Filled in the background like the tags, and for the same reason: the answer
    /// costs a process, and no panel may wait on one.
    @Published private(set) var gitByPath: [String: GitBadge] = [:]
    private var gitScanTask: Task<Void, Never>?
    private var gitScannedSignature: Int?

    /// How many repository folders in one listing are asked whether they hold uncommitted work.
    /// Each answer is a `git status` of a whole repository, so a folder holding a hundred clones
    /// would otherwise start a hundred of them; past the cap the branch name is still shown.
    private static let dirtyChecksPerListing = 40
    /// How many of those run at once. They are separate processes waiting on disk, so a few in
    /// parallel finish in the time one of them takes.
    private static let dirtyChecksAtOnce = 4

    /// What Git said about the folders visited lately, newest first.
    ///
    /// Coming back to a folder then shows its marks in the same frame as its names, instead of
    /// blinking them in when git answers. The reading still runs and replaces this a moment
    /// later, so a stale mark cannot outlive one refresh.
    private var gitCache: [(path: String, badges: [String: GitBadge])] = []
    private static let gitCacheSize = 12

    private func rememberGit(_ badges: [String: GitBadge], for path: String) {
        gitCache.removeAll { $0.path == path }
        gitCache.insert((path, badges), at: 0)
        if gitCache.count > Self.gitCacheSize { gitCache.removeLast() }
    }

    /// Reread Git's opinion of the listing.
    ///
    /// Called from the same place as the tags, so it follows every load, and keyed on the same
    /// path set — the metadata pass and the folder-size pass re-announce the SAME rows, and
    /// answering them would restart git over and over.
    func refreshGit(force: Bool = false) {
        guard PanelAppearanceSettings.isGitStatusEnabled else { cancelGitScan(); return }
        // Nothing here has a working tree: an archive, a remote listing, the network browser,
        // the Trash, the shelf. Their paths look ordinary enough to fool a walk up the tree.
        guard !insideRemote, !insideArchive, !state.insideNetworkBrowser, !state.insideTrash,
              !TrashService.isTrashPath(currentPath),
              !DropStackStore.isStackPath(currentPath),
              currentPath.hasPrefix("/") else {
            cancelGitScan(); return
        }
        let folder = currentPath
        let entries = allItems.filter { $0.name != ".." }
        guard !entries.isEmpty else { cancelGitScan(); return }

        var hasher = Hasher()
        hasher.combine(folder)
        for item in entries { hasher.combine(item.path) }
        let signature = hasher.finalize()
        guard force || signature != gitScannedSignature else { return }

        let folders = entries.filter(\.isDirectory).map(\.path)
        gitScanTask?.cancel()
        gitScannedSignature = signature

        // What this folder said last time, shown at once. Without it the marks blink in a
        // moment after the names every single time the folder is opened.
        if let remembered = gitCache.first(where: { $0.path == folder }) {
            gitByPath = remembered.badges
        } else if !gitByPath.isEmpty {
            gitByPath = [:]      // never show the previous folder's marks against these names
        }

        // Answers are published in three goes rather than one, because they arrive that way:
        // the folder's own marks come from a single call, the branch names are free file reads,
        // and only the "is it uncommitted" question costs a process per repository.
        gitScanTask = Task.detached(priority: .userInitiated) {
            var found: [String: GitBadge] = [:]

            func publish() async {
                let snapshot = found
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.rememberGit(snapshot, for: folder)
                    guard self.gitByPath != snapshot else { return }
                    self.gitByPath = snapshot
                }
            }

            // One call answers for every row of a folder that lives inside a repository.
            if let root = GitStatusService.repositoryRoot(for: folder) {
                if Task.isCancelled { return }
                for (path, mark) in GitStatusService.marks(inDirectory: folder, repoRoot: root) {
                    found[path, default: GitBadge()].mark = mark
                }
                await publish()
            }

            // A folder that IS a repository says which branch it is on — straight out of HEAD,
            // no process, so this lands immediately after the marks.
            var repositories: [String] = []
            for path in folders {
                if Task.isCancelled { return }
                guard GitStatusService.isRepositoryRoot(path),
                      let branch = GitStatusService.headBranch(repoRoot: path) else { continue }
                found[path, default: GitBadge()].branch = branch
                repositories.append(path)
            }
            guard !repositories.isEmpty else {
                if found.isEmpty { await publish() }
                return
            }
            await publish()

            // And the slow question last, a few repositories at a time.
            let asked = Array(repositories.prefix(Self.dirtyChecksPerListing))
            let dirty = await withTaskGroup(of: (String, Bool).self) { group -> [String: Bool] in
                var running = 0, next = 0
                var answers: [String: Bool] = [:]
                while next < asked.count || running > 0 {
                    while running < Self.dirtyChecksAtOnce, next < asked.count {
                        let path = asked[next]
                        next += 1
                        running += 1
                        group.addTask { (path, GitStatusService.isDirty(repoRoot: path)) }
                    }
                    guard let (path, isDirty) = await group.next() else { break }
                    running -= 1
                    answers[path] = isDirty
                }
                return answers
            }
            if Task.isCancelled { return }
            for (path, isDirty) in dirty where isDirty { found[path]?.dirty = true }
            await publish()
        }
    }

    /// Forget Git and stop any reading still running for the folder being left.
    private func cancelGitScan() {
        gitScanTask?.cancel()
        gitScanTask = nil
        gitScannedSignature = nil
        if !gitByPath.isEmpty { gitByPath = [:] }
    }

    /// Drop the tags and stop any scan still running for the folder being left. Clearing the
    /// signature too, so coming back to that folder scans it again.
    private func cancelTagScan() {
        tagScanTask?.cancel()
        tagScanTask = nil
        scannedPathsSignature = nil
        if !tagsByPath.isEmpty { tagsByPath = [:] }
    }

    // MARK: - Computed Properties (forwarding to state/data)

    var currentPath: String {
        get { state.currentPath }
        set {
            // Guarded on a real change, not on every assignment: the loader re-assigns the same
            // path on every refresh, and the file watcher triggers one 300 ms after any activity on
            // disk — an unguarded clear would wipe the filter out from under the user mid-typing.
            if newValue != state.currentPath { clearQuickFilter() }
            state.currentPath = newValue
        }
    }

    /// What the panel shows. READ-ONLY on purpose: assigning here used to be how the folder was
    /// updated, and with a quick filter in play a read-modify-write ("drop the deleted paths",
    /// "patch in the folder sizes") would read the visible matches and store them back as the whole
    /// folder, silently losing everything the filter was hiding. Write `allItems` instead.
    var items: [FileItem] { data.items }

    /// The whole folder. This is the one that gets written.
    var allItems: [FileItem] {
        get { data.allItems }
        set {
            data.allItems = newValue
            applyQuickFilter()
        }
    }

    // MARK: - Quick filter

    /// Text typed into the panel's quick-filter bubble; empty means no filtering.
    private(set) var quickFilterText: String = ""
    /// Fired after every recompute of the filtered list, including the ones the panel did not
    /// start itself — the tag scan landing, say. The bubble's read-out lives in the view
    /// controller and would otherwise stay saying "no matches" over a list of them.
    var onQuickFilterRecomputed: (() -> Void)?

    /// Общая папка из обзора сети смонтирована — куда её показать, решает панель: в своей
    /// вкладке, чтобы папка, из которой пришли, осталась на месте. Без привязки — на месте.
    var onNetworkShareMounted: ((String) -> Void)?

    /// Архив не открылся — сказать вслух. Окно, а не только errorMessage: тот рисуется
    /// лишь в пустом списке, а список при неудачном входе полон, и человек видел молчание.
    /// Подменяется в тестах: модальному окну там взяться неоткуда.
    var complainAboutArchive: (_ name: String, _ why: String) -> Void = { name, why in
        DialogService.shared.showError(title: L("panel.error.openArchivePath", name), message: why)
    }

    /// Show what the pattern does NOT match. A view of the folder, not a state of the
    /// selection: turning the list over says "show me the others", and what is marked is left
    /// exactly as it was — marking is what the Select button is for.
    private(set) var quickFilterInverted = false

    /// Does the panel currently show every file in the folder?
    var isQuickFiltering: Bool { !quickFilterText.isEmpty }

    /// How many files the folder holds, whatever is on screen — for "3 of 128" style read-outs.
    var unfilteredItemCount: Int { data.allItems.filter { $0.name != ".." }.count }

    func setQuickFilter(_ text: String) {
        // The same text arrives again when a saved preset chip is pressed over its own mask —
        // and the press still means "this mask, the right way up", so an inversion left behind
        // must not survive the guard.
        guard quickFilterText != text || quickFilterInverted else { return }
        quickFilterText = text
        // A new pattern starts the right way up.
        quickFilterInverted = false
        applyQuickFilter()
    }

    /// Turn the filter over: matches out, everything else in.
    func toggleQuickFilterInversion() {
        guard !quickFilterText.isEmpty else { return }
        quickFilterInverted.toggle()
        applyQuickFilter()
    }

    func clearQuickFilter() { setQuickFilter("") }

    /// Recompute what is on screen, then put the cursor back on the same FILE rather than the same
    /// row — the row number means something different after every keystroke.
    private func applyQuickFilter() {
        let keepPath = data.cursorItem?.path
        let anchorPath = anchorIndex.flatMap { data.items.indices.contains($0) ? data.items[$0].path : nil }

        if quickFilterText.isEmpty {
            data.publishDisplayItems(data.allItems)
        } else {
            // "*.png" is a MASK, not a substring — as a substring it matches nothing at all,
            // which is exactly what the filter used to report. Plain text stays a substring.
            // Built ONCE per pass: the expression compiles a regular expression per term, and
            // doing that for every file turned a big folder into a stutter.
            let expression = MaskExpression(quickFilterText)
            let inverted = quickFilterInverted
            let tags = tagsByPath
            data.publishDisplayItems(data.allItems.filter { item in
                // ".." is navigation, not content: hiding it would strand the user in the folder.
                guard item.name != ".." else { return true }
                let hit = expression.matches(item.name, tags: tags[item.path] ?? [])
                return inverted ? !hit : hit
            })
        }
        // Brief and thumbnails only reload when the count, path, sort token or tags change, so an
        // edit that happens to leave the match count the same would show the previous set in two of
        // the three modes without this.
        data.sortToken &+= 1

        if let keepPath, let row = data.items.firstIndex(where: { $0.path == keepPath }) {
            data.cursorIndex = row
        } else {
            // Never leave a stale index behind: a range selection indexes into items unguarded.
            data.cursorIndex = data.items.isEmpty ? 0 : min(data.cursorIndex, data.items.count - 1)
        }
        anchorIndex = anchorPath.flatMap { path in data.items.firstIndex { $0.path == path } }
        onQuickFilterRecomputed?()
    }

    /// Path of a file currently being launched by the system (for loading indicator)
    var launchingFilePath: String? {
        get { state.launchingFilePath }
        set { state.launchingFilePath = newValue }
    }

    var cursorIndex: Int {
        get { data.cursorIndex }
        set {
            data.cursorIndex = newValue
            onCursorChanged()
        }
    }

    var viewMode: ViewMode {
        get { state.viewMode }
        set {
            let oldValue = state.viewMode
            state.viewMode = newValue
            if canPersistState {
                saveViewMode()
            }
            // Slow volume: progressively load metadata when switching to detailed mode
            if currentPathIsSlowVolume && newValue == .detailed && oldValue != .detailed {
                let reqID = UUID()
                directoryLoadRequestID = reqID
                startSlowVolumeVisibleMetadataPhase(
                    destination: currentPath,
                    requestID: reqID
                )
            }
        }
    }

    private(set) var sortField: PanelSortField {
        get { data.sortField }
        set { data.sortField = newValue }
    }

    private(set) var sortAscending: Bool {
        get { data.sortAscending }
        set { data.sortAscending = newValue }
    }

    var visibleColumns: Set<PanelColumn> {
        get { data.visibleColumns }
        set {
            let normalized = Self.normalizedVisibleColumns(newValue)
            guard normalized != data.visibleColumns else { return }
            objectWillChange.send()
            data.visibleColumns = normalized
            saveVisibleColumns()
        }
    }

    /// Column widths reported by NSTableView for SortBarView alignment in detailed mode.
    var detailedColumnWidths: [PanelColumn: CGFloat] {
        get { data.detailedColumnWidths }
        set {
            guard newValue != data.detailedColumnWidths else { return }
            objectWillChange.send()
            data.detailedColumnWidths = newValue
        }
    }

    /// Icon column width reported by NSTableView.
    var detailedIconColumnWidth: CGFloat {
        get { data.detailedIconColumnWidth }
        set {
            guard newValue != data.detailedIconColumnWidth else { return }
            objectWillChange.send()
            data.detailedIconColumnWidth = newValue
        }
    }

    /// User-set column widths (NSTableColumn identifier → width).
    /// When non-empty, NSTableView keeps these widths; users can drag column
    /// dividers to set their preferred layout. Empty dictionary falls back
    /// to proportional auto-distribution.
    /// Plain storage — no objectWillChange: nothing in SwiftUI renders from
    /// this dictionary (headers render from detailedColumnWidths), and the
    /// setter is hit per-pixel during a drag.
    var userColumnWidths: [String: CGFloat] {
        get { data.userColumnWidths }
        set { data.userColumnWidths = newValue }
    }

    /// Forget the user layout and return to proportional auto-distribution.
    /// Clears memory + UserDefaults and notifies PanelViewController to
    /// redistribute (columnWidthsDidReset).
    func resetUserColumnWidths() {
        data.userColumnWidths = [:]
        UserDefaults.standard.removeObject(forKey: Self.columnWidthsKey(for: pathDefaultsKey))
        data.columnWidthsDidReset.send()
    }

    /// Ask PanelViewController to size every column to its content.
    func requestAutoFitAllColumns() {
        data.autoFitAllColumnsRequested.send()
    }

    var selectedPaths: Set<String> {
        get { data.selectedPaths }
        set { data.selectedPaths = newValue }
    }

    var errorMessage: String? {
        get { state.errorMessage }
        set { state.errorMessage = newValue }
    }

    var insideArchive: Bool {
        get { state.insideArchive }
        set { state.insideArchive = newValue }
    }

    var archivePath: String? {
        get { state.archivePath }
        set { state.archivePath = newValue }
    }

    /// Current folder inside the open archive ("" at the archive root).
    /// Used as the destination base path when adding files into the archive.
    var currentArchiveRelativePath: String { archiveRelativePath }

    /// The real folder holding the open archive — where ".." finally leads out to, and therefore
    /// where entries dropped onto ".." are extracted.
    var archiveParentFolder: String? {
        guard let archivePath else { return nil }
        if let parent = try? service.parentPath(for: archivePath) { return parent }
        let fallback = (archivePath as NSString).deletingLastPathComponent
        return fallback.isEmpty ? "/" : fallback
    }

    var scrollResetToken: UInt64 {
        get { data.scrollResetToken }
        set { data.scrollResetToken = newValue }
    }

    private(set) var sortToken: UInt64 {
        get { data.sortToken }
        set { data.sortToken = newValue }
    }
    var scrollOnCursorChange: Bool = true
    var anchorIndex: Int?

    nonisolated(unsafe) private let service: CoreBridgeService
    // Readable by the panel controller so its own gestures go through the one service rather
    // than reaching for NSWorkspace/FileManager themselves.
    nonisolated(unsafe) let operationsService: FileOperationsService
    private let pathDefaultsKey: String
    private let viewModeDefaultsKey: String
    private let visibleColumnsDefaultsKey: String
    private var showHiddenFiles: Bool
    /// Read-only access for extensions in separate files (showHiddenFiles is private).
    var isShowingHiddenFiles: Bool { showHiddenFiles }
    private var canPersistState = false

    private var archiveCaches: [String: ArchiveCache] = [:]
    /// Архивы, которые не прочлись, — с подписью файла на тот момент. Пока файл не изменился,
    /// повторять не стоит: на сетевом томе каждая попытка — обращение по сети, а курсор
    /// проходит по одним и тем же файлам десятки раз.
    private var archivePrewarmFailures: [String: ArchiveFileSignature] = [:]
    private var archiveRelativePath: String = ""
    /// Where ".." leads when leaving a NESTED archive: the outer archive, the folder inside it,
    /// and the entry to put the cursor back on. A stack — zip inside tar inside 7z just nests.
    private var archiveReturnStack: [(archive: String, relative: String, cursorEntry: String)] = []
    /// Consumed after the next archive listing lands: puts the cursor on this entry.
    private var pendingArchiveCursorEntry: String?
    /// True while browsing an archive that was itself extracted OUT of another archive. Edits
    /// would land on the temp copy and silently evaporate, so they are refused while nested.
    var isNestedArchive: Bool { !archiveReturnStack.isEmpty }
    private var archiveOpenTask: Task<Void, Never>?
    private var archiveOpenRequestID: UUID?
    private var archivePrewarmTask: Task<Void, Never>?
    private var archivePriorityPrewarmTask: Task<Void, Never>?
    private var archiveHoverPrewarmTask: Task<Void, Never>?
    private var priorityPrewarmArchivePath: String?
    private var archiveLoadTasks: [String: ArchiveLoadTask] = [:]
    var remoteLoadTask: Task<Void, Never>?
    private var directoryDetailsTask: Task<Void, Never>?
    private var folderSizeTask: Task<Void, Never>?
    private var folderSizeRequestID: UUID?
    private var directoryLoadRequestID: UUID?
    private var directoryCaches: [String: DirectoryCache] = [:]
    private var directoryCacheLRU: [String] = []
    private(set) var currentPathIsSlowVolume: Bool = false

    // MARK: - Network Browser

    private var networkUpdateObserver: Any?

    /// Where the panel stood before the Trash was opened, so ".." goes back there.
    private var trashReturnPath: String = ""
    /// Where the panel was before it opened the shelf.
    private var stackReturnPath: String = ""

    /// Real path in the Trash → the folder it was deleted from. Built once per listing, because
    /// the answer comes from parsing a .DS_Store and a per-cell lookup would reparse it per row.
    private(set) var trashOrigins: [String: String] = [:]

    /// Tell the person when the empty list is the system's doing, not an empty network.
    /// Before the scan has finished only a NAMED refusal is worth a word; after a full scan
    /// that found nobody, silence from the gateway is too — macOS keeps a program off the
    /// local network without asking when its prompt never came, and nothing else on screen
    /// would ever say so. Said at most once per visit.
    private func warnIfLocalNetworkBlocked(afterScan: Bool, listIsEmpty: Bool) async {
        // Шлюз спрашиваем у системы, а не назначаем «первым адресом подсети»: он там не
        // всегда, а проверка разрешения должна стучаться в живое.
        let gateway = await Task.detached(priority: .utility) {
            LANDiscovery.defaultGateway()
        }.value
        let state = await Task.detached(priority: .utility) {
            LocalNetworkPermission.state(gateway: gateway)
        }.value
        guard let advice = LocalNetworkPermission.adviceAfterEmptyScan(state),
              LocalNetworkPermission.shouldWarn(advice, afterScan: afterScan,
                                                listIsEmpty: listIsEmpty),
              advice != lastLocalNetworkAdvice else { return }
        lastLocalNetworkAdvice = advice
        let key = advice == .denied ? "network.denied" : "network.unsure"
        let open = await fcxlPresentModalAsync {
            DialogService.shared.showConfirmationCustom(
                title: L("\(key).title"),
                message: L("\(key).message"),
                confirmTitle: L("network.denied.open"),
                cancelTitle: L("button.cancel"))
        }
        if open { NSWorkspace.shared.open(LocalNetworkPermission.settingsURL) }
    }

    private var lastLocalNetworkAdvice: LocalNetworkPermission.Advice?
    private var networkScanObserver: Any?

    /// Load a virtual network directory: /NETWORK → computers, /NETWORK/Comp → shares
    private func loadNetworkDirectory(at path: String) async {
        state.insideNetworkBrowser = true
        stopFSWatcher()

        if path == NetworkBrowserService.networkRoot {
            // Level 1: show discovered computers
            NetworkBrowserService.shared.startScanning()

            // Auto-refresh when new hosts are discovered
            if networkUpdateObserver == nil {
                networkUpdateObserver = NotificationCenter.default.addObserver(
                    forName: .networkBrowserDidUpdate, object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self, self.state.insideNetworkBrowser,
                          self.currentPath == NetworkBrowserService.networkRoot else { return }
                    // Refresh the computer list
                    let computers = NetworkBrowserService.shared.listComputers()
                    self.applyLoadedFileSystemItems(
                        computers, destination: NetworkBrowserService.networkRoot,
                        resetCursor: false, preferredCursorPath: nil, clearSelection: false
                    )
                }
            }

            // The whole subnet has been asked and nobody answered: say why that may be.
            if networkScanObserver == nil {
                networkScanObserver = NotificationCenter.default.addObserver(
                    forName: .networkBrowserScanDidFinish, object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self, self.state.insideNetworkBrowser,
                          self.currentPath == NetworkBrowserService.networkRoot else { return }
                    let empty = NetworkBrowserService.shared.listComputers().isEmpty
                    Task { @MainActor in
                        await self.warnIfLocalNetworkBlocked(afterScan: true, listIsEmpty: empty)
                    }
                }
            }

            let computers = NetworkBrowserService.shared.listComputers()
            applyLoadedFileSystemItems(computers, destination: path, resetCursor: true,
                                      preferredCursorPath: nil, clearSelection: true)
            // An empty list has two very different meanings: nobody is there, or macOS is
            // refusing this program the local network (Privacy & Security ▸ Local Network).
            // The refusal is silent — Bonjour answers nothing, every connection dies with
            // "Local network prohibited" — and the person sees the same empty list either way.
            // Ask once, and say it out loud.
            await warnIfLocalNetworkBlocked(afterScan: false, listIsEmpty: computers.isEmpty)
            return
        }

        if let shareInfo = NetworkBrowserService.shareInfo(from: path) {
            // Level 3: mount specific share → navigate to real filesystem
            state.insideNetworkBrowser = false
            removeNetworkObserver()
            if let mountPath = await NetworkBrowserService.shared.mountShare(
                computerName: shareInfo.computer, shareName: shareInfo.share
            ) {
                NSLog("[FCXL-NAV] share '%@/%@' mounted → navigating to '%@' (exists=%d)",
                      shareInfo.computer, shareInfo.share, mountPath, directoryStillExists(mountPath) ? 1 : 0)
                if let onNetworkShareMounted {
                    onNetworkShareMounted(mountPath)
                } else {
                    loadFileSystemDirectory(at: mountPath, resetCursor: true)
                }
            } else {
                NSLog("[FCXL-NAV] share '%@/%@' mount returned nil → back to shares list", shareInfo.computer, shareInfo.share)
                // Mount failed — go back to shares list
                state.insideNetworkBrowser = true
                let parentPath = "\(NetworkBrowserService.networkRoot)/\(shareInfo.computer)"
                await loadNetworkDirectory(at: parentPath)
            }
            return
        }

        if let computerName = NetworkBrowserService.computerName(from: path) {
            // Level 2: show shares on this computer (reads Keychain for auth).
            // Listing (smbutil view + possible auth) can take a few seconds — show the
            // cursor spinner so the click doesn't feel like nothing happened.
            state.isListingNetworkShares = true
            let result = await NetworkBrowserService.shared.listShares(computerName: computerName)
            state.isListingNetworkShares = false
            // «Отмена» во входе — это «я передумал», а не «папок нет»: панель возвращается
            // туда, откуда пришла, к списку компьютеров. Раньше она оставалась в пустой
            // папке, и выглядело это так, будто сеть исчезла.
            if result.cancelled {
                await loadNetworkDirectory(at: NetworkBrowserService.networkRoot)
                return
            }
            if result.shares.isEmpty {
                errorMessage = L("network.noShares")
            }
            applyLoadedFileSystemItems(result.shares, destination: path, resetCursor: true,
                                      preferredCursorPath: nil, clearSelection: true)
            return
        }
    }

    /// Show the macOS Trash. Flat by design: entries keep their REAL paths, so viewing (F3),
    /// icons and previews need no special case, and stepping into a trashed folder simply browses
    /// it where it lies.
    func loadTrashDirectory() {
        if !state.insideTrash {
            // Remembered so ".." leads back where the user came from rather than to the root.
            // Путь внутри самой корзины сюда не годится: в корзину попадают и «..» из лежащей
            // в ней папки — запомнив его, «..» из корзины возвращало бы обратно в корзину.
            trashReturnPath = TrashService.isInsideTrashFolder(currentPath) ? "" : currentPath
        }
        state.insideTrash = true
        state.insideNetworkBrowser = false
        stopFSWatcher()
        dropPendingDirectoryLoad()
        let entries = TrashService.entries()
        trashOrigins = entries.reduce(into: [:]) { map, entry in
            map[entry.url.path] = entry.originalFolder
        }
        applyLoadedFileSystemItems(TrashService.items(), destination: TrashService.trashRoot,
                                   resetCursor: false, preferredCursorPath: nil,
                                   clearSelection: false)
    }

    /// Show the shelf. Its contents are ordinary files at their real paths, so everything the
    /// panel and the operations already do works on them unchanged — the shelf is a listing,
    /// not a place.
    func loadStackDirectory() {
        if !state.insideStack {
            // Remembered so ".." leads back where the user came from rather than to the root.
            stackReturnPath = currentPath
        }
        state.insideStack = true
        state.insideTrash = false
        state.insideNetworkBrowser = false
        stopFSWatcher()
        dropPendingDirectoryLoad()
        applyLoadedFileSystemItems(DropStackStore.items(), destination: DropStackStore.stackRoot,
                                   resetCursor: false, preferredCursorPath: nil,
                                   clearSelection: false)
    }

    /// Оборвать незавершённое чтение прежней папки перед виртуальным видом.
    ///
    /// Поздние фазы чтения сверяют и номер запроса, и путь; первая — «только имена» —
    /// только номер, потому что она и есть переход. Человек вошёл в медленную папку, не
    /// дождался и нажал «Корзина»: вид корзины показан, а затем доходит старый список и
    /// ложится поверх — с путём папки и признаком «я в корзине», где F8 стирает насовсем.
    private func dropPendingDirectoryLoad() {
        directoryDetailsTask?.cancel()
        directoryLoadRequestID = UUID()
    }

    /// Leave the shelf for wherever the panel was before it.
    private func goUpStack() {
        state.insideStack = false
        let destination = stackReturnPath.isEmpty || DropStackStore.isStackPath(stackReturnPath)
            ? NSHomeDirectory()
            : stackReturnPath
        loadFileSystemDirectory(at: destination, resetCursor: true)
    }

    /// Leave the Trash for wherever the panel was before it.
    private func goUpTrash() {
        state.insideTrash = false
        let destination = trashReturnPath.isEmpty || TrashService.isTrashPath(trashReturnPath)
                || TrashService.isInsideTrashFolder(trashReturnPath)
            ? NSHomeDirectory()
            : trashReturnPath
        loadFileSystemDirectory(at: destination, resetCursor: true)
    }

    /// Navigate up in network browser levels.
    private func goUpNetwork() {
        if let _ = NetworkBrowserService.computerName(from: currentPath) {
            // From shares list → back to computers list
            Task { await loadNetworkDirectory(at: NetworkBrowserService.networkRoot) }
        } else {
            // From computers list → exit network mode
            state.insideNetworkBrowser = false
            removeNetworkObserver()
            loadFileSystemDirectory(at: NSHomeDirectory(), resetCursor: true)
        }
    }

    private func removeNetworkObserver() {
        if let obs = networkUpdateObserver {
            NotificationCenter.default.removeObserver(obs)
            networkUpdateObserver = nil
        }
    }

    // MARK: - Remote Session
    /// When non-nil, the panel holds a remote connection (may be parked on another tab).
    var remoteSession: RemoteSession? {
        get { state.remoteSession }
        set {
            let previous = state.remoteSession
            state.remoteSession = newValue
            // Общий список — отсюда, из единственной двери: полоса дисков другой панели
            // показывает это подключение тоже.
            if previous !== newValue {
                RemoteSessionRegistry.shared.replace(previous, with: newValue)
            }
        }
    }
    /// True only when the panel is actively displaying remote content.
    /// Separate from remoteSession != nil — session can be parked while browsing local tabs.
    var isActivelyRemote: Bool {
        get { state.isActivelyRemote }
        set { state.isActivelyRemote = newValue }
    }

    // MARK: - FSEvents Watcher
    private var fsWatcher: FCXLWatcherBridge?
    private var fsWatcherDebounceTask: Task<Void, Never>?
    private var watchedPath: String?

    // MARK: - Navigation History
    private var historyBack: [String] = []
    private var historyForward: [String] = []
    private var isNavigatingHistory = false

    var canGoBack: Bool { !historyBack.isEmpty }
    var canGoForward: Bool { !historyForward.isEmpty }

    // MARK: - Bookmarks
    /// The app-wide favourites — one list, not a per-panel copy that goes stale.
    var bookmarks: [String] { FavoriteFolders.paths }

    // MARK: - Navigation History Methods

    func goBack() {
        guard let previousPath = historyBack.popLast() else { return }
        isNavigatingHistory = true
        historyForward.append(currentPath)
        loadFileSystemDirectory(at: previousPath, resetCursor: true)
        isNavigatingHistory = false
    }

    /// The folder the panel came UP from, if it lies beneath this one: the trail a run of
    /// "up"s leaves in the history, read one step at a time. nil once the trail is walked
    /// back, or when the last move was not an ascent.
    var trailBelow: String? {
        guard let back = historyBack.last else { return nil }
        let here = (currentPath as NSString).standardizingPath
        let below = (back as NSString).standardizingPath
        let root = here.hasSuffix("/") ? here : here + "/"
        return below != here && below.hasPrefix(root) ? below : nil
    }

    /// One step back down the trail — into the folder this one was reached from by going up.
    /// Through the history, so back and forward stay consistent with it. False when there is
    /// no trail beneath.
    @discardableResult
    func descendTrail() -> Bool {
        guard trailBelow != nil else { return false }
        goBack()
        return true
    }

    func goForward() {
        guard let nextPath = historyForward.popLast() else { return }
        isNavigatingHistory = true
        historyBack.append(currentPath)
        loadFileSystemDirectory(at: nextPath, resetCursor: true)
        isNavigatingHistory = false
    }

    func pushHistory(from oldPath: String, to newPath: String) {
        guard !isNavigatingHistory, oldPath != newPath else { return }
        historyBack.append(oldPath)
        historyForward.removeAll()
        if historyBack.count > 50 {
            historyBack.removeFirst(historyBack.count - 50)
        }
    }

    // MARK: - Bookmarks

    func addBookmark(_ path: String? = nil) {
        FavoriteFolders.add(path ?? currentPath)
    }

    func removeBookmark(_ path: String) {
        FavoriteFolders.remove(path)
    }

    /// The one road to a favourite folder, whoever asks. Favourites are local places, so a
    /// panel sitting on FTP steps back onto the local disk first — the same order the volume
    /// bar's eject uses.
    func navigateToBookmark(_ path: String) {
        if insideRemote { exitRemote() }
        loadDirectory(at: path, resetCursor: true)
    }

    // MARK: - Breadcrumbs

    var breadcrumbs: [(name: String, path: String)] {
        state.breadcrumbs
    }

    // MARK: - Selection by Mask

    /// Add every VISIBLE name matching the mask to the selection. Visible, not everything on
    /// disk: what a quick filter hides is not what the user is looking at.
    @discardableResult
    func selectByMask(_ pattern: String) -> Int {
        let expression = MaskExpression(pattern)
        guard !expression.isEmpty else { return 0 }
        var added = 0
        for item in items where item.name != ".." {
            if expression.matches(item.name, tags: tagsByPath[item.path] ?? []),
               selectedPaths.insert(item.path).inserted {
                added += 1
            }
        }
        return added
    }

    @discardableResult
    func deselectByMask(_ pattern: String) -> Int {
        let expression = MaskExpression(pattern)
        guard !expression.isEmpty else { return 0 }
        var removed = 0
        for item in items where item.name != ".." {
            if expression.matches(item.name, tags: tagsByPath[item.path] ?? []),
               selectedPaths.remove(item.path) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Mark everything the panel is showing right now. Acting on what is VISIBLE rather than on
    /// the pattern is what keeps the buttons honest once the filter is turned over.
    @discardableResult
    func selectVisible() -> Int {
        var added = 0
        for item in items where item.name != ".." {
            if selectedPaths.insert(item.path).inserted { added += 1 }
        }
        return added
    }

    /// Is anything the panel is SHOWING marked? What the clear button can actually act on —
    /// files marked outside the filter are none of its business, and judging the button by the
    /// whole selection left it lit with nothing to do.
    var hasSelectionAmongVisible: Bool {
        items.contains { $0.name != ".." && selectedPaths.contains($0.path) }
    }

    @discardableResult
    func deselectVisible() -> Int {
        var removed = 0
        for item in items where item.name != ".." {
            if selectedPaths.remove(item.path) != nil { removed += 1 }
        }
        return removed
    }

    /// Swap the marks over the WHOLE folder: what was marked lets go, what was not is marked.
    /// Across the folder rather than across the screen, because the point of inverting under a
    /// filter is to get at the files the filter is hiding.
    func invertSelectionInFolder() {
        var next = Set<String>()
        for item in allItems where item.name != ".." {
            if !selectedPaths.contains(item.path) { next.insert(item.path) }
        }
        selectedPaths = next
    }

    func selectSameType() {
        guard let current = cursorItem, !current.isDirectory else { return }
        let ext = current.fileExtension.lowercased()
        for item in items where item.fileExtension.lowercased() == ext && !item.isDirectory {
            selectedPaths.insert(item.path)
        }
    }

    func invertSelection() {
        var newSelection = Set<String>()
        for item in items where item.name != ".." {
            if !selectedPaths.contains(item.path) {
                newSelection.insert(item.path)
            }
        }
        selectedPaths = newSelection
    }

    /// A file mask as a regular expression. Only `*` and `?` mean anything; EVERYTHING else is
    /// escaped, including the characters that are regex operators in their own right — a mask
    /// like "report(1).*" or "[draft]*" used to leak its brackets into the pattern and either
    /// threw the expression away or matched the wrong files.
    nonisolated static func wildcardToRegex(_ pattern: String) -> String {
        var regex = "^"
        for char in pattern {
            switch char {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        regex += "$"
        return regex
    }

    /// Several patterns at once: "*.png & *.pdf" is png AND pdf on screen.
    ///
    /// A file cannot be both a png and a pdf, so an operator between two masks can only join
    /// SETS, never conditions — which is exactly how it is meant when typed. Every separator a
    /// user might reach for reads the same way: `&`, `|`, `,`, `;` and a plain space all mean
    /// "and also". A term after `!` is thrown out instead: "*.png !копия*" is every png except
    /// the copies.
    ///
    /// A term with a `*` or a `?` is a MASK and is matched whole; a term without one is just a
    /// piece of a name, the way typing into the panel has always worked. Which is why the
    /// per-file "and" needs no operator at all — "contains 2026 and is a png" is `*2026*.png`.
    nonisolated struct MaskExpression {
        private struct Term {
            let regex: NSRegularExpression?
            let substring: String?
            /// `#красный` — the file carries this colour tag; `#` alone, any tag at all. Held as
            /// the set of colours the typed name could begin ("#с" starts both синяя and серая,
            /// and showing both is the answer, not an error).
            let tags: Set<FinderTag>?

            func matches(_ name: String, tags fileTags: [FinderTag]) -> Bool {
                if let tags { return fileTags.contains { tags.contains($0) } }
                // A substring needs nothing done to it: Swift compares strings by canonical
                // equivalence, so the two Unicode forms of a name already read as one.
                if let substring { return name.lowercased().contains(substring) }
                guard let regex else { return false }
                // A regular expression does not. It compares UTF-16 units, while a name arrives
                // in whichever form it was written with — decomposed for everything made through
                // Cocoa, where "ё" is "е" plus U+0308 — and a mask typed into the panel arrives
                // composed. Both sides are composed before they meet.
                let composed = name.precomposedStringWithCanonicalMapping
                return regex.firstMatch(in: composed,
                                        range: NSRange(composed.startIndex..., in: composed)) != nil
            }
        }

        private let includes: [Term]
        private let excludes: [Term]
        /// Nothing to filter by: an empty box, or only separators.
        var isEmpty: Bool { includes.isEmpty && excludes.isEmpty }
        /// Whether any term asks about tags — the caller then knows the answer can change when
        /// the background tag scan lands, and refilters.
        let usesTags: Bool

        init(_ text: String) {
            var includes: [Term] = [], excludes: [Term] = []

            // A space separates like every other operator — "png jpg" is two patterns, and the
            // help says so. It does mean a name typed with a space in it ("отчёт 2026") reads
            // as two searches and shows more than asked for; that way round is the safer one,
            // since a wider list still holds the file while a literal search for a pattern the
            // user meant as two would show nothing at all.
            for raw in text.split(whereSeparator: { "&|,; \t".contains($0) }) {
                var piece = String(raw)
                let negated = piece.hasPrefix("!")
                if negated { piece.removeFirst() }
                guard !piece.isEmpty else { continue }
                let term: Term
                if piece.hasPrefix("#"),
                   case let colours = PanelViewModel.tags(named: String(piece.dropFirst())),
                   !colours.isEmpty {
                    term = Term(regex: nil, substring: nil, tags: colours)
                } else if piece.hasPrefix("#") {
                    // "#" followed by something no colour is called — "#заметки" — is a file
                    // NAME, and files named with a # must stay findable.
                    term = Term(regex: nil, substring: piece.lowercased(), tags: nil)
                } else if PanelViewModel.looksLikeMask(piece) {
                    term = Term(regex: try? NSRegularExpression(
                        pattern: PanelViewModel.wildcardToRegex(
                            piece.precomposedStringWithCanonicalMapping),
                        options: .caseInsensitive),
                                substring: nil, tags: nil)
                } else {
                    term = Term(regex: nil, substring: piece.lowercased(), tags: nil)
                }
                if negated { excludes.append(term) } else { includes.append(term) }
            }
            self.includes = includes
            self.excludes = excludes
            self.usesTags = (includes + excludes).contains { $0.tags != nil }
        }

        func matches(_ name: String, tags: [FinderTag] = []) -> Bool {
            if excludes.contains(where: { $0.matches(name, tags: tags) }) { return false }
            // Only exclusions typed ("!*.tmp") means everything else stays.
            return includes.isEmpty || includes.contains { $0.matches(name, tags: tags) }
        }
    }

    /// Which of the seven colours a typed tag name means. By its BEGINNING, in the app's
    /// language or in English (Finder stores the English name): "#кр" is красный, "#с" is синяя
    /// or серая — both, since either is what was typed. Empty after the # — any tag at all.
    /// A name no colour starts with means an empty set: the term then matches nothing, the same
    /// way a mask that fits no file shows an empty list rather than everything.
    ///
    /// Two things Russian makes necessary. "ё" counts as "е": the tag is stored as "Жёлтая" and
    /// everybody types "желтая". And the ENDING is forgiven — the tag is named "Жёлтая" but the
    /// colour is thought of as "жёлтый", so a word that walks with the name for three letters
    /// and then parts ways only over its tail still names it. Three, because the shortest pair
    /// of colours ("синий"/"синяя") agrees exactly that far.
    nonisolated static func tags(named prefix: String) -> Set<FinderTag> {
        guard !prefix.isEmpty else { return Set(FinderTag.allCases) }
        func fold(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "ё", with: "е")
        }
        let wanted = fold(prefix)
        return Set(FinderTag.allCases.filter { tag in
            let names = [fold(tag.localizedName), fold(tag.rawValue)]
            if names.contains(where: { $0.hasPrefix(wanted) }) { return true }
            return names.contains { $0.commonPrefix(with: wanted).count >= 3 }
        })
    }

    /// Whether a name matches a mask expression. Case-insensitive, like every other name
    /// comparison here.
    nonisolated static func name(_ name: String, matchesMask pattern: String) -> Bool {
        let expression = MaskExpression(pattern)
        return expression.isEmpty ? false : expression.matches(name)
    }

    /// A mask is what the user typed when it carries a wildcard. Plain text stays plain text —
    /// typing "png" must keep finding "screenshot.png.bak", the way it always has. An operator
    /// counts too: "png|pdf" is plainly meant as two patterns, not as one odd name.
    nonisolated static func looksLikeMask(_ text: String) -> Bool {
        if text.contains("*") || text.contains("?")
            || text.contains(where: { "&|,;!".contains($0) }) { return true }
        // A tag term is mask syntax — but only where a term BEGINS with #. A name that merely
        // holds one ("file#1") stays a plain substring search, as it always was.
        return text.split(whereSeparator: { "&|,; \t".contains($0) })
            .contains { $0.hasPrefix("#") }
    }

    deinit {
        archiveOpenTask?.cancel()
        archivePrewarmTask?.cancel()
        archivePriorityPrewarmTask?.cancel()
        archiveHoverPrewarmTask?.cancel()
        directoryDetailsTask?.cancel()
        folderSizeTask?.cancel()
        archiveLoadTasks.values.forEach { $0.task.cancel() }
        operationsService.cleanupArchivePreviewTemporaryDirectories()
    }

    init(service: CoreBridgeService,
         initialPath: String,
         pathDefaultsKey: String,
         viewModeDefaultsKey: String,
         showHiddenFiles: Bool) {
        self.service = service
        operationsService = FileOperationsService(bridgeService: service)
        self.pathDefaultsKey = pathDefaultsKey
        self.viewModeDefaultsKey = viewModeDefaultsKey
        visibleColumnsDefaultsKey = Self.visibleColumnsDefaultsKey(for: pathDefaultsKey)
        self.showHiddenFiles = showHiddenFiles

        // Initialize facade objects
        self.state = PanelState()
        self.data = PanelData()

        let defaults = UserDefaults.standard
        if let savedModeRawValue = defaults.string(forKey: viewModeDefaultsKey) {
            if let savedMode = ViewMode(rawValue: savedModeRawValue) {
                state.viewMode = savedMode
            } else {
                state.viewMode = .detailed
            }
        } else {
            state.viewMode = .detailed
        }

        let resolvedInitialPath = defaults.string(forKey: pathDefaultsKey) ?? initialPath
        state.currentPath = resolvedInitialPath
        if let storedColumns = defaults.array(forKey: visibleColumnsDefaultsKey) as? [String] {
            let parsedColumns = Set(storedColumns.compactMap(PanelColumn.init(rawValue:)))
            data.visibleColumns = Self.normalizedVisibleColumns(parsedColumns)
        } else {
            data.visibleColumns = Set(PanelColumn.allCases)
        }

        // Restore user column widths (only if persistence enabled by user).
        let persistWidths = defaults.object(forKey: Self.persistColumnWidthsKey) as? Bool ?? true
        if persistWidths,
           let stored = defaults.dictionary(forKey: Self.columnWidthsKey(for: pathDefaultsKey)) as? [String: Double] {
            data.userColumnWidths = stored.mapValues { CGFloat($0) }
        }

        // Forward state.objectWillChange to self.objectWillChange for SwiftUI compatibility
        state.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward ALL PanelData subjects to objectWillChange.
        // This ensures SwiftUI views (brief/thumbnails via AlternateFileListWrapper)
        // get re-rendered on cursor, selection, items, and scroll changes.
        // Safe: NSTableView is outside SwiftUI hierarchy, so no layout penalty.
        // This is the FUNDAMENTAL bridge between PanelData and SwiftUI —
        // do NOT remove even during refactoring. Without it, brief/thumbnails
        // modes lose cursor, selection, and item updates.
        //
        // Debounced to coalesce rapid-fire subject emissions (e.g. items + cursor +
        // selection during directory reload) into a single objectWillChange.send().
        // Uses .debounce (not .collect(.byTime)) so no timer runs when idle.
        Publishers.MergeMany(
            data.dataDidChange, data.cursorDidChange,
            data.selectionDidChange, data.scrollResetRequested
        )
        .debounce(for: .milliseconds(8), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)

        // Status numbers ride their own synchronous hooks, not the debounced SwiftUI
        // bridge: the bar renders from THREE READY integers, and the O(N) count runs once
        // per list publish instead of once per cursor tick.
        data.dataDidChange
            .sink { [weak self] in self?.rebuildStatusNumbers() }
            .store(in: &cancellables)
        data.selectionDidChange
            .sink { [weak self] in self?.recomputeSelectedStatus() }
            .store(in: &cancellables)

        canPersistState = true
        // Первое чтение папки. Если запомненная папка лежит в охраняемой системой — Рабочий
        // стол, Документы, Загрузки, iCloud, съёмный или сетевой том, — macOS спросит
        // разрешение. А из инициализации панели этот вопрос выходил ДО первого окна: человек
        // видел системное окно про папки раньше, чем саму программу, и не понимал, чьё оно.
        // Такие пути читаются на такт позже, когда окно уже на экране; все остальные —
        // сразу, как раньше.
        if Self.needsVisibleWindowBeforeReading(resolvedInitialPath) {
            DispatchQueue.main.async { [weak self] in
                self?.loadFileSystemDirectory(at: resolvedInitialPath, resetCursor: true)
            }
        } else {
            loadFileSystemDirectory(at: resolvedInitialPath, resetCursor: true)
        }
    }

    /// Охраняет ли macOS доступ к этому пути — то есть может ли первое обращение к нему
    /// поднять системный вопрос «разрешить доступ?».
    ///
    /// Список закрытых мест у macOS свой и известный: Рабочий стол, Документы, Загрузки,
    /// хранилище iCloud, съёмные и сетевые тома. Обойти сам вопрос нельзя — его задаёт
    /// система любому файловому менеджеру, кроме Finder; можно только не задавать его раньше,
    /// чем человек увидел программу.
    nonisolated static func needsVisibleWindowBeforeReading(
        _ path: String, home: String = NSHomeDirectory()) -> Bool {
        if path.hasPrefix("/Volumes/") { return true }
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { home + "/" + $0 }
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Status numbers (cached)

    /// The three numbers the status bar shows, kept READY instead of recomputed in the view.
    /// The bar re-renders on every cursor tick (the SwiftUI bridge fires for the brief and
    /// thumbnail modes), and filtering a hundred thousand FileItems per keystroke — copying
    /// every struct, three passes — was the Big Stutter: arrows crawled on big branch views.
    private(set) var statusVisibleCount = 0
    private(set) var statusSelectedCount = 0
    private(set) var statusSelectedBytes: UInt64 = 0
    private var visibleSizeByPath: [String: UInt64] = [:]

    private func rebuildStatusNumbers() {
        var sizes = [String: UInt64](minimumCapacity: data.items.count)
        var count = 0
        for item in data.items where item.name != ".." {
            sizes[item.path] = item.size
            count += 1
        }
        visibleSizeByPath = sizes
        statusVisibleCount = count
        recomputeSelectedStatus()
    }

    /// O(selection), not O(folder): walking the selected paths against the size map means a
    /// Shift+arrow in a 100k list costs what the SELECTION costs, not what the folder does.
    private func recomputeSelectedStatus() {
        var count = 0
        var bytes: UInt64 = 0
        for path in data.selectedPaths {
            if let size = visibleSizeByPath[path] {
                count += 1
                bytes &+= size
            }
        }
        statusSelectedCount = count
        statusSelectedBytes = bytes
    }

    func isColumnVisible(_ column: PanelColumn) -> Bool {
        visibleColumns.contains(column)
    }

    /// The columns the panel actually shows right now. Everything that draws a column — the
    /// table, the sort bar headers — must ask this and not `visibleColumns`, or the Trash ends
    /// up with headers over one set and data from another.
    var effectiveVisibleColumns: Set<PanelColumn> {
        state.insideTrash ? PanelColumn.trashColumns : visibleColumns
    }

    // MARK: - Column order (drag to reorder)

    static let columnOrderKey = "fcxl.columnOrder"
    /// Every metadata column in its out-of-the-box order; `.name` is pinned outside it.
    nonisolated static let defaultColumnOrder: [PanelColumn] =
        [.type, .size, .dateCreated, .dateModified, .dateAdded, .permissions, .owner, .origin]

    /// The user's column order, one for both panels. Unknown names are dropped, columns a
    /// later version adds are appended — a saved order can never LOSE a column.
    var columnOrder: [PanelColumn] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Self.columnOrderKey) ?? []
            return Self.sanitizedColumnOrder(raw.compactMap(PanelColumn.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(Self.sanitizedColumnOrder(newValue).map(\.rawValue),
                                      forKey: Self.columnOrderKey)
            // The header bar renders from this (objectWillChange), the AppKit table follows
            // the subject — the same pair every visibility change already rides.
            objectWillChange.send()
            data.columnVisibilityDidChange.send()
        }
    }

    /// A well-formed order: no duplicates, never `.name`, every known column present.
    nonisolated static func sanitizedColumnOrder(_ order: [PanelColumn]) -> [PanelColumn] {
        var seen = Set<PanelColumn>()
        var result: [PanelColumn] = []
        for column in order where column != .name && seen.insert(column).inserted {
            result.append(column)
        }
        for column in defaultColumnOrder where !seen.contains(column) {
            result.append(column)
        }
        return result
    }

    /// `order` with `moving` placed before `target` (nil target = to the end).
    nonisolated static func columnOrder(_ order: [PanelColumn], moving: PanelColumn,
                                        before target: PanelColumn?) -> [PanelColumn] {
        guard moving != target else { return order }
        var rest = order.filter { $0 != moving }
        if let target, let idx = rest.firstIndex(of: target) {
            rest.insert(moving, at: idx)
        } else {
            rest.append(moving)
        }
        return rest
    }

    /// What the header bar draws: name first, then the ordered VISIBLE metadata columns.
    var orderedVisibleColumns: [PanelColumn] {
        let visible = effectiveVisibleColumns
        return [.name] + columnOrder.filter { visible.contains($0) }
    }

    func setColumnVisibility(_ column: PanelColumn, isVisible: Bool) {
        guard column != .name else { return }
        var updated = visibleColumns
        if isVisible {
            updated.insert(column)
        } else {
            updated.remove(column)
        }
        visibleColumns = Self.normalizedVisibleColumns(updated)
    }

    var selectedItems: [FileItem] {
        items.filter { selectedPaths.contains($0.path) }
    }

    /// Настройка «Клавиши ▸ Выделение»: файл под курсором участвует в операции вместе с
    /// выделенными. Выключено — как в Total Commander: выделено что-то — берётся только оно.
    static let includeCursorInOperationsKey = "fcxl.includeCursorInOperations"

    /// Что берёт операция: выделенное, иначе — файл под курсором. При включённой настройке
    /// файл под курсором добавляется к выделенным — после ⇧+стрелок курсор стоит на
    /// следующей, невыделенной строке, и человек ждёт, что она тоже пойдёт в дело.
    var operationTargets: [FileItem] {
        if !selectedItems.isEmpty {
            var targets = selectedItems.filter { $0.name != ".." }
            if UserDefaults.standard.bool(forKey: Self.includeCursorInOperationsKey),
               let cursorItem, cursorItem.name != "..", !selectedPaths.contains(cursorItem.path) {
                targets.append(cursorItem)
            }
            return targets
        }
        guard let cursorItem, cursorItem.name != ".." else {
            return []
        }
        return [cursorItem]
    }

    var cursorItem: FileItem? {
        data.cursorItem
    }

    func toggleSort(by field: PanelSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
        resortCurrentItemsKeepingSelectionAndCursor()
    }

    // MARK: - Directory Loading

    // MARK: - Branch view (Ctrl+B)

    /// Root of the flattened subtree; nil while the panel shows an ordinary folder.
    var branchViewRoot: String? {
        get { data.branchViewRoot }
        set { data.branchViewRoot = newValue }
    }
    var isBranchView: Bool { branchViewRoot != nil }

    /// Ctrl+B: the whole subtree as ONE flat list — TC's branch view. Toggling off returns
    /// to the plain folder. Local filesystem only: archives, remote listings, the network
    /// browser and the trash have nothing honest to flatten.
    func toggleBranchView() {
        guard !insideArchive, !insideRemote, !state.insideNetworkBrowser, !state.insideTrash
        else { return }
        if isBranchView {
            exitBranchView()
        } else {
            branchViewRoot = currentPath
            rebuildBranchView(resetCursor: true)
        }
    }

    /// Files gathered so far while the walk is reading; nil when no walk is running.
    /// Drives the panel's "reading the tree…" badge.
    private(set) var branchScanCount: Int?
    var isBranchScanning: Bool { branchScanCount != nil }
    /// Bumped on every (re)walk and on exit: a slow walk that comes home to a different
    /// generation throws its result away instead of overwriting a newer list.
    private var branchScanGeneration = 0
    private var branchScanCancelFlag: OSAllocatedUnfairLock<Bool>?

    /// Esc while the walk is reading: stop it and SHOW what it gathered — a partial branch
    /// view is an answer, an aborted one is a shrug.
    func cancelBranchScan() {
        branchScanCancelFlag?.withLock { $0 = true }
    }

    func exitBranchView() {
        guard isBranchView else { return }
        branchViewRoot = nil
        branchScanGeneration &+= 1          // a walk still out there must not come home
        cancelBranchScan()
        branchScanCount = nil
        loadDirectory(resetCursor: true)
    }

    /// (Re)walk the subtree off the main thread and swap the flat list in. Also the refresh
    /// road: the FS watcher's reloads land here while branch view is active.
    func rebuildBranchView(resetCursor: Bool) {
        guard let root = branchViewRoot else { return }
        branchScanGeneration &+= 1
        let generation = branchScanGeneration
        let showHidden = showHiddenFiles
        let keepCursorPath = resetCursor ? nil : cursorItem?.path

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        branchScanCancelFlag = cancelFlag
        branchScanCount = 0
        data.branchScanDidChange.send()

        Task { @MainActor [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                Self.buildBranchItems(
                    root: root, showHidden: showHidden,
                    progress: { count in
                        Task { @MainActor [weak self] in
                            guard let self, self.branchScanGeneration == generation else { return }
                            self.branchScanCount = count
                            self.data.branchScanDidChange.send()
                        }
                    },
                    shouldCancel: { cancelFlag.withLock { $0 } })
            }.value
            guard let self, self.branchScanGeneration == generation,
                  self.branchViewRoot == root else { return }
            self.branchScanCount = nil
            self.data.branchScanDidChange.send()
            var rows = built
            rows.insert(Self.branchParentRow(root: root), at: 0)
            self.allItems = self.sortItemsForDisplay(rows)
            if let keepCursorPath,
               let idx = self.items.firstIndex(where: { $0.path == keepCursorPath }) {
                self.cursorIndex = idx
            } else {
                self.cursorIndex = 0
            }
        }
    }

    /// ".." — the door back to the plain folder; branch view has no "up", only "out".
    nonisolated private static func branchParentRow(root: String) -> FileItem {
        FileItem(path: root, name: "..", fileExtension: "", size: 0, isDirectory: true,
                 isHidden: false, isSymlink: false, permissions: "", dateModified: Date())
    }

    /// Every FILE of the subtree, flat, each carrying its subpath for display. Directories
    /// are not rows — their contents are the point. Symlinked folders are not descended
    /// into (cycles); the walk stops at `limit` so a branch view of "/" cannot eat the
    /// machine — what it gathered by then is still shown.
    nonisolated static func buildBranchItems(root: String, showHidden: Bool,
                                             limit: Int = 100_000,
                                             progress: ((Int) -> Void)? = nil,
                                             shouldCancel: (() -> Bool)? = nil) -> [FileItem] {
        let rootURL = URL(fileURLWithPath: root)
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: options)
        else { return [] }

        var result: [FileItem] = []
        // The same folder wears two spellings on macOS — "/var/…" and "/private/var/…" —
        // and the enumerator is free to answer in either. URL.resolvingSymlinksInPath
        // deliberately leaves /var and /tmp ALONE, so realpath(3) does the honest work.
        func canonical(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let rootSpellings = Set([rootURL.path, canonical(rootURL.path)])
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func subpath(of full: String) -> String {
            for spelling in rootSpellings where full.hasPrefix(spelling) {
                return String(full.dropFirst(spelling.count))
            }
            return (full as NSString).lastPathComponent
        }
        for case let url as URL in enumerator {
            if result.count >= limit { break }
            if shouldCancel?() == true { break }   // Esc: what is gathered is the answer
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            guard var item = FileItem.fromPath(url.path) else { continue }
            item.branchPath = subpath(of: url.path)
            result.append(item)
            if result.count % 512 == 0 { progress?(result.count) }
        }
        return result
    }

    func loadDirectory(at path: String? = nil, resetCursor: Bool = true, preferredCursorPath: String? = nil) {
        if insideRemote {
            startRemoteLoad(at: path ?? currentPath)
            return
        }
        if insideArchive && path == nil {
            reloadArchiveDirectory(resetCursor: resetCursor)
            return
        }
        // Branch view: a refresh rebuilds the flat subtree; a real navigation leaves it.
        if isBranchView {
            if path == nil {
                rebuildBranchView(resetCursor: resetCursor)
                return
            }
            branchViewRoot = nil
        }

        let destination = path ?? currentPath

        // Network browser: intercept /NETWORK paths
        if NetworkBrowserService.isNetworkPath(destination) {
            Task { await loadNetworkDirectory(at: destination) }
            return
        }
        // Trash: intercept /TRASH the same way
        if TrashService.isTrashPath(destination) {
            loadTrashDirectory()
            return
        }
        // The shelf stands on a path no filesystem has, exactly like the Trash.
        if DropStackStore.isStackPath(destination) {
            loadStackDirectory()
            return
        }
        if state.insideTrash { state.insideTrash = false }
        if state.insideStack { state.insideStack = false }
        // Leaving network browser mode
        if state.insideNetworkBrowser {
            state.insideNetworkBrowser = false
        }
        // When reloading the SAME directory (after move/delete/rename),
        // invalidate cache so we read fresh data from filesystem.
        if destination == currentPath {
            removeDirectoryCache(for: destination)
        }
        loadFileSystemDirectory(at: destination, resetCursor: resetCursor, preferredCursorPath: preferredCursorPath)
    }

    /// Remove deleted items from the current display without a full directory reload.
    /// Avoids Phase 1 (names-only) flicker when sorted by date.
    /// FSWatcher will refresh the full state from disk shortly after.
    func removeDeletedItems(_ deletedPaths: Set<String>, preferredCursorPath: String?) {
        allItems = allItems.filter { !deletedPaths.contains($0.path) }
        if let preferredCursorPath,
           let idx = items.firstIndex(where: { $0.path == preferredCursorPath }) {
            cursorIndex = idx
        } else {
            cursorIndex = min(cursorIndex, max(0, items.count - 1))
        }
    }

    func reloadKeepingCursor(preferredName: String? = nil) {
        // Build preferredCursorPath for async directory loading
        var preferredCursorPath: String?
        if let preferredName {
            preferredCursorPath = (currentPath as NSString).appendingPathComponent(preferredName)
        }

        if insideRemote {
            startRemoteLoad(at: currentPath)
            return
        }
        if insideArchive {
            reloadArchiveDirectory(resetCursor: false)
            return
        }
        if isBranchView {
            rebuildBranchView(resetCursor: false)
            return
        }
        // The Trash and the network browser stand on paths no filesystem has. Falling through to
        // an ordinary listing of "/TRASH" fails and drops the panel onto some real volume — which
        // is what happened on every return to the app, since becoming active resumes the watchers
        // and every resume comes through here.
        if state.insideTrash {
            loadTrashDirectory()
            return
        }
        if state.insideStack {
            loadStackDirectory()
            return
        }
        if state.insideNetworkBrowser {
            Task { await loadNetworkDirectory(at: currentPath) }
            return
        }

        loadFileSystemDirectory(
            at: currentPath,
            resetCursor: false,
            preferredCursorPath: preferredCursorPath ?? cursorItem?.path
        )
    }

    func setShowHiddenFiles(_ showHidden: Bool) {
        guard showHiddenFiles != showHidden else { return }
        showHiddenFiles = showHidden

        if insideRemote {
            startRemoteLoad(at: currentPath)
            return
        }
        if insideArchive {
            clearArchiveVisibleItemsCaches()
            reloadArchiveDirectory()
        } else {
            // Through the one reload that knows every mode, not straight at the filesystem.
            reloadKeepingCursor()
        }
    }

    func goUp() {
        if insideRemote {
            goUpRemote()
            return
        }
        // Branch view has no "up" — ".." and Backspace lead OUT, back to the plain folder.
        if isBranchView {
            exitBranchView()
            return
        }
        // Route on the PATH as well as the flag. The two can desync — a concurrent local load
        // clears the flag while a slower network task reinstates a /NETWORK path — and when
        // they did, this fell through to the filesystem loader, which refuses virtual paths and
        // returned silently: the panel could no longer go up OR enter anything.
        if state.insideNetworkBrowser || NetworkBrowserService.isNetworkPath(currentPath) {
            goUpNetwork()
            return
        }
        if state.insideTrash || TrashService.isTrashPath(currentPath) {
            goUpTrash()
            return
        }
        if state.insideStack || DropStackStore.isStackPath(currentPath) {
            goUpStack()
            return
        }
        if insideArchive {
            goUpInsideArchive()
            return
        }

        // Out of a vault's volume, ".." leads back to the FOLDER its bundle lies in — with the
        // cursor on the bundle — not to /Volumes, where the person never was.
        if (currentPath as NSString).deletingLastPathComponent == "/Volumes",
           let vault = VaultService.vaultPath(forMountPoint: currentPath) {
            loadFileSystemDirectory(
                at: (vault as NSString).deletingLastPathComponent,
                resetCursor: true,
                preferredCursorPath: vault
            )
            return
        }

        // "C:" boundary — don't go above home directory
        if Self.isHomeDirectory(currentPath) { return }
        // The same boundary for iCloud Drive: the ".." row is already gone from the listing,
        // and Backspace must not be a back door into "Mobile Documents" either.
        if URL(fileURLWithPath: currentPath).standardizedFileURL.path
            == URL(fileURLWithPath: CloudStatusService.cloudDriveRoot)
                .standardizedFileURL.path { return }

        do {
            let previousPath = currentPath
            let parent = try service.parentPath(for: currentPath)
            if parent != currentPath {
                loadFileSystemDirectory(
                    at: parent,
                    resetCursor: true,
                    preferredCursorPath: previousPath
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shouldOpenAsContainer(_ item: FileItem) -> Bool {
        if item.name == ".." {
            return true
        }
        // A .app launches as an application — it is not a container to browse.
        if isAppBundle(item) {
            return false
        }
        if insideRemote {
            return item.isDirectory
        }
        if state.insideNetworkBrowser {
            return item.isDirectory
        }
        if insideArchive {
            return item.isDirectory
        }
        // In the Trash a folder is entered, never launched — including a trashed .app, which the
        // user is far more likely to want to look inside than to run.
        if state.insideTrash {
            return item.isDirectory
        }
        return item.isDirectory || isArchivePath(item.path)
    }

    func isArchiveFile(_ item: FileItem) -> Bool {
        !item.isDirectory && isArchivePath(item.path)
    }

    /// True for a local `.app` application bundle — a directory on disk that should
    /// be LAUNCHED, not entered. Not applicable inside remote/archive/network views.
    func isAppBundle(_ item: FileItem) -> Bool {
        guard !insideRemote, !state.insideNetworkBrowser, !insideArchive,
              !state.insideTrash else { return false }
        return item.isAppBundle
    }

    @discardableResult
    func open(_ item: FileItem, forceFolder: Bool = false,
              diskImageRoad: DiskImageOpenMode? = nil) -> Bool {
        if item.name == ".." {
            goUp()
            return true
        }

        if insideRemote {
            return openRemoteItem(item)
        }

        // Same path-or-flag routing as goUp() — see the comment there.
        if state.insideNetworkBrowser || NetworkBrowserService.isNetworkPath(currentPath) {
            if item.isDirectory {
                Task { await loadNetworkDirectory(at: item.path) }
                return true
            }
            return false
        }

        if insideArchive {
            if item.isDirectory {
                navigateInsideArchive(to: item.path)
            } else if isArchiveFile(item) {
                // An archive inside an archive: extract it to temp and browse it right here,
                // instead of handing it to the system, which unpacked it into Finder.
                enterNestedArchive(item)
            } else {
                openFileInsideArchive(item)
            }
            return true
        }

        // A .app bundle launches as an application (the controller handles the
        // actual launch) unless the user explicitly chose "enter as folder".
        if !forceFolder, isAppBundle(item) {
            return false
        }

        // A vault BEFORE the plain-directory branch, because a sparsebundle IS a directory:
        // the folder branch was reached first and walked into the raw band files — the person
        // stood inside the encrypted image's plumbing believing the vault was open. Enter
        // unlocks it — through the fingerprint when the password is in the keychain, through
        // the password window otherwise — and enters the mounted volume.
        if !forceFolder, VaultService.isVault(item.path) {
            unlockAndEnterVault(item)
            return true
        }

        if item.isDirectory {
            loadFileSystemDirectory(at: item.path, resetCursor: true)
            return true
        }

        // Symlink pointing to a directory — navigate into target
        if item.isSymlink, let target = item.symlinkTarget {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
                loadFileSystemDirectory(at: target, resetCursor: true)
                return true
            }
        }

        // A disk image goes whichever road the setting names — see DiskImageOpenMode. Answering
        // false hands the file to the caller's ordinary system-open path, and DiskImageMounter
        // does the rest: it mounts the image AND opens the volume in its own Finder window,
        // artwork and all. Mounting it here instead keeps the user inside the panel.
        if DiskImageOpenMode.isDiskImage(item.path) {
            guard (diskImageRoad ?? DiskImageOpenMode.chosen) == .panel else { return false }
            mountAndEnterDiskImage(item)
            return true
        }

        guard isArchivePath(item.path) else {
            return false
        }

        enterArchive(at: item.path)
        return true
    }

    /// Enter a vault: already open — just walk in; closed — get the password (Touch ID first,
    /// the window second) and open it. The work runs off the main thread behind the row
    /// spinner, like a disk image's mount.
    private func unlockAndEnterVault(_ item: FileItem) {
        guard launchingFilePath == nil else { return }
        let path = item.path
        if let mounted = VaultService.mountPoint(ofVault: path) {
            pushHistory(from: currentPath, to: mounted)
            loadDirectory(at: mounted)
            return
        }
        launchingFilePath = path
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.launchingFilePath = nil } }
            // The stored password first: reading it is what makes macOS ask for the finger.
            // Cancelling that prompt falls through to the typed password, not to a dead end.
            var password = await Task.detached(priority: .userInitiated) { () -> String? in
                guard VaultService.hasStoredPassword(for: path) else { return nil }
                return VaultService.storedPassword(
                    for: path,
                    reason: String(format: L("vault.touchID.reason"),
                                   (path as NSString).lastPathComponent))
            }.value

            var typedNow = false
            if password == nil {
                guard let typed = await MainActor.run(body: {
                    ArchivePasswords.ask(archiveName: (path as NSString).lastPathComponent)
                }) else { return }
                password = typed
                typedNow = true
            }
            guard let password else { return }

            do {
                let mounted = try await Task.detached(priority: .userInitiated) {
                    try VaultService.unlock(path, password: password)
                }.value
                VaultService.noteOpened(mountPoint: mounted, vault: path)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // A password that just proved itself is worth keeping — but only if the
                    // person had to type it, and NEVER against their word: a vault created
                    // with "open by Touch ID" switched off stays typed-only.
                    if typedNow, !VaultService.hasStoredPassword(for: path),
                       !VaultService.touchIDDeclined(for: path) {
                        _ = VaultService.rememberPassword(password, for: path)
                    }
                    pushHistory(from: currentPath, to: mounted)
                    loadDirectory(at: mounted)
                }
            } catch {
                await MainActor.run {
                    DialogService.shared.showOperationError(title: L("vault.unlock.title"),
                                                            error: error)
                }
            }
        }
    }

    /// Mount the image off the main thread (hdiutil verifies checksums — seconds on big images;
    /// the row spinner shows meanwhile), then navigate into the mounted volume. The volume shows
    /// up in the drive bar by itself, and its eject button unmounts as with any disk.
    private func mountAndEnterDiskImage(_ item: FileItem) {
        Self.logger.info("dmg.open pressed: \(item.path, privacy: .public) inFlight=\(self.launchingFilePath ?? "nil", privacy: .public)")
        guard launchingFilePath == nil else { return }   // a mount is already in flight
        launchingFilePath = item.path
        let dmgPath = item.path
        let ops = operationsService
        Task { [weak self] in
            do {
                let mountPoint: String = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { cont.resume(returning: try ops.attachDiskImage(at: dmgPath)) }
                        catch { cont.resume(throwing: error) }
                    }
                }
                guard let self else { return }
                Self.logger.info("dmg.mounted at: \(mountPoint, privacy: .public)")
                self.launchingFilePath = nil
                self.loadFileSystemDirectory(at: mountPoint, resetCursor: true)
            } catch {
                guard let self else { return }
                Self.logger.error("dmg.mount failed: \(error.localizedDescription, privacy: .public)")
                self.launchingFilePath = nil
                // A dialog, not the panel's quiet error strip: a failed mount after an Enter that
                // visibly did nothing else reads as "the app ignored me".
                DialogService.shared.showOperationError(title: L("dmg.mountFailed"), error: error)
            }
        }
    }

    func setCursor(index: Int) {
        guard !items.isEmpty else {
            cursorIndex = 0
            return
        }
        cursorIndex = max(0, min(index, items.count - 1))
    }

    private func onCursorChanged() {
        guard !insideArchive, !insideRemote else {
            cancelPriorityArchivePrewarm()
            return
        }
        guard let item = cursorItem,
              item.name != "..",
              isArchiveFile(item) else {
            cancelPriorityArchivePrewarm()
            return
        }
        priorityCacheArchive(item)
    }

    private func priorityCacheArchive(_ item: FileItem) {
        let path = item.path
        if priorityPrewarmArchivePath != path {
            archivePriorityPrewarmTask?.cancel()
            archiveHoverPrewarmTask?.cancel()
            priorityPrewarmArchivePath = path
        }

        guard !isArchiveCacheValid(for: path) else { return }

        switch prewarmStrategy(for: item) {
        case .immediate:
            startPriorityArchivePrewarm(item)
        case .onCursorHover:
            archiveHoverPrewarmTask?.cancel()
            archiveHoverPrewarmTask = Task(priority: .background) { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.hoverPrewarmDelayNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                guard !Task.isCancelled,
                      !self.insideArchive, !self.insideRemote,
                      self.cursorItem?.path == path else {
                    return
                }
                self.startPriorityArchivePrewarm(item)
            }
        case .onUserOpen:
            return
        }
    }

    private func startPriorityArchivePrewarm(_ item: FileItem) {
        let path = item.path
        guard !isArchiveCacheValid(for: path) else { return }
        archivePriorityPrewarmTask?.cancel()
        archivePriorityPrewarmTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.prewarmArchiveIfNeeded(item, qos: .userInitiated)
        }
    }

    private func cancelPriorityArchivePrewarm() {
        archivePriorityPrewarmTask?.cancel()
        archiveHoverPrewarmTask?.cancel()
        archivePriorityPrewarmTask = nil
        archiveHoverPrewarmTask = nil
        priorityPrewarmArchivePath = nil
    }

    func moveCursorUp(rowsPerColumn: Int = 1, columnsPerRow: Int = 1) {
        if viewMode == .thumbnails {
            setCursor(index: cursorIndex - max(1, columnsPerRow))
            return
        }
        _ = rowsPerColumn
        setCursor(index: cursorIndex - 1)
    }

    func moveCursorDown(rowsPerColumn: Int = 1, columnsPerRow: Int = 1) {
        if viewMode == .thumbnails {
            setCursor(index: cursorIndex + max(1, columnsPerRow))
            return
        }
        _ = rowsPerColumn
        setCursor(index: cursorIndex + 1)
    }

    func moveCursorLeft(rowsPerColumn: Int = 1, columnsPerRow: Int = 1) {
        guard !items.isEmpty else { return }

        if viewMode == .detailed {
            if cursorIndex > 0 {
                setCursor(index: 0)
            }
            return
        }
        if viewMode == .thumbnails {
            _ = columnsPerRow
            setCursor(index: cursorIndex - 1)
            return
        }

        let rows = max(1, rowsPerColumn)
        let target = cursorIndex - rows
        if target >= 0 {
            setCursor(index: target)
        } else {
            setCursor(index: 0)
        }
    }

    func moveCursorRight(rowsPerColumn: Int = 1, columnsPerRow: Int = 1) {
        guard !items.isEmpty else { return }

        if viewMode == .detailed {
            if cursorIndex < items.count - 1 {
                setCursor(index: items.count - 1)
            }
            return
        }
        if viewMode == .thumbnails {
            _ = columnsPerRow
            setCursor(index: cursorIndex + 1)
            return
        }

        let rows = max(1, rowsPerColumn)
        let target = cursorIndex + rows
        if target < items.count {
            setCursor(index: target)
        } else {
            setCursor(index: items.count - 1)
        }
    }

    func toggleSelectionAtCursor(rowsPerColumn: Int = 1, columnsPerRow: Int = 1) {
        guard let item = cursorItem else { return }
        if item.name == ".." {
            moveCursorDown(rowsPerColumn: rowsPerColumn, columnsPerRow: columnsPerRow)
            return
        }
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
        moveCursorDown(rowsPerColumn: rowsPerColumn, columnsPerRow: columnsPerRow)
    }

    func toggleSelection(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        guard item.name != ".." else { return }
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    /// Cmd+click toggle, including the file the cursor started on.
    func cmdClickToggle(at index: Int) {
        selectedPaths = Self.cmdClickSelection(
            current: selectedPaths, items: items, cursorIndex: cursorIndex, clickedIndex: index)
    }

    /// The new marked-set after a Cmd+click on `clickedIndex`.
    ///
    /// Toggles the clicked file, as Cmd+click always has. The addition: when the selection was
    /// EMPTY, the user is starting a fresh pick, and the file already under the cursor is the
    /// point they began from — so it joins the selection too. That matches Finder (the current
    /// item is part of the set you extend) and is what "Cmd-click 2 and 3 while sitting on 1"
    /// should give: {1, 2, 3}, not {2, 3}. Mid-selection the cursor is just wherever the last
    /// click landed, so seeding only happens on the first pick.
    nonisolated static func cmdClickSelection(current: Set<String>, items: [FileItem],
                                              cursorIndex: Int, clickedIndex: Int) -> Set<String> {
        guard items.indices.contains(clickedIndex) else { return current }
        let clicked = items[clickedIndex]
        guard clicked.name != ".." else { return current }

        var result = current
        if result.isEmpty, items.indices.contains(cursorIndex) {
            let cursor = items[cursorIndex]
            if cursor.name != ".." && cursor.path != clicked.path {
                result.insert(cursor.path)
            }
        }
        if result.contains(clicked.path) {
            result.remove(clicked.path)
        } else {
            result.insert(clicked.path)
        }
        return result
    }

    func selectRange(from start: Int, to end: Int) {
        guard !items.isEmpty else {
            selectedPaths.removeAll()
            anchorIndex = nil
            return
        }
        let safeStart = max(0, min(start, items.count - 1))
        let safeEnd = max(0, min(end, items.count - 1))
        let lower = min(safeStart, safeEnd)
        let upper = max(safeStart, safeEnd)
        selectedPaths = Set(
            items[lower...upper]
                .filter { $0.name != ".." }
                .map(\.path)
        )
    }

    func selectAll() {
        selectedPaths = Set(items.filter { $0.name != ".." }.map(\.path))
    }

    func activateItemForContextMenu(at index: Int) {
        guard items.indices.contains(index) else { return }

        let item = items[index]
        setCursor(index: index)

        if selectedPaths.contains(item.path) {
            anchorIndex = index
            return
        }

        selectedPaths.removeAll()
        if item.name != ".." {
            selectedPaths.insert(item.path)
        }
        anchorIndex = index
    }

    func clearSelection() {
        selectedPaths.removeAll()
        anchorIndex = nil
    }

    private func directoryStillExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Nearest existing ancestor of a gone path. A deleted sub-folder falls back
    /// to its disk root; a removed/ejected disk falls back to the home folder
    /// (landing in "/Volumes" or "/" would be useless).
    private func nearestExistingAncestor(of path: String) -> String {
        var p = (path as NSString).deletingLastPathComponent
        while !p.isEmpty && p != "/" && p != "/Volumes" {
            if directoryStillExists(p) { return p }
            p = (p as NSString).deletingLastPathComponent
        }
        return NSHomeDirectory()
    }

    func loadFileSystemDirectory(at destination: String,
                                     resetCursor: Bool,
                                     preferredCursorPath: String? = nil) {
        // Virtual network-browser paths (/NETWORK/…) are NOT real filesystem paths.
        // A stale reload of one — e.g. an on-activate refresh firing right after an SMB
        // mount's auth dialog closes — must not be handled here: it would fail the
        // "does the target still exist?" check, bail to the home folder, and clobber the
        // share we just mounted. Real network navigation goes via loadNetworkDirectory.
        if NetworkBrowserService.isNetworkPath(destination) {
            // Silent for a long time, and that made a wedged panel undiagnosable: if the flag
            // ever desyncs from the path, open()/goUp() land here and simply stop. open() and
            // goUp() now also route on the PATH so this should be unreachable — log it if not.
            return
        }

        // Корзина и полка стоят на путях, которых нет на диске. Их перехват есть в
        // loadDirectory, но сюда приходят и в обход него: путь панели, запомненный при
        // выходе из программы, история, откат к ближайшей живой папке. Без перехвата такой
        // путь не читается — и панель, закрытая в Корзине, открывалась в домашней папке.
        if TrashService.isTrashPath(destination) {
            loadTrashDirectory()
            return
        }
        if DropStackStore.isStackPath(destination) {
            loadStackDirectory()
            return
        }

        // Настоящая папка корзины — это и есть Корзина, а не обычная папка с точкой в имени.
        // Список корзины плоский: человек заходит в лежащую там папку и выходит обратно «..»,
        // попадая на ~/.Trash. Раньше здесь начиналась обычная папка — свои колонки, своё меню
        // с упаковкой и переименованием, — хотя из корзины никто не уходил. Проверка стоит в
        // ЕДИНСТВЕННОЙ воронке всех настоящих путей: сюда приходят и «..», и строка пути, и
        // вкладки при запуске, и история, и откат к ближайшей живой папке.
        if TrashService.isTrashFolder(destination) {
            loadTrashDirectory()
            return
        }

        directoryDetailsTask?.cancel()

        // Настоящая папка на диске — значит, панель больше не в полке, не в Корзине и не в
        // сетевом обзоре. Снимать признаки надо ИМЕННО здесь, в единственной воронке всех
        // настоящих путей: вход в папку с полки шёл сюда напрямую, минуя loadDirectory с его
        // снятием, — признак «я на полке» оставался, и первое же перечитывание (после
        // копирования, переименования или возврата с другого рабочего стола) выбрасывало
        // человека из папки обратно на полку.
        state.insideStack = false
        state.insideTrash = false
        state.insideNetworkBrowser = false

        // If the target no longer exists (folder deleted, disk ejected), bail out
        // to the nearest existing ancestor instead of showing stale/cached items.
        // Skip while an NTFS write has the volume temporarily unmounted — it isn't
        // really gone, and we must not yank the panel to the home folder.
        var destination = destination
        var resetCursor = resetCursor
        let ntfsBusy = FileOperationsService.ntfsWritingVolumes.contains {
            destination == $0 || destination.hasPrefix($0 + "/")
        }
        if !ntfsBusy && !destination.isEmpty && !directoryStillExists(destination) {
            let fallback = nearestExistingAncestor(of: destination)
            NSLog("[FCXL-NAV] bail: '%@' not readable → '%@'", destination, fallback)
            removeDirectoryCache(for: destination)
            destination = fallback
            resetCursor = true
            // Ближайшей живой папкой может оказаться сама корзина: человек стоял в лежащей
            // в ней папке, а её тем временем стёрли. Проверку надо повторить — она была ДО
            // отката, и панель осталась бы на сыром ~/.Trash обычной папкой.
            if TrashService.isTrashFolder(destination) {
                loadTrashDirectory()
                return
            }
        }

        // Save current items to cache before navigating away (preserves folder sizes)
        if !allItems.isEmpty && !currentPath.isEmpty && destination != currentPath && !insideArchive && !insideRemote {
            // The WHOLE folder: caching only what a quick filter left visible would bring the
            // folder back truncated the next time it is opened.
            let itemsToCache = allItems.filter { $0.name != ".." }
            if !itemsToCache.isEmpty {
                storeDirectoryCache(path: currentPath, items: itemsToCache)
            }
        }

        // Настоящая папка на диске — значит, и из архива панель выходит. Снять признак
        // надо ЗДЕСЬ, до применения результата: защита «местное чтение не затирает панель
        // в облаке или архиве» иначе отбрасывала и этот, намеренный выход, и «..» в корне
        // архива не выводил никуда. (Кэш выше уже сохранён — признак нужен ему честным.)
        if insideArchive {
            clearArchiveState()
        }

        let requestID = UUID()
        directoryLoadRequestID = requestID

        if let cachedItems = resolveCachedDirectoryItems(for: destination) {
            let isNavigation = destination != currentPath
            applyLoadedFileSystemItems(
                cachedItems,
                destination: destination,
                resetCursor: resetCursor,
                preferredCursorPath: preferredCursorPath,
                clearSelection: isNavigation
            )
            startDirectoryRefreshPhase(
                destination: destination,
                requestID: requestID,
                preferredCursorPath: cursorItem?.path
            )
            return
        }

        let showHidden = showHiddenFiles
        // When reloading the SAME directory and items are already loaded,
        // skip Phase 1 (names-only) to avoid cursor flicker from sort order
        // mismatch (names-only items have no dates → wrong sort by date).
        // Go directly to Phase 2 (full metadata).
        // The same-dir fast path skips Phase 1 (which honors preferredCursorPath) to avoid
        // flicker. But if the requested cursor target isn't in the CURRENT list yet — e.g.
        // a folder we JUST created — the fast path can't place the cursor on it. In that
        // case fall back to the full path so Phase 1 lands the cursor once the new listing
        // (which contains the item) is loaded.
        let preferredIsNewItem = preferredCursorPath != nil
            && !items.contains(where: { $0.path == preferredCursorPath })
        let isSameDirectoryReload = destination == currentPath && !items.isEmpty && !preferredIsNewItem
        // Phase 1 is what honors preferredCursorPath, and Phase 2 deliberately
        // preserves the CURRENT cursor — so on a same-dir reload an explicitly
        // requested cursor target (e.g. search's "go to file" when the panel is
        // already in that folder) would be silently dropped. The item is already
        // listed, so place the cursor right away; Phase 2 then keeps it.
        if isSameDirectoryReload, let preferredCursorPath,
           let preferredIndex = items.firstIndex(where: { $0.path == preferredCursorPath }) {
            setCursor(index: preferredIndex)
        }
        directoryDetailsTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                if !isSameDirectoryReload {
                    // Phase 1: show names instantly via readdir (zero stat calls).
                    // On APFS/SSD this takes <1ms, on NTFS/USB ~10ms — always instant.
                    // getattrlistbulk is NOT used here because on NTFS it's 3.5x SLOWER
                    // than readdir (28s vs 8s per Tempelmann's benchmarks).
                    let namesOnly = try await self.loadDirectoryNamesOnlyAsync(
                        destination: destination,
                        showHidden: showHidden
                    )

                    guard self.directoryLoadRequestID == requestID else { return }

                    await MainActor.run {
                        let isNavigation = destination != self.currentPath
                        self.applyLoadedFileSystemItems(
                            namesOnly,
                            destination: destination,
                            resetCursor: resetCursor,
                            preferredCursorPath: preferredCursorPath,
                            clearSelection: isNavigation
                        )
                    }
                }

                // Phase 2: Load full metadata in background.
                let (isSlow, isDetailed) = await MainActor.run {
                    (self.currentPathIsSlowVolume, self.viewMode == .detailed)
                }
                if isSlow {
                    // Slow volume: progressive metadata for visible items in detailed mode,
                    // full metadata for other modes (needed for sizes/dates)
                    if isDetailed {
                        await MainActor.run {
                            self.startSlowVolumeVisibleMetadataPhase(
                                destination: destination,
                                requestID: requestID
                            )
                        }
                    } else {
                        self.startDirectoryFullMetadataPhase(
                            destination: destination,
                            requestID: requestID,
                            showHidden: showHidden
                        )
                    }
                } else {
                    // Fast volume: full metadata always
                    self.startDirectoryFullMetadataPhase(
                        destination: destination,
                        requestID: requestID,
                        showHidden: showHidden
                    )
                }
            } catch {
                guard self.directoryLoadRequestID == requestID else { return }
                await MainActor.run {
                    self.errorMessage = "\(L("panel.error.loadPath", destination)): \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyLoadedFileSystemItems(_ loaded: [FileItem],
                                            destination: String,
                                            resetCursor: Bool,
                                            preferredCursorPath: String?,
                                            clearSelection: Bool) {
        // Панель могла уйти в облако или архив, пока это чтение шло. Применить сюда
        // МЕСТНЫЙ результат — значит затереть путь панели обратно на «/Users/…»: следом
        // облако читалось по этому местному пути, Диск отвечал «нет такой папки», и
        // человек смотрел на пустую панель Google Drive без единого файла.
        guard !insideRemote, !insideArchive else { return }

        // A virtual location has no volume behind it, so it is neither fast nor slow. Asked about
        // "/TRASH" the detector finds nothing and answers "slow", which set the whole slow-volume
        // machinery on a place it cannot read.
        currentPathIsSlowVolume = Self.isVirtualLocation(destination)
            ? false
            : Self.isSlowVolume(destination)
        let previousItems = items
        let previousCursorPath = cursorItem?.path
        let previousSelection = selectedPaths
        let previousAnchorPath: String?
        if let anchorIndex, previousItems.indices.contains(anchorIndex) {
            previousAnchorPath = previousItems[anchorIndex].path
        } else {
            previousAnchorPath = nil
        }

        // When reloading the SAME directory, preserve metadata from previous
        // items so that Phase 1 (names-only) sorts correctly by date/size.
        // Without this, names-only items have zero dates → wrong sort order
        // → cursor flicker when sorted by dateCreated/dateModified.
        var itemsToSort = loaded
        // From allItems, not the filtered view: with a quick filter active, a map built from the
        // visible rows forgets the calculated folder sizes (and slow-volume dates) of every hidden
        // row — the selection rebuild below already learned this exact lesson.
        let previousAll = allItems
        if !previousAll.isEmpty && destination == currentPath {
            let previousByPath = Dictionary(
                uniqueKeysWithValues: previousAll
                    .filter { $0.name != ".." }
                    .map { ($0.path, $0) }
            )
            if !previousByPath.isEmpty {
                itemsToSort = itemsToSort.map { item in
                    guard item.name != "..",
                          let prev = previousByPath[item.path] else { return item }
                    return FileItem(
                        path: item.path,
                        name: item.name,
                        fileExtension: item.fileExtension,
                        size: max(item.size, prev.size),
                        isDirectory: item.isDirectory,
                        isHidden: item.isHidden,
                        isSymlink: item.isSymlink,
                        // Same disease the hardlink count had: || could only ever turn the
                        // badge ON. A names-only pass (dates unmeasured) keeps the previous
                        // answer; a full pass measured it and is believed, false included.
                        isAlias: item.dateModified > Date.distantPast
                            ? item.isAlias : (item.isAlias || prev.isAlias),
                        symlinkTarget: item.symlinkTarget ?? prev.symlinkTarget,
                        // The fresh count WINS. It used to be max(fresh, previous), which
                        // could only ever grow: delete one of two names and the file kept
                        // wearing the hard-link badge for ever. Zero means this pass never
                        // measured, and only then does the previous value stand in.
                        hardlinkCount: item.hardlinkCount > 0 ? item.hardlinkCount
                                                             : prev.hardlinkCount,
                        permissions: item.permissions.isEmpty ? prev.permissions : item.permissions,
                        dateModified: item.dateModified > Date.distantPast ? item.dateModified : prev.dateModified,
                        dateCreated: item.dateCreated ?? prev.dateCreated,
                        dateAdded: item.dateAdded ?? prev.dateAdded,
                        owner: item.owner.isEmpty ? prev.owner : item.owner,
                        // The fresh listing is the authority; the previous value only fills a gap
                        // left by a listing that never asked (names-only, remote).
                        entryCount: item.entryCount >= 0 ? item.entryCount : prev.entryCount
                    )
                }
            }
        }

        // Remembered sizes appear the moment the listing does; the adaptive walker then quietly
        // re-verifies each one and corrects any that drifted. Local folders only — the cache
        // holds absolute local paths, and remote/archive listings have their own size semantics.
        if !insideArchive, !insideRemote, !state.insideTrash,
           UserDefaults.standard.bool(forKey: "fcxl.calculateFolderSizes") {
            let cache = FolderSizeCache.shared
            itemsToSort = itemsToSort.map { item in
                guard item.isDirectory, item.name != "..", item.size == 0,
                      let remembered = cache.size(for: item.path) else { return item }
                return item.withSize(remembered)
            }
        }

        var sorted = sortItemsForDisplay(itemsToSort)

        // A vault's volume is a root by the filesystem's lights, but the person ENTERED it
        // from a folder — so it keeps its "..", and goUp knows where that door leads. Asked
        // only of direct children of /Volumes: the answer may cost an hdiutil call, and an
        // ordinary folder load must never pay it.
        let isVaultVolume = (destination as NSString).deletingLastPathComponent == "/Volumes"
            && VaultService.vaultPath(forMountPoint: destination) != nil
        if destination != "/" && (isVaultVolume || !Self.isVolumeRoot(destination))
            && !Self.isHomeDirectory(destination)
            && destination != NetworkBrowserService.networkRoot {
            // The network root (computer list) is a top-level virtual location — nothing
            // above it — so it gets no "..". Share lists (/NETWORK/Computer) still do.
            let parentPath: String
            do {
                parentPath = try service.parentPath(for: destination)
            } catch {
                let fallback = (destination as NSString).deletingLastPathComponent
                parentPath = fallback.isEmpty ? "/" : fallback
            }

            let upItem = FileItem(
                path: parentPath,
                name: "..",
                fileExtension: "",
                size: 0,
                isDirectory: true,
                isHidden: false,
                isSymlink: false,
                permissions: "",
                dateModified: Date()
            )
            sorted.insert(upItem, at: 0)
        }

        clearArchiveState()

        let oldPath = currentPath
        allItems = sorted
        sortToken &+= 1  // Force NSTableView reload (items content changed even if count didn't)
        currentPath = destination
        pushHistory(from: oldPath, to: destination)
        if let preferredCursorPath,
           let preferredIndex = items.firstIndex(where: { $0.path == preferredCursorPath }) {
            cursorIndex = preferredIndex
        } else if resetCursor {
            cursorIndex = 0
            scrollResetToken &+= 1
        } else if let previousCursorPath,
                  let previousIndex = items.firstIndex(where: { $0.path == previousCursorPath }) {
            cursorIndex = previousIndex
        } else {
            cursorIndex = min(max(0, cursorIndex), max(0, items.count - 1))
        }

        if clearSelection {
            selectedPaths.removeAll()
            anchorIndex = nil
        } else {
            // Against the whole folder: intersecting with the narrowed view would make a reload
            // — the file watcher fires one 300 ms after any change on disk — quietly unmark every
            // file the quick filter is hiding.
            let availablePaths = Set(allItems.map(\.path))
            selectedPaths = previousSelection.intersection(availablePaths)
            if let previousAnchorPath,
               let nextAnchor = items.firstIndex(where: { $0.path == previousAnchorPath }) {
                anchorIndex = nextAnchor
            } else {
                anchorIndex = nil
            }
        }

        errorMessage = nil
        saveCurrentPath()
        scheduleArchivePrewarm(for: sorted)
        if !currentPathIsSlowVolume,
           UserDefaults.standard.bool(forKey: "fcxl.calculateFolderSizes") {
            scheduleFolderSizeRefresh(for: destination)
        }
        restartFSWatcherIfNeeded(for: destination)
    }

    // MARK: - FSEvents Watcher

    private func restartFSWatcherIfNeeded(for directory: String) {
        // Don't watch archives or slow volumes
        guard !insideArchive, !currentPathIsSlowVolume else {
            stopFSWatcher()
            return
        }
        guard directory != watchedPath else { return }
        stopFSWatcher()

        let watcher = FCXLWatcherBridge()
        do {
            try watcher.watchDirectory(directory) { [weak self] _, _ in
                // Callback fires on background thread — debounce + dispatch to main
                Task { @MainActor [weak self] in
                    self?.handleFSEvent()
                }
            }
            fsWatcher = watcher
            watchedPath = directory
        } catch {
            Self.logger.warning("FSEvents watcher failed for \(directory): \(error.localizedDescription)")
        }
    }

    private func stopFSWatcher() {
        fsWatcherDebounceTask?.cancel()
        fsWatcherDebounceTask = nil
        fsWatcher?.stop()
        fsWatcher = nil
        watchedPath = nil
    }

    private func handleFSEvent() {
        // Debounce: wait 300ms after last event before reloading.
        // FSWatcher is paused when app goes to background (pauseFSWatcher),
        // so this only fires while the user is actively using the app.
        fsWatcherDebounceTask?.cancel()
        fsWatcherDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reloadKeepingCursor()
        }
    }

    func stopWatching() {
        stopFSWatcher()
    }

    /// Stop watcher if it monitors a path on the given volume.
    func stopWatcherIfOnVolume(_ volumePath: String) {
        guard let wp = watchedPath else { return }
        let normVolume = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        let normWatched = wp.hasSuffix("/") ? wp : wp + "/"
        if normWatched.hasPrefix(normVolume) {
            stopFSWatcher()
        }
    }

    /// Full cleanup before volume eject: stop watcher, cancel async tasks, navigate away.
    /// Returns true if panel was on this volume and needed navigation.
    @discardableResult
    func prepareForVolumeEject(_ volumePath: String) -> Bool {
        let normVolume = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        let normCurrent = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
        let isOnVolume = normCurrent.hasPrefix(normVolume) || normCurrent == volumePath

        stopWatcherIfOnVolume(volumePath)
        if isOnVolume {
            directoryDetailsTask?.cancel()
            directoryDetailsTask = nil
            loadDirectory(at: NSHomeDirectory())
        }
        return isOnVolume
    }

    /// Pause FSEvents watching (call when app goes to background).
    func pauseFSWatcher() {
        stopFSWatcher()
    }

    /// Resume FSEvents watching and reload directory (call when app returns to foreground).
    func resumeFSWatcher() {
        guard !insideArchive, !insideRemote else { return }
        // A virtual location has nothing for FSEvents to watch, but re-reading it on the way back
        // is still right — things may have been thrown away or unshared while we were gone.
        if !state.insideTrash && !state.insideNetworkBrowser {
            restartFSWatcherIfNeeded(for: currentPath)
        }
        reloadKeepingCursor()
    }

    /// Calculate sizes for all folders in current directory (manual trigger via Cmd+Shift+Enter).
    func calculateAllFolderSizes() {
        guard !insideArchive, !insideRemote else { return }
        // The user asked by hand — the answer is wanted NOW, whatever the background slider says.
        scheduleFolderSizeRefresh(for: currentPath, fullSpeed: true)
    }

    private func scheduleFolderSizeRefresh(for destination: String, fullSpeed: Bool = false) {
        folderSizeTask?.cancel()
        // Never calculate folder sizes for remote or archive directories
        guard !insideArchive, !insideRemote else { return }
        let requestID = UUID()
        folderSizeRequestID = requestID

        let directories = allItems.filter { $0.isDirectory && $0.name != ".." }
        guard !directories.isEmpty else { return }

        // The adaptive part. The slider buys workers and their priority; by default this is a
        // couple of low-priority threads that fill sizes in while the user works, instead of
        // every core at once the moment a folder opens. Manual ⌘⇧↵ ignores the slider entirely.
        let loadPercent = fullSpeed ? 100
            : max(10, min(100, UserDefaults.standard.object(forKey: "fcxl.folderSizeLoadPercent")
                as? Int ?? 25))
        let workers = FolderSizeCache.workerCount(loadPercent: loadPercent)
        let priority = FolderSizeCache.workerPriority(loadPercent: loadPercent)

        // From the cursor outward: the cursor is on screen in every view mode, so what the user
        // is looking at fills in first — the economy stays honest, the feel stays fast.
        let order = FolderSizeCache.walkOrder(count: directories.count, cursorIndex: {
            guard let cursorPath = cursorItem?.path else { return 0 }
            return directories.firstIndex(where: { $0.path == cursorPath }) ?? 0
        }())
        let queue = order.map { directories[$0].path }

        folderSizeTask = Task(priority: priority) { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: (String, UInt64).self) { group in
                var pending = queue.makeIterator()
                // A bounded pool, not a task per folder: the whole point is that the machine
                // never sees more than `workers` walks at once.
                func addNext() -> Bool {
                    guard let path = pending.next() else { return false }
                    group.addTask(priority: priority) {
                        let service = FileOperationsService(bridgeService: CoreBridgeService())
                        let size = service.directoryTotalSize(at: path)
                        return (path, size)
                    }
                    return true
                }
                for _ in 0..<workers where addNext() {}

                for await (path, size) in group {
                    if Task.isCancelled { return }
                    guard self.folderSizeRequestID == requestID else { return }
                    guard self.currentPath == destination else { return }
                    // Verified against the real disk — THIS is what the cache remembers.
                    FolderSizeCache.shared.store(size: size, for: path)
                    if let idx = self.allItems.firstIndex(where: { $0.path == path }),
                       self.allItems[idx].size != size {
                        // Patch the folder, not the view: a size arriving for a file the filter is
                        // hiding must still be remembered for when the filter is lifted.
                        self.allItems[idx] = self.allItems[idx].withSize(size)
                    }
                    _ = addNext()
                }
            }

            // Final re-sort and cache after all folders are done
            if !Task.isCancelled, self.folderSizeRequestID == requestID, self.currentPath == destination {
                self.resortCurrentItemsKeepingSelectionAndCursor()
                self.storeDirectoryCache(path: destination, items: self.allItems.filter { $0.name != ".." })
            }
        }
    }

    private func resortCurrentItemsKeepingSelectionAndCursor() {
        guard !items.isEmpty else { return }

        let previousCursorPath = cursorItem?.path
        let previousAnchorPath: String?
        if let anchorIndex, items.indices.contains(anchorIndex) {
            previousAnchorPath = items[anchorIndex].path
        } else {
            previousAnchorPath = nil
        }

        allItems = sortItemsForDisplay(allItems)
        sortToken &+= 1

        if let previousCursorPath,
           let nextCursorIndex = items.firstIndex(where: { $0.path == previousCursorPath }) {
            cursorIndex = nextCursorIndex
        } else {
            cursorIndex = min(max(0, cursorIndex), max(0, items.count - 1))
        }

        if let previousAnchorPath,
           let nextAnchorIndex = items.firstIndex(where: { $0.path == previousAnchorPath }) {
            anchorIndex = nextAnchorIndex
        } else {
            anchorIndex = nil
        }
    }

    func sortItemsForDisplay(_ sourceItems: [FileItem]) -> [FileItem] {
        let upItems = sourceItems.filter { $0.name == ".." }
        let regularItems = sourceItems.filter { $0.name != ".." }

        let sortedRegularItems = regularItems.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let comparison = comparisonResult(lhs: lhs, rhs: rhs)
            if comparison == .orderedSame {
                let pathComparison = finderLikeCompare(lhs.path, rhs.path)
                if sortAscending {
                    return pathComparison == .orderedAscending
                }
                return pathComparison == .orderedDescending
            }

            if sortAscending {
                return comparison == .orderedAscending
            }
            return comparison == .orderedDescending
        }

        return upItems + sortedRegularItems
    }

    private func comparisonResult(lhs: FileItem, rhs: FileItem) -> ComparisonResult {
        switch sortField {
        case .name:
            return finderLikeCompare(lhs.name, rhs.name)
        case .type:
            let typeComparison = finderLikeCompare(lhs.typeSortKey, rhs.typeSortKey)
            if typeComparison != .orderedSame {
                return typeComparison
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .fileExtension:
            let extensionComparison = finderLikeCompare(lhs.fileExtension, rhs.fileExtension)
            if extensionComparison != .orderedSame {
                return extensionComparison
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .size:
            if lhs.size != rhs.size {
                return lhs.size < rhs.size ? .orderedAscending : .orderedDescending
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .dateCreated:
            let lhsDate = lhs.dateCreated ?? Date.distantPast
            let rhsDate = rhs.dateCreated ?? Date.distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate ? .orderedAscending : .orderedDescending
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .dateModified:
            if lhs.dateModified != rhs.dateModified {
                return lhs.dateModified < rhs.dateModified ? .orderedAscending : .orderedDescending
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .dateAdded:
            let lhsDate = lhs.dateAdded ?? Date.distantPast
            let rhsDate = rhs.dateAdded ?? Date.distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate ? .orderedAscending : .orderedDescending
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .permissions:
            let permissionsComparison = finderLikeCompare(lhs.permissions, rhs.permissions)
            if permissionsComparison != .orderedSame {
                return permissionsComparison
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .owner:
            let ownerComparison = finderLikeCompare(lhs.owner, rhs.owner)
            if ownerComparison != .orderedSame {
                return ownerComparison
            }
            return finderLikeCompare(lhs.name, rhs.name)
        case .origin:
            let originComparison = finderLikeCompare(trashOrigins[lhs.path] ?? "",
                                                    trashOrigins[rhs.path] ?? "")
            if originComparison != .orderedSame {
                return originComparison
            }
            return finderLikeCompare(lhs.name, rhs.name)
        }
    }

    private func finderLikeCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }

    private func resolveCachedDirectoryItems(for path: String) -> [FileItem]? {
        guard let cache = directoryCaches[path] else { return nil }
        guard isDirectoryCacheValid(path: path, cache: cache) else {
            removeDirectoryCache(for: path)
            return nil
        }
        touchDirectoryCache(path)
        return cache.items
    }

    private func isDirectoryCacheValid(path: String, cache: DirectoryCache) -> Bool {
        let currentMtime = directoryModificationDate(for: path)
        switch (cache.mtime, currentMtime) {
        case let (cached?, current?):
            return abs(cached.timeIntervalSince1970 - current.timeIntervalSince1970) < 0.001
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func directoryModificationDate(for path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private func storeDirectoryCache(path: String, items: [FileItem]) {
        directoryCaches[path] = DirectoryCache(
            items: items,
            cachedAt: Date(),
            mtime: directoryModificationDate(for: path)
        )
        touchDirectoryCache(path)
        trimDirectoryCacheIfNeeded()
    }

    private func touchDirectoryCache(_ path: String) {
        directoryCacheLRU.removeAll { $0 == path }
        directoryCacheLRU.append(path)
        if var cache = directoryCaches[path] {
            cache = DirectoryCache(items: cache.items, cachedAt: Date(), mtime: cache.mtime)
            directoryCaches[path] = cache
        }
    }

    private func removeDirectoryCache(for path: String) {
        directoryCaches.removeValue(forKey: path)
        directoryCacheLRU.removeAll { $0 == path }
    }

    private func trimDirectoryCacheIfNeeded() {
        while directoryCacheLRU.count > Self.directoryCacheLimit {
            let evictedPath = directoryCacheLRU.removeFirst()
            directoryCaches.removeValue(forKey: evictedPath)
        }
    }

    private func startDirectoryRefreshPhase(destination: String,
                                            requestID: UUID,
                                            preferredCursorPath: String?) {
        let includeHidden = showHiddenFiles
        directoryDetailsTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            let refreshedItems: [FileItem]
            do {
                refreshedItems = try await self.loadDirectoryFastAsync(
                    destination: destination,
                    showHidden: includeHidden
                )
            } catch {
                Self.logger.error("Directory refresh failed for \(destination): \(error.localizedDescription)")
                return
            }

            await MainActor.run {
                self.applyDirectoryRefreshIfCurrent(
                    refreshedItems,
                    destination: destination,
                    requestID: requestID,
                    preferredCursorPath: preferredCursorPath
                )
            }
        }
    }

    private func loadDirectoryFastAsync(destination: String,
                                        showHidden: Bool) async throws -> [FileItem] {
        let bridgeService = service
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let loaded = try bridgeService.listDirectoryFast(
                        path: destination,
                        showHidden: showHidden
                    )
                    continuation.resume(returning: loaded)
                } catch {
                        continuation.resume(throwing: error)
                }
            }
        }
    }

    private func applyDirectoryRefreshIfCurrent(_ refreshedItems: [FileItem],
                                                destination: String,
                                                requestID: UUID,
                                                preferredCursorPath: String?) {
        guard directoryLoadRequestID == requestID else { return }
        guard !insideArchive, !insideRemote, currentPath == destination else { return }

        applyLoadedFileSystemItems(
            refreshedItems,
            destination: destination,
            resetCursor: false,
            preferredCursorPath: preferredCursorPath,
            clearSelection: false
        )
        storeDirectoryCache(path: destination, items: refreshedItems)
    }

    private func startDirectoryDetailsPhase(destination: String, requestID: UUID) {
        let includeHidden = showHiddenFiles
        directoryDetailsTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            let detailedItems: [FileItem]
            do {
                detailedItems = try await self.loadDirectoryDetailsAsync(
                    destination: destination,
                    showHidden: includeHidden
                )
            } catch {
                Self.logger.error("Directory details failed for \(destination): \(error.localizedDescription)")
                return
            }

            await MainActor.run {
                self.applyDirectoryDetailsIfCurrent(
                    detailedItems,
                    destination: destination,
                    requestID: requestID
                )
            }
        }
    }

    /// Background metadata loading: tries getattrlistbulk (fast on APFS),
    /// falls back to optimized lstat (1 call per file) on NTFS/FAT32/exFAT.
    private func startDirectoryFullMetadataPhase(destination: String,
                                                  requestID: UUID,
                                                  showHidden: Bool) {
        directoryDetailsTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            let detailedItems: [FileItem]
            do {
                detailedItems = try await self.loadDirectoryFastAsync(
                    destination: destination,
                    showHidden: showHidden
                )
            } catch {
                // getattrlistbulk failed — fall back to optimized lstat
                do {
                    detailedItems = try await self.loadDirectoryDetailsAsync(
                        destination: destination,
                        showHidden: showHidden
                    )
                } catch {
                        Self.logger.error("Full metadata failed for \(destination): \(error.localizedDescription)")
                    return
                }
            }

            guard self.directoryLoadRequestID == requestID else { return }

            await MainActor.run {
                guard !self.insideArchive, !self.insideRemote, self.currentPath == destination else { return }
                self.applyLoadedFileSystemItems(
                    detailedItems,
                    destination: destination,
                    resetCursor: false,
                    preferredCursorPath: self.cursorItem?.path,
                    clearSelection: false
                )
                self.storeDirectoryCache(path: destination, items: detailedItems)
            }
        }
    }

    /// Progressive metadata loading for slow volumes in detailed mode.
    /// Loads metadata in small batches starting from cursor position,
    /// so the user sees dates/sizes around the cursor first.
    private func startSlowVolumeVisibleMetadataPhase(destination: String,
                                                      requestID: UUID) {
        directoryDetailsTask?.cancel()
        directoryDetailsTask = Task { [weak self] in
            guard let self else { return }

            let centerIndex = await MainActor.run { self.cursorIndex }
            let itemPaths = await MainActor.run { self.items.map(\.path) }
            let totalCount = itemPaths.count
            guard totalCount > 0 else { return }

            // Build index order: center outward (cursor ± 1, ± 2, ...)
            var orderedIndices: [Int] = []
            orderedIndices.reserveCapacity(totalCount)
            let clampedCenter = min(max(centerIndex, 0), totalCount - 1)
            orderedIndices.append(clampedCenter)
            for offset in 1..<totalCount {
                let before = clampedCenter - offset
                let after = clampedCenter + offset
                if before >= 0 { orderedIndices.append(before) }
                if after < totalCount { orderedIndices.append(after) }
                if orderedIndices.count >= totalCount { break }
            }

            let batchSize = 30
            var batchStart = 0

            while batchStart < orderedIndices.count {
                if Task.isCancelled { return }
                guard self.directoryLoadRequestID == requestID else { return }

                let batchEnd = min(batchStart + batchSize, orderedIndices.count)
                let batchIndices = Array(orderedIndices[batchStart..<batchEnd])
                let pathsToStat = batchIndices.map { itemPaths[$0] }

                // Stat files on background thread
                let metadataResults = await Task.detached(priority: .utility) {
                    () -> [String: (size: UInt64, dateModified: Date, dateCreated: Date?, permissions: String, owner: String, symlinkTarget: String?, nlink: UInt)] in
                    let fm = FileManager.default
                    var results: [String: (size: UInt64, dateModified: Date, dateCreated: Date?, permissions: String, owner: String, symlinkTarget: String?, nlink: UInt)] = [:]
                    for path in pathsToStat {
                        if Task.isCancelled { return results }
                        guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                        let size = (attrs[.size] as? UInt64) ?? 0
                        let dateMod = (attrs[.modificationDate] as? Date) ?? .distantPast
                        let dateCreated = attrs[.creationDate] as? Date
                        let mask = (attrs[.posixPermissions] as? Int) ?? 0
                        let perms = String(format: "%03o", mask & 0o777)
                        let owner = (attrs[.ownerAccountName] as? String) ?? ""
                        let nlink = (attrs[.referenceCount] as? UInt) ?? 1
                        var linkTarget: String?
                        if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                            if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
                                if dest.hasPrefix("/") {
                                    linkTarget = dest
                                } else {
                                    linkTarget = URL(fileURLWithPath: dest,
                                                     relativeTo: URL(fileURLWithPath: path).deletingLastPathComponent())
                                        .standardized.path
                                }
                            }
                        }
                        results[path] = (size, dateMod, dateCreated, perms, owner, linkTarget, nlink)
                    }
                    return results
                }.value

                if Task.isCancelled { return }
                guard self.directoryLoadRequestID == requestID else { return }

                // Apply batch to UI
                await MainActor.run {
                    guard self.currentPath == destination else { return }
                    var changed = false
                    self.allItems = self.allItems.map { item in
                        guard let meta = metadataResults[item.path] else { return item }
                        changed = true
                        return FileItem(
                            path: item.path,
                            name: item.name,
                            fileExtension: item.fileExtension,
                            size: item.isDirectory ? item.size : meta.size,
                            isDirectory: item.isDirectory,
                            isHidden: item.isHidden,
                            isSymlink: item.isSymlink,
                            // Carried over like dateAdded below: this pass does not re-read it,
                            // and dropping it would un-mark every alias the listing found.
                            isAlias: item.isAlias,
                            symlinkTarget: meta.symlinkTarget ?? item.symlinkTarget,
                            hardlinkCount: meta.nlink,
                            permissions: meta.permissions,
                            dateModified: meta.dateModified,
                            dateCreated: meta.dateCreated,
                            // Not re-read above, so it has to be carried over: dropping it reset
                            // the field to nil and blanked the "added" column — the deletion date
                            // in the Trash — on every row this pass touched.
                            dateAdded: item.dateAdded,
                            owner: meta.owner,
                            entryCount: item.entryCount
                        )
                    }
                    if changed {
                        self.sortToken &+= 1
                    }
                }

                batchStart = batchEnd
                await Task.yield()
            }

            // Cache final result
            await MainActor.run {
                guard self.currentPath == destination else { return }
                self.storeDirectoryCache(path: destination, items: self.allItems.filter { $0.name != ".." })
            }
        }
    }

    private func loadDirectoryDetailsAsync(destination: String,
                                           showHidden: Bool) async throws -> [FileItem] {
        let bridgeService = service
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let loaded = try bridgeService.listDirectory(
                        path: destination,
                        showHidden: showHidden
                    )
                    continuation.resume(returning: loaded)
                } catch {
                        continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Ultra-fast listing via readdir() only — no stat() calls.
    /// Returns names and types instantly; metadata loaded in background.
    private func loadDirectoryNamesOnlyAsync(destination: String,
                                             showHidden: Bool) async throws -> [FileItem] {
        let bridgeService = service
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let loaded = try bridgeService.listDirectoryNamesOnly(
                        path: destination,
                        showHidden: showHidden
                    )
                    continuation.resume(returning: loaded)
                } catch {
                        continuation.resume(throwing: error)
                }
            }
        }
    }

    private func applyDirectoryDetailsIfCurrent(_ detailedItems: [FileItem],
                                                destination: String,
                                                requestID: UUID) {
        guard directoryLoadRequestID == requestID else { return }
        guard !insideArchive, !insideRemote, currentPath == destination else { return }

        applyLoadedFileSystemItems(
            detailedItems,
            destination: destination,
            resetCursor: false,
            preferredCursorPath: cursorItem?.path,
            clearSelection: false
        )
        storeDirectoryCache(path: destination, items: detailedItems)
    }

    private func enterArchive(at path: String, preferredRelativePath: String = "") {
        archiveOpenTask?.cancel()
        let requestID = UUID()
        archiveOpenRequestID = requestID
        archiveOpenTask = Task { [weak self] in
            await self?.enterArchiveAsync(
                at: path,
                requestID: requestID,
                preferredRelativePath: preferredRelativePath
            )
        }
    }

    /// Enter an archive that is itself an ENTRY of the archive being browsed.
    private func enterNestedArchive(_ item: FileItem) {
        guard let outerArchive = archivePath else { return }
        let entryPath = normalizeArchiveEntryPath(item.path)
        do {
            let extracted = try operationsService.extractArchiveEntryToTemp(
                archivePath: outerArchive, entryPath: entryPath)
            archiveReturnStack.append(
                (archive: outerArchive, relative: archiveRelativePath, cursorEntry: entryPath))
            enterArchive(at: extracted)
        } catch {
            errorMessage = "\(L("panel.error.openArchiveEntry")): \(error.localizedDescription)"
        }
    }

    private func navigateInsideArchive(to subpath: String) {
        archiveRelativePath = normalizeArchiveEntryPath(subpath)
        reloadArchiveDirectory()
    }

    /// After a listing lands, put the cursor where the navigation promised it — on the nested
    /// archive we just stepped out of.
    private func applyPendingArchiveCursor() {
        guard let entry = pendingArchiveCursorEntry else { return }
        pendingArchiveCursorEntry = nil
        if let index = items.firstIndex(where: { normalizeArchiveEntryPath($0.path) == entry }) {
            setCursor(index: index)
        }
    }

    private func reloadArchiveDirectory(resetCursor: Bool = true) {
        guard insideArchive, let activeArchivePath = archivePath else { return }

        if !isArchiveCacheValid(for: activeArchivePath) {
            clearArchiveEntriesCache(for: activeArchivePath)
            enterArchive(at: activeArchivePath, preferredRelativePath: archiveRelativePath)
            return
        }

        var visibleItems = cachedArchiveItems(for: archiveRelativePath)
        if let upItem = makeArchiveUpItem() {
            visibleItems.insert(upItem, at: 0)
        }

        allItems = visibleItems
        currentPath = currentArchiveDisplayPath(archivePath: activeArchivePath)
        if resetCursor {
            cursorIndex = 0
            scrollResetToken &+= 1
        } else {
            cursorIndex = min(max(0, cursorIndex), max(0, items.count - 1))
        }
        selectedPaths.removeAll()
        anchorIndex = nil
        errorMessage = nil
    }

    private func enterArchiveAsync(at path: String,
                                   requestID: UUID,
                                   preferredRelativePath: String) async {
        guard archiveOpenRequestID == requestID else { return }

        if isArchiveCacheValid(for: path) {
            insideArchive = true
            archivePath = path
            archiveRelativePath = resolveArchiveRelativePath(preferredRelativePath, for: path)
            reloadArchiveDirectory()
            applyPendingArchiveCursor()
            archiveOpenRequestID = nil
            return
        }

        var cancelRequested = false
        var progressController: ProgressController?

        // Show progress dialog only after a delay to avoid flashing for quick reads
        let showTask = Task { @MainActor in
            try await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            guard !Task.isCancelled else { return }
            let pc = DialogService.shared.showProgress(
                title: L("progress.reading"),
                message: L("progress.preparing"),
                cancelHandler: { [weak self] in
                    cancelRequested = true
                    self?.service.cancelArchiveOperations()
                }
            )
            pc.setIndeterminate(true)
            progressController = pc
        }

        do {
            let entries = try await loadArchiveEntries(path: path, qos: .userInitiated)
            showTask.cancel()
            progressController?.close()

            guard archiveOpenRequestID == requestID, !cancelRequested else { return }
            let signature = archiveFileSignature(for: path)
                ?? ArchiveFileSignature(modificationTime: nil, size: nil)
            setArchiveCache(
                path: path,
                entries: entries,
                signature: signature,
                format: archiveFormat(for: path)
            )
            insideArchive = true
            archivePath = path
            archiveRelativePath = resolveArchiveRelativePath(preferredRelativePath, for: path)
            reloadArchiveDirectory()
            applyPendingArchiveCursor()
            archiveOpenRequestID = nil
        } catch {
            showTask.cancel()
            progressController?.close()
            guard archiveOpenRequestID == requestID else { return }
            archiveOpenRequestID = nil
            if !cancelRequested {
                // Ядро отвечает по-английски («Unknown or corrupted archive format»);
                // человеку — переводом.
                let why = CoreErrorCode.of(error) == .archiveError
                    ? L("error.archiveCorruptedMessage") : error.localizedDescription
                let name = (path as NSString).lastPathComponent
                errorMessage = "\(L("panel.error.openArchivePath", name)): \(why)"
                complainAboutArchive(name, why)
            }
        }
    }

    private func listArchiveEntriesAsync(path: String,
                                         qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [ArchiveListEntry] {
        let bridgeService = service
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    let entries = try bridgeService.listArchiveEntries(archivePath: path)
                    continuation.resume(returning: entries)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadArchiveEntries(path: String,
                                    qos: DispatchQoS.QoSClass) async throws -> [ArchiveListEntry] {
        if let runningTask = archiveLoadTasks[path],
           qosRank(runningTask.qos) >= qosRank(qos) {
            return try await runningTask.task.value
        }

        if let runningTask = archiveLoadTasks[path] {
            runningTask.task.cancel()
        }

        let requestID = UUID()
        let task = Task<[ArchiveListEntry], Error> {
            try await listArchiveEntriesAsync(path: path, qos: qos)
        }
        archiveLoadTasks[path] = ArchiveLoadTask(requestID: requestID, qos: qos, task: task)

        do {
            let entries = try await task.value
            if archiveLoadTasks[path]?.requestID == requestID {
                archiveLoadTasks.removeValue(forKey: path)
            }
            return entries
        } catch {
            if archiveLoadTasks[path]?.requestID == requestID {
                archiveLoadTasks.removeValue(forKey: path)
            }
            throw error
        }
    }

    private func qosRank(_ qos: DispatchQoS.QoSClass) -> Int {
        switch qos {
        case .userInteractive:
            return 5
        case .userInitiated:
            return 4
        case .default:
            return 3
        case .utility:
            return 2
        case .background:
            return 1
        case .unspecified:
            return 0
        @unknown default:
            return 0
        }
    }

    private func goUpInsideArchive() {
        guard let activeArchivePath = archivePath else { return }

        // Leaving a nested archive's root goes back INTO the outer archive, onto the entry the
        // nested one came from — not out to the temp folder the copy happens to live in.
        if archiveRelativePath.isEmpty, let outer = archiveReturnStack.popLast() {
            pendingArchiveCursorEntry = outer.cursorEntry
            enterArchive(at: outer.archive, preferredRelativePath: outer.relative)
            return
        }

        if !archiveRelativePath.isEmpty {
            let previousRelativePath = archiveRelativePath
            archiveRelativePath = parentArchiveRelativePath(from: archiveRelativePath)
            reloadArchiveDirectory(resetCursor: false)
            if let index = items.firstIndex(where: { $0.path == previousRelativePath }) {
                setCursor(index: index)
            }
            return
        }

        let parentPath = archiveParentFolder ?? "/"

        loadFileSystemDirectory(
            at: parentPath,
            resetCursor: true,
            preferredCursorPath: activeArchivePath
        )
    }

    private func cachedArchiveItems(for relativePath: String) -> [FileItem] {
        guard let activeArchivePath = archivePath,
              var archiveCache = archiveCaches[activeArchivePath] else {
            return []
        }

        let cacheKey = normalizeArchiveEntryPath(relativePath)
        archiveCache.cachedAt = Date()
        if let cachedItems = archiveCache.visibleItemsByRelativePath[cacheKey] {
            archiveCaches[activeArchivePath] = archiveCache
            return sortItemsForDisplay(cachedItems)
        }

        let generatedItems = makeArchiveVisibleItems(
            relativePath: cacheKey,
            entries: archiveCache.entries
        )
        archiveCache.visibleItemsByRelativePath[cacheKey] = generatedItems
        archiveCaches[activeArchivePath] = archiveCache
        return sortItemsForDisplay(generatedItems)
    }

    private func makeArchiveVisibleItems(relativePath: String,
                                         entries: [ArchiveListEntry]) -> [FileItem] {
        var directories: [String: FileItem] = [:]
        var files: [String: FileItem] = [:]

        let prefix = currentArchivePrefix(relativePath: relativePath)

        for entry in entries {
            let normalizedEntryPath = normalizeArchiveEntryPath(entry.path)
            if normalizedEntryPath.isEmpty {
                continue
            }
            if !prefix.isEmpty && !normalizedEntryPath.hasPrefix(prefix) {
                continue
            }

            var relativeRemainder = normalizedEntryPath
            if !prefix.isEmpty {
                relativeRemainder.removeFirst(prefix.count)
            }
            if relativeRemainder.isEmpty {
                continue
            }

            let components = relativeRemainder.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first else {
                continue
            }

            let childName = String(first)
            if !showHiddenFiles && childName.hasPrefix(".") {
                continue
            }

            let childRelativePath = prefix + childName
            let isDirectChild = components.count == 1

            if isDirectChild {
                let isDirectory = entry.isDirectory || normalizedEntryPath.hasSuffix("/")
                if isDirectory {
                    directories[childRelativePath] = makeArchiveDirectoryItem(
                        relativePath: childRelativePath,
                        name: childName
                    )
                } else {
                    files[childRelativePath] = makeArchiveFileItem(
                        relativePath: childRelativePath,
                        name: childName,
                        size: entry.uncompressedSize
                    )
                }
                continue
            }

            directories[childRelativePath] = makeArchiveDirectoryItem(
                relativePath: childRelativePath,
                name: childName
            )
        }

        return sortItemsForDisplay(Array(directories.values) + Array(files.values))
    }

    private func makeArchiveUpItem() -> FileItem? {
        guard insideArchive else { return nil }

        if archiveRelativePath.isEmpty {
            guard let activeArchivePath = archivePath else { return nil }

            let parentPath: String
            do {
                parentPath = try service.parentPath(for: activeArchivePath)
            } catch {
                let fallback = (activeArchivePath as NSString).deletingLastPathComponent
                parentPath = fallback.isEmpty ? "/" : fallback
            }

            return FileItem(
                path: parentPath,
                name: "..",
                fileExtension: "",
                size: 0,
                isDirectory: true,
                isHidden: false,
                isSymlink: false,
                permissions: "",
                dateModified: Date()
            )
        }

        return FileItem(
            path: parentArchiveRelativePath(from: archiveRelativePath),
            name: "..",
            fileExtension: "",
            size: 0,
            isDirectory: true,
            isHidden: false,
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
    }

    private func makeArchiveDirectoryItem(relativePath: String, name: String) -> FileItem {
        FileItem(
            path: normalizeArchiveEntryPath(relativePath),
            name: name,
            fileExtension: "",
            size: 0,
            isDirectory: true,
            isHidden: name.hasPrefix("."),
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
    }

    private func makeArchiveFileItem(relativePath: String, name: String, size: UInt64) -> FileItem {
        FileItem(
            path: normalizeArchiveEntryPath(relativePath),
            name: name,
            fileExtension: (name as NSString).pathExtension,
            size: size,
            isDirectory: false,
            isHidden: name.hasPrefix("."),
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
    }

    private func clearArchiveState() {
        if insideArchive {
            operationsService.cleanupArchivePreviewTemporaryDirectories()
        }
        cancelPriorityArchivePrewarm()
        insideArchive = false
        archivePath = nil
        archiveRelativePath = ""
        archiveReturnStack.removeAll()
        pendingArchiveCursorEntry = nil
        // archiveCaches intentionally stays alive across archive switches.
        // Each archive has its own cache and is invalidated by signature checks
        // when the file changes on disk.
    }

    private func currentArchivePrefix(relativePath: String) -> String {
        let normalized = normalizeArchiveEntryPath(relativePath)
        if normalized.isEmpty {
            return ""
        }
        return normalized + "/"
    }

    private func currentArchiveDisplayPath(archivePath: String) -> String {
        if archiveRelativePath.isEmpty {
            return "\(archivePath)::/"
        }
        return "\(archivePath)::/\(archiveRelativePath)"
    }

    private func parentArchiveRelativePath(from value: String) -> String {
        let normalized = normalizeArchiveEntryPath(value)
        guard !normalized.isEmpty else { return "" }

        let parent = (normalized as NSString).deletingLastPathComponent
        if parent == "." {
            return ""
        }
        return normalizeArchiveEntryPath(parent)
    }

    private func normalizeArchiveEntryPath(_ value: String) -> String {
        var normalized = value
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func resolveArchiveRelativePath(_ preferredRelativePath: String, for path: String) -> String {
        let normalizedPreferred = normalizeArchiveEntryPath(preferredRelativePath)
        guard !normalizedPreferred.isEmpty else { return "" }
        guard let archiveCache = archiveCaches[path] else { return "" }

        let prefix = normalizedPreferred + "/"
        let existsInArchive = archiveCache.entries.contains { entry in
            let normalizedEntry = normalizeArchiveEntryPath(entry.path)
            return normalizedEntry == normalizedPreferred || normalizedEntry.hasPrefix(prefix)
        }
        return existsInArchive ? normalizedPreferred : ""
    }

    private func clearArchiveEntriesCache(for path: String? = nil) {
        if let path {
            archiveCaches.removeValue(forKey: path)
        } else {
            archiveCaches.removeAll()
        }
    }

    func invalidateArchiveCache(for path: String) {
        clearArchiveEntriesCache(for: path)
        if let loadTask = archiveLoadTasks[path] {
            loadTask.task.cancel()
            archiveLoadTasks.removeValue(forKey: path)
        }
        if insideArchive, archivePath == path {
            reloadArchiveDirectory(resetCursor: false)
        }
    }

    private func scheduleArchivePrewarm(for directoryItems: [FileItem]) {
        archivePrewarmTask?.cancel()

        let allArchives = directoryItems.filter(isPrewarmArchiveCandidate)
        guard !allArchives.isEmpty else { return }

        if allArchives.count <= Self.smallArchiveFolderThreshold {
            schedulePrewarmAll(allArchives)
        } else {
            schedulePrewarmSelective(allArchives)
        }
    }

    private func schedulePrewarmAll(_ archives: [FileItem]) {
        let (focusedArchive, remaining) = splitFocusedArchive(from: archives)
        let fastArchives = remaining.filter(isIndexedArchive)
        let slowArchives = limitSlowArchiveBatch(remaining.filter { !isIndexedArchive($0) })
        guard focusedArchive != nil || !fastArchives.isEmpty || !slowArchives.isEmpty else { return }

        archivePrewarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            if let focusedArchive {
                await self.prewarmArchiveIfNeeded(focusedArchive, qos: .userInitiated)
            }
            guard !Task.isCancelled else { return }

            await self.runPrewarmQueue(
                fastArchives,
                workerCount: Self.fastPrewarmWorkerCount,
                qos: .utility
            )
            guard !Task.isCancelled else { return }

            await self.runPrewarmQueue(
                slowArchives,
                workerCount: Self.slowPrewarmWorkerCount,
                qos: .utility
            )
        }
    }

    private func schedulePrewarmSelective(_ archives: [FileItem]) {
        let immediateArchives = archives.filter { prewarmStrategy(for: $0) == .immediate }
        let (focusedArchive, remaining) = splitFocusedArchive(from: immediateArchives)
        let fastArchives = remaining.filter(isIndexedArchive)
        let slowArchives = limitSlowArchiveBatch(remaining.filter { !isIndexedArchive($0) })
        guard focusedArchive != nil || !fastArchives.isEmpty || !slowArchives.isEmpty else { return }

        archivePrewarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            if let focusedArchive {
                await self.prewarmArchiveIfNeeded(focusedArchive, qos: .userInitiated)
            }
            guard !Task.isCancelled else { return }

            await self.runPrewarmQueue(
                fastArchives,
                workerCount: Self.fastPrewarmWorkerCount,
                qos: .utility
            )
            guard !Task.isCancelled else { return }

            await self.runPrewarmQueue(
                slowArchives,
                workerCount: Self.slowPrewarmWorkerCount,
                qos: .utility
            )
        }
    }

    private func splitFocusedArchive(from archives: [FileItem]) -> (FileItem?, [FileItem]) {
        guard !archives.isEmpty else { return (nil, []) }
        guard let focusedPath = cursorItem?.path,
              let focusedIndex = archives.firstIndex(where: { $0.path == focusedPath }) else {
            return (nil, archives)
        }

        var remaining = archives
        let focused = remaining.remove(at: focusedIndex)
        return (focused, remaining)
    }

    private func limitSlowArchiveBatch(_ archives: [FileItem]) -> [FileItem] {
        let sorted = archives.sorted { lhs, rhs in
            if lhs.size == rhs.size {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.size < rhs.size
        }

        var selected: [FileItem] = []
        var usedBudget: UInt64 = 0
        for item in sorted {
            if item.size > Self.slowArchiveHardLimitBytes {
                continue
            }
            if item.size > Self.slowArchivePrewarmBudgetBytes {
                continue
            }
            if usedBudget > Self.slowArchivePrewarmBudgetBytes - item.size {
                continue
            }
            selected.append(item)
            usedBudget += item.size
        }
        return selected
    }

    private func runPrewarmQueue(_ archives: [FileItem],
                                 workerCount: Int,
                                 qos: DispatchQoS.QoSClass) async {
        guard !archives.isEmpty else { return }
        let maxWorkers = min(workerCount, archives.count)
        guard maxWorkers > 0 else { return }

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard !Task.isCancelled else { return }
                guard nextIndex < archives.count else { return }
                let item = archives[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.prewarmArchiveIfNeeded(item, qos: qos)
                }
            }

            for _ in 0..<maxWorkers {
                enqueueNext()
            }

            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                enqueueNext()
            }
        }
    }

    private func prewarmArchiveIfNeeded(_ item: FileItem,
                                        qos: DispatchQoS.QoSClass) async {
        let path = item.path
        let currentSignature = archiveFileSignature(for: path) ?? archiveFileSignature(for: item)

        if isArchiveCacheValid(for: path) {
            return
        }
        // Уже не прочёлся, и файл с тех пор не менялся — вторая попытка кончится тем же.
        if let failed = archivePrewarmFailures[path],
           areArchiveSignaturesEqual(failed, currentSignature) {
            return
        }

        do {
            let entries = try await loadArchiveEntries(path: path, qos: qos)
            guard !Task.isCancelled else { return }

            let refreshedSignature = archiveFileSignature(for: path) ?? currentSignature
            let showHidden = showHiddenFiles
            let visibleItemsByRelativePath = await Self.buildArchiveVisibleItemsCacheAsync(
                entries: entries,
                showHiddenFiles: showHidden
            )
            setArchiveCache(
                path: path,
                entries: entries,
                signature: refreshedSignature,
                format: archiveFormat(for: path),
                visibleItemsByRelativePath: visibleItemsByRelativePath
            )
        } catch {
            // Ошибку не показываем — её покажет обычное открытие, — но запоминаем: пока файл
            // тот же, повторять чтение незачем.
            if !Task.isCancelled { archivePrewarmFailures[path] = currentSignature }
        }
    }

    private func setArchiveCache(path: String,
                                 entries: [ArchiveListEntry],
                                 signature: ArchiveFileSignature,
                                 format: ArchiveFormat,
                                 visibleItemsByRelativePath: [String: [FileItem]] = [:]) {
        archivePrewarmFailures.removeValue(forKey: path)
        archiveCaches[path] = ArchiveCache(
            entries: entries,
            signature: signature,
            visibleItemsByRelativePath: visibleItemsByRelativePath,
            cachedAt: Date(),
            format: format
        )
        trimArchiveCacheIfNeeded()
    }

    nonisolated private static func buildArchiveVisibleItemsCacheAsync(
        entries: [ArchiveListEntry],
        showHiddenFiles: Bool
    ) async -> [String: [FileItem]] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let cache = buildArchiveVisibleItemsCache(
                    entries: entries,
                    showHiddenFiles: showHiddenFiles
                )
                continuation.resume(returning: cache)
            }
        }
    }

    nonisolated private static func buildArchiveVisibleItemsCache(
        entries: [ArchiveListEntry],
        showHiddenFiles: Bool
    ) -> [String: [FileItem]] {
        var directoriesByParent: [String: [String: FileItem]] = ["": [:]]
        var filesByParent: [String: [String: FileItem]] = ["": [:]]

        func ensureParent(_ parent: String) {
            if directoriesByParent[parent] == nil {
                directoriesByParent[parent] = [:]
            }
            if filesByParent[parent] == nil {
                filesByParent[parent] = [:]
            }
        }

        for entry in entries {
            let normalizedEntryPath = normalizeArchiveEntryPathStatic(entry.path)
            if normalizedEntryPath.isEmpty {
                continue
            }

            let components = normalizedEntryPath.split(separator: "/", omittingEmptySubsequences: true)
            if components.isEmpty {
                continue
            }

            let isDirectoryEntry = entry.isDirectory || normalizedEntryPath.hasSuffix("/")
            var parent = ""

            for (index, rawName) in components.enumerated() {
                let name = String(rawName)
                if !showHiddenFiles && name.hasPrefix(".") {
                    break
                }

                ensureParent(parent)
                let childRelativePath = parent.isEmpty ? name : "\(parent)/\(name)"
                let isLast = index == components.count - 1

                if isLast && !isDirectoryEntry {
                    filesByParent[parent]?[childRelativePath] = makeArchiveFileItemStatic(
                        relativePath: childRelativePath,
                        name: name,
                        size: entry.uncompressedSize
                    )
                } else {
                    directoriesByParent[parent]?[childRelativePath] = makeArchiveDirectoryItemStatic(
                        relativePath: childRelativePath,
                        name: name
                    )
                    ensureParent(childRelativePath)
                }

                parent = childRelativePath
            }
        }

        var result: [String: [FileItem]] = [:]
        let allParents = Set(directoriesByParent.keys).union(filesByParent.keys)
        for parent in allParents {
            let directories = Array((directoriesByParent[parent] ?? [:]).values).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let files = Array((filesByParent[parent] ?? [:]).values).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            result[parent] = directories + files
        }

        if result[""] == nil {
            result[""] = []
        }
        return result
    }

    nonisolated private static func normalizeArchiveEntryPathStatic(_ value: String) -> String {
        var normalized = value
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    nonisolated private static func makeArchiveDirectoryItemStatic(relativePath: String, name: String) -> FileItem {
        FileItem(
            path: normalizeArchiveEntryPathStatic(relativePath),
            name: name,
            fileExtension: "",
            size: 0,
            isDirectory: true,
            isHidden: name.hasPrefix("."),
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
    }

    nonisolated private static func makeArchiveFileItemStatic(relativePath: String, name: String, size: UInt64) -> FileItem {
        FileItem(
            path: normalizeArchiveEntryPathStatic(relativePath),
            name: name,
            fileExtension: (name as NSString).pathExtension,
            size: size,
            isDirectory: false,
            isHidden: name.hasPrefix("."),
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
    }

    private func clearArchiveVisibleItemsCaches() {
        let allPaths = Array(archiveCaches.keys)
        for path in allPaths {
            guard var cache = archiveCaches[path] else { continue }
            cache.visibleItemsByRelativePath.removeAll()
            archiveCaches[path] = cache
        }
    }

    private func archiveFileSignature(for path: String) -> ArchiveFileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }

        return ArchiveFileSignature(
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
            size: (attributes[.size] as? NSNumber)?.uint64Value
        )
    }

    private func archiveFileSignature(for item: FileItem) -> ArchiveFileSignature {
        ArchiveFileSignature(
            modificationTime: item.dateModified.timeIntervalSince1970,
            size: item.size
        )
    }

    private func areArchiveSignaturesEqual(_ lhs: ArchiveFileSignature, _ rhs: ArchiveFileSignature) -> Bool {
        let canCompareSize = lhs.size != nil && rhs.size != nil
        let canCompareMtime = lhs.modificationTime != nil && rhs.modificationTime != nil

        if canCompareSize && lhs.size != rhs.size {
            return false
        }

        if canCompareMtime,
           let lhsMtime = lhs.modificationTime,
           let rhsMtime = rhs.modificationTime,
           abs(lhsMtime - rhsMtime) >= 0.001
        {
            return false
        }

        return canCompareSize || canCompareMtime
    }

    private func trimArchiveCacheIfNeeded() {
        guard archiveCaches.count > Self.archiveCacheLimit else { return }

        let stalePaths = archiveCaches
            .sorted { $0.value.cachedAt < $1.value.cachedAt }
            .prefix(archiveCaches.count - Self.archiveCacheLimit)
            .map(\.key)

        for path in stalePaths {
            archiveCaches.removeValue(forKey: path)
        }
    }

    private func isArchiveCacheValid(for path: String) -> Bool {
        guard var cache = archiveCaches[path] else { return false }
        guard let currentSignature = archiveFileSignature(for: path) else {
            archiveCaches.removeValue(forKey: path)
            return false
        }

        if !areArchiveSignaturesEqual(cache.signature, currentSignature) {
            archiveCaches.removeValue(forKey: path)
            return false
        }

        cache.cachedAt = Date()
        archiveCaches[path] = cache
        return true
    }

    private func isArchivePath(_ path: String) -> Bool {
        archiveFormat(for: path) != .unknown
    }

    private func archiveFormat(for path: String) -> ArchiveFormat {
        let lowercased = path.lowercased()
        if lowercased.hasSuffix(".tar.gz") { return .tarGz }
        if lowercased.hasSuffix(".tar.bz2") { return .tarBz2 }
        if lowercased.hasSuffix(".tar.xz") { return .tarXz }
        if lowercased.hasSuffix(".tar.zst") { return .tarZst }
        if lowercased.hasSuffix(".tzst") { return .tarZst }
        // .lz4 BEFORE .lz: ".lz" is its suffix, and the first match would claim every lz4 file.
        if lowercased.hasSuffix(".tar.lz4") { return .tarLz4 }
        if lowercased.hasSuffix(".lz4") { return .tarLz4 }
        if lowercased.hasSuffix(".tar.lz") { return .tarLz }
        if lowercased.hasSuffix(".tlz") { return .tarLz }
        if lowercased.hasSuffix(".lz") { return .tarLz }
        if lowercased.hasSuffix(".zst") { return .tarZst }
        if lowercased.hasSuffix(".iso") { return .iso }
        if lowercased.hasSuffix(".tbz2") { return .tbz2 }
        if lowercased.hasSuffix(".tgz") { return .tgz }
        if lowercased.hasSuffix(".txz") { return .txz }
        if lowercased.hasSuffix(".zip") { return .zip }
        if lowercased.hasSuffix(".7z") { return .sevenZip }
        if lowercased.hasSuffix(".rar") { return .rar }
        if lowercased.hasSuffix(".tar") { return .tar }
        if lowercased.hasSuffix(".gz") { return .gz }
        if lowercased.hasSuffix(".bz2") { return .bz2 }
        if lowercased.hasSuffix(".xz") { return .xz }
        return .unknown
    }

    private func isPrewarmArchiveCandidate(_ item: FileItem) -> Bool {
        !item.isDirectory && isArchivePath(item.path)
    }

    private func isIndexedArchive(_ item: FileItem) -> Bool {
        archiveFormat(for: item.path).isIndexed
    }

    private var isSmallArchiveFolder: Bool {
        items.filter(isPrewarmArchiveCandidate).count <= Self.smallArchiveFolderThreshold
    }

    private func prewarmStrategy(for item: FileItem) -> PrewarmStrategy {
        Self.prewarmDecision(sizeBytes: item.size,
                             indexed: isIndexedArchive(item),
                             smallFolder: isSmallArchiveFolder,
                             slowVolume: currentPathIsSlowVolume)
    }

    /// Когда читать оглавление архива заранее — само решение, без панели, чтобы его можно
    /// было проверить.
    ///
    /// Пустой файл читать нечего: это либо заглушка, либо обрыв, и попытка только упадёт.
    /// На медленном томе (сеть, USB) сразу — никогда: курсор, идущий стрелкой по списку,
    /// поднимал бы чтение по сети на каждой остановке; читается только то, на чём курсор
    /// задержался. На быстром диске — как и было: маленькое сразу, среднее по задержке,
    /// большое только по Enter.
    nonisolated static func prewarmDecision(sizeBytes: UInt64, indexed: Bool,
                                            smallFolder: Bool, slowVolume: Bool) -> PrewarmStrategy {
        if sizeBytes == 0 { return .onUserOpen }
        if slowVolume { return .onCursorHover }
        if smallFolder {
            if indexed { return .immediate }
            return sizeBytes <= slowArchiveHardLimitBytes ? .immediate : .onUserOpen
        }
        if indexed { return .immediate }
        let sizeInMB = sizeBytes / (1024 * 1024)
        if sizeInMB < 50 { return .immediate }
        if sizeInMB < 500 { return .onCursorHover }
        return .onUserOpen
    }

    private func openFileInsideArchive(_ item: FileItem) {
        guard let activeArchivePath = archivePath else {
            errorMessage = L("error.archivePathUnknown")
            return
        }

        let entryPath = normalizeArchiveEntryPath(item.path)
        guard !entryPath.isEmpty else {
            errorMessage = L("error.archiveEntryEmpty")
            return
        }

        do {
            try operationsService.openExtractedArchiveEntry(
                at: activeArchivePath,
                entryPath: entryPath
            )
        } catch {
            errorMessage = "\(L("panel.error.openArchiveEntry")): \(error.localizedDescription)"
        }
    }

    private func saveCurrentPath() {
        guard canPersistState else { return }
        UserDefaults.standard.set(currentPath, forKey: pathDefaultsKey)
    }

    private func saveViewMode() {
        guard canPersistState else { return }
        UserDefaults.standard.set(viewMode.rawValue, forKey: viewModeDefaultsKey)
    }

    private func saveVisibleColumns() {
        guard canPersistState else { return }
        let values = visibleColumns.map(\.rawValue).sorted()
        UserDefaults.standard.set(values, forKey: visibleColumnsDefaultsKey)
    }

    private static func normalizedVisibleColumns(_ columns: Set<PanelColumn>) -> Set<PanelColumn> {
        var normalized = columns.intersection(Set(PanelColumn.allCases))
        normalized.insert(.name)
        // "Where it came from" belongs to the Trash and is added there by effectiveVisibleColumns.
        // Keeping it out of the user's set is what stops a stale saved set from putting an empty
        // column on an ordinary folder.
        normalized.remove(.origin)
        return normalized
    }

    private static func visibleColumnsDefaultsKey(for pathDefaultsKey: String) -> String {
        if pathDefaultsKey == "leftPanelPath" {
            return "leftVisibleColumns"
        }
        if pathDefaultsKey == "rightPanelPath" {
            return "rightVisibleColumns"
        }
        return "\(pathDefaultsKey).visibleColumns"
    }

    static let persistColumnWidthsKey = "fcxl.persistColumnWidths"

    static func columnWidthsKey(for pathDefaultsKey: String) -> String {
        if pathDefaultsKey == "leftPanelPath" { return "leftColumnWidths" }
        if pathDefaultsKey == "rightPanelPath" { return "rightColumnWidths" }
        return "\(pathDefaultsKey).columnWidths"
    }

    /// Persist user-set widths if the user opted in. Called once per drag
    /// gesture (on mouseUp), not per pixel. When the setting is off we simply
    /// don't write — stored data is left intact (it is also never loaded
    /// while the setting is off), so toggling off→on doesn't destroy the
    /// user's saved layout.
    func saveUserColumnWidthsIfEnabled() {
        guard canPersistState else { return }
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Self.persistColumnWidthsKey) as? Bool ?? true
        guard enabled, !userColumnWidths.isEmpty else { return }
        defaults.set(userColumnWidths.mapValues { Double($0) },
                     forKey: Self.columnWidthsKey(for: pathDefaultsKey))
    }

    // MARK: - Volume detection

    /// Returns true if path is the user's home directory (the "C:" drive boundary).
    private static func isHomeDirectory(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        return normalized == home
    }

    /// Returns true if path is a volume mount point (e.g., "/", "/Volumes/USB").
    private static func isVolumeRoot(_ path: String) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if std == "/" { return true }
        // iCloud Drive is a PLACE, the way Finder shows it — not a folder buried in Library.
        // Above it lies "Mobile Documents", the plumbing where macOS keeps every iCloud-aware
        // program's container; walking up into that from the drive button is a trapdoor into
        // the kitchen, so the drive's own root is where the road ends.
        if std == URL(fileURLWithPath: CloudStatusService.cloudDriveRoot)
            .standardizedFileURL.path { return true }
        // A direct child of /Volumes IS a mounted volume's root (e.g.
        // "/Volumes/Toshiba 1T USB"). This string check is robust — it does not
        // depend on .volumeURLKey, which fails transiently while an NTFS volume
        // is unmounted for a write, making ".." wrongly appear at the disk root.
        if (std as NSString).deletingLastPathComponent == "/Volumes" { return true }
        // A path that is itself a mount point counts as a drive root ONLY if the volume is
        // user-browsable — the kind Finder shows as a disk. System devfs/system mounts such
        // as /dev are `nobrowse`; they are reached by navigating DOWN from "/", so they must
        // keep a ".." to go back up instead of being treated as a top-level drive root.
        if let values = try? URL(fileURLWithPath: std)
            .resourceValues(forKeys: [.volumeURLKey, .volumeIsBrowsableKey]),
           values.volumeIsBrowsable == true,
           let volumeURL = values.volume {
            return std == volumeURL.standardizedFileURL.path
        }
        return false
    }

    /// Places the panel shows that no filesystem has: the Trash and the network browser.
    private static func isVirtualLocation(_ path: String) -> Bool {
        TrashService.isTrashPath(path) || NetworkBrowserService.isNetworkPath(path)
    }

    private static func isSlowVolume(_ path: String) -> Bool {
        let info = VolumeInterfaceDetector.detect(forPath: path)
        return !info.isFast
    }

    /// Returns the volume mount point for a given path (e.g., "/Volumes/Toshiba 1T USB" for a subpath).
    private static func volumeRoot(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume {
            return volumeURL.standardizedFileURL.path
        }
        // Fallback: walk up the path looking for a volume root
        var current = url.standardizedFileURL
        while current.path != "/" {
            if isVolumeRoot(current.path) {
                return current.path
            }
            current = current.deletingLastPathComponent()
        }
        return "/"
    }
}
