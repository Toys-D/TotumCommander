import SwiftUI

/// Writing the rules: the list on the left, the chosen one opened on the right.
///
/// Order carries meaning — the first rule that matches a file takes it — so the list can be
/// rearranged and says as much, rather than sorting itself by name behind the person's back.
struct FolderRulesEditorView: View {
    let session: FCXLDialogSession<[FolderRule]>

    @State private var rules: [FolderRule]
    @State private var selection: UUID?
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    init(session: FCXLDialogSession<[FolderRule]>, rules: [FolderRule]) {
        self.session = session
        _rules = State(initialValue: rules)
        _selection = State(initialValue: rules.first?.id)
    }

    @State private var showHelp = false

    private var chosenIndex: Int? { rules.firstIndex { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("rules.editor.title"), icon: "slider.horizontal.3")
                .overlay(alignment: .topTrailing) {
                    Button { showHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    // Out of the focus chain: with Full Keyboard Access on, the system draws its
                    // own ring on whatever holds focus, and the "?" would open the dialog wearing
                    // a blue square.
                    .focusable(false)
                    .help(L("rules.help.button"))
                    .popover(isPresented: $showHelp, arrowEdge: .top) { helpContent }
                    .padding(.trailing, 20)
                    .padding(.top, 18)
                }

            HStack(spacing: 12) {
                list
                Divider()
                if let index = chosenIndex {
                    editor(for: index)
                } else {
                    VStack {
                        Spacer()
                        Text(L("rules.editor.empty"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)

            FCXLDialogButtonBar(
                primaryTitle: L("button.save"),
                primaryAction: { session.finish(rules) },
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    // MARK: - Help

    /// The same words as the Help window's "Folder rules" topic — the keys are shared, so the
    /// two can never drift into describing different programs.
    private var helpContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("rules.editor.title")).font(.system(size: 15, weight: .semibold))
                Text(L("rules.help.intro")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                helpSection("rules.help.order.title", "rules.help.order.body")
                helpSection("rules.help.head.title", "rules.help.head.body")
                helpSection("rules.help.conditions.title", "rules.help.conditions.body")
                helpSection("rules.help.tests.title", "rules.help.tests.body")
                helpSection("rules.help.actions.title", "rules.help.actions.body")
                helpSection("rules.help.destination.title", "rules.help.destination.body")
                helpSection("rules.help.masks.title", "rules.help.masks.body")
                helpSection("rules.help.apply.title", "rules.help.apply.body")
                helpSection("rules.help.safety.title", "rules.help.safety.body")
            }
            .padding(18)
            .frame(width: 430, alignment: .leading)
        }
        .frame(width: 430, height: 520)
    }

    private func helpSection(_ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(titleKey)).font(.system(size: 13, weight: .semibold))
            Text(L(bodyKey)).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 6) {
            // No ScrollView over nothing: with "Show scroll bars: Always" it drew a full-height
            // scroller down an empty list. The box stays; the words about + are on the right.
            Group {
                if rules.isEmpty {
                    Color.clear
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(rules) { rule in
                                let isChosen = rule.id == selection
                                HStack(spacing: 6) {
                                    FCXLSwitch(isOn: binding(for: rule.id, \.isEnabled))
                                    Text(rule.name.isEmpty ? L("rules.editor.untitled") : rule.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundStyle(isChosen ? Color.white : .primary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(isChosen ? accent : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { selection = rule.id }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 6) {
                toolButton("plus", L("rules.editor.add")) {
                    var rule = FolderRule(name: L("rules.editor.untitled"))
                    rule.conditions = [RuleCondition()]
                    rules.append(rule)
                    selection = rule.id
                }
                toolButton("minus", L("rules.editor.remove")) {
                    guard let index = chosenIndex else { return }
                    rules.remove(at: index)
                    selection = rules.first?.id
                }
                .disabled(chosenIndex == nil)
                Spacer()
                toolButton("chevron.up", L("rules.editor.up")) { move(by: -1) }
                    .disabled((chosenIndex ?? 0) == 0)
                toolButton("chevron.down", L("rules.editor.down")) { move(by: 1) }
                    .disabled(chosenIndex == nil || chosenIndex == rules.count - 1)
            }
        }
        .frame(width: 220)
        .padding(.vertical, 8)
    }

    private func toolButton(_ symbol: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(FCXLToolbarButtonStyle())
        .help(help)
    }

    private func move(by offset: Int) {
        guard let index = chosenIndex else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
    }

    // MARK: - The rule

    @ViewBuilder
    private func editor(for index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    FCXLFormRow(label: L("rules.editor.name")) {
                        FCXLDialogTextField(text: binding(index, \.name))
                    }
                    FCXLFormRow(label: L("rules.editor.match")) {
                        FCXLDropdown(
                            selection: binding(index, \.matchAll),
                            options: [(true, L("rules.editor.matchAll")),
                                      (false, L("rules.editor.matchAny"))])
                        Spacer()
                    }
                    FCXLToggleRow(label: L("rules.editor.includeFolders"),
                                  isOn: binding(index, \.includeFolders),
                                  showDivider: false)
                }

                Text(L("rules.editor.conditions"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                FCXLFormCard {
                    ForEach(Array(rules[index].conditions.enumerated()), id: \.element.id) {
                        position, condition in
                        conditionRow(ruleIndex: index, position: position, condition: condition)
                    }
                    FCXLFormRow(showDivider: false) {
                        Button(L("rules.editor.addCondition")) {
                            rules[index].conditions.append(RuleCondition())
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                        Spacer()
                    }
                }

                Text(L("rules.editor.action"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                FCXLFormCard {
                    FCXLFormRow(label: L("rules.editor.doThis")) {
                        FCXLDropdown(
                            selection: binding(index, \.action.kind),
                            options: RuleAction.Kind.allCases.map {
                                ($0, L("rules.action.\($0.rawValue)"))
                            })
                        Spacer()
                    }
                    actionFields(index)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func actionFields(_ index: Int) -> some View {
        switch rules[index].action.kind {
        case .move, .copy:
            FCXLFormRow(label: L("rules.editor.destination")) {
                FCXLDialogTextField(text: binding(index, \.action.destination),
                                    placeholder: "/Users/…")
                Button(L("rules.editor.choose")) {
                    if let picked = chooseFolder() {
                        rules[index].action.destination = picked
                    }
                }
                .buttonStyle(FCXLToolbarButtonStyle())
            }
            FCXLFormRow(label: L("rules.editor.subfolder"), showDivider: false) {
                FCXLDialogTextField(text: binding(index, \.action.subfolder),
                                    placeholder: "yyyy/MM")
                Text(L("rules.editor.subfolder.hint"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .rename:
            FCXLFormRow(label: L("rules.editor.nameMask")) {
                FCXLDialogTextField(text: binding(index, \.action.nameMask), placeholder: "[N]")
            }
            FCXLFormRow(label: L("rules.editor.extMask"), showDivider: false) {
                FCXLDialogTextField(text: binding(index, \.action.extMask), placeholder: "[E]")
            }
        case .tag:
            FCXLFormRow(label: L("rules.editor.tag"), showDivider: false) {
                FCXLDropdown(
                    selection: binding(index, \.action.tag),
                    options: FinderTag.allCases.map { ($0.rawValue, $0.localizedName) })
                Spacer()
            }
        case .trash, .shelf, .unpack:
            FCXLFormRow(showDivider: false) {
                Text(L("rules.action.\(rules[index].action.kind.rawValue).hint"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func conditionRow(ruleIndex: Int, position: Int,
                              condition: RuleCondition) -> some View {
        FCXLFormRow(showDivider: true) {
            FCXLDropdown(
                selection: Binding(
                    get: { rules[ruleIndex].conditions[position].field },
                    set: { field in
                        rules[ruleIndex].conditions[position].field = field
                        // The tests on offer change with the field; a leftover one from the
                        // previous field would read as nonsense ("size matches *.jpg").
                        if let first = field.tests.first,
                           !field.tests.contains(rules[ruleIndex].conditions[position].test) {
                            rules[ruleIndex].conditions[position].test = first
                        }
                        // Words typed BEFORE the switch were written under another meaning, so
                        // they are put in order now — otherwise "jpg jpeg" stays dotless just
                        // because the field was changed after the typing rather than before it.
                        if field == .ext {
                            let typed = rules[ruleIndex].conditions[position].text
                            rules[ruleIndex].conditions[position].text =
                                FolderRules.normalizedExtensions(typed)
                        }
                    }),
                options: RuleCondition.Field.allCases.map { ($0, $0.localizedName) })

            FCXLDropdown(
                selection: Binding(
                    get: { rules[ruleIndex].conditions[position].test },
                    set: { rules[ruleIndex].conditions[position].test = $0 }),
                options: condition.field.tests.map { ($0, $0.localizedName) })

            switch condition.field {
            case .size, .modified, .created, .added:
                FCXLDialogTextField(
                    text: Binding(
                        get: { numberText(rules[ruleIndex].conditions[position].number) },
                        set: { rules[ruleIndex].conditions[position].number = Double($0) ?? 0 }),
                    placeholder: "0")
                .frame(width: 70)
                Text(condition.field == .size ? L("unit.megabytes") : L("unit.days"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            default:
                FCXLDialogTextField(
                    text: Binding(
                        get: { rules[ruleIndex].conditions[position].text },
                        set: { typed in
                            // An extension list tidies itself as it is typed; everything else is
                            // taken exactly as written.
                            rules[ruleIndex].conditions[position].text =
                                condition.field == .ext ? FolderRules.tidiedExtensions(typed)
                                                        : typed
                        }),
                    placeholder: placeholder(for: condition.field))
            }

            Button {
                rules[ruleIndex].conditions.remove(at: position)
            } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(FCXLToolbarButtonStyle())
        }
    }

    private func placeholder(for field: RuleCondition.Field) -> String {
        switch field {
        case .name: return "отчёт*"
        case .ext:  return ".jpg, .png"
        case .kind: return "image, video"
        case .tag:  return FinderTag.red.rawValue
        default:    return ""
        }
    }

    private func numberText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func chooseFolder() -> String? {
        DialogService.shared.showFolderPicker(title: L("rules.editor.choose"), defaultPath: nil)
    }

    // MARK: - Bindings

    private func binding<Value>(_ index: Int,
                                _ path: WritableKeyPath<FolderRule, Value>) -> Binding<Value> {
        Binding(get: { rules[index][keyPath: path] },
                set: { rules[index][keyPath: path] = $0 })
    }

    private func binding<Value>(for id: UUID,
                                _ path: WritableKeyPath<FolderRule, Value>) -> Binding<Value> {
        Binding(
            get: { rules.first { $0.id == id }?[keyPath: path] ?? rules[0][keyPath: path] },
            set: { value in
                guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
                rules[index][keyPath: path] = value
            })
    }
}
