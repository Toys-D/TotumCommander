import AppKit
import SwiftUI

/// What to do to a PDF: take it apart, or turn its pages.
///
/// Both ask before doing, and both show the answer to "what will I get" before anything is
/// written — a page lost out of a contract is noticed far too late to be fixed by an apology.
struct PDFSplitDialogView: View {
    let session: FCXLDialogSession<PDFSplitRequest>
    let path: String
    let pageCount: Int

    /// Pages per part when nothing is typed — and what the hint in the field says.
    private static let defaultChunk = 2

    @State private var mode: PDFSplitRequest.Mode = .everyPage
    @State private var size: Int = PDFSplitDialogView.defaultChunk
    @State private var sizeText: String = String(PDFSplitDialogView.defaultChunk)
    @State private var ranges: String = ""
    @State private var showsHelp = false

    private var parts: [[Int]] {
        switch mode {
        case .everyPage: return PDFEditService.chunks(pageCount: pageCount, size: 1)
        case .everyN:    return PDFEditService.chunks(pageCount: pageCount, size: max(1, size))
        case .ranges:    return [PDFEditService.pages(from: ranges, pageCount: pageCount)]
                                .filter { !$0.isEmpty }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("pdf.split.title"), icon: "square.split.2x1")
                .overlay(alignment: .topTrailing) { helpButton($showsHelp, topic: .split) }

            Text(String(format: L("pdf.split.subtitle"),
                        (path as NSString).lastPathComponent, pageCount))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    FCXLFormRow(label: L("pdf.split.how")) {
                        FCXLDropdown(
                            selection: $mode,
                            options: PDFSplitRequest.Mode.allCases.map { ($0, $0.localizedName) })
                        Spacer()
                    }
                    if mode == .everyN {
                        FCXLFormRow(label: L("pdf.split.size"), showDivider: false) {
                            FCXLDialogTextField(
                                text: Binding(
                                    get: { sizeText },
                                    set: { typed in
                                        sizeText = typed.filter(\.isNumber)
                                        // An empty field means the number that is written in it
                                        // as a hint — not one. Falling to one silently turned
                                        // "a few pages at a time" into "every page on its own",
                                        // and the list below said so while the field looked
                                        // like it still said two.
                                        size = max(1, Int(sizeText) ?? Self.defaultChunk)
                                    }),
                                placeholder: String(Self.defaultChunk))
                            .frame(width: 70)
                            Text(L("pdf.pages")).font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    if mode == .ranges {
                        FCXLFormRow(label: L("pdf.split.range"), showDivider: false) {
                            FCXLDialogTextField(text: $ranges, placeholder: "1-3, 7, 12-",
                                                focusOnAppear: true)
                        }
                    }
                }

                Text(L("pdf.split.result"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { number, pages in
                            Text(String(format: L("pdf.split.part"), number + 1,
                                        humanPages(pages)))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if parts.isEmpty {
                            Text(L("pdf.error.noPages"))
                                .font(.system(size: 11)).foregroundColor(.orange)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 8)

            FCXLDialogButtonBar(
                primaryTitle: L("pdf.split.confirm"),
                primaryEnabled: !parts.isEmpty,
                primaryAction: { session.finish(PDFSplitRequest(parts: parts)) },
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    /// "страницы 1–3" — page numbers as a person counts them, not as an array is indexed.
    private func humanPages(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "" }
        if pages.count == 1 { return String(format: L("pdf.page.one"), first + 1) }
        // A run of consecutive pages reads as a range; anything else is listed.
        let isRun = pages.enumerated().allSatisfy { $0.element == first + $0.offset }
        return isRun
            ? String(format: L("pdf.page.range"), first + 1, last + 1)
            : pages.map { String($0 + 1) }.joined(separator: ", ")
    }
}

/// The "?" every PDF window carries, and the words behind it. The same keys the Help window
/// renders, so the two can never drift apart.
enum PDFHelpTopic: String {
    case make, merge, split, rotate

    var sections: [(String, String)] {
        switch self {
        case .make:
            return [("pdf.help.make.title", "pdf.help.make.body"),
                    ("pdf.help.pageSize.title", "pdf.help.pageSize.body"),
                    ("pdf.help.order.title", "pdf.help.order.body"),
                    ("pdf.help.where.title", "pdf.help.where.body")]
        case .merge:
            return [("pdf.help.merge.title", "pdf.help.merge.body"),
                    ("pdf.help.order.title", "pdf.help.order.body"),
                    ("pdf.help.where.title", "pdf.help.where.body")]
        case .split:
            return [("pdf.help.split.title", "pdf.help.split.body"),
                    ("pdf.help.ranges.title", "pdf.help.ranges.body"),
                    ("pdf.help.where.title", "pdf.help.where.body")]
        case .rotate:
            return [("pdf.help.rotate.title", "pdf.help.rotate.body"),
                    ("pdf.help.ranges.title", "pdf.help.ranges.body"),
                    ("pdf.help.replace.title", "pdf.help.replace.body")]
        }
    }
}

extension View {
    /// The question mark in the corner of a PDF window.
    func helpButton(_ shown: Binding<Bool>, topic: PDFHelpTopic) -> some View {
        Button { shown.wrappedValue.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        // Out of the focus chain: with Full Keyboard Access on, the system draws its own ring
        // on whatever holds focus, and the window would open wearing a blue square.
        .focusable(false)
        .help(L("pdf.help.button"))
        .popover(isPresented: shown, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(topic.sections, id: \.0) { title, body in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L(title)).font(.system(size: 13, weight: .semibold))
                            Text(L(body)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(width: 420, alignment: .leading)
            }
            .frame(width: 420, height: 460)
        }
        .padding(.trailing, 20)
        .padding(.top, 18)
    }
}

struct PDFSplitRequest {
    enum Mode: String, CaseIterable {
        case everyPage, everyN, ranges
        var localizedName: String { L("pdf.split.mode.\(rawValue)") }
    }
    let parts: [[Int]]
}

/// Turning pages.
struct PDFRotateDialogView: View {
    let session: FCXLDialogSession<PDFRotateRequest>
    let paths: [String]
    let pageCount: Int

    @State private var degrees = 90
    @State private var showsHelp = false
    @State private var ranges = ""
    @State private var replaces = false

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("pdf.rotate.title"), icon: "rotate.right")
                .overlay(alignment: .topTrailing) { helpButton($showsHelp, topic: .rotate) }

            Text(String(format: L("pdf.rotate.subtitle"), paths.count))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    FCXLFormRow(label: L("pdf.rotate.angle")) {
                        FCXLDropdown(
                            selection: $degrees,
                            options: [(90, L("pdf.rotate.right")),
                                      (270, L("pdf.rotate.left")),
                                      (180, L("pdf.rotate.over"))])
                        Spacer()
                    }
                    FCXLFormRow(label: L("pdf.rotate.pages")) {
                        FCXLDialogTextField(text: $ranges,
                                            placeholder: L("pdf.rotate.pages.all"))
                    }
                    FCXLToggleRow(label: L("pdf.rotate.replace"), isOn: $replaces,
                                  showDivider: false)
                }
                Text(L(replaces ? "pdf.rotate.note.replace" : "pdf.rotate.note.copy"))
                    .font(.system(size: 11))
                    .foregroundStyle(replaces ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 8)

            FCXLDialogButtonBar(
                primaryTitle: L("pdf.rotate.confirm"),
                primaryAction: {
                    session.finish(PDFRotateRequest(degrees: degrees, ranges: ranges,
                                                    replaces: replaces))
                },
                destructive: replaces,
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 500, minHeight: 340)
    }
}

struct PDFRotateRequest {
    let degrees: Int
    /// Empty means every page.
    let ranges: String
    let replaces: Bool
}

/// Making a PDF out of pictures — and out of PDFs, taken in whole.
struct PDFMakeDialogView: View {
    let session: FCXLDialogSession<PDFMakeRequest>
    @State private var order: [String]
    @State private var chosen: String?
    @State private var pageSize: PDFEditService.PageSize = .picture
    @State private var showsHelp = false
    @State private var name = ""

    /// What the file is called if nothing is typed: the first picture's name. It shows as the
    /// hint in the field, so the answer to "what will it be called" is on screen either way.
    private var suggestedName: String {
        guard let first = order.first else { return "PDF" }
        let stem = ((first as NSString).lastPathComponent as NSString).deletingPathExtension
        return stem + L("pdf.make.suffix")
    }

    init(session: FCXLDialogSession<PDFMakeRequest>, paths: [String]) {
        self.session = session
        _order = State(initialValue: paths)
    }

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("pdf.make.title"), icon: "doc.badge.plus")
                .overlay(alignment: .topTrailing) { helpButton($showsHelp, topic: .make) }

            Text(L("pdf.make.subtitle"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 8)

            FCXLFormCard {
                FCXLFormRow(label: L("pdf.name")) {
                    FCXLDialogTextField(text: $name, placeholder: suggestedName)
                }
                FCXLFormRow(label: L("pdf.make.pageSize"), showDivider: false) {
                    FCXLDropdown(
                        selection: $pageSize,
                        options: PDFEditService.PageSize.allCases.map { ($0, $0.localizedName) })
                    Spacer()
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(chosen == path ? Color.white : .primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(chosen == path ? accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { chosen = path }
                    }
                }
                .padding(6)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)

            HStack(spacing: 6) {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(FCXLToolbarButtonStyle()).disabled(chosen == nil)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(FCXLToolbarButtonStyle()).disabled(chosen == nil)
                Spacer()
                Text(String(format: L("pdf.make.count"), order.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)

            FCXLDialogButtonBar(
                primaryTitle: L("pdf.make.confirm"),
                primaryEnabled: !order.isEmpty,
                primaryAction: {
                    session.finish(PDFMakeRequest(order: order, pageSize: pageSize,
                                                  name: name.isEmpty ? suggestedName : name))
                },
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 540, minHeight: 460)
    }

    private func move(_ offset: Int) {
        guard let chosen, let index = order.firstIndex(of: chosen) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }
}

struct PDFMakeRequest {
    let order: [String]
    let pageSize: PDFEditService.PageSize
    let name: String
}

/// Putting several documents into one. The order is the point, so it can be changed here.
struct PDFMergeDialogView: View {
    let session: FCXLDialogSession<PDFMergeRequest>
    @State private var order: [String]
    @State private var chosen: String?
    @State private var showsHelp = false
    @State private var name = ""

    init(session: FCXLDialogSession<PDFMergeRequest>, paths: [String]) {
        self.session = session
        _order = State(initialValue: paths)
    }

    private var suggestedName: String {
        guard let first = order.first else { return "PDF" }
        let stem = ((first as NSString).lastPathComponent as NSString).deletingPathExtension
        return stem + L("pdf.merge.suffix")
    }

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("pdf.merge.title"), icon: "square.stack")
                .overlay(alignment: .topTrailing) { helpButton($showsHelp, topic: .merge) }

            Text(L("pdf.merge.subtitle"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 8)

            FCXLFormCard {
                FCXLFormRow(label: L("pdf.name"), showDivider: false) {
                    FCXLDialogTextField(text: $name, placeholder: suggestedName)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(chosen == path ? Color.white : .primary)
                            Spacer(minLength: 0)
                            Text(String(format: L("pdf.merge.pages"),
                                        PDFEditService.pageCount(of: path)))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(chosen == path ? accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { chosen = path }
                    }
                }
                .padding(6)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)

            HStack(spacing: 6) {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(FCXLToolbarButtonStyle())
                    .disabled(chosen == nil)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(FCXLToolbarButtonStyle())
                    .disabled(chosen == nil)
                Spacer()
                Text(String(format: L("pdf.merge.total"),
                            order.reduce(0) { $0 + PDFEditService.pageCount(of: $1) }))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)

            FCXLDialogButtonBar(
                primaryTitle: L("pdf.merge.confirm"),
                primaryEnabled: order.count > 1,
                primaryAction: {
                    session.finish(PDFMergeRequest(order: order,
                                                   name: name.isEmpty ? suggestedName : name))
                },
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 540, minHeight: 440)
    }

    private func move(_ offset: Int) {
        guard let chosen, let index = order.firstIndex(of: chosen) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }
}


struct PDFMergeRequest {
    let order: [String]
    let name: String
}
