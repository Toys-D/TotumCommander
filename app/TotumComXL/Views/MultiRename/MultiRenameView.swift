import SwiftUI

/// The Multi-Rename tool window content. Built from FCXLDialogKit so it matches the app's other
/// dialogs (Advanced Search in particular). Feature set mirrors Total Commander's Multi-Rename
/// Tool; the styling is ours.
struct MultiRenameView: View {
    @ObservedObject var vm: MultiRenameViewModel
    let onClose: () -> Void

    @State private var showHelp = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    /// Tags offered by the "insert tag" menu, grouped. Inserted by appending to the name mask.
    private let tagGroups: [(String, [String])] = [
        ("mrt.taggroup.name", ["[N]", "[N1-5]", "[E]", "[A]"]),
        ("mrt.taggroup.counter", ["[C]", "[C1+1:2]", "[Ca]", "[c]"]),
        ("mrt.taggroup.date", ["[Y]", "[y]", "[M]", "[D]", "[YMD]", "[h]", "[m]", "[s]", "[hms]"]),
        ("mrt.taggroup.path", ["[P]", "[G]", "[B0]", "[B+0]", "[I]"]),
        ("mrt.taggroup.meta", ["[=tc.size]", "[=tc.width]", "[=tc.height]", "[=tc.writedate]"]),
        ("mrt.taggroup.case", ["[U]", "[L]", "[F]", "[f]", "[n]"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("mrt.title"), subtitle: L("mrt.subtitle", vm.items.count))
                .overlay(alignment: .topTrailing) {
                    Button { showHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    // Skip this button in the focus chain. With macOS "Full Keyboard Access" on,
                    // the system draws a focus ring on whatever holds focus and focusEffectDisabled
                    // cannot suppress it — the "?" was the first focusable control in the dialog, so
                    // it opened with a blue square around it. Focus now starts on the real controls.
                    .focusable(false)
                    .help(L("mrt.help.button"))
                    .popover(isPresented: $showHelp, arrowEdge: .top) { helpContent }
                    .padding(.trailing, 20)
                    .padding(.top, 18)
                }

            VStack(spacing: 12) {
                masksCounterCard
                searchCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            previewSection

            statusRow
            buttonBar
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    // MARK: - Cards

    /// Masks + counter/case in one card, laid out as a Grid so the two rows share column
    /// positions: the tag menu sits above "Регистр", and "Расширение" above the case dropdown.
    private var masksCounterCard: some View {
        FCXLFormCard {
            // Fixed-width columns so the two rows line up tidily:
            //   col1 label · col2-3 name field (spans старт+шаг) · col4 Теги (over цифр) ·
            //   col5 flexible spacer · col6 right-aligned label · col7 left-aligned value.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text(L("mrt.nameMask")).font(.system(size: 13)).fixedSize()
                    FCXLDialogTextField(text: $vm.rule.nameMask, placeholder: "[N]")
                        .frame(width: Self.counterColWidth * 2 + 10)
                        .gridCellColumns(2)
                    tagMenu
                    Spacer()
                    Text(L("mrt.extMask")).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                    FCXLDialogTextField(text: $vm.rule.extMask, placeholder: "[E]")
                        .frame(width: 120)
                        .gridColumnAlignment(.leading)
                }
                Divider()
                GridRow {
                    Text(L("mrt.counter")).font(.system(size: 13)).fixedSize()
                    counterField(L("mrt.counter.start"), \.counterStart, range: 0...999999)
                    counterField(L("mrt.counter.step"), \.counterStep, range: 1...999999)
                    counterField(L("mrt.counter.digits"), \.counterDigits, range: 1...10)
                    Spacer()
                    Text(L("mrt.case")).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize()
                    FCXLDropdown(selection: $vm.rule.caseMode, options: [
                        (.unchanged, L("mrt.case.unchanged")),
                        (.lower, L("mrt.case.lower")),
                        (.upper, L("mrt.case.upper")),
                        (.firstUpper, L("mrt.case.firstUpper")),
                        (.eachWord, L("mrt.case.eachWord")),
                    ], onChange: { vm.recomputeNow() })
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// "Insert tag" menu for the NAME mask — appends the chosen placeholder. Native pull-down
    /// (chevron on the right, flat) so it matches the case dropdown and the Settings pickers.
    private var tagMenu: some View {
        FCXLMenuButton(
            title: L("mrt.tags"),
            groups: tagGroups.map { (header: L($0.0), items: $0.1) },
            onSelect: { tag in vm.rule.nameMask += tag })
        .fixedSize()
        .help(L("mrt.insertTag"))
    }

    /// Fixed width of one counter column (caption + field + stepper). The name field spans two of
    /// these so the tag menu lands in the third column, directly above the "цифр" field.
    static let counterColWidth: CGFloat = 106

    /// Counter field: inline caption + a numeric field with ↕ stepper arrows. You can type any
    /// number or click the arrows; both write the rule (its didSet schedules a recompute).
    private func counterField(_ label: String, _ kp: WritableKeyPath<RenameRule, Int>,
                              range: ClosedRange<Int>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            FCXLDialogTextField(text: intBinding(kp)).frame(width: 40)
            Stepper("", value: intValue(kp), in: range).labelsHidden()
        }
        .frame(width: Self.counterColWidth, alignment: .leading)
    }

    /// String<->Int bridge for the counter text field. Writing back mutates the rule (via its
    /// didSet, which schedules a recompute), so no explicit onChange is needed.
    private func intBinding(_ kp: WritableKeyPath<RenameRule, Int>) -> Binding<String> {
        Binding(get: { String(vm.rule[keyPath: kp]) },
                set: { vm.rule[keyPath: kp] = Int($0.filter(\.isNumber)) ?? 0 })
    }

    /// Direct Int binding for the stepper (its didSet schedules a recompute).
    private func intValue(_ kp: WritableKeyPath<RenameRule, Int>) -> Binding<Int> {
        Binding(get: { vm.rule[keyPath: kp] }, set: { vm.rule[keyPath: kp] = $0 })
    }

    private var searchCard: some View {
        FCXLFormCard {
            FCXLFormRow(label: L("mrt.search")) {
                FCXLDialogTextField(text: $vm.rule.search, placeholder: L("mrt.search.placeholder"))
            }
            FCXLFormRow(label: L("mrt.replace")) {
                FCXLDialogTextField(text: $vm.rule.replace, placeholder: L("mrt.replace.placeholder"))
            }
            FCXLFormRow(label: "", showDivider: false) {
                switchOption(L("mrt.regex"), $vm.rule.useRegex)
                switchOption(L("mrt.respectCase"), $vm.rule.respectCase)
                switchOption(L("mrt.once"), $vm.rule.replaceOnce)
                switchOption(L("mrt.inExt"), $vm.rule.searchInExtension)
                Spacer()
            }
        }
    }

    /// One boolean option as our switch + label. Writing the binding mutates the rule, whose
    /// didSet schedules the preview recompute — no explicit onChange needed.
    private func switchOption(_ label: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            FCXLSwitch(isOn: value)
            Text(label).font(.system(size: 12))
        }
        .padding(.trailing, 8)
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(spacing: 4) {
            HStack {
                Text(L("mrt.preview")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            RenamePreviewTable(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Status row + button bar (FCXLDialog family style)

    private var statusRow: some View {
        HStack(spacing: 12) {
            presetsMenu
            if vm.conflictCount > 0 {
                Label(L("mrt.conflicts", vm.conflictCount), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            Spacer()
            Text(L("mrt.willRename", vm.actionablePlans.count))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var presetsMenu: some View {
        Menu {
            if vm.presets.isEmpty {
                Text(L("mrt.presets.empty"))
            } else {
                ForEach(vm.presets, id: \.name) { preset in
                    Button(preset.name) { vm.applyPreset(preset) }
                }
                Divider()
                Menu(L("mrt.presets.delete")) {
                    ForEach(vm.presets, id: \.name) { preset in
                        Button(preset.name) { vm.deletePreset(name: preset.name) }
                    }
                }
            }
            Divider()
            Button(L("mrt.presets.saveAs")) { promptSavePreset() }
        } label: {
            Label(L("mrt.presets"), systemImage: "bookmark")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func promptSavePreset() {
        fcxlPresentModal {
            if let name = DialogService.shared.showTextInput(
                title: L("mrt.presets.saveTitle"),
                message: L("mrt.presets.saveMessage"),
                defaultValue: ""),
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vm.savePreset(name: name)
            }
        }
    }

    private var buttonBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button(action: { vm.undo() }) { barLabel(L("mrt.undo")) }
                    .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                    .disabled(!vm.undoAvailable)

                Divider().frame(height: 48)
                Button(action: onClose) { barLabel(L("button.close")) }
                    .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                    .keyboardShortcut(.cancelAction)

                Divider().frame(height: 48)
                Button(action: { vm.execute() }) { barLabel(L("mrt.rename")) }
                    .buttonStyle(FCXLDialogPrimaryButtonStyle(
                        accent: accent,
                        textColor: PanelAppearanceSettings.contrastingTextColor(on: accent),
                        fontSize: 13))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!vm.canExecute)
            }
        }
    }

    private func barLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 4)
    }

    // MARK: - Help popover

    private var helpContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("mrt.help.title")).font(.system(size: 15, weight: .semibold))
                Text(L("mrt.help.intro")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                helpSection("mrt.help.masks.title", "mrt.help.masks.body")
                helpSection("mrt.help.counter.title", "mrt.help.counter.body")
                helpSection("mrt.help.date.title", "mrt.help.date.body")
                helpSection("mrt.help.search.title", "mrt.help.search.body")
                helpSection("mrt.help.switches.title", "mrt.help.switches.body")
                helpSection("mrt.help.case.title", "mrt.help.case.body")
                helpSection("mrt.help.subfolder.title", "mrt.help.subfolder.body")
                helpSection("mrt.help.preview.title", "mrt.help.preview.body")

                Divider().padding(.vertical, 2)
                Text(L("mrt.help.reference.title")).font(.system(size: 15, weight: .semibold))
                tagRefSection("mrt.help.tags.name.title", "mrt.help.tags.name.body")
                tagRefSection("mrt.help.tags.counter.title", "mrt.help.tags.counter.body")
                tagRefSection("mrt.help.tags.date.title", "mrt.help.tags.date.body")
                tagRefSection("mrt.help.tags.path.title", "mrt.help.tags.path.body")
                tagRefSection("mrt.help.tags.meta.title", "mrt.help.tags.meta.body")
                tagRefSection("mrt.help.tags.case.title", "mrt.help.tags.case.body")
            }
            .padding(18)
            .frame(width: 420, alignment: .leading)
        }
        .frame(width: 420, height: 520)
    }

    private func helpSection(_ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(titleKey)).font(.system(size: 13, weight: .semibold))
            Text(L(bodyKey)).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A tag-reference block: the tag list is monospaced so [N2-5] and friends line up and read
    /// clearly as literal placeholders.
    private func tagRefSection(_ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(titleKey)).font(.system(size: 13, weight: .semibold))
            Text(L(bodyKey))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
