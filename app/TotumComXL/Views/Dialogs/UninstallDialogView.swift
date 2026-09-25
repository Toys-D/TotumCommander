import AppKit
import SwiftUI

/// What a program left behind, listed before anything is removed.
///
/// The whole value of the dialog is that it SHOWS the list first. An uninstaller that guesses
/// which folder belongs to which program will be wrong sooner or later, so the person gets the
/// paths, the sizes and a switch on every line — and the ones outside their own Library are
/// marked, because those need an administrator and are not removed here.
struct UninstallDialogView: View {
    let session: FCXLDialogSession<[String]>
    let appPath: String
    let appName: String
    let bundleID: String?

    @State private var leftovers: [AppUninstaller.Leftover] = []
    @State private var chosen: Set<String> = []
    /// The search runs while this window is already on screen. Doing it before opening meant
    /// several silent seconds on a big program — a delete that looked like a freeze.
    @State private var searching = true
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    init(session: FCXLDialogSession<[String]>, appPath: String, appName: String,
         bundleID: String?) {
        self.session = session
        self.appPath = appPath
        self.appName = appName
        self.bundleID = bundleID
    }

    private var totalBytes: UInt64 {
        leftovers.filter { chosen.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: String(format: L("uninstall.title"), appName),
                             icon: "trash.fill",
                             iconBusy: searching)

            Text(L("uninstall.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(leftovers) { item in
                        row(item)
                        Divider().opacity(0.35)
                    }
                    if searching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(leftovers.isEmpty ? L("uninstall.searching")
                                                   : L("uninstall.measuring"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)

            HStack {
                Text(String(format: L("uninstall.chosen"), chosen.count,
                            ByteText.file(Int64(totalBytes))))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            FCXLDialogButtonBar(
                primaryTitle: L("uninstall.confirm"),
                primaryEnabled: !chosen.isEmpty && !searching,
                primaryAction: { session.finish(leftovers.map(\.path).filter { chosen.contains($0) }) },
                destructive: true,
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: search)
    }

    /// Two passes, so the window is never a blank wait. The first finds the paths — quick —
    /// and the list appears. The second measures them, which means walking gigabytes on a big
    /// program, and the numbers fill in as they arrive.
    private func search() {
        let path = appPath
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppUninstaller.leftovers(appPath: path, measure: false)
            DispatchQueue.main.async {
                leftovers = found
                chosen = Set(found.filter { !$0.needsAdmin }.map(\.path))
            }
            for (index, item) in found.enumerated() {
                let bytes = AppUninstaller.size(of: item.path)
                DispatchQueue.main.async {
                    guard leftovers.indices.contains(index),
                          leftovers[index].path == item.path else { return }
                    leftovers[index] = AppUninstaller.Leftover(
                        path: item.path, kind: item.kind, bytes: bytes,
                        needsAdmin: item.needsAdmin)
                }
            }
            DispatchQueue.main.async { searching = false }
        }
    }

    @ViewBuilder
    private func row(_ item: AppUninstaller.Leftover) -> some View {
        HStack(spacing: 10) {
            // Places outside the user's own Library CAN be chosen — macOS simply asks for a
            // password when the time comes. They are still never pre-ticked: a removal that
            // needs an administrator should be a decision, not something that happened while
            // the person was reading the list.
            FCXLSwitch(isOn: Binding(
                get: { chosen.contains(item.path) },
                set: { on in
                    if on { chosen.insert(item.path) } else { chosen.remove(item.path) }
                }))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(item.kind)
                        .font(.system(size: 10))
                        .foregroundStyle(accent)
                    if item.needsAdmin {
                        Text(L("uninstall.needsAdmin"))
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                Text((item.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
            }
            Spacer()
            Text(ByteText.file(Int64(item.bytes)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
