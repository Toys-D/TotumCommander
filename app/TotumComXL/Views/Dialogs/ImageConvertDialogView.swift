import AppKit
import SwiftUI

/// Converting and resizing a pile of pictures — with the plan shown before anything is made.
///
/// The list at the bottom is the point of the window: it says, file by file, what will be
/// written and what size it will be. A batch that quietly replaced originals or stretched
/// photographs would only be noticed much later.
struct ImageConvertDialogView: View {
    let session: FCXLDialogSession<ImageConversionService.Options>
    let paths: [String]

    @State private var options = ImageConversionService.Options()
    @State private var steps: [ImageConversionService.Step] = []
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    private var changes: Bool {
        ImageConversionService.changesAnything(options, steps: steps)
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("convert.title"), icon: "photo.badge.arrow.down")

            Text(String(format: L("convert.subtitle"), paths.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    FCXLFormCard {
                        FCXLFormRow(label: L("convert.format")) {
                            FCXLDropdown(
                                selection: $options.format,
                                options: ImageConversionService.Format.allCases.map {
                                    ($0, $0.localizedName)
                                },
                                onChange: rebuild)
                            Spacer()
                        }
                        if options.format.usesQuality {
                            FCXLFormRow(label: L("convert.quality")) {
                                Slider(value: $options.quality, in: 0.3...1.0)
                                Text("\(Int(options.quality * 100))%")
                                    .font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                        FCXLToggleRow(label: L("convert.keepMetadata"),
                                      isOn: $options.keepsMetadata, showDivider: false)
                    }

                    FCXLFormCard {
                        FCXLFormRow(label: L("convert.size")) {
                            FCXLDropdown(
                                selection: $options.resize,
                                options: ImageConversionService.Resize.allCases.map {
                                    ($0, $0.localizedName)
                                },
                                onChange: rebuild)
                            Spacer()
                        }
                        if options.resize == .fit {
                            FCXLFormRow(label: L("convert.side")) {
                                number($options.side, placeholder: "2000")
                                Text(L("convert.pixels")).font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        if options.resize == .percent {
                            FCXLFormRow(label: L("convert.percent")) {
                                number($options.percent, placeholder: "50")
                                Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        if options.resize != .none {
                            FCXLToggleRow(label: L("convert.allowUpscale"),
                                          isOn: $options.allowsUpscale, showDivider: false)
                                .onChange(of: options.allowsUpscale) { _ in rebuild() }
                        }
                    }

                    FCXLFormCard {
                        FCXLFormRow(label: L("convert.where")) {
                            FCXLDropdown(
                                selection: $options.destination,
                                options: ImageConversionService.Destination.allCases.map {
                                    ($0, $0.localizedName)
                                },
                                onChange: rebuild)
                            Spacer()
                        }
                        if options.destination == .beside {
                            FCXLFormRow(label: L("convert.suffix"), showDivider: false) {
                                FCXLDialogTextField(text: $options.suffix,
                                                    placeholder: L("convert.suffix.default"),
                                                    onSubmit: rebuild)
                            }
                            .onChange(of: options.suffix) { _ in rebuild() }
                        }
                        if options.destination == .subfolder {
                            FCXLFormRow(label: L("convert.subfolder"), showDivider: false) {
                                FCXLDialogTextField(text: $options.subfolderName,
                                                    placeholder: L("convert.subfolder.default"),
                                                    onSubmit: rebuild)
                            }
                            .onChange(of: options.subfolderName) { _ in rebuild() }
                        }
                        if options.destination == .replace {
                            FCXLFormRow(showDivider: false) {
                                Text(L("convert.where.replace.note"))
                                    .font(.system(size: 11)).foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                        }
                    }

                    Text(L("convert.plan"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    FCXLFormCard {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            FCXLFormRow(showDivider: index < steps.count - 1) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((step.target as NSString).lastPathComponent)
                                        .font(.system(size: 12)).lineLimit(1)
                                    Text(line(for: step))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 20)

            if !changes {
                Text(L("convert.error.nothing"))
                    .font(.system(size: 11)).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 6)
            }

            FCXLDialogButtonBar(
                primaryTitle: L("convert.confirm"),
                primaryEnabled: changes && !steps.isEmpty,
                primaryAction: { session.finish(options) },
                destructive: options.destination == .replace,
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear(perform: rebuild)
    }

    /// "1200 × 600 → 600 × 300" — or just the size, when it is left alone.
    private func line(for step: ImageConversionService.Step) -> String {
        let original = step.originalSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "—"
        guard let new = step.newSize else { return original }
        return "\(original) → \(Int(new.width)) × \(Int(new.height))"
    }

    private func number(_ value: Binding<Int>, placeholder: String) -> some View {
        FCXLDialogTextField(
            text: Binding(get: { String(value.wrappedValue) },
                          set: {
                              value.wrappedValue = Int($0.filter(\.isNumber)) ?? 0
                              rebuild()
                          }),
            placeholder: placeholder)
        .frame(width: 80)
    }

    /// The plan follows every change of the settings — otherwise the list at the bottom would
    /// describe a batch nobody asked for any more.
    private func rebuild() {
        steps = ImageConversionService.plan(paths: paths, options: options)
    }
}
