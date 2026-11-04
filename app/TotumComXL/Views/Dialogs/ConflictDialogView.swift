import AppKit
import SwiftUI

/// What the user picked in the conflict dialog (nil result = cancel).
enum ConflictDialogChoice {
    case replace
    case replaceAll
    case createCopy
    case skip
    case skipAll
}

/// One side (source or destination) of the conflict comparison card.
struct ConflictSideInfo {
    let label: String
    let sizeText: String
    let dateText: String
    let hints: [String]   // e.g. ["новее", "больше"]

    /// Build from a file path (size + modification date + comparison hints filled later).
    static func make(label: String, path: String) -> (info: ConflictSideInfo, size: Int64, date: Date?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = attrs?[.modificationDate] as? Date
        let fmt = DateFormatter.fcxlDisplay(date: .short, time: .short)
        let info = ConflictSideInfo(
            label: label,
            sizeText: ByteText.file(size),
            dateText: date.map { fmt.string(from: $0) } ?? "—",
            hints: []
        )
        return (info, size, date)
    }

    func withHints(_ hints: [String]) -> ConflictSideInfo {
        ConflictSideInfo(label: label, sizeText: sizeText, dateText: dateText, hints: hints)
    }
}

/// Settings-style "file already exists" dialog: comparison card + a row of
/// equal-width action buttons (Replace is the accent default, HIG-style).
struct ConflictDialogView: View {
    let session: FCXLDialogSession<ConflictDialogChoice>
    let fileName: String
    var message: String?
    var source: ConflictSideInfo?
    var destination: ConflictSideInfo?
    var allowReplace: Bool = true
    var showApplyToAll: Bool = true
    /// Archive extraction cannot write an entry under a different name, so "Create copy"
    /// is hidden there rather than offered and silently ignored.
    var allowCreateCopy: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: String(format: L("conflict.title"), fileName),
                             subtitle: message)

            Form {
                if let source, let destination {
                    Section {
                        sideRow(source)
                        sideRow(destination)
                    }
                }
            }
            .formStyle(.grouped)

            FCXLDialogMultiButtonBar(buttons: barButtons)
        }
    }

    private var barButtons: [FCXLDialogBarButton] {
        if showApplyToAll {
            return [
                FCXLDialogBarButton(title: L("conflict.cancel"), action: { session.cancel() }),
                FCXLDialogBarButton(title: L("conflict.skipAll"), action: { session.finish(.skipAll) }),
                FCXLDialogBarButton(title: L("conflict.skip"), action: { session.finish(.skip) }),
                FCXLDialogBarButton(title: L("conflict.createCopy"), enabled: allowCreateCopy,
                                    action: { session.finish(.createCopy) }),
                FCXLDialogBarButton(title: L("conflict.replaceAll"), enabled: allowReplace,
                                    action: { session.finish(.replaceAll) }),
                FCXLDialogBarButton(title: L("conflict.replace"), role: .primary, enabled: allowReplace,
                                    action: { session.finish(.replace) }),
            ]
        }
        return [
            FCXLDialogBarButton(title: L("conflict.cancel"), action: { session.cancel() }),
            FCXLDialogBarButton(title: L("conflict.createCopy"), action: { session.finish(.createCopy) }),
            FCXLDialogBarButton(title: L("conflict.replace"), role: .primary, enabled: allowReplace,
                                action: { session.finish(.replace) }),
        ]
    }

    private func sideRow(_ side: ConflictSideInfo) -> some View {
        LabeledContent(side.label) {
            HStack(spacing: 8) {
                Text("\(side.sizeText) · \(side.dateText)")
                    .foregroundStyle(.secondary)
                ForEach(side.hints, id: \.self) { hint in
                    Text(hint)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
            }
        }
    }
}
