import SwiftUI

/// What the rules would do to this folder, shown BEFORE anything is done.
///
/// The plan is the whole safety of the feature. A rule is a small program written in a hurry,
/// and the first time one runs it is usually not quite what its author meant — so it is read
/// here, line by line, with a switch on every line, and only what stays ticked happens.
struct FolderRulesApplyView: View {
    let session: FCXLDialogSession<[RuleStep]>
    let folder: String
    let steps: [RuleStep]

    @State private var chosen: Set<String>
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    init(session: FCXLDialogSession<[RuleStep]>, folder: String, steps: [RuleStep]) {
        self.session = session
        self.folder = folder
        self.steps = steps
        // Everything the rules matched starts ticked: the person asked for the rules to run.
        _chosen = State(initialValue: Set(steps.map(\.source)))
    }

    private var removals: Int {
        steps.filter { chosen.contains($0.source) && $0.action.kind == .trash }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("rules.apply.title"),
                             icon: "wand.and.rays")

            Text(String(format: L("rules.apply.subtitle"),
                        (folder as NSString).lastPathComponent))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(steps) { step in
                        row(step)
                        Divider().opacity(0.35)
                    }
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)

            HStack {
                Text(String(format: L("rules.apply.chosen"), chosen.count, steps.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if removals > 0 {
                    Text(String(format: L("rules.apply.removals"), removals))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                Spacer()
                Button(L("rules.apply.none")) { chosen = [] }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                Button(L("rules.apply.all")) { chosen = Set(steps.map(\.source)) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            FCXLDialogButtonBar(
                primaryTitle: L("rules.apply.confirm"),
                primaryEnabled: !chosen.isEmpty,
                primaryAction: { session.finish(steps.filter { chosen.contains($0.source) }) },
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 640, minHeight: 440)
    }

    @ViewBuilder
    private func row(_ step: RuleStep) -> some View {
        HStack(spacing: 10) {
            FCXLSwitch(isOn: Binding(
                get: { chosen.contains(step.source) },
                set: { on in
                    if on { chosen.insert(step.source) } else { chosen.remove(step.source) }
                }))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text((step.source as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(step.action.localizedName)
                        .font(.system(size: 10))
                        .foregroundStyle(step.action.kind == .trash ? Color.orange : accent)
                    if !step.ruleName.isEmpty {
                        Text("· \(step.ruleName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // Where it ends up. The actions that leave the file alone say so instead of
                // showing an empty line.
                Text(step.target.isEmpty ? L("rules.apply.inPlace") : step.target)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(step.target.isEmpty ? step.source : step.target)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
