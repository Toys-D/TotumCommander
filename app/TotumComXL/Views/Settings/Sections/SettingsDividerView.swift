import SwiftUI

struct SettingsDividerView: View {
    @AppStorage("centerDividerWidth") private var centerDividerWidth: Double = 36
    @AppStorage("quickLinksGap") private var quickLinksGap: Double = 12
    @AppStorage("dividerIconSpacing") private var dividerIconSpacing: Double = 2
    @AppStorage("dividerOffsetY") private var dividerOffsetY: Double = 0
    @AppStorage("dividerShowQuickLinks") private var dividerShowQuickLinks: Bool = true
    @AppStorage("dividerShowLabels") private var dividerShowLabels: Bool = true

    var body: some View {
        Form {
            Section(L("design.section.divider")) {
                slider(L("design.centerDividerWidth"), value: $centerDividerWidth, in: 20...150, step: 2)
                slider(L("design.quickLinksGap"), value: $quickLinksGap, in: 0...30, step: 2)
                slider(L("design.dividerIconSpacing"), value: $dividerIconSpacing, in: 0...10, step: 1)
                slider(L("design.dividerOffsetY"), value: $dividerOffsetY, in: -100...100, step: 5)
                Toggle(L("design.dividerShowQuickLinks"), isOn: $dividerShowQuickLinks)
                Toggle(L("design.dividerShowLabels"), isOn: $dividerShowLabels)
                    .disabled(centerDividerWidth < 40)
                if centerDividerWidth < 40 {
                    Text(L("design.dividerShowLabels.hint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) px")
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            Slider(value: value.snapped(to: step), in: range)
        }
    }
}
