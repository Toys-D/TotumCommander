import AppKit
import SwiftUI

// MARK: - Model

/// Space + interface info for one mounted volume, for the "disk info" sheet.
struct DiskVolumeInfo: Identifiable {
    let id = UUID()
    let name: String
    let icon: String          // SF Symbol for the volume kind
    let interface: String     // e.g. "Internal (NVMe)", "USB 3.x", "Network"
    let isFast: Bool
    let filesystem: String
    let totalBytes: Int64
    let freeBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var usedFraction: Double { totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0 }
}

enum DiskInfoProvider {
    /// All mounted, visible volumes with a real capacity — internal disk(s), external
    /// drives and network shares — each with total/free space and its interface.
    static func allVolumes() -> [DiskVolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .isVolumeKey, .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        var result: [DiskVolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: keys), v.isVolume == true else { continue }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }   // skip pseudo / zero-capacity volumes

            let free = Int64(v.volumeAvailableCapacity ?? 0)
            let name = v.volumeName ?? url.lastPathComponent
            let fs = v.volumeLocalizedFormatDescription ?? "—"
            let isNetwork = v.volumeIsLocal == false
            let isInternal = v.volumeIsInternal == true
            let iface = VolumeInterfaceDetector.detect(forPath: url.path)

            let icon: String = isNetwork ? "externaldrive.connected.to.line.below"
                : (isInternal ? "internaldrive" : "externaldrive.fill")

            result.append(DiskVolumeInfo(
                name: name,
                icon: icon,
                interface: isNetwork ? L("diskinfo.network") : iface.displayName,
                isFast: iface.isFast,
                filesystem: fs,
                totalBytes: total,
                freeBytes: free
            ))
        }
        // Internal disks first, then by name.
        return result.sorted { a, b in
            let ai = a.icon == "internaldrive", bi = b.icon == "internaldrive"
            if ai != bi { return ai }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Sheet

/// A read-only "disk information" window: every mounted volume with its total / used /
/// free space and a fill bar. Presented from the window toolbar "i" button, in the shared
/// FCXLDialog style — chrome-less panel, settings-style header, accent button bar.
struct DiskInfoView: View {
    let session: FCXLDialogSession<Bool>

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    @State private var volumes: [DiskVolumeInfo] = DiskInfoProvider.allVolumes()

    var body: some View {
        VStack(spacing: 0) {
            // Header styled like FCXLDialogHeader (title2 / semibold, same insets), with a
            // refresh button on the trailing edge — the one action this window needs.
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .foregroundColor(accent)
                Text(L("diskinfo.title"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    volumes = DiskInfoProvider.allVolumes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()   // drop the system blue focus ring
                .help(L("diskinfo.refresh"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(volumes) { vol in
                        DiskRow(vol: vol, accent: accent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("diskinfo.done"), role: .primary) { session.finish(true) }
            ])
        }
    }
}

/// One volume card: name + interface badge, filesystem, sizes and a fill bar.
private struct DiskRow: View {
    let vol: DiskVolumeInfo
    let accent: Color

    private static let fmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    /// The bar is a gradient painted across the FULL width, then masked to the
    /// used portion — so the colour reads as a position on the scale, not as a
    /// property of the fill. A half-full disk shows only the calm left half; the
    /// warm end appears solely as the bar actually approaches the right edge.
    ///
    /// Painting the gradient into the fill's own width instead would squeeze the
    /// whole ramp into every bar, making a nearly-empty disk end in red.
    private var barGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: accent, location: 0.00),
                .init(color: accent, location: 0.65),
                .init(color: .orange, location: 0.86),
                .init(color: .red, location: 1.00),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: vol.icon)
                    .foregroundColor(accent)
                    .frame(width: 18)
                Text(vol.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(vol.interface)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }

            // Fill bar (used / total).
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barGradient)
                        .mask(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .frame(width: max(2, geo.size.width * vol.usedFraction))
                        }
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(Self.fmt.string(fromByteCount: vol.usedBytes)) \(L("diskinfo.usedOf")) \(Self.fmt.string(fromByteCount: vol.totalBytes)) · \(Int((vol.usedFraction * 100).rounded()))%")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(L("diskinfo.free")): \(Self.fmt.string(fromByteCount: vol.freeBytes))")
                    .font(.system(size: 11, weight: .medium))
            }

            Text("\(L("diskinfo.filesystem")): \(vol.filesystem)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
