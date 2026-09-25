import AppKit
import SwiftUI

/// Two files side by side, line against line.
///
/// The pair to the folder comparison: that one says WHICH files differ, this one says how. Both
/// halves scroll as one, because they are one — every row holds both sides, so there is no
/// second scroll view to keep in step and no way for the two to drift apart.
struct FileDiffDialogView: View {
    let session: FCXLDialogSession<Bool>
    let leftPath: String
    let rightPath: String

    @State private var rows: [FileDiffService.Row] = []
    @State private var failure: String?
    @State private var identical = false
    /// Fold away the unchanged lines: on a long file the differences are needles, and the
    /// haystack is not worth scrolling through.
    @State private var onlyDifferences = false
    /// How many unchanged lines to keep around each difference. Two is what `diff` shows by
    /// default and reads well; zero is for someone who wants the changed lines and nothing else.
    /// Remembered, because it is a habit rather than a per-file decision.
    @AppStorage("fcxl.diffContextLines") private var contextLines: Int = 2
    @State private var wrapsLines = false
    @State private var currentRun = 0

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    private var visibleRows: [FileDiffService.Row] {
        onlyDifferences ? FileDiffService.foldingEqualLines(in: rows, context: contextLines)
            : rows
    }

    private var runs: [Int] { FileDiffService.differenceRuns(in: visibleRows) }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("diff.title"), subtitle: sharedFolder)

            toolbar
            Divider()
            columnHeaders
            Divider()
            content

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("button.close"), role: .primary) {
                    session.cancel()
                },
            ])
        }
        .onAppear(perform: load)
    }

    // MARK: - The bar above the columns

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(identical ? .secondary : .primary)

            Spacer()

            if !runs.isEmpty {
                Text("\(min(currentRun + 1, runs.count)) / \(runs.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                    .keyboardShortcut(.upArrow, modifiers: .option)
                    .focusEffectDisabled()
                    .help(L("diff.previous"))
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                    .keyboardShortcut(.downArrow, modifiers: .option)
                    .focusEffectDisabled()
                    .help(L("diff.next"))
            }

            // The app's own switch, as everywhere else in it — a system checkbox is a stranger
            // among these controls.
            switchRow(L("diff.onlyDifferences"), isOn: $onlyDifferences, enabled: !identical)
            if onlyDifferences {
                // Only while the fold is on: how many unchanged lines stay around each
                // difference. On its own it would be a control that explains nothing.
                Text(L("diff.context"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                FCXLDialogMenuPicker(items: Self.contextChoices, selection: $contextLines,
                                     title: { "\($0)" }, compact: true)
            }
            switchRow(L("diff.wrapLines"), isOn: $wrapsLines, enabled: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// Nothing, a couple of lines, or enough to read a paragraph.
    static let contextChoices = [0, 2, 5]

    private func switchRow(_ label: String, isOn: Binding<Bool>, enabled: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(enabled ? .primary : .tertiary)
            FCXLSwitch(isOn: isOn)
        }
        .disabled(!enabled)
    }

    private var summary: String {
        if let failure { return failure }
        if identical { return L("diff.identical") }
        let count = FileDiffService.differenceRuns(in: rows).count
        return String(format: L("diff.differences"), count)
    }

    /// The name of each file over its own column. Two columns with the names merged into one
    /// line above them say WHICH files these are but not which side each is on.
    private var columnHeaders: some View {
        HStack(spacing: 0) {
            columnName(leftPath)
            Divider()
            columnName(rightPath)
        }
        // A Divider inside an HStack has no height of its own and takes whatever is going: left
        // to itself the row swallowed half the window and left the names floating in the middle
        // of it. The height is the text's, and the divider follows.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.secondary.opacity(0.08))
    }

    private func columnName(_ path: String) -> some View {
        Text((path as NSString).lastPathComponent)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The folder both files are in, when it is the same one — then the names above the columns
    /// are the whole story. Otherwise both folders, since that is what tells them apart.
    private var sharedFolder: String {
        let left = (leftPath as NSString).deletingLastPathComponent
        let right = (rightPath as NSString).deletingLastPathComponent
        return left == right ? left : "\(left)  ↔  \(right)"
    }

    // MARK: - The columns

    @ViewBuilder
    private var content: some View {
        if failure != nil || identical || rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: failure == nil ? "equal.circle" : "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRows) { row in
                            DiffRowView(row: row, wraps: wrapsLines)
                                .id(row.id)
                        }
                    }
                }
                .onChange(of: currentRun) { _ in
                    guard runs.indices.contains(currentRun) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(visibleRows[runs[currentRun]].id, anchor: .center)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Doing

    private func load() {
        do {
            rows = FileDiffService.rows(from: try FileDiffService.compare(leftPath, rightPath))
            identical = !rows.contains(where: \.isDifference)
        } catch FileDiffService.Failure.binary(let left, let right) {
            let name = left && right ? L("diff.binary.both")
                : ((left ? leftPath : rightPath) as NSString).lastPathComponent
            let same = FileDiffService.areIdentical(leftPath, rightPath) ?? false
            failure = String(format: L("diff.binary"), name)
                + (same ? " " + L("diff.binary.same") : " " + L("diff.binary.differ"))
        } catch FileDiffService.Failure.notAFile(let name) {
            failure = String(format: L("diff.notAFile"), name)
        } catch FileDiffService.Failure.core(let message) {
            failure = message
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Step to the next place the files differ, wrapping round at the ends — a long file is
    /// easier to walk in a circle than to scroll back to the top of.
    private func step(_ direction: Int) {
        guard !runs.isEmpty else { return }
        currentRun = (currentRun + direction + runs.count) % runs.count
    }
}

/// One line of the comparison: both sides of it.
private struct DiffRowView: View {
    let row: FileDiffService.Row
    let wraps: Bool

    var body: some View {
        if let hidden = row.hiddenCount {
            // What was folded away, said out loud. A fold with nothing to show for it reads as
            // a switch that did nothing.
            HStack(spacing: 6) {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                Text(String(format: L("diff.hiddenLines"), hidden))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
        } else {
            HStack(spacing: 0) {
                cell(number: row.leftNumber, text: row.leftText, tint: leftTint)
                Divider()
                cell(number: row.rightNumber, text: row.rightText, tint: rightTint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Red for what went, green for what came, amber for a line that became another — the
    /// colours every diff has used since diffs were printed on paper. Kept pale so the text on
    /// top stays the thing being read.
    private var leftTint: Color {
        switch row.kind {
        case .removed, .changed:      return .red.opacity(0.16)
        case .equal, .added, .gap:    return .clear
        }
    }

    private var rightTint: Color {
        switch row.kind {
        case .added, .changed:        return .green.opacity(0.16)
        case .equal, .removed, .gap:  return .clear
        }
    }

    private func cell(number: Int?, text: String?, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(text ?? "")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A line missing on this side is left blank rather than filled with a placeholder:
            // the tint on the other side already says which way the difference goes.
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
    }
}
