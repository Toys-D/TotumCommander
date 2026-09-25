import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search Mode

enum SearchMode: String, CaseIterable {
    case byName = "search.mode.name"
    /// Ask macOS's index instead of walking the disk — a separate mode rather than a switch on
    /// "by name", because it answers a different question: it is instant across a whole disk
    /// and can read inside PDFs, but it knows nothing about hidden files, package interiors or
    /// unindexed volumes, and has no regular expressions. A hidden switch that quietly changed
    /// what the other controls mean would be exactly the kind of surprise this app avoids.
    case spotlight = "search.mode.spotlight"
    case byContent = "search.mode.content"
    case duplicates = "search.mode.duplicates"
}

enum DuplicateMode: Int, CaseIterable {
    case byName = 0
    case bySize = 1
    case byHash = 2

    var label: String {
        switch self {
        case .byName: return L("search.dup.byName")
        case .bySize: return L("search.dup.bySize")
        case .byHash: return L("search.dup.byHash")
        }
    }
}

enum SizeUnit: Int64, CaseIterable {
    case bytes = 1
    case kb = 1024
    case mb = 1_048_576
    case gb = 1_073_741_824

    var label: String {
        switch self {
        case .bytes: return "B"
        case .kb: return "KB"
        case .mb: return "MB"
        case .gb: return "GB"
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
    @Published var sizeUnit: SizeUnit = .kb

    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var useDateFilter: Bool = false

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
    var onCopyFiles: (([String], String) -> Void)?
    var onDeleteFiles: (([String]) -> Void)?

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

    /// Add what the pictures answered to what the text search already found.
    func appendPictureHits(_ hits: [SearchHit], reachedLimit: Bool) {
        pictureLimitReached = reachedLimit
        guard !hits.isEmpty else { return }
        let known = Set(results.map(\.id))
        results.append(contentsOf: hits.filter { !known.contains($0.id) })
        resultsRevision += 1
    }

    var resultCount: Int {
        searchMode == .duplicates
            ? duplicateResults.reduce(0) { $0 + $1.files.count }
            : results.count
    }

    func search() {
        let contentText = contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // "By content" requires the content text; other modes require the name mask.
        if searchMode == .byContent {
            guard !contentText.isEmpty else { return }
        } else if searchMode == .spotlight {
            // An unbounded index query answers with the whole disk, which is nobody's question.
            // Size and date alone are not enough of a question either — a name or some text is.
            let mask = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (!mask.isEmpty && mask != "*") || !contentText.isEmpty else {
                errorMessage = L("search.spot.needQuery")
                return
            }
        } else {
            guard !pattern.isEmpty || searchMode == .duplicates else { return }
        }
        isSearching = true
        errorMessage = nil
        results = []
        duplicateResults = []
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
        let unit = sizeUnit.rawValue
        let minS = UInt64(minSizeValue) ?? 0
        let maxS = UInt64(maxSizeValue) ?? 0
        let dFrom = useDateFilter ? dateFrom : nil
        let dTo = useDateFilter ? dateTo : nil
        let excludes = Self.excludeList(excludeSpec)
        let alsoPictures = readPictures

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
            do {
                switch mode {
                case .spotlight:
                    break   // handled on the main actor above; never reaches this queue

                case .byName:
                    let hits = try bgService.advancedSearch(
                        rootPath: root, pattern: pat, useRegex: regex,
                        recursive: rec, includeHidden: hidden,
                        minSize: minS * UInt64(unit), maxSize: maxS > 0 ? maxS * UInt64(unit) : 0,
                        dateFrom: dFrom, dateTo: dTo,
                        typeFilter: fType.rawValue,
                        excludePatterns: excludes,
                        onScanDir: onScanDir
                    )
                    let capped = Self.capped(hits)
                    DispatchQueue.main.async {
                        self?.publish(results: capped.hits, total: capped.total)
                        self?.isSearching = false
                        self?.currentScanPath = ""
                        self?.calculateFolderSizes()
                    }

                case .byContent:
                    // Find the content text inside files, then keep only those whose NAME
                    // matches the top mask ("*" / empty = every file).
                    let hits = try bgService.searchContent(
                        rootPath: root, pattern: contentText, useRegex: regex, recursive: rec,
                        excludePatterns: excludes,
                        onScanDir: onScanDir
                    )
                    let capped = Self.capped(Self.filterHitsByName(hits, namePattern: pat))
                    DispatchQueue.main.async {
                        self?.publish(results: capped.hits, total: capped.total)
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
                    let keptByName = Self.filterHitsByName(pictureHits, namePattern: pat)
                    DispatchQueue.main.async {
                        self?.appendPictureHits(keptByName, reachedLimit: found.reachedLimit)
                        self?.isSearching = false
                        self?.currentScanPath = ""
                    }

                case .duplicates:
                    let groups = try bgService.findDuplicates(
                        rootPath: root, mode: dupMode.rawValue, recursive: rec,
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
                    self?.errorMessage = error.localizedDescription
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
        let (predicate, postFilter) = SpotlightQueryBuilder.predicate(
            mask: pattern,
            contentQuery: contentQuery,
            minBytes: (UInt64(minSizeValue) ?? 0) * UInt64(sizeUnit.rawValue),
            maxBytes: (UInt64(maxSizeValue) ?? 0) * UInt64(sizeUnit.rawValue),
            dateFrom: useDateFilter ? dateFrom : nil,
            dateTo: useDateFilter ? dateTo : nil)

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
                        self.publish(results: capped.hits, total: capped.total)
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
    /// "*", "" → no filtering. Without wildcards the query is a substring match.
    nonisolated static func filterDuplicateGroups(_ groups: [DuplicateGroup],
                                                  namePattern raw: String) -> [DuplicateGroup] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "*" else { return groups }
        let wildcard = (trimmed.contains("*") || trimmed.contains("?"))
            ? trimmed
            : "*\(trimmed)*"
        let predicate = NSPredicate(format: "SELF LIKE[cd] %@", wildcard)
        return groups.filter { group in
            group.files.contains { predicate.evaluate(with: ($0 as NSString).lastPathComponent) }
        }
    }

    /// Keep only content-search hits whose file NAME matches the top mask ("*"/empty = all).
    /// Substring match unless the mask already has wildcards.
    nonisolated static func filterHitsByName(_ hits: [SearchHit], namePattern raw: String) -> [SearchHit] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "*" else { return hits }
        let wildcard = (trimmed.contains("*") || trimmed.contains("?")) ? trimmed : "*\(trimmed)*"
        let predicate = NSPredicate(format: "SELF LIKE[cd] %@", wildcard)
        return hits.filter { predicate.evaluate(with: ($0.path as NSString).lastPathComponent) }
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
        onNavigateToFile?(path)
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
        if searchMode == .duplicates {
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
                Text(L("search.spot.truncated"))
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
            Text("\(L("search.selected")): \(vm.selectedResults.count)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var buttonBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button(action: { AdvancedSearchPanelController.shared.close() }) {
                    barLabel(L("button.cancel"))
                }
                .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))

                Divider().frame(height: 48)
                Button(action: {
                    if let first = vm.selectedResults.first {
                        vm.navigateToResult(first)
                        // Close so the panel (with the cursor on the item) is visible.
                        AdvancedSearchPanelController.shared.close()
                    }
                }) { barLabel(L("search.action.goto")) }
                .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                .disabled(vm.selectedResults.isEmpty)

                Divider().frame(height: 48)
                Button(action: {
                    let paths = vm.selectedPaths
                    fcxlPresentModal { [weak vm] in
                        if let dest = DialogService.shared.showFolderPicker(
                            title: L("search.action.copy"), defaultPath: nil
                        ) {
                            vm?.onCopyFiles?(paths, dest)
                        }
                    }
                }) { barLabel(L("search.action.copy")) }
                .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                .disabled(vm.selectedResults.isEmpty)

                Divider().frame(height: 48)
                Button(action: { vm.onDeleteFiles?(vm.selectedPaths) }) {
                    barLabel(L("search.action.delete"))
                }
                .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                .disabled(vm.selectedResults.isEmpty)

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

    private var searchForm: some View {
        FCXLFormCard {
            FCXLFormRow(label: L("search.pattern")) {
                FCXLDialogTextField(
                    text: $vm.pattern,
                    placeholder: "*.txt",
                    focusOnAppear: true,
                    initialSelection: .all,
                    onSubmit: { vm.search() },
                    onCancel: { AdvancedSearchPanelController.shared.close() },
                    onMoveDown: { focusResults() }
                )
                // Spotlight has no regular expressions at any level — the switch is hidden
                // rather than greyed, because a control that is there but does nothing is
                // worse than one that is honestly absent.
                if vm.searchMode != .spotlight {
                    Text(L("search.regex"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    FCXLSwitch(isOn: $vm.useRegex)
                }
            }

            FCXLFormRow(label: L("search.path")) {
                FCXLDialogTextField(
                    text: $vm.rootPath,
                    placeholder: "/",
                    onSubmit: { vm.search() },
                    onCancel: { AdvancedSearchPanelController.shared.close() }
                )
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

            FCXLFormRow(label: L("search.exclude")) {
                FCXLDialogTextField(
                    text: $vm.excludeSpec,
                    placeholder: "node_modules; .cache; *.tmp",
                    onSubmit: { vm.search() },
                    onCancel: { AdvancedSearchPanelController.shared.close() }
                )
            }

            // An index scope always covers everything below it, and the index has no
            // dot-files: both switches would be lies in Spotlight mode. In their place, the
            // one choice that IS Spotlight's own — this folder or the whole Mac.
            if vm.searchMode == .spotlight {
                FCXLToggleRow(label: L("search.spot.wholeDisk"), isOn: $vm.spotlightWholeDisk)
            } else {
                FCXLToggleRow(label: L("search.recursive"), isOn: $vm.recursive)
                FCXLToggleRow(label: L("search.hidden"), isOn: $vm.includeHidden)
            }

            FCXLFormRow(label: L("search.modeLabel"), showDivider: true) {
                Picker("", selection: $vm.searchMode) {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
                        Text(L(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if vm.searchMode == .spotlight {
                FCXLFormRow(showDivider: false) {
                    Text(L("search.spot.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }

            // "By content" mode: a separate field for the text to find INSIDE the files that
            // match the name mask above.
            // Spotlight gets the same field: full text inside PDFs, Pages and Word documents
            // is the reason the mode exists — the walking engine can never match those.
            if vm.searchMode == .byContent || vm.searchMode == .spotlight {
                FCXLFormRow(label: L("search.contentQuery"), showDivider: false) {
                    FCXLDialogTextField(
                        text: $vm.contentQuery,
                        placeholder: L("search.contentQuery.placeholder"),
                        focusOnAppear: true,
                        onSubmit: { vm.search() },
                        onCancel: { AdvancedSearchPanelController.shared.close() }
                    )
                }
            }

            // Reading the pictures as well. Only in the walking mode: Spotlight answers from an
            // index that was built without ever looking inside a photograph.
            if vm.searchMode == .byContent {
                FCXLToggleRow(label: L("search.readPictures"), isOn: $vm.readPictures,
                              showDivider: false)
                if vm.readPictures {
                    FCXLFormRow(showDivider: false) {
                        Text(String(format: L("search.readPictures.hint"),
                                    TextRecognitionService.searchFileLimit))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
            }

            if vm.searchMode == .duplicates {
                FCXLFormRow(showDivider: false) {
                    Picker("", selection: $vm.duplicateMode) {
                        ForEach(DuplicateMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            // Size, type and dates work in Spotlight too — as predicates, so a whole-disk
            // query is narrowed inside the index rather than after it.
            if vm.searchMode == .byName || vm.searchMode == .spotlight {
                filtersSection
            }
        }
    }

    @ViewBuilder
    private var filtersSection: some View {
        FCXLFormRow(label: L("search.size")) {
            Text(L("search.from"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            FCXLDialogTextField(text: $vm.minSizeValue)
                .frame(width: 70)
            Text(L("search.to"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            FCXLDialogTextField(text: $vm.maxSizeValue)
                .frame(width: 70)
            FCXLDialogMenuPicker(items: Array(SizeUnit.allCases),
                                 selection: $vm.sizeUnit,
                                 title: \.label)
            Spacer()
        }

        FCXLFormRow(label: L("search.type")) {
            Picker("", selection: $vm.fileType) {
                ForEach(FileTypeOption.allCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        FCXLFormRow(label: L("search.date"), showDivider: false) {
            FCXLSwitch(isOn: $vm.useDateFilter)
            if vm.useDateFilter {
                DatePicker("", selection: Binding(
                    get: { vm.dateFrom ?? Date.distantPast },
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
            rows: SearchResultRows.build(mode: vm.searchMode,
                                         results: vm.results,
                                         duplicates: vm.duplicateResults),
            revision: vm.resultsRevision,
            selection: $vm.selectedResults,
            folderSizes: vm.folderSizes,
            accent: PanelAppearanceSettings.nsColor(from: accentColorHex, fallback: .systemPurple),
            focusRequest: vm.focusRequest,
            onActivate: { path in
                vm.navigateToResult(path)
                AdvancedSearchPanelController.shared.close()
            })
        .frame(maxHeight: .infinity)
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
                if vm.searchMode == .duplicates {
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
                if let first = vm?.selectedResults.first {
                    vm?.navigateToResult(first)
                    AdvancedSearchPanelController.shared.close()
                }
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

private class SearchWindow: NSWindow {
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
}

// MARK: - NSPanel Controller

@MainActor
final class AdvancedSearchPanelController {
    private var window: NSWindow?
    private var vm: AdvancedSearchViewModel?

    static let shared = AdvancedSearchPanelController()

    func show(rootPath: String,
              onNavigate: @escaping (String) -> Void,
              onCopy: @escaping ([String], String) -> Void,
              onDelete: @escaping ([String]) -> Void) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Reuse the previous session's model: the search "history" (pattern, filters,
        // mode, results, selection — and the search root) survives close/reopen and
        // lives until the next search replaces it. A fresh model is seeded with the
        // active panel's path only on the very first open.
        let viewModel: AdvancedSearchViewModel
        if let existing = vm {
            viewModel = existing
        } else {
            viewModel = AdvancedSearchViewModel()
            viewModel.rootPath = rootPath
        }
        // Callbacks always point at the CURRENT panels, so refresh them every open.
        viewModel.onNavigateToFile = onNavigate
        viewModel.onCopyFiles = onCopy
        viewModel.onDeleteFiles = onDelete
        self.vm = viewModel

        let content = AdvancedSearchContentView(vm: viewModel)
        let hostingView = NSHostingView(rootView: content)

        let w = SearchWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
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
