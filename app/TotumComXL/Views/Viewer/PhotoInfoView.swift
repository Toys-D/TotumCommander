import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// What a photograph carries besides the picture: the camera, the settings, the words in it and
/// the place it was taken — with the place shown on a map rather than as two numbers nobody can
/// picture.
struct PhotoInfoView: View {
    let path: String

    @State private var info = PhotoMetadataService.Info()
    @State private var isLoading = true
    @State private var copied = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.top, 30)
                } else if info.isEmpty {
                    Text(L("exif.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 30)
                } else {
                    ForEach(PhotoMetadataService.Section.allCases, id: \.self) { section in
                        let rows = info.entries(in: section)
                        if !rows.isEmpty {
                            Text(section.localizedName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            FCXLFormCard {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    FCXLFormRow(label: row.label,
                                                showDivider: index < rows.count - 1) {
                                        Text(row.value)
                                            .font(.system(size: 12))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    if let coordinate = info.coordinate {
                        map(coordinate)
                    }
                    HStack {
                        Button(L("exif.clean.button")) {
                            fcxlPresentModal {
                                guard let request = DialogService.shared
                                    .showCleanMetadata(paths: [path]) else { return }
                                _ = try? PhotoMetadataService.clean(
                                    path: path, what: request.what,
                                    keepingOriginal: request.keepOriginal)
                                load()
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: load)
        .onChange(of: path) { _ in load() }
    }

    @ViewBuilder
    private func map(_ coordinate: CLLocationCoordinate2D) -> some View {
        // A map rather than two numbers: "-22.906800, -43.172900" is a place nobody can picture,
        // and the whole point of the line is knowing where the picture was taken.
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))) {
                Marker("", coordinate: coordinate)
                    .tint(accent)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        HStack(spacing: 8) {
            Button(L("exif.openInMaps")) {
                let place = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
                place.name = (path as NSString).lastPathComponent
                place.openInMaps()
            }
            Button(copied ? L("ocr.dialog.copied") : L("exif.copyCoordinates")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PhotoMetadataService.format(coordinate),
                                               forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    copied = false
                }
            }
            Spacer()
        }
    }

    /// Reading the header of a 60-megapixel photograph is quick, but it is still a file read —
    /// and the viewer must never wait on one.
    private func load() {
        isLoading = true
        let path = self.path
        Task.detached(priority: .userInitiated) {
            let found = PhotoMetadataService.read(path: path)
            await MainActor.run {
                guard self.path == path else { return }
                info = found
                isLoading = false
            }
        }
    }
}
