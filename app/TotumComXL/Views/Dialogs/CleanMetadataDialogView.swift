import AppKit
import SwiftUI

/// Taking the invisible notes out of photographs before they are sent anywhere.
///
/// This one asks first and says plainly what will go, because it changes the files themselves:
/// a photograph carries the place it was taken, and once it is out it cannot be put back.
struct CleanMetadataDialogView: View {
    let session: FCXLDialogSession<CleanMetadataRequest>
    let paths: [String]

    @State private var what: PhotoMetadataService.Cleaning = .everything
    @State private var keepOriginal = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("exif.clean.title"), icon: "eye.slash")

            Text(String(format: L("exif.clean.subtitle"), paths.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    FCXLFormRow(label: L("exif.clean.what")) {
                        FCXLDropdown(
                            selection: $what,
                            options: PhotoMetadataService.Cleaning.allCases.map {
                                ($0, $0.localizedName)
                            })
                        Spacer()
                    }
                    FCXLToggleRow(label: L("exif.clean.keepOriginal"), isOn: $keepOriginal,
                                  showDivider: false)
                }

                Text(L(keepOriginal ? "exif.clean.note.copy" : "exif.clean.note.inPlace"))
                    .font(.system(size: 11))
                    .foregroundStyle(keepOriginal ? .secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(paths, id: \.self) { path in
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 8)

            FCXLDialogButtonBar(
                primaryTitle: L("exif.clean.confirm"),
                primaryAction: {
                    session.finish(CleanMetadataRequest(what: what, keepOriginal: keepOriginal))
                },
                // Red, like everything in this program that removes something: the picture
                // survives, but what it remembered does not.
                destructive: !keepOriginal,
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

/// What the person chose in the dialog.
struct CleanMetadataRequest {
    let what: PhotoMetadataService.Cleaning
    let keepOriginal: Bool
}
