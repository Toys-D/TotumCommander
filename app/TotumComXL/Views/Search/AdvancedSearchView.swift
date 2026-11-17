import AppKit
import Combine
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search Mode

/// The four ways to search — the tabs at the top of the window, from the plainest to the
/// most particular.
enum SearchMode: String, CaseIterable {
    case byName = "search.mode.name"
    case byContent = "search.mode.content"
    /// Ask macOS's index instead of walking the disk — a separate mode rather than a switch on
    /// "by name", because it answers a different question: it is instant across a whole disk
    /// and can read inside PDFs, but it knows nothing about hidden files, package interiors or
    /// unindexed volumes, and has no regular expressions. A hidden switch that quietly changed
    /// what the other controls mean would be exactly the kind of surprise this app avoids.
    case spotlight = "search.mode.spotlight"
    case duplicates = "search.mode.duplicates"

    var title: String { L(rawValue) }

    var symbol: String {
        switch self {
        case .byName: return "textformat"
        case .byContent: return "doc.text.magnifyingglass"
        case .spotlight: return "sparkle.magnifyingglass"
        case .duplicates: return "square.on.square"
        }
    }
}

enum DuplicateMode: Int, CaseIterable {
    case byName = 0
    case bySize = 1
    case byHash = 2

    /// In the order the window offers them: the one that means "the same file twice" first.
    /// "Same size" is not offered: two files of one size are not copies of each other, and a
    /// list of them answered a question nobody asks. The engine still knows the criterion.
    static let shown: [DuplicateMode] = [.byHash, .byName]

    var label: String {
        switch self {
        case .byName: return L("search.dup.byName")
        case .bySize: return L("search.dup.bySize")
        case .byHash: return L("search.dup.byHash")
        }
    }
}

/// Units of the size condition — by the thousand, the way the panels and Finder count a
/// file's size. By 1024, a file the panel shows as "10 MB" (ten million bytes) failed the
/// condition "from 10 MB".
enum SizeUnit: Int64, CaseIterable {
    case bytes = 1
    case kb = 1_000
    case mb = 1_000_000
    case gb = 1_000_000_000

    var label: String {
        switch self {
        case .bytes: return L("search.unit.b")
        case .kb: return L("search.unit.kb")
        case .mb: return L("search.unit.mb")
        case .gb: return L("search.unit.gb")
        }
    }
}

enum FileTypeOption: Int, CaseIterable {
    case all = 0
    case filesOnly = 1
    case dirsOnly = 2

    var label: String {
        switch self {
        case .all: return L("search.type.all")
        case .filesOnly: return L("search.type.files")
        case .dirsOnly: return L("search.type.dirs")
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AdvancedSearchViewModel: ObservableObject {
    @Published var pattern: String = "*"
    /// Text to find INSIDE files — used only in "by content" mode. The top `pattern` field
    /// stays the file-NAME mask (which files to look in); this is what to find within them.
    @Published var contentQuery: String = ""
    /// Read pictures, scans and PDFs as well when searching by content. Off by default: it is
    /// the one part of a search that costs a fraction of a second PER FILE, and nobody should
    /// pay for it without asking.
    @Published var readPictures: Bool = false
    /// "By content" only: tell «Договор» from «договор». Off by default — someone looking for
    /// a word wants it however it was capitalised, and has to ask for the opposite.
    @Published var caseSensitive: Bool = false
    /// Set when the picture search stopped at its own limit rather than at the end of the folder.
    @Published var pictureLimitReached = false
    @Published var rootPath: String = ""
    @Published var useRegex: Bool = false
    @Published var recursive: Bool = true
    @Published var includeHidden: Bool = false

    @Published var searchMode: SearchMode = .byName
    @Published var duplicateMode: DuplicateMode = .byHash
    @Published var fileType: FileTypeOption = .all

    @Published var minSizeValue: String = ""
    @Published var maxSizeValue: String = ""
    @Published var sizeUnit: SizeUnit = .mb

    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    /// Which stretch of time the search is limited to. "Custom" uses the two dates above.
    @Published var datePreset: SearchDatePreset = .any {
        didSet {
            // The fields must show what the search will use: the first time "custom" is
            // chosen they open on the last week rather than on "01.01.0001 — today".
            guard datePreset == .custom, dateFrom == nil, dateTo == nil else { return }
            let range = SearchDateRange.initial()
            dateFrom = range.from
            dateTo = range.to
        }
    }

    /// The folders the two panels show — for the quick places next to "Where".
    var panelPath: String = ""
    var otherPanelPath: String = ""
    /// Where the recent places are kept; the tests hand in their own.
    var placesDefaults: UserDefaults = .standard

    /// True once a search has been started in this window — the empty list then means
    /// "nothing found" rather than "nothing asked yet".
    @Published var hasSearched: Bool = false

    // MARK: Order of the list

    static let sortKeyDefaultsKey = "fcxl.search.sortKey"
    static let sortAscendingDefaultsKey = "fcxl.search.sortAscending"

    /// The column the list is ordered by, and which way. Remembered between launches: someone
    /// who looks for the biggest files wants them on top the next time as well.
    @Published private(set) var sortKey: SearchSortKey =
        SearchSortKey(rawValue: UserDefaults.standard.string(forKey: sortKeyDefaultsKey) ?? "") ?? .name
    @Published private(set) var sortAscending: Bool =
        UserDefaults.standard.object(forKey: sortAscendingDefaultsKey) as? Bool ?? true
    /// Where the order is remembered; nil in tests, which must not touch the real settings.
    var sortDefaults: UserDefaults? = .standard

    /// Lists longer than this are put in order off the main thread: comparing a hundred
    /// thousand names the way a person reads them takes long enough to be felt.
    static let sortInlineLimit = 5_000

    func setSort(key: SearchSortKey, ascending: Bool) {
        guard key != sortKey || ascending != sortAscending else { return }
        sortKey = key
        sortAscending = ascending
        sortDefaults?.set(key.rawValue, forKey: Self.sortKeyDefaultsKey)
        sortDefaults?.set(ascending, forKey: Self.sortAscendingDefaultsKey)
        resort()
    }

    /// A click on a column header: a new column starts ascending, the same one turns around.
    func sort(by key: SearchSortKey) {
        setSort(key: key, ascending: key == sortKey ? !sortAscending : true)
    }

    private func resort() {
        let key = sortKey
        let ascending = sortAscending
        guard results.count > Self.sortInlineLimit else {
            results = SearchSort.sorted(results, by: key, ascending: ascending)
            resultsRevision += 1
            return
        }
        let unordered = results
        Task { [weak self] in
            let ordered = await Task.detached(priority: .userInitiated) {
                SearchSort.sorted(unordered, by: key, ascending: ascending)
            }.value
            // The list may have been replaced, or the order changed again, while this ran.
            guard let self, self.sortKey == key, self.sortAscending == ascending,
                  self.results.count == unordered.count else { return }
            self.results = ordered
            self.resultsRevision += 1
        }
    }

    /// The mode of the search the list on screen came from. The list belongs to that search,
    /// not to whichever tab is open now: switching the tab to prepare the next question must
    /// not reinterpret — or seem to empty — the answer to the last one.
    @Published var resultsMode: SearchMode = .byName

    @Published var results: [SearchHit] = []
    @Published var duplicateResults: [DuplicateGroup] = []
    @Published var isSearching: Bool = false
    /// The directory currently being scanned — shown in the status line while searching.
    @Published var currentScanPath: String = ""
    @Published var errorMessage: String?
    @Published var selectedResults: Set<String> = []
    @Published var folderSizes: [String: UInt64] = [:]

    /// Spotlight mode only: search the whole indexed computer instead of the folder above.
    /// Off by default — Finder's habit of answering a search inside a folder with hits from
    /// the entire Mac is the single most complained-about thing about it.
    @Published var spotlightWholeDisk: Bool = false
    /// The cap cut the answer short; the status line says so instead of quietly lying.
    @Published var spotlightTruncated: Bool = false

    /// How many hits there really were when the list had to be cut. 0 = nothing was cut.
    @Published var totalBeforeCap: Int = 0

    /// Bumped whenever the result list itself changes. The table reloads on this and on
    /// nothing else — SwiftUI hands the view an update on every keystroke in the form, and
    /// reloading a hundred thousand rows for a typed letter is the kind of work that used to
    /// make this dialog feel broken.
    @Published var resultsRevision: Int = 0
    /// Bumped to ask the results table for the keyboard.
    @Published var focusRequest: Int = 0

    /// Folders and files the search must not enter — "node_modules;.cache;*.tmp".
    ///
    /// Remembered between searches (and between launches): a home folder is mostly build
    /// caches, and retyping the same exclusions every time is how a useful field becomes an
    /// unused one. An excluded DIRECTORY is not entered at all, so this is the setting that
    /// makes a search of $HOME fast rather than merely tidy.
    @Published var excludeSpec: String = UserDefaults.standard.string(forKey: excludeDefaultsKey) ?? "" {
        didSet { UserDefaults.standard.set(excludeSpec, forKey: Self.excludeDefaultsKey) }
    }
    static let excludeDefaultsKey = "fcxl.searchExclude"

    /// The spec as a list. Semicolons and commas both separate — the first is what commander
    /// users type, the second is what everyone else reaches for.
    nonisolated static func excludeList(_ spec: String) -> [String] {
        spec.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True when any component of the path is excluded — the sieve for Spotlight, which does
    /// its own walking inside the index and cannot be told to skip a folder.
    nonisolated static func pathIsExcluded(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        // Only the leading "/" is dropped, and only when it IS the root: dropping the first
        // component outright ate the first folder of every relative path, which is exactly the
        // name that had to be matched.
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        return components.contains { component in
            patterns.contains { fnmatch($0, component, FNM_CASEFOLD) == 0 }
        }
    }

    private func publish(results hits: [SearchHit], total: Int) {
        results = hits
        totalBeforeCap = total
        resultsRevision += 1
    }

    private func publish(duplicates groups: [DuplicateGroup], total: Int) {
        duplicateResults = groups
        totalBeforeCap = total
        resultsRevision += 1
    }

    /// The most rows this dialog will hold.
    ///
    /// It used to be two thousand, and it had to be: the results were a SwiftUI List, which
    /// builds its whole item tree up front, and a duplicates run answering with 662 821 files
    /// hung the app inside that tree. The list is an AppKit table now — it makes views only
    /// for the rows on screen — so the ceiling is no longer about drawing at all. What is left
    /// is memory: every row holds its full path, and a hundred thousand of them is already
    /// tens of megabytes. That is the number, and it is high enough that no real search meets
    /// it; when one does, the status line says so instead of pretending it found less.
    static let maxShownResults = 100_000

    /// Cut a result list down to what can be drawn, and report what it really was.
    nonisolated static func capped(_ hits: [SearchHit],
                                   limit: Int = maxShownResults) -> (hits: [SearchHit], total: Int) {
        guard hits.count > limit else { return (hits, 0) }
        return (Array(hits.prefix(limit)), hits.count)
    }

    /// Same for duplicates, counted in FILES rather than groups — a group is never split in
    /// half, so a group straddling the limit is kept whole.
    nonisolated static func capped(_ groups: [DuplicateGroup],
                                   limit: Int = maxShownResults) -> (groups: [DuplicateGroup], total: Int) {
        let total = groups.reduce(0) { $0 + $1.files.count }
        guard total > limit else { return (groups, 0) }
        var kept: [DuplicateGroup] = []
        var shown = 0
        for group in groups {
            kept.append(group)
            shown += group.files.count
            if shown >= limit { break }
        }
        return (kept, total)
    }

    private let service = CoreBridgeService()
    private var activeSearchService: CoreBridgeService?
    private var spotlight: SpotlightSearchService?
    var onNavigateToFile: ((String) -> Void)?
    /// The folder "Go to" last took the panel to. While the panel still stands there, reopening
    /// the window continues the same search instead of pointing it at that subfolder.
    var visitedFromResults: String?
    var onDeleteFiles: (([String]) -> Void)?
    /// Copy (true) or move (false) the finds — through the program's own copy dialog, which
    /// offers the other panel's folder and lets it be changed.
    var onTransfer: (([String], Bool) -> Void)?
    var onEdit: ((String) -> Void)?
    /// All the finds, and the folder they were looked for in — to be shown in a panel.
    var onShowInPanel: (([String], String) -> Void)?
    /// Show or hide the quick look of the selected finds; the window owns the preview.
    var onQuickLook: (() -> Void)?
    var onClose: (() -> Void)?

    /// Where the list on screen was looked for — the folder column shows paths from here,
    /// and "to panel" opens the list in it. "/" for Spotlight asked about the whole Mac.
    @Published var resultsRoot: String = ""

    /// Asynchronously calculate folder sizes for directory results.
    ///
    /// Each one is a full recursive walk, so this is deliberately limited to the head of the
    /// list: a search answering with thousands of folders would otherwise start thousands of
    /// disk walks nobody asked for, for rows the user will never scroll to.
    static let maxFolderSizesComputed = 200

    func calculateFolderSizes() {
        let dirs = results.filter { $0.isDirectory }.map(\.path).prefix(Self.maxFolderSizesComputed)
        guard !dirs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for dir in dirs {
                let fm = FileManager.default
                var total: UInt64 = 0
                if let enumerator = fm.enumerator(at: URL(fileURLWithPath: dir),
                                                   includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                   options: [.skipsHiddenFiles]) {
                    for case let url as URL in enumerator {
                        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                           values.isRegularFile == true {
                            total += UInt64(values.fileSize ?? 0)
                        }
                    }
                }
                DispatchQueue.main.async {
                    self?.folderSizes[dir] = total
                }
            }
        }
    }

    /// Finds made so far, while the search is still walking: the list fills as it goes instead
    /// of standing empty until the end. The final answer replaces all of this when it comes.
    func appendFound(_ hits: [SearchHit], limit: Int = AdvancedSearchViewModel.maxShownResults) {
        let room = limit - results.count
        guard room > 0, !hits.isEmpty else { return }
        results.append(contentsOf: hits.prefix(room))
        // A short list is kept in order as it grows; a long one waits for the final answer,
        // which arrives ordered — sorting a hundred thousand rows per batch would be felt.
        if results.count <= Self.sortInlineLimit {
            results = SearchSort.sorted(results, by: sortKey, ascending: sortAscending)
        }
        resultsRevision += 1
    }

    // MARK: Duplicates: the spare copies

    /// Select every copy but one in each group — what a duplicates run is for.
    func selectDuplicateExtras(keep: DuplicateKeep) {
        guard resultsMode == .duplicates else { return }
        selectedResults = DuplicateSelection.extras(in: duplicateResults, keep: keep,
                                                    modified: DuplicateSelection.modifiedOnDisk)
    }

    /// What deleting the selection would free, and in how many groups it would leave no copy
    /// at all. Nil outside duplicates, and when nothing is selected.
    var duplicateSummary: (bytes: UInt64, emptiedGroups: Int)? {
        guard resultsMode == .duplicates, !selectedResults.isEmpty else { return nil }
        return DuplicateSelection.summary(groups: duplicateResults, selected: selectedResults)
    }

    /// Add what the pictures answered to what the text search already found.
    func appendPictureHits(_ hits: [SearchHit], reachedLimit: Bool) {
        pictureLimitReached = reachedLimit
        guard !hits.isEmpty else { return }
        let known = Set(results.map(\.id))
        results = SearchSort.sorted(results + hits.filter { !known.contains($0.id) },
                                    by: sortKey, ascending: sortAscending)
        resultsRevision += 1
    }

    var resultCount: Int {
        resultsMode == .duplicates
            ? duplicateResults.reduce(0) { $0 + $1.files.count }
            : results.count
    }

    /// What the block "Filters" holds, as it applies in the current mode: a condition the
    /// mode does not have arrives here already empty.
    var filterState: SearchFilterState {
        let maskIsFilter = searchMode == .byContent || searchMode == .duplicates
        let hasFolders = searchMode == .byName || searchMode == .spotlight
        return SearchFilterState(
            nameMask: maskIsFilter ? pattern : "",
            exclude: excludeSpec,
            minSize: minSizeValue, maxSize: maxSizeValue, unit: sizeUnit,
            type: hasFolders ? fileType : .all,
            datePreset: datePreset, dateFrom: dateFrom, dateTo: dateTo)
    }

    /// Clear the conditions of THIS search. "Skip" stays: it is a standing habit, typed once.
    /// The mask is cleared only where it is a filter — by name it is the question itself.
    func resetFilters() {
        if searchMode == .byContent || searchMode == .duplicates { pattern = "*" }
        minSizeValue = ""
        maxSizeValue = ""
        fileType = .all
        datePreset = .any
    }

    /// The date limits the engines get — whole days, or none.
    private var dateLimits: (from: Date?, to: Date?) {
        SearchDateRange.range(for: datePreset, customFrom: dateFrom, customTo: dateTo)
    }

    /// Why "Find" cannot start, in words — or nil when it can. The button used to do nothing
    /// at all in these cases, which read as a broken button.
    var problemBeforeSearch: String? {
        let contentText = contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        switch searchMode {
        case .byContent:
            return contentText.isEmpty ? L("search.error.needText") : nil
        case .spotlight:
            // An unbounded index query answers with the whole disk, which is nobody's question.
            // Size and date alone are not enough of a question either — a name or some text is.
            return SearchNameMask.matchesEverything(pattern) && contentText.isEmpty
                ? L("search.spot.needQuery") : nil
        case .byName, .duplicates:
            // An empty mask means "everything", the same as "*".
            return nil
        }
    }

    func search() {
        let contentText = contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = problemBeforeSearch {
            errorMessage = problem
            return
        }
        hasSearched = true
        resultsMode = searchMode
        resultsRoot = searchMode == .spotlight && spotlightWholeDisk
            ? "/" : (rootPath as NSString).standardizingPath
        if !(searchMode == .spotlight && spotlightWholeDisk) {
            SearchRecentPlaces.remember(rootPath, in: placesDefaults)
        }
        // What was asked — for the list next to the field. The mask is remembered where it
        // is the question, not where it is one of the filters.
        if searchMode == .byName || searchMode == .spotlight {
            SearchHistory.remember(pattern, kind: .name, in: placesDefaults)
        }
        if searchMode == .byContent || searchMode == .spotlight {
            SearchHistory.remember(contentQuery, kind: .text, in: placesDefaults)
        }
        isSearching = true
        errorMessage = nil
        results = []
        duplicateResults = []
        // The selection belonged to the list that is being thrown away: "Selected: 1" over
        // an empty list, with "Delete" still lit, pointed at a row nobody could see.
        selectedResults = []
        pictureLimitReached = false
        resultsRevision += 1
        currentScanPath = ""
        spotlightTruncated = false
        totalBeforeCap = 0

        // Spotlight is Foundation, notification-driven and main-thread-bound: it must not be
        // pushed onto the background queue the C++ engines need.
        if searchMode == .spotlight {
            startSpotlight()
            return
        }

        let root = rootPath
        let pat = pattern
        let regex = useRegex
        let rec = recursive
        let hidden = includeHidden
        let mode = searchMode
        let dupMode = duplicateMode
        let fType = fileType
        let minBytes = SearchSize.bytes(minSizeValue, unit: sizeUnit)
        let maxBytes = SearchSize.bytes(maxSizeValue, unit: sizeUnit)
        let dates = dateLimits
        let dFrom = dates.from
        let dTo = dates.to
        let excludes = Self.excludeList(excludeSpec)
        let alsoPictures = readPictures
        let matchCase = caseSensitive
        let orderKey = sortKey
        let orderAscending = sortAscending

        // Create a fresh bridge instance for background thread
        let bgService = CoreBridgeService()
        activeSearchService = bgService

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Throttle "scanning …" updates — the callback fires per directory (thousands/sec).
            // lastScanUpdate is touched only on this one background thread, so no lock needed.
            var lastScanUpdate = Date.distantPast
            let onScanDir: (String) -> Void = { dir in
                let now = Date()
                guard now.timeIntervalSince(lastScanUpdate) > 0.08 else { return }
                lastScanUpdate = now
                DispatchQueue.main.async {
                    // Ignore stale updates from a cancelled or superseded search — only the
                    // currently-active search (same bridge instance) may set the status path.
                    guard self?.activeSearchService === bgService else { return }
                    self?.currentScanPath = dir
                }
            }
            // Finds as they are made. Only the search that is still the current one may add
            // to the list: a cancelled walk can go on answering for a moment.
            let onFound: ([SearchHit]) -> Void = { batch in
                DispatchQueue.main.async {
                    guard self?.activeSearchService === bgService else { return }
                    self?.appendFound(batch)
                }
            }
            do {
                switch mode {
                case .spotlight:
                    break   // handled on the main actor above; never reaches this queue

                case .byName:
                    let hits = try bgService.advancedSearch(
                        rootPath: root, pattern: pat, useRegex: regex,
                        recursive: rec, includeHidden: hidden,
                        minSize: minBytes, maxSize: maxBytes,
                        dateFrom: dFrom, dateTo: dTo,
                        typeFilter: fType.rawValue,
                        excludePatterns: excludes,
                        onScanDir: onScanDir,
                        onFound: onFound
                    )
                    let capped = Self.capped(hits)
                    // Put in order here, off the main thread, before the list is shown.
                    let ordered = SearchSort.sorted(capped.hits, by: orderKey, ascending: orderAscending)
                    DispatchQueue.main.async {
                        self?.publish(results: ordered, total: capped.total)
                        self?.isSearching = false
                        self?.currentScanPath = ""
                        self?.calculateFolderSizes()
                    }

                case .byContent:
                    // Find the content text inside the files whose NAME matches the top mask
                    // ("*" / empty = every file). The mask goes down to the engine, which
                    // then does not open the other files at all.
                    let hits = try bgService.searchContent(
                        rootPath: root, pattern: contentText, useRegex: regex, recursive: rec,
                        caseSensitive: matchCase, includeHidden: hidden, nameMask: pat,
                        minSize: minBytes, maxSize: maxBytes, dateFrom: dFrom, dateTo: dTo,
                        excludePatterns: excludes,
                        onScanDir: onScanDir,
                        onFound: onFound
                    )
                    let capped = Self.capped(hits)
                    let ordered = SearchSort.sorted(capped.hits, by: orderKey, ascending: orderAscending)
                    DispatchQueue.main.async {
                        self?.publish(results: ordered, total: capped.total)
                        // Text files answer at once; pictures take a moment each, so they are
                        // added afterwards rather than making the whole search wait for them.
                        if alsoPictures {
                            self?.currentScanPath = ""
                        } else {
                            self?.isSearching = false
                            self?.currentScanPath = ""
                        }
                    }
                    guard alsoPictures else { break }
                    let found = TextRecognitionService.search(
                        contentText, useRegex: regex, under: root, recursive: rec,
                        includeHidden: hidden, excludes: excludes,
                        shouldCancel: { [weak self] in
                            self?.activeSearchService !== bgService
                        },
                        onFile: { path in
                            DispatchQueue.main.async {
                                guard self?.activeSearchService === bgService else { return }
                                self?.currentScanPath = path
                            }
                        })
                    let pictureHits = found.hits.map {
                        SearchHit(path: $0.path, name: ($0.path as NSString).lastPathComponent,
                                  lineNumber: UInt64($0.line), column: nil,
                                  lineContent: $0.text, dateModified: nil, size: nil,
                                  isDirectory: false)
                    }
                    // What the picture reader found passes the same sieve the engine applied
                    // to the text files: the name mask and the size and date limits.
                    let limits = SearchFileLimits(minBytes: minBytes, maxBytes: maxBytes,
                                                  from: dFrom, to: dTo)
                    let keptByName = Self.filterHitsByName(pictureHits, namePattern: pat)
                        .filter { limits.allows(path: $0.path) }
                    DispatchQueue.main.async {
                        self?.appendPictureHits(keptByName, reachedLimit: found.reachedLimit)
                        self?.isSearching = false
                        self?.currentScanPath = ""
                    }

                case .duplicates:
                    let groups = try bgService.findDuplicates(
                        rootPath: root, mode: dupMode.rawValue, recursive: rec,
                        includeHidden: hidden,
                        minSize: minBytes, maxSize: maxBytes, dateFrom: dFrom, dateTo: dTo,
                        excludePatterns: excludes,
                        onScanDir: onScanDir
                    )
                    // The query FILTERS the duplicates by file name ("*" / empty = all):
                    // the user asks "find duplicates of THIS file", not a full dump.
                    let capped = Self.capped(Self.filterDuplicateGroups(groups, namePattern: pat))
                    DispatchQueue.main.async {
                        self?.publish(duplicates: capped.groups, total: capped.total)
                        self?.isSearching = false
                        self?.currentScanPath = ""
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = SearchErrorText.text(for: error)
                    self?.isSearching = false
                    self?.currentScanPath = ""
                }
            }
        }
    }

    /// Ask the index. Everything here runs on the main actor: NSMetadataQuery delivers through
    /// a run loop, and the only heavy part — asking mdutil whether the volume is indexed at
    /// all — is a short hop to a background queue first.
    private func startSpotlight() {
        let spotlightDates = dateLimits
        let (predicate, postFilter) = SpotlightQueryBuilder.predicate(
            mask: pattern,
            contentQuery: contentQuery,
            minBytes: SearchSize.bytes(minSizeValue, unit: sizeUnit),
            maxBytes: SearchSize.bytes(maxSizeValue, unit: sizeUnit),
            dateFrom: spotlightDates.from,
            dateTo: spotlightDates.to)

        guard let predicate else {
            errorMessage = L("search.spot.needQuery")
            isSearching = false
            return
        }

        let scope: SpotlightSearchService.Scope =
            spotlightWholeDisk ? .wholeDisk : .folder(rootPath)
        let probePath = spotlightWholeDisk ? "/" : rootPath
        let mask = pattern
        let type = fileType
        // Spotlight walks inside the index and cannot be told to skip a folder, so the
        // exclusions are applied to what it hands back.
        let excludes = Self.excludeList(excludeSpec)

        // The index answers in a blink, but the status line must never be blank while a
        // search is running — it says WHERE it is asking, as the walking modes say where they
        // are walking.
        currentScanPath = spotlightWholeDisk ? L("search.spot.wholeDisk") : rootPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let indexed = SpotlightIndexProbe.indexingEnabled(forPath: probePath)
            DispatchQueue.main.async {
                guard let self, self.isSearching else { return }
                guard indexed else {
                    // Не «ничего не найдено», а «искать негде» — разница для пользователя
                    // принципиальная: во втором случае надо просто поискать обходом.
                    self.errorMessage = L("search.spot.noIndex")
                    self.isSearching = false
                    return
                }
                let engine = SpotlightSearchService()
                self.spotlight = engine
                engine.start(scope: scope, predicate: predicate, mask: mask,
                             postFilter: postFilter, typeFilter: type) { [weak self] result in
                    guard let self, self.spotlight === engine else { return }
                    self.spotlight = nil
                    self.isSearching = false
                    self.currentScanPath = ""
                    switch result {
                    case .success(let outcome):
                        let kept = excludes.isEmpty ? outcome.hits : outcome.hits.filter {
                            !Self.pathIsExcluded($0.path, patterns: excludes)
                        }
                        let capped = Self.capped(kept)
                        self.publish(results: SearchSort.sorted(capped.hits, by: self.sortKey,
                                                                ascending: self.sortAscending),
                                     total: capped.total)
                        self.spotlightTruncated = outcome.truncated
                        self.calculateFolderSizes()
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Keep only duplicate groups where at least one copy's NAME matches the query.
    /// The whole group is kept (all copies — hash-duplicates can differ in name).
    /// The query follows the mask rules of the whole dialog — see `SearchNameMask`.
    nonisolated static func filterDuplicateGroups(_ groups: [DuplicateGroup],
                                                  namePattern raw: String) -> [DuplicateGroup] {
        guard !SearchNameMask.matchesEverything(raw) else { return groups }
        let matches = SearchNameMask.matcher(raw)
        return groups.filter { group in
            group.files.contains { matches(($0 as NSString).lastPathComponent) }
        }
    }

    /// Keep only the hits whose file NAME matches the top mask — for the hits the engine did
    /// not sieve itself (what the picture reader found).
    nonisolated static func filterHitsByName(_ hits: [SearchHit], namePattern raw: String) -> [SearchHit] {
        guard !SearchNameMask.matchesEverything(raw) else { return hits }
        let matches = SearchNameMask.matcher(raw)
        return hits.filter { matches(($0.path as NSString).lastPathComponent) }
    }

    func cancelSearch() {
        activeSearchService?.cancelSearch()
        activeSearchService = nil
        spotlight?.cancel()
        spotlight = nil
        isSearching = false
        currentScanPath = ""
    }

    func navigateToResult(_ path: String) {
        // Pass the FULL item path: the handler navigates the panel to its folder AND
        // places the cursor on the item. (Stripping to the directory here used to
        // combine with a second strip in the handler — the panel opened the parent
        // of the right folder and the cursor never landed on the file.)
        visitedFromResults = (path as NSString).deletingLastPathComponent
        onNavigateToFile?(path)
    }

    /// Where "Go to" leads when several results are selected: the first of them in list
    /// order. It used to be whichever one a Set happened to hand out first.
    var primarySelection: String? {
        guard !selectedResults.isEmpty else { return nil }
        if resultsMode == .duplicates {
            for group in duplicateResults {
                if let path = group.files.first(where: selectedResults.contains) { return path }
            }
            return nil
        }
        return results.first { selectedResults.contains($0.path) }?.path
    }

    /// The selected finds in the order the list shows them.
    var orderedSelectedPaths: [String] {
        guard !selectedResults.isEmpty else { return [] }
        if resultsMode == .duplicates {
            return duplicateResults.flatMap { $0.files }.filter(selectedResults.contains)
        }
        return results.filter { selectedResults.contains($0.path) }.map(\.path)
    }

    /// Every find, in list order.
    var allResultPaths: [String] {
        resultsMode == .duplicates ? duplicateResults.flatMap { $0.files } : results.map(\.path)
    }

    /// One road for the buttons, the keys and the right-click menu.
    func perform(_ action: SearchResultAction) {
        let paths = orderedSelectedPaths
        switch action {
        case .goTo:
            guard let first = primarySelection else { return }
            navigateToResult(first)
            // Closed so the panel, with the cursor on the find, is in sight.
            onClose?()
        case .quickLook:
            guard !paths.isEmpty else { return }
            onQuickLook?()
        case .edit:
            guard let first = primarySelection else { return }
            onEdit?(first)
        case .copy:
            guard !paths.isEmpty else { return }
            onTransfer?(paths, true)
        case .move:
            guard !paths.isEmpty else { return }
            onTransfer?(paths, false)
        case .delete:
            guard !paths.isEmpty else { return }
            onDeleteFiles?(paths)
        case .toPanel:
            // The whole list, not the selection: in the panel it can be selected any way.
            let all = allResultPaths
            guard !all.isEmpty else { return }
            onShowInPanel?(all, resultsRoot)
            onClose?()
        case .copyPath:
            guard !paths.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        }
    }

    /// The right-click menu of the list — the same actions the buttons and keys perform.
    func resultsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ key: String, _ symbol: String, _ action: SearchResultAction,
                 destructive: Bool = false) {
            menu.addStyledItem(title: L(key), symbolName: symbol, isDestructive: destructive) {
                [weak self] in self?.perform(action)
            }
        }
        add("search.menu.goto", "arrow.right.circle", .goTo)
        add("search.menu.quickLook", "eye", .quickLook)
        add("search.menu.edit", "pencil", .edit)
        menu.addItem(.separator())
        add("search.menu.toPanel", "list.bullet.rectangle", .toPanel)
        menu.addItem(.separator())
        add("search.menu.copy", "doc.on.doc", .copy)
        add("search.menu.move", "arrow.right.doc.on.clipboard", .move)
        add("search.menu.copyPath", "link", .copyPath)
        menu.addItem(.separator())
        add("search.menu.delete", "trash", .delete, destructive: true)
        return menu
    }

    /// Drop items that no longer exist (e.g. after "Удалить") from the results.
    func removeFromResults(_ paths: [String]) {
        let gone = Set(paths)
        results.removeAll { gone.contains($0.path) }
        duplicateResults = duplicateResults.compactMap { group in
            let files = group.files.filter { !gone.contains($0) }
            guard files.count > 1 else { return nil }   // a "group" of one is no duplicate
            return DuplicateGroup(size: group.size, hash: group.hash, files: files)
        }
        selectedResults.subtract(gone)
    }

    var selectedPaths: [String] {
        if resultsMode == .duplicates {
            return Array(selectedResults)
        }
        return results.filter { selectedResults.contains($0.path) }.map(\.path)
    }
}

// MARK: - SwiftUI View

struct AdvancedSearchContentView: View {
    @ObservedObject var vm: AdvancedSearchViewModel
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("search.title"))
            searchForm
                .padding(.horizontal, 20)
                .padding(.top, 8)
            resultsList
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.top, 12)
            statusRow
            buttonBar
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(SearchKeyHandler(vm: vm))
        // When a search finishes, put the "cursor" on the first result so arrow
        // keys work immediately.
        .onChange(of: vm.isSearching) { searching in
            if !searching && vm.resultCount > 0 { focusResults() }
        }
    }

    // MARK: - Status Row + Button Bar (FCXLDialog family style)

    private var statusRow: some View {
        HStack(spacing: 10) {
            if vm.isSearching {
                ProgressView().controlSize(.small)
                if !vm.currentScanPath.isEmpty {
                    Text(vm.currentScanPath)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if vm.resultCount > 0 {
                Text("\(L("search.found")): \(vm.resultCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            // An answer cut short must say so — silence here would read as "that is all there is".
            if vm.totalBeforeCap > 0 {
                Text(String(format: L("search.cappedOf"), vm.totalBeforeCap))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            } else if vm.spotlightTruncated {
                Text(String(format: L("search.spot.truncated"), SpotlightSearchService.defaultCap))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            } else if vm.pictureLimitReached {
                Text(String(format: L("search.readPictures.stopped"),
                            TextRecognitionService.searchFileLimit))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            if let err = vm.errorMessage {
                Text(err).foregroundColor(.red).font(.system(size: 11)).lineLimit(1)
            }
            Spacer()
            if vm.resultsMode == .duplicates, vm.resultCount > 0 {
                // What a duplicates run is for: the spare copies, picked in one move.
                ProgramMenuButton(chipStyle: FCXLChipButtonStyle(compact: true),
                                  makeMenu: duplicatesMenu) {
                    HStack(spacing: 4) {
                        Text(L("search.dup.select"))
                        MenuChevron()
                    }
                }
            }
            if let summary = vm.duplicateSummary {
                if summary.emptiedGroups > 0 {
                    // Selecting every copy in a group is how the last one gets deleted too.
                    Text(String(format: L("search.dup.allSelected"), summary.emptiedGroups))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                if summary.bytes > 0 {
                    Text(String(format: L("search.dup.frees"), ByteText.file(Int64(summary.bytes))))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Text("\(L("search.selected")): \(vm.selectedResults.count)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
    }

    private func duplicatesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addNote(L("search.dup.select.note"))
        for keep in DuplicateKeep.allCases {
            menu.addChoiceItem(title: keep.title) { vm.selectDuplicateExtras(keep: keep) }
        }
        menu.addItem(.separator())
        menu.addChoiceItem(title: L("search.dup.select.none")) { vm.selectedResults = [] }
        return menu
    }

    private var buttonBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                // "Close", not "Cancel": there is nothing here to cancel — the window keeps
                // its results for the next time it opens.
                Button(action: { AdvancedSearchPanelController.shared.close() }) {
                    barLabel(L("button.close"))
                }
                .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))

                barAction(L("search.action.goto"), .goTo, enabled: !vm.selectedResults.isEmpty,
                          tip: L("search.action.goto.tip"))
                // The whole list goes to the panel, so the button needs a list, not a selection.
                barAction(L("search.action.toPanel"), .toPanel, enabled: vm.resultCount > 0,
                          tip: L("search.action.toPanel.tip"))
                barAction(L("search.action.copy"), .copy, enabled: !vm.selectedResults.isEmpty,
                          tip: L("search.action.copy.tip"))
                barAction(L("search.action.move"), .move, enabled: !vm.selectedResults.isEmpty,
                          tip: L("search.action.move.tip"))
                barAction(L("search.action.delete"), .delete, enabled: !vm.selectedResults.isEmpty,
                          tip: L("search.action.delete.tip"))

                Divider().frame(height: 48)
                // Primary: start search; turns into "cancel search" while running.
                Button(action: { vm.isSearching ? vm.cancelSearch() : vm.search() }) {
                    barLabel(vm.isSearching ? L("search.cancel") : L("search.start"))
                }
                .buttonStyle(FCXLDialogPrimaryButtonStyle(
                    accent: accent,
                    textColor: PanelAppearanceSettings.contrastingTextColor(on: accent),
                    fontSize: 13))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// One button of the bar: all of one kind and one width, each behind its divider.
    @ViewBuilder
    private func barAction(_ title: String, _ action: SearchResultAction, enabled: Bool,
                           tip: String) -> some View {
        Divider().frame(height: 48)
        Button(action: { vm.perform(action) }) { barLabel(title) }
            .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
            .disabled(!enabled)
            .help(tip)
    }

    private func barLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 4)
    }

    /// Move keyboard focus into the results list, seeding the selection ("cursor")
    /// with the first result when nothing is selected yet.
    /// Hand the keyboard to the results table and put its cursor on the first row, so the
    /// arrows work the moment a search finishes.
    private func focusResults() {
        vm.focusRequest += 1
    }

    // MARK: - Search Form

    /// Is the block "Filters" open. Remembered: someone who always filters keeps it open,
    /// someone who never does keeps the room for the results.
    @AppStorage("fcxl.search.filtersExpanded") private var filtersExpanded: Bool = false

    /// The form reads top to bottom as a sentence: HOW to search (the tabs), WHAT to look for
    /// (the one field the mode is about), WHERE, and — folded away until wanted — which of
    /// the finds to keep. The mode used to sit in the middle of the form while changing the
    /// rows both above and below itself.
    private var searchForm: some View {
        VStack(spacing: 10) {
            FCXLSegmented(items: SearchMode.allCases, selection: $vm.searchMode,
                          title: { $0.title }, symbol: { $0.symbol },
                          height: 30, prominent: true)
            FCXLFormCard {
                questionRows
                whereRow
                scopeRow
            }
            FCXLFormCard {
                filtersHeader
                if filtersExpanded { filterRows }
            }
        }
    }

    // MARK: What to look for

    @ViewBuilder
    private var questionRows: some View {
        switch vm.searchMode {
        case .byName:
            FCXLFormRow(label: L("search.name")) {
                queryField($vm.pattern, placeholder: L("search.name.placeholder"), focus: true)
                historyButton(.name, into: $vm.pattern)
                option(L("search.regex"), symbol: "asterisk", tip: L("search.regex.tip"),
                       isOn: $vm.useRegex)
            }
            .id(SearchMode.byName)

        case .byContent:
            FCXLFormRow(label: L("search.text")) {
                queryField($vm.contentQuery, placeholder: L("search.contentQuery.placeholder"),
                           focus: true)
                historyButton(.text, into: $vm.contentQuery)
                option(L("search.caseShort"), symbol: "textformat.alt",
                       tip: L("search.caseSensitive"), isOn: $vm.caseSensitive)
                option(L("search.regex"), symbol: "asterisk", tip: L("search.regex.tip"),
                       isOn: $vm.useRegex)
            }
            .id(SearchMode.byContent)
            // Reading the pictures as well. Only in the walking mode: Spotlight answers from an
            // index that was built without ever looking inside a photograph.
            FCXLToggleRow(label: L("search.readPictures"), isOn: $vm.readPictures)
            if vm.readPictures {
                hintRow(String(format: L("search.readPictures.hint"),
                               TextRecognitionService.searchFileLimit))
            }

        case .spotlight:
            // Either field is a question on its own, and both narrow each other: full text
            // inside PDFs, Pages and Word documents is the reason the mode exists.
            FCXLFormRow(label: L("search.name")) {
                queryField($vm.pattern, placeholder: L("search.name.placeholder"), focus: true)
                historyButton(.name, into: $vm.pattern)
            }
            .id(SearchMode.spotlight)
            FCXLFormRow(label: L("search.text")) {
                queryField($vm.contentQuery, placeholder: L("search.contentQuery.placeholder"))
                historyButton(.text, into: $vm.contentQuery)
            }
            hintRow(L("search.spot.hint"))

        case .duplicates:
            FCXLFormRow(label: L("search.dup.what")) {
                FCXLSegmented(items: DuplicateMode.shown, selection: $vm.duplicateMode,
                              title: { $0.label })
            }
        }
    }

    private func queryField(_ text: Binding<String>, placeholder: String,
                            focus: Bool = false) -> some View {
        FCXLDialogTextField(
            text: text,
            placeholder: placeholder,
            focusOnAppear: focus,
            initialSelection: focus ? .all : .none,
            onSubmit: { vm.search() },
            onCancel: { AdvancedSearchPanelController.shared.close() },
            onMoveDown: { focusResults() }
        )
    }

    /// What was asked before, one click away from the field it was asked in. The same small
    /// clock as the places next to "Where" — the two lists are the same kind of help.
    private func historyButton(_ kind: SearchHistory.Kind, into text: Binding<String>) -> some View {
        ProgramMenuButton(chipStyle: FCXLChipButtonStyle(compact: true), makeMenu: {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let queries = SearchHistory.load(kind, from: vm.placesDefaults)
            if queries.isEmpty {
                menu.addNote(L("search.history.empty"))
            } else {
                for query in queries {
                    menu.addChoiceItem(title: query, checked: query == text.wrappedValue) {
                        text.wrappedValue = query
                    }
                }
                menu.addItem(.separator())
                menu.addChoiceItem(title: L("search.history.clear")) {
                    SearchHistory.clear(kind, in: vm.placesDefaults)
                }
            }
            return menu
        }) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                MenuChevron()
            }
            .frame(height: 14)
        }
        .help(L("search.history.tip"))
    }

    /// A switch that belongs to the field next to it — the same control the editor's find bar
    /// uses for "Match case" and "Regex", so the two searches of the program look alike.
    private func option(_ title: String, symbol: String, tip: String,
                        isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            FCXLBarLabel(title: title, symbol: symbol)
        }
        .buttonStyle(FCXLBarButtonStyle(isOn: isOn.wrappedValue))
        .help(tip)
    }

    private func hintRow(_ text: String) -> some View {
        FCXLFormRow {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
            Spacer()
        }
    }

    // MARK: Where

    /// Spotlight asked about the whole Mac does not look at the folder at all.
    private var searchesWholeDisk: Bool {
        vm.searchMode == .spotlight && vm.spotlightWholeDisk
    }

    private var whereRow: some View {
        FCXLFormRow(label: L("search.path")) {
            FCXLDialogTextField(
                text: $vm.rootPath,
                placeholder: "/",
                onSubmit: { vm.search() },
                onCancel: { AdvancedSearchPanelController.shared.close() }
            )
            .opacity(searchesWholeDisk ? 0.35 : 1)
            ProgramMenuButton(chipStyle: FCXLChipButtonStyle(compact: true),
                              makeMenu: placesMenu) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                    MenuChevron()
                }
                .frame(height: 14)
            }
            .help(L("search.places.tip"))
            Button(L("search.browse")) {
                fcxlPresentModal {
                    if let path = DialogService.shared.showFolderPicker(
                        title: L("search.browse"),
                        defaultPath: vm.rootPath
                    ) {
                        vm.rootPath = path
                    }
                }
            }
            .buttonStyle(FCXLChipButtonStyle(compact: true))
        }
        .disabled(searchesWholeDisk)
    }

    /// The places one click away: where the panels stand, home, and where it was searched
    /// before. Retyping a long path is how a search ends up in the wrong folder.
    private func placesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var offered = Set<String>()
        func add(_ title: String, _ path: String, symbol: String) {
            let standard = (path as NSString).standardizingPath
            guard !path.isEmpty, offered.insert(standard).inserted else { return }
            menu.addStyledItem(title: "\(title) — \(Self.shortPath(standard))", symbolName: symbol) {
                vm.rootPath = standard
            }
        }
        add(L("search.places.panel"), vm.panelPath, symbol: "rectangle.lefthalf.inset.filled")
        add(L("search.places.otherPanel"), vm.otherPanelPath,
            symbol: "rectangle.righthalf.inset.filled")
        add(L("search.places.home"), NSHomeDirectory(), symbol: "house")

        let recent = SearchRecentPlaces.load(from: vm.placesDefaults)
            .filter { !offered.contains($0) }
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addNote(L("search.places.recent"))
            for path in recent {
                menu.addStyledItem(title: Self.shortPath(path), symbolName: "clock") {
                    vm.rootPath = path
                }
            }
        }
        return menu
    }

    /// A path as a person reads it: "~" for home, the middle folded when it is long.
    static func shortPath(_ path: String, limit: Int = 60) -> String {
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        guard tilde.count > limit else { return tilde }
        let head = tilde.prefix(limit / 2 - 1)
        let tail = tilde.suffix(limit / 2 - 1)
        return "\(head)…\(tail)"
    }

    /// How far the search reaches from "Where". An index scope always covers everything below
    /// it, and the index has no dot-files: both switches would be lies in Spotlight mode. In
    /// their place, the one choice that IS Spotlight's own — this folder or the whole Mac.
    private var scopeRow: some View {
        FCXLFormRow(showDivider: false) {
            if vm.searchMode == .spotlight {
                inlineSwitch(L("search.spot.wholeDisk"), isOn: $vm.spotlightWholeDisk)
            } else {
                inlineSwitch(L("search.recursive"), isOn: $vm.recursive)
                inlineSwitch(L("search.hidden"), isOn: $vm.includeHidden)
                    .padding(.leading, 18)
            }
            Spacer()
        }
    }

    /// A switch with its label right beside it — for a row that holds two of them. A switch
    /// at the far edge of a wide row is a long way from the words that say what it does.
    private func inlineSwitch(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            FCXLSwitch(isOn: isOn)
            Text(label).font(.system(size: 13))
        }
    }

    // MARK: Which finds to keep

    /// The header of the folded block. Folded, it SAYS what is set inside: a condition out of
    /// sight that silently changes the answer is the worst thing a form can do.
    private var filtersHeader: some View {
        let state = vm.filterState
        let parts = SearchFilterSummary.parts(state)
        return HStack(spacing: 8) {
            Button { filtersExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(filtersExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(L("search.filters"))
                        .font(.system(size: 13))
                    if !filtersExpanded {
                        Text(parts.isEmpty ? L("search.filters.none") : parts.joined(separator: "  ·  "))
                            .font(.system(size: 12))
                            .foregroundStyle(state.isNarrowing ? accent : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if state.isNarrowing {
                Button(L("search.filters.reset")) { vm.resetFilters() }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 14)
    }

    /// The same conditions in every mode, as far as the mode has them: size and date apply
    /// everywhere; the type only where folders can be an answer; the name mask is a filter
    /// where it is not already the question.
    @ViewBuilder
    private var filterRows: some View {
        Divider().padding(.leading, 14)
        if vm.searchMode == .byContent || vm.searchMode == .duplicates {
            FCXLFormRow(label: L("search.filters.mask")) {
                FCXLDialogTextField(
                    text: $vm.pattern,
                    placeholder: L("search.name.placeholder"),
                    onSubmit: { vm.search() },
                    onCancel: { AdvancedSearchPanelController.shared.close() }
                )
            }
        }

        FCXLFormRow(label: L("search.exclude")) {
            FCXLDialogTextField(
                text: $vm.excludeSpec,
                placeholder: "node_modules; .cache; *.tmp",
                onSubmit: { vm.search() },
                onCancel: { AdvancedSearchPanelController.shared.close() }
            )
        }

        FCXLFormRow(label: L("search.size")) {
            Text(L("search.from"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            FCXLDialogTextField(text: $vm.minSizeValue, placeholder: "0",
                                onSubmit: { vm.search() })
                .frame(width: 70)
            Text(L("search.to"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            FCXLDialogTextField(text: $vm.maxSizeValue, placeholder: "∞",
                                onSubmit: { vm.search() })
                .frame(width: 70)
            FCXLDialogMenuPicker(items: Array(SizeUnit.allCases),
                                 selection: $vm.sizeUnit,
                                 title: \.label)
            Spacer()
        }

        if vm.searchMode == .byName || vm.searchMode == .spotlight {
            FCXLFormRow(label: L("search.type")) {
                FCXLSegmented(items: Array(FileTypeOption.allCases), selection: $vm.fileType,
                              title: { $0.label })
                    .frame(width: 300)
                Spacer()
            }
        }

        FCXLFormRow(label: L("search.date"), showDivider: false) {
            FCXLDialogMenuPicker(items: Array(SearchDatePreset.allCases),
                                 selection: $vm.datePreset,
                                 title: \.title)
            if vm.datePreset == .custom {
                DatePicker("", selection: Binding(
                    get: { vm.dateFrom ?? Date() },
                    set: { vm.dateFrom = $0 }
                ), displayedComponents: .date).labelsHidden().frame(width: 120)
                Text("\u{2014}").foregroundStyle(.secondary)
                DatePicker("", selection: Binding(
                    get: { vm.dateTo ?? Date() },
                    set: { vm.dateTo = $0 }
                ), displayedComponents: .date).labelsHidden().frame(width: 120)
            }
            Spacer()
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        SearchResultsTable(
            makeRows: { [vm] in
                SearchResultRows.build(mode: vm.resultsMode,
                                       results: vm.results,
                                       duplicates: vm.duplicateResults)
            },
            revision: vm.resultsRevision,
            selection: $vm.selectedResults,
            folderSizes: vm.folderSizes,
            accent: PanelAppearanceSettings.nsColor(from: accentColorHex, fallback: .systemPurple),
            focusRequest: vm.focusRequest,
            // Duplicate groups keep the order the finder gave them: the most wasteful first.
            sort: vm.resultsMode == .duplicates ? nil : (vm.sortKey, vm.sortAscending),
            root: vm.resultsRoot,
            onSort: { key, ascending in vm.setSort(key: key, ascending: ascending) },
            onActivate: { path in
                vm.navigateToResult(path)
                AdvancedSearchPanelController.shared.close()
            },
            onAction: { vm.perform($0) },
            makeMenu: { vm.resultsMenu() })
        .frame(maxHeight: .infinity)
        .overlay {
            // An empty box said nothing: not asked yet, still looking, or nothing there.
            if vm.resultCount == 0, !vm.isSearching {
                Text(vm.hasSearched && vm.errorMessage == nil
                     ? L("search.empty.none") : L("search.empty.start"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .allowsHitTesting(false)
            }
        }
    }

}

// MARK: - Key Handler for Search Window

/// Intercepts keyboard shortcuts so they work inside the search window
/// instead of going to the main file panel.
struct SearchKeyHandler: NSViewRepresentable {
    let vm: AdvancedSearchViewModel

    func makeNSView(context: Context) -> SearchKeyView {
        let view = SearchKeyView()
        view.vm = vm
        return view
    }

    func updateNSView(_ nsView: SearchKeyView, context: Context) {
        nsView.vm = vm
    }

    class SearchKeyView: NSView {
        weak var vm: AdvancedSearchViewModel?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let cmd = event.modifierFlags.contains(.command)

            // Cmd+A — select all results
            if cmd && event.charactersIgnoringModifiers == "a" {
                guard let vm else { return }
                if vm.resultsMode == .duplicates {
                    for group in vm.duplicateResults {
                        for file in group.files {
                            vm.selectedResults.insert(file)
                        }
                    }
                } else {
                    vm.selectedResults = Set(vm.results.map(\.path))
                }
                return
            }

            // Cmd+D — deselect all
            if cmd && event.charactersIgnoringModifiers == "d" {
                vm?.selectedResults.removeAll()
                return
            }

            // Cmd+I — invert selection
            if cmd && event.charactersIgnoringModifiers == "i" {
                guard let vm else { return }
                let allPaths = Set(vm.results.map(\.path))
                vm.selectedResults = allPaths.subtracting(vm.selectedResults)
                return
            }

            // Enter — navigate to selected result (and close so the panel is visible)
            if event.keyCode == 36 {
                vm?.perform(.goTo)
                return
            }

            // Escape — close search
            if event.keyCode == 53 {
                AdvancedSearchPanelController.shared.close()
                return
            }

            super.keyDown(with: event)
        }
    }
}

// MARK: - Search Window (proper key window)

private class SearchWindow: NSWindow, QLPreviewPanelDataSource, QLPreviewPanelDelegate,
                             SearchResultsHosting {
    weak var vm: AdvancedSearchViewModel?
    /// The list of finds — so the arrow keys keep moving through it while the preview is up.
    weak var resultsTable: NSTableView?
    private var selectionWatch: AnyCancellable?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ESC closes the search window. Called by AppKit responder chain on Escape key.
    override func cancelOperation(_ sender: Any?) {
        AdvancedSearchPanelController.shared.close()
    }

    /// Also intercept ESC via keyDown in case cancelOperation doesn't fire
    /// (e.g. when a text field has focus and consumes cancelOperation).
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            AdvancedSearchPanelController.shared.close()
            return
        }
        super.keyDown(with: event)
    }

    /// While this window is in front, the F-keys are about the finds. They are also key
    /// equivalents of the main menu ("Delete F8"), and AppKit offers a key to the key window
    /// before the menu — so it is taken here. Left alone, F8 pressed over the list of finds
    /// reached the menu and deleted whatever was selected in the panel BEHIND this window.
    /// The key is swallowed even when no find is selected, for the same reason.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let action = SearchKeys.action(
               keyCode: event.keyCode,
               modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)) {
            vm?.perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Quick look of the selected finds

    /// The system preview, floating over this window: the selected finds, in list order.
    /// The viewers of the main window follow the panel's cursor, and the finds are not in
    /// the panel — so the search window shows its own.
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var previewPaths: [String] { vm?.orderedSelectedPaths ?? [] }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        // The preview follows the selection. On the next turn of the run loop: the
        // publisher fires BEFORE the value changes.
        selectionWatch = vm?.$selectedResults
            .receive(on: RunLoop.main)
            .sink { [weak panel] _ in panel?.reloadData() }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        selectionWatch = nil
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewPaths.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let paths = previewPaths
        guard paths.indices.contains(index) else { return nil }
        return NSURL(fileURLWithPath: paths[index])
    }

    /// Up and down move through the list of finds while the preview has the keyboard.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126,
              let table = resultsTable else { return false }
        table.keyDown(with: event)
        return true
    }
}

// MARK: - NSPanel Controller

@MainActor
final class AdvancedSearchPanelController {
    /// Результатам нужно место: при 580 точках список находок был узкой полосой под фильтрами.
    nonisolated static let preferredSize = NSSize(width: 760, height: 850)

    /// Не выше видимой части экрана — на низком экране нижние кнопки иначе ушли бы за край.
    nonisolated static func initialSize(visibleHeight: CGFloat?) -> NSSize {
        guard let visibleHeight else { return preferredSize }
        let height = max(580, min(preferredSize.height, visibleHeight - 40))
        return NSSize(width: preferredSize.width, height: height)
    }

    /// Where the window will search when it opens: the folder the active panel shows.
    ///
    /// The field used to keep the previous search's folder, so F9 in a new place searched the
    /// old one. One case keeps the old root on purpose: the panel stands exactly where
    /// "Go to" took it. The window is then being reopened to walk the same results or to
    /// refine the same search, and pointing it at the subfolder of one find would quietly
    /// narrow that search.
    nonisolated static func rootOnOpen(panelPath: String,
                                       previousRoot: String?,
                                       visitedFromResults: String?) -> String {
        guard let previousRoot, !previousRoot.isEmpty else { return panelPath }
        if let visited = visitedFromResults,
           (visited as NSString).standardizingPath == (panelPath as NSString).standardizingPath {
            return previousRoot
        }
        return panelPath
    }

    private var window: NSWindow?
    private var vm: AdvancedSearchViewModel?

    static let shared = AdvancedSearchPanelController()

    func show(rootPath: String,
              otherPanelPath: String = "",
              onNavigate: @escaping (String) -> Void,
              onTransfer: @escaping ([String], Bool) -> Void,
              onEdit: @escaping (String) -> Void,
              onShowInPanel: @escaping ([String], String) -> Void,
              onDelete: @escaping ([String]) -> Void) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Reuse the previous session's model: the search "history" (pattern, filters,
        // mode, results, selection) survives close/reopen and lives until the next search
        // replaces it. WHERE to search does not: it follows the panel — see rootOnOpen.
        let viewModel = vm ?? AdvancedSearchViewModel()
        let root = Self.rootOnOpen(panelPath: rootPath,
                                   previousRoot: vm == nil ? nil : viewModel.rootPath,
                                   visitedFromResults: viewModel.visitedFromResults)
        if root != viewModel.rootPath {
            viewModel.rootPath = root
            viewModel.visitedFromResults = nil
        }
        viewModel.panelPath = rootPath
        viewModel.otherPanelPath = otherPanelPath
        // Callbacks always point at the CURRENT panels, so refresh them every open.
        viewModel.onNavigateToFile = onNavigate
        viewModel.onTransfer = onTransfer
        viewModel.onEdit = onEdit
        viewModel.onShowInPanel = onShowInPanel
        viewModel.onDeleteFiles = onDelete
        viewModel.onClose = { [weak self] in self?.close() }
        self.vm = viewModel

        let content = AdvancedSearchContentView(vm: viewModel)
        let hostingView = NSHostingView(rootView: content.focusEffectDisabled())

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height
        let w = SearchWindow(contentRect: NSRect(origin: .zero,
                                                 size: Self.initialSize(visibleHeight: visible)),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        // CRITICAL: NSWindow defaults to isReleasedWhenClosed = true — close() would
        // release the window while this controller still holds a strong reference,
        // and the second release crashes the app (caught by NSZombie: SearchWindow).
        w.isReleasedWhenClosed = false
        w.title = L("search.title")
        // FCXLDialog family chrome: clean titlebar, no window buttons, movable by
        // background; the in-content header + bottom button bar own the window.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isMovableByWindowBackground = true
        w.vm = viewModel
        viewModel.onQuickLook = { [weak w] in w?.toggleQuickLook() }
        w.contentView = hostingView
        // Warm-up layout only when the kept history is small: with thousands of
        // results a synchronous full layout stalls the open for seconds.
        let historySize = viewModel.results.count
            + viewModel.duplicateResults.reduce(0) { $0 + $1.files.count }
        if historySize < 300 {
            w.contentView?.layoutSubtreeIfNeeded()
        }
        SettingsWindowAnimator.centerOnScreen(w)
        SettingsWindowAnimator.growOpen(w)
        w.makeKeyAndOrderFront(nil)
        self.window = w
    }

    func close() {
        vm?.cancelSearch()
        // The preview belonged to this window's finds.
        if QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(),
           preview.isVisible, preview.dataSource === window {
            preview.orderOut(nil)
        }
        if let window {
            // Same shrink-and-fade as the dialogs (stopModal inside is a no-op here).
            SettingsWindowAnimator.closeWithShrink(window)
        }
        window = nil
        // `vm` is intentionally KEPT: it holds the search history (query, filters,
        // results, selection) shown again on the next open, until a new search runs.
    }

    /// Purge deleted files from the live results (called after "Удалить" completes).
    func removeFromResults(_ paths: [String]) {
        vm?.removeFromResults(paths)
    }
}
