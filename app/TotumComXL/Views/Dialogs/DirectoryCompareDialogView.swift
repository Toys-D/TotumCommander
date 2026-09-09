import AppKit
import SwiftUI
import FCXLBridgeObjC

/// How a path differs between the two folders. Raw values are what the C++ core reports.
enum CompareStatus: String {
    case same, different, leftOnly, rightOnly

    var titleKey: String {
        switch self {
        case .same:      return "compare.status.same"
        case .different: return "compare.status.different"
        case .leftOnly:  return "compare.status.leftOnly"
        case .rightOnly: return "compare.status.rightOnly"
        }
    }
}

/// Which way a row will be copied. `none` means "leave this one alone".
enum SyncDirection: String {
    case toRight, toLeft, moveRight, moveLeft, none, deleteLeft, deleteRight

    var symbol: String {
        switch self {
        case .toRight:     return "arrow.right"
        case .toLeft:      return "arrow.left"
        case .moveRight:   return "arrow.right"
        case .moveLeft:    return "arrow.left"
        case .none:        return "equal"
        case .deleteLeft:  return "trash"
        case .deleteRight: return "trash"
        }
    }

    var tint: Color {
        switch self {
        case .toRight:                  return .green
        case .toLeft:                   return .blue
        // Moving both writes and removes, so it gets its own colour — mistaking it for a plain
        // copy would cost the user the original.
        case .moveRight, .moveLeft:     return .orange
        case .none:                     return .secondary
        case .deleteLeft, .deleteRight: return .red
        }
    }

    /// A move is drawn as the arrow PLUS a small bin: the arrow says where the file goes, the bin
    /// says it will not stay behind.
    var showsTrashBadge: Bool { self == .moveRight || self == .moveLeft }

}

struct CompareEntry: Identifiable {
    let relativePath: String
    var status: CompareStatus
    let isDirectory: Bool
    /// nil when the file is missing on that side.
    var leftSize: UInt64?
    var rightSize: UInt64?
    var leftDate: Date?
    var rightDate: Date?
    var id: String { relativePath }
    var name: String { (relativePath as NSString).lastPathComponent }

    /// What the tool proposes before the user overrides it: a file that exists on one side only
    /// travels to the other, a file that differs goes from whichever copy is newer, and identical
    /// files are left alone. Same rule Total Commander applies.
    var defaultDirection: SyncDirection {
        guard !isDirectory else { return .none }
        switch status {
        case .leftOnly:  return .toRight
        case .rightOnly: return .toLeft
        case .same:      return .none
        case .different:
            guard let l = leftDate, let r = rightDate, l != r else { return .none }
            return l > r ? .toRight : .toLeft
        }
    }
}

/// What the window hands back: the files to copy each way. `nil` means the user just closed it.
struct DirectorySyncPlan {
    let toRight: [String]        // relative paths, copied left → right
    let toLeft: [String]         // relative paths, copied right → left
    let moveRight: [String]      // relative paths, MOVED left → right (source removed)
    let moveLeft: [String]       // relative paths, MOVED right → left (source removed)
    let deleteLeft: [String]     // relative paths, moved to Trash on the LEFT side
    let deleteRight: [String]    // relative paths, moved to Trash on the RIGHT side
    let leftRoot: String
    let rightRoot: String

    var copies: Int { toRight.count + toLeft.count }
    var moves: Int { moveRight.count + moveLeft.count }
    var deletions: Int { deleteLeft.count + deleteRight.count }
    var total: Int { copies + moves + deletions }
}

/// Directory comparison and synchronisation, modelled on Total Commander's Synchronize dirs: what
/// differs between the two panels' folders, which way each file should travel, and a summary before
/// anything is copied.
///
/// The copying is NOT done here — the window returns a plan and the main controller runs it through
/// the ordinary FileOperationsService, so transfers keep the app's usual progress, conflict handling
/// and queue instead of growing a second copy implementation.
struct DirectoryCompareDialogView: View {
    let session: FCXLDialogSession<DirectorySyncPlan>
    let leftRoot: String
    let rightRoot: String

    private enum Filter: String, CaseIterable, Identifiable {
        case differences, leftOnly, rightOnly, same, all
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .differences: return "compare.filter.differences"
            case .leftOnly:    return "compare.status.leftOnly"
            case .rightOnly:   return "compare.status.rightOnly"
            case .same:        return "compare.status.same"
            case .all:         return "compare.filter.all"
            }
        }
        var systemImage: String {
            switch self {
            case .differences: return "notequal"
            case .leftOnly:    return "arrow.right"
            case .rightOnly:   return "arrow.left"
            case .same:        return "equal"
            case .all:         return "list.bullet"
            }
        }
    }

    @State private var entries: [CompareEntry] = []
    /// Per-row overrides. A row not in here uses its `defaultDirection`.
    @State private var overrides: [String: SyncDirection] = [:]
    @State private var filter: Filter = .differences
    @State private var byContent = false
    @State private var ignoreDate = false
    @State private var mask = ""
    @State private var excludeMask = ""
    /// Rows the user hid by hand — they take no part in the comparison or the plan.
    @State private var excluded: Set<String> = []
    @State private var running = true
    @State private var failed = false
    @State private var showHelp = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""

    // MARK: - Derived

    private func direction(_ e: CompareEntry) -> SyncDirection {
        overrides[e.relativePath] ?? e.defaultDirection
    }

    /// The states a click walks through for THIS row. Deleting is included at the user's request,
    /// but only on a side that actually has the file — offering "delete on the right" for something
    /// that only exists on the left would be a dead state.
    private func cycle(for e: CompareEntry) -> [SyncDirection] {
        var states: [SyncDirection] = []
        // A copy needs a SOURCE. Offering "→" for a file that exists only on the right showed a
        // green arrow that promised an action and then silently did nothing at sync time.
        if e.leftSize != nil { states.append(.toRight) }
        if e.rightSize != nil { states.append(.toLeft) }
        if e.leftSize != nil { states.append(.moveRight) }
        if e.rightSize != nil { states.append(.moveLeft) }
        if e.leftSize != nil { states.append(.deleteLeft) }
        if e.rightSize != nil { states.append(.deleteRight) }
        states.append(.none)
        return states
    }

    private func advance(_ e: CompareEntry) {
        let states = cycle(for: e)
        let current = direction(e)
        let index = states.firstIndex(of: current) ?? states.count - 1
        overrides[e.relativePath] = states[(index + 1) % states.count]
    }

    /// Entries after the mask and after deciding what "same" means for the current options.
    ///
    /// The core only ever compares SIZE unless it is asked to read the files, so on its own it calls
    /// two files identical whenever their byte counts match — and plenty of edits keep the size
    /// exactly (2025 → 2026 in a text file, one pixel in an uncompressed image). The date is the
    /// cheap second signal, so it is applied here, where both sides' timestamps are already known.
    private var adjusted: [CompareEntry] {
        let pattern = mask.trimmingCharacters(in: .whitespaces)
        let skip = excludeMask.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return entries.compactMap { e in
            if excluded.contains(e.relativePath) { return nil }
            if !pattern.isEmpty, !e.isDirectory, !matches(e.name, pattern) { return nil }
            if !e.isDirectory, skip.contains(where: { matches(e.name, $0) }) { return nil }
            var e = e
            e.status = effectiveStatus(e)
            return e
        }
    }

    /// Timestamps only survive a copy to within a couple of seconds on FAT/exFAT volumes — the very
    /// ones people compare a Mac folder against. Anything inside that window is the same instant.
    private static let dateTolerance: TimeInterval = 2

    private func effectiveStatus(_ e: CompareEntry) -> CompareStatus {
        // Only files present on BOTH sides can be re-judged; leftOnly/rightOnly are facts.
        guard !e.isDirectory, e.status == .same || e.status == .different,
              let ls = e.leftSize, let rs = e.rightSize else { return e.status }

        // Reading the files is the only conclusive answer — take the core's verdict as it stands.
        if byContent { return e.status }

        if ls != rs { return .different }
        if ignoreDate { return .same }          // sizes match and dates are not to be considered
        guard let ld = e.leftDate, let rd = e.rightDate else { return .same }
        return abs(ld.timeIntervalSince(rd)) <= Self.dateTolerance ? .same : .different
    }

    private var visible: [CompareEntry] {
        adjusted.filter { e in
            switch filter {
            case .all:         return true
            case .differences: return e.status != .same
            case .leftOnly:    return e.status == .leftOnly
            case .rightOnly:   return e.status == .rightOnly
            case .same:        return e.status == .same
            }
        }
    }

    private func count(_ status: CompareStatus) -> Int {
        adjusted.filter { $0.status == status && !$0.isDirectory }.count
    }

    private var plan: DirectorySyncPlan {
        var right: [String] = [], left: [String] = []
        var movR: [String] = [], movL: [String] = []
        var delL: [String] = [], delR: [String] = []
        for e in adjusted where !e.isDirectory {
            switch direction(e) {
            case .toRight:     if e.leftSize != nil { right.append(e.relativePath) }
            case .toLeft:      if e.rightSize != nil { left.append(e.relativePath) }
            case .moveRight:   if e.leftSize != nil { movR.append(e.relativePath) }
            case .moveLeft:    if e.rightSize != nil { movL.append(e.relativePath) }
            case .deleteLeft:  delL.append(e.relativePath)
            case .deleteRight: delR.append(e.relativePath)
            case .none:        break
            }
        }
        return DirectorySyncPlan(toRight: right, toLeft: left,
                                 moveRight: movR, moveLeft: movL,
                                 deleteLeft: delL, deleteRight: delR,
                                 leftRoot: leftRoot, rightRoot: rightRoot)
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("compare.title"), subtitle: "")
                .overlay(alignment: .topTrailing) {
                    Button { showHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    // Skip this button in the focus chain. With macOS "Full Keyboard Access" on,
                    // the system draws a focus ring on whatever holds focus and focusEffectDisabled
                    // cannot suppress it — the "?" was the first focusable control in the dialog, so
                    // it opened with a blue square around it. Focus now starts on the real controls.
                    .focusable(false)
                    .help(L("compare.help.button"))
                    .popover(isPresented: $showHelp, arrowEdge: .top) { helpContent }
                    .padding(.trailing, 20)
                    .padding(.top, 18)
                }

            optionsBar
            Divider()

            HStack(spacing: 0) {
                filterSidebar
                Divider()
                content
            }

            Divider()
            summaryBar

            FCXLDialogButtonBar(
                primaryTitle: L("compare.synchronize"),
                primaryEnabled: !running && plan.total > 0,
                primaryAction: { session.finish(plan) },
                cancelTitle: L("button.close"),
                cancelAction: { session.cancel() })
        }
        .task(id: byContent) { await scan() }
    }

    /// The list plus everything above it — the right-hand side of the split.
    private var content: some View {
        VStack(spacing: 0) {
            // The paths live here, right above the Left / Right columns they label — reading the
            // header and then the columns is one short glance instead of a jump across the window.
            sidesBar
            Divider()

            if running {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("compare.scanning")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                Text(L("compare.failed")).font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                legendBar
                columnHeader
                Divider()
                if visible.isEmpty {
                    Text(L("compare.identical")).font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Filters as accent pills down the side, the same shape and behaviour as the Settings
    /// sidebar — a segmented control could not show an icon and a count per row comfortably.
    private var filterSidebar: some View {
        let accent = PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
        let onAccent = PanelAppearanceSettings.contrastingTextColor(on: accent)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Filter.allCases) { f in
                let isSelected = f == filter
                Button { filter = f } label: {
                    HStack(spacing: 8) {
                        Image(systemName: f.systemImage)
                            .frame(width: 16)
                            .foregroundStyle(isSelected ? onAccent : accent)
                        Text(L(f.titleKey))
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected ? onAccent : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(filterCount(f))")
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(isSelected ? onAccent : .secondary)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focusable(false)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 186)
    }

    private func filterCount(_ f: Filter) -> Int {
        switch f {
        case .all:         return adjusted.filter { !$0.isDirectory }.count
        case .differences: return count(.different) + count(.leftOnly) + count(.rightOnly)
        case .leftOnly:    return count(.leftOnly)
        case .rightOnly:   return count(.rightOnly)
        case .same:        return count(.same)
        }
    }

    // MARK: - Bars

    private var optionsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                switchOption(L("compare.byContent"), $byContent, hint: L("compare.byContent.hint"))
                switchOption(L("compare.ignoreDate"), $ignoreDate, hint: L("compare.ignoreDate.hint"))
                Spacer()
                maskField("line.3.horizontal.decrease.circle", $mask,
                          L("compare.mask.placeholder"), L("compare.mask.hint"), width: 130)
                maskField("nosign", $excludeMask,
                          L("compare.excludeMask.placeholder"), L("compare.excludeMask.hint"),
                          width: 150)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// A mask box. The shared text field is borderless — right inside a form row, but floating in a
    /// toolbar it reads as a label, so give it an underline that says "you can type here".
    private func maskField(_ symbol: String, _ text: Binding<String>,
                           _ placeholder: String, _ hint: String, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                FCXLDialogTextField(text: text, placeholder: placeholder)
                Rectangle().fill(Color.secondary.opacity(0.45)).frame(height: 1)
            }
            .frame(width: width)
        }
        .help(hint)
    }

    /// One boolean option drawn with the app's own switch (FCXLSwitch), the same control the
    /// Multi-Rename window and the Settings rows use — not a system checkbox.
    private func switchOption(_ label: String, _ value: Binding<Bool>, hint: String) -> some View {
        HStack(spacing: 6) {
            FCXLSwitch(isOn: value)
            Text(label).font(.system(size: 12))
        }
        .help(hint)
    }

    /// Which folder is on which side, spelled out — "АВТО ⟷ АВТО" told the user nothing when both
    /// folders happen to share a name.
    private var sidesBar: some View {
        HStack(spacing: 10) {
            sideLabel(L("compare.column.left"), leftRoot, .green)
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 10))
                .foregroundStyle(.secondary)
            sideLabel(L("compare.column.right"), rightRoot, .blue)
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
    }

    private func sideLabel(_ title: String, _ path: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(path).font(.system(size: 11)).lineLimit(1).truncationMode(.head).help(path)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Always-visible legend. The arrows are the heart of this window, and a user should not have to
    /// open the help to find out what they mean.
    private var legendBar: some View {
        HStack(spacing: 12) {
            legendItem("arrow.right", .green, L("compare.legend.toRight"))
            legendItem("arrow.left", .blue, L("compare.legend.toLeft"))
            legendItem("arrow.right", .orange, L("compare.legend.move"))
            legendItem("trash", .red, L("compare.legend.delete"))
            legendItem("equal", .secondary, L("compare.legend.skip"))
            Spacer()
            Text(L("compare.legend.clickHint")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }

    private func legendItem(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(L("compare.column.name")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("compare.column.left")).frame(width: 116, alignment: .trailing)
            // The arrow column sits BETWEEN the two sides: it describes movement from one to the
            // other, and reads as nonsense anywhere else (it used to be at the far left).
            Text("").frame(width: 34)
            Text(L("compare.column.right")).frame(width: 116, alignment: .leading)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 4)
    }

    private var summaryBar: some View {
        HStack(spacing: 8) {
            Label("\(plan.toRight.count)", systemImage: "arrow.right")
                .foregroundStyle(plan.toRight.isEmpty ? Color.secondary : .green)
            Label("\(plan.toLeft.count)", systemImage: "arrow.left")
                .foregroundStyle(plan.toLeft.isEmpty ? Color.secondary : .blue)
            Text("·").foregroundStyle(.secondary)
            Text(String(format: L("compare.summary.untouched"),
                        max(0, adjusted.filter { !$0.isDirectory }.count - plan.total)))
                .foregroundStyle(.secondary)
            if plan.moves > 0 {
                Label("\(plan.moves)", systemImage: "arrow.left.arrow.right").foregroundStyle(.orange)
            }
            if plan.deletions > 0 {
                Label("\(plan.deletions)", systemImage: "trash").foregroundStyle(.red)
            }
            Spacer()
            if !excluded.isEmpty {
                Button(String(format: L("compare.restoreExcluded"), excluded.count)) {
                    excluded.removeAll()
                }
                .buttonStyle(.link).focusable(false)
            }
            Button(L("compare.resetDirections")) { overrides.removeAll() }
                .buttonStyle(.link).disabled(overrides.isEmpty).focusable(false)
        }
        .font(.system(size: 11)).monospacedDigit()
        .padding(.horizontal, 20).padding(.vertical, 6)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { entry in
                    row(entry)
                    Divider().padding(.leading, 20)
                }
            }
        }
    }

    private func row(_ entry: CompareEntry) -> some View {
        let dir = direction(entry)
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                if entry.isDirectory {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(entry.relativePath)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(entry.relativePath)

            sideColumn(size: entry.leftSize, date: entry.leftDate,
                       newer: isNewer(entry, left: true), alignment: .trailing,
                       doomed: dir == .deleteLeft || dir == .moveRight)

            // The arrow between the two sides: it points from the column the file comes FROM to the
            // column it goes TO, so its meaning is readable without the help text.
            // The bin sits on the side the file DISAPPEARS from: "🗑→" leaves the left empty and
            // lands on the right, "←🗑" the other way round. Reading the pair left-to-right then
            // matches the two columns it stands between.
            HStack(spacing: 1) {
                if dir == .moveRight {
                    Image(systemName: "trash").font(.system(size: 8, weight: .semibold))
                }
                Image(systemName: entry.isDirectory ? "minus" : dir.symbol)
                    .font(.system(size: 13, weight: .semibold))
                if dir == .moveLeft {
                    Image(systemName: "trash").font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(entry.isDirectory ? Color.secondary.opacity(0.4) : dir.tint)
            .frame(width: 34)
            .help(entry.isDirectory ? "" : L("compare.direction.hint"))

            sideColumn(size: entry.rightSize, date: entry.rightDate,
                       newer: isNewer(entry, left: false), alignment: .leading,
                       doomed: dir == .deleteRight || dir == .moveLeft)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !entry.isDirectory else { return }
            advance(entry)
        }
        .contextMenu {
            if !entry.isDirectory {
                Button(L("compare.menu.exclude")) { excluded.insert(entry.relativePath) }
                Divider()
                // Deletions live here rather than in the click cycle: arming one has to be a
                // deliberate act, not something a mis-click can do.
                if entry.leftSize != nil {
                    Button(L("compare.menu.moveRight")) {
                        overrides[entry.relativePath] = .moveRight
                    }
                }
                if entry.rightSize != nil {
                    Button(L("compare.menu.moveLeft")) {
                        overrides[entry.relativePath] = .moveLeft
                    }
                }
                Divider()
                if entry.leftSize != nil {
                    Button(L("compare.menu.deleteLeft"), role: .destructive) {
                        overrides[entry.relativePath] = .deleteLeft
                    }
                }
                if entry.rightSize != nil {
                    Button(L("compare.menu.deleteRight"), role: .destructive) {
                        overrides[entry.relativePath] = .deleteRight
                    }
                }
                if dir == .deleteLeft || dir == .deleteRight {
                    Divider()
                    Button(L("compare.menu.cancelDelete")) { overrides[entry.relativePath] = .none }
                }
            }
        }
    }

    /// Highlights the newer copy, so the user can see at a glance which side the arrow favours.
    private func isNewer(_ e: CompareEntry, left: Bool) -> Bool {
        guard let l = e.leftDate, let r = e.rightDate, l != r else { return false }
        return left ? l > r : r > l
    }

    private func sideColumn(size: UInt64?, date: Date?, newer: Bool,
                            alignment: HorizontalAlignment, doomed: Bool = false) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            if let size {
                Text(ByteText.file(Int64(min(size, UInt64(Int64.max)))))
                    .font(.system(size: 11)).monospacedDigit()
                    .strikethrough(doomed)
                    .foregroundStyle(doomed ? Color.red : Color.primary)
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let date {
                Text(Self.dateFormatter.string(from: date))
                    .font(.system(size: 9)).monospacedDigit()
                    .strikethrough(doomed)
                    .foregroundStyle(doomed ? Color.red : (newer ? Color.primary : Color.secondary))
            }
        }
        .frame(width: 116, alignment: alignment == .trailing ? .trailing : .leading)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: - Help popover

    private var helpContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("compare.help.title")).font(.system(size: 15, weight: .semibold))
                Text(L("compare.help.intro")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                helpSection("compare.help.what.title", "compare.help.what.body")
                helpSection("compare.help.arrows.title", "compare.help.arrows.body")
                helpSection("compare.help.paths.title", "compare.help.paths.body")
                helpSection("compare.help.columns.title", "compare.help.columns.body")
                helpSection("compare.help.filter.title", "compare.help.filter.body")
                helpSection("compare.help.content.title", "compare.help.content.body")
                helpSection("compare.help.ignoredate.title", "compare.help.ignoredate.body")
                helpSection("compare.help.mask.title", "compare.help.mask.body")
                helpSection("compare.help.copy.title", "compare.help.copy.body")
                helpSection("compare.help.move.title", "compare.help.move.body")
                helpSection("compare.help.exclude.title", "compare.help.exclude.body")
                helpSection("compare.help.delete.title", "compare.help.delete.body")
                helpSection("compare.help.folders.title", "compare.help.folders.body")
                helpSection("compare.help.safety.title", "compare.help.safety.body")
                helpSection("compare.help.summary.title", "compare.help.summary.body")
                helpSection("compare.help.example.title", "compare.help.example.body")
            }
            .padding(18)
            .frame(width: 430, alignment: .leading)
        }
        .frame(maxHeight: 520)
    }

    private func helpSection(_ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(titleKey)).font(.system(size: 13, weight: .semibold))
            Text(L(bodyKey)).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Work

    /// `*` and `?` wildcards on the file name, the mask syntax the rest of the app uses.
    private func matches(_ name: String, _ pattern: String) -> Bool {
        NSPredicate(format: "SELF LIKE[c] %@", pattern).evaluate(with: name)
    }

    /// Walk both trees on a background thread — the comparison reads every file when "by content"
    /// is on, and the dialog is modal.
    private func scan() async {
        running = true
        failed = false
        overrides.removeAll()
        let left = leftRoot, right = rightRoot, content = byContent
        let scanned = await Task.detached(priority: .userInitiated) { () -> [CompareEntry]? in
            let bridge = FCXLCompareBridge()
            guard let raw = try? bridge.compareDirectory(atPath: left, withDirectoryAtPath: right,
                                                         byContent: content) as? [[String: Any]]
            else { return nil }
            let fm = FileManager.default
            func stat(_ path: String) -> (UInt64, Date)? {
                guard let a = try? fm.attributesOfItem(atPath: path) else { return nil }
                return ((a[.size] as? UInt64) ?? 0, (a[.modificationDate] as? Date) ?? .distantPast)
            }
            return raw.compactMap { dict -> CompareEntry? in
                guard let rel = dict["relativePath"] as? String,
                      let statusRaw = dict["status"] as? String,
                      let status = CompareStatus(rawValue: statusRaw) else { return nil }
                let isDir = (dict["isDirectory"] as? Bool) ?? false
                // The core reports what differs; sizes and dates come from the file system, so the
                // user can see WHICH side is newer instead of only that the two disagree.
                let l = isDir ? nil : stat((left as NSString).appendingPathComponent(rel))
                let r = isDir ? nil : stat((right as NSString).appendingPathComponent(rel))
                return CompareEntry(relativePath: rel, status: status, isDirectory: isDir,
                                    leftSize: l?.0, rightSize: r?.0,
                                    leftDate: l?.1, rightDate: r?.1)
            }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }.value

        guard let scanned else { failed = true; running = false; return }
        entries = scanned
        running = false
    }
}
