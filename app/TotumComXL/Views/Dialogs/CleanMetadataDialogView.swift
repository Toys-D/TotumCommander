import AppKit
import SwiftUI

/// Taking the invisible notes out of files before they are sent anywhere.
///
/// This one asks first and says plainly what will go, file by file, because it changes the
/// files themselves: once a photograph's place or a document's author is out, it cannot be put
/// back.
struct CleanMetadataDialogView: View {
    let session: FCXLDialogSession<CleanMetadataRequest>
    let paths: [String]

    @State private var scope: MetadataScrubber.Scope = .everything
    @State private var keepOriginal = false

    private var kinds: [MetadataScrubber.Kind] {
        paths.map { MetadataScrubber.Kind(pathExtension: ($0 as NSString).pathExtension) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("metadata.clean.title"), icon: "eye.slash")

            Text(String(format: L("metadata.clean.subtitle"), paths.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    // "Only the place" means something only to photographs and films.
                    if kinds.contains(where: \.knowsPlace) {
                        FCXLFormRow(label: L("metadata.clean.what")) {
                            FCXLDropdown(
                                selection: $scope,
                                options: MetadataScrubber.Scope.allCases.map {
                                    ($0, $0.localizedName)
                                })
                            Spacer()
                        }
                    }
                    FCXLToggleRow(label: L("metadata.clean.keepOriginal"), isOn: $keepOriginal,
                                  showDivider: false)
                }

                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(keepOriginal ? .secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(zip(paths, kinds)), id: \.0) { path, kind in
                            HStack(spacing: 6) {
                                Text((path as NSString).lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(kind.localizedLoss(scope))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 8)

            FCXLDialogButtonBar(
                primaryTitle: L("metadata.clean.confirm"),
                primaryAction: {
                    session.finish(CleanMetadataRequest(scope: scope, keepOriginal: keepOriginal))
                },
                // Red, like everything in this program that removes something: the files
                // survive, but what they remembered does not.
                destructive: !keepOriginal,
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var note: String {
        var text = L(keepOriginal ? "metadata.clean.note.copy" : "metadata.clean.note.inPlace")
        if scope == .place, kinds.contains(where: { !$0.knowsPlace }) {
            text += " " + L("metadata.clean.note.placeOnly")
        }
        return text
    }
}

/// What the person chose in the dialog.
struct CleanMetadataRequest {
    let scope: MetadataScrubber.Scope
    let keepOriginal: Bool
}
