import SwiftUI

struct SettingsContextMenuView: View {
    @AppStorage(ContextMenuSettings.fontSizeKey) private var fontSize: Double = ContextMenuSettings.defaultFontSize
    @AppStorage(ContextMenuSettings.rowHeightKey) private var rowHeight: Double = ContextMenuSettings.defaultRowHeight
    @AppStorage(ContextMenuSettings.iconSizeKey) private var iconSize: Double = ContextMenuSettings.defaultIconSize
    @AppStorage(ContextMenuSettings.paddingKey) private var padding: Double = ContextMenuSettings.defaultPadding
    @AppStorage(ContextMenuSettings.cornerRadiusKey) private var cornerRadius: Double = ContextMenuSettings.defaultCornerRadius
    @AppStorage(ContextMenuSettings.minWidthKey) private var minWidth: Double = ContextMenuSettings.defaultMinWidth
    @State private var previewWork: DispatchWorkItem?
    @State private var query = ""
    @ObservedObject private var layout = ContextMenuLayout.shared
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""

    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    var body: some View {
        Form {
            Section {
                Text(L("settings.contextMenu.livePreview"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("settings.contextMenu.arrange")) {
                Text(L("settings.contextMenu.arrange.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) {
                    available
                    VStack(alignment: .leading, spacing: 10) {
                        part(title: L("settings.contextMenu.main"), ids: layout.shownMain,
                             inExtra: false, empty: L("settings.contextMenu.emptyMain"))
                        part(title: L("settings.contextMenu.extra"), ids: layout.extra,
                             inExtra: true, empty: L("settings.contextMenu.emptyExtra"))
                    }
                }
                if layout.isCustomised {
                    Button(L("settings.contextMenu.reset")) { layout.reset(); refreshPreview() }
                }
            }

            Section(L("settings.contextMenu.sizes")) {
                slider(L("settings.contextMenu.fontSize"), value: $fontSize, in: 9...20, step: 1, unit: "pt")
                slider(L("design.rowHeight"), value: $rowHeight, in: 18...40, step: 1, unit: "px")
                slider(L("settings.contextMenu.iconSize"), value: $iconSize, in: 10...28, step: 1, unit: "px")
                slider(L("settings.contextMenu.padding"), value: $padding, in: 6...24, step: 1, unit: "px")
                slider(L("settings.contextMenu.cornerRadius"), value: $cornerRadius, in: 0...12, step: 1, unit: "px")
                slider(L("settings.contextMenu.minWidth"), value: $minWidth, in: 120...400, step: 5, unit: "px")
            }
            Section {
                Text(L("settings.contextMenu.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        // A LIVE preview: while this page is open, a real context menu hangs over the real
        // file panel, rebuilt as the knobs turn — and taken down the moment the page is left.
        .onAppear { refreshPreview() }
        .onDisappear { previewWork?.cancel(); mainController?.dismissContextMenuPreview() }
        .onChange(of: previewFingerprint) { _ in refreshPreview() }
    }

    // MARK: - Все команды программы

    /// Одна строка левого списка: штатный пункт меню, команда программы или разделитель.
    private struct Choice: Identifiable {
        let id: String
        let title: String
        let group: String
        let symbol: String
    }

    /// Всё, что можно положить в меню: разделитель, штатные пункты, затем каждая команда
    /// программы в своей группе — ровно те, что есть в строке меню.
    private var choices: [Choice] {
        var result = [Choice(id: ContextMenuLayout.separatorID,
                             title: L("settings.contextMenu.separator"),
                             group: "", symbol: "minus")]
        result += ContextMenuCatalogue.all.map {
            Choice(id: $0.id, title: $0.title, group: L("settings.contextMenu.builtins"),
                   symbol: $0.symbol)
        }
        result += CommandRegistry.commands().map {
            Choice(id: $0.stableID, title: $0.title, group: $0.group,
                   symbol: $0.symbolName ?? "command")
        }
        return result
    }

    /// Поиск по названию — тем же счётом, что и в палитре команд: человек набирает обрывок
    /// или начальные буквы, а не точное название.
    private var matches: [Choice] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return choices }
        return choices
            .compactMap { choice -> (Choice, Int)? in
                guard let score = CommandMatcher.score(text, against: choice.title) else { return nil }
                return (choice, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var available: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("settings.contextMenu.available"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if matches.isEmpty {
                        Text(L("settings.contextMenu.noMatches"))
                            .font(.caption).foregroundColor(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, choice in
                        if choice.group != groupAbove(index) {
                            Text(choice.group)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                        }
                        availableRow(choice)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func groupAbove(_ index: Int) -> String? {
        index == 0 ? nil : matches[index - 1].group
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundColor(.secondary)
            // Поле — из набора программы (то же, что в справке и в диалогах), а не системное.
            FCXLDialogTextField(text: $query, placeholder: L("settings.contextMenu.search"),
                                onCancel: { query = "" }, fontSize: 11)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func availableRow(_ choice: Choice) -> some View {
        // Разделителей в меню сколько угодно, поэтому «уже там» про них не говорят.
        let used = choice.id != ContextMenuLayout.separatorID && layout.contains(choice.id)
        return HStack(spacing: 6) {
            Image(systemName: choice.symbol)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundColor(.secondary)
            Text(choice.title)
                .font(.system(size: 11))
                .foregroundColor(used ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if used {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .help(L("settings.contextMenu.inMenu"))
                    .frame(width: 18, height: 16)
            } else {
                button("plus", help: L("settings.contextMenu.addToMain")) {
                    layout.add(choice.id, toExtra: false); refreshPreview()
                }
                button("arrow.down.to.line", help: L("settings.contextMenu.addToExtra")) {
                    layout.add(choice.id, toExtra: true); refreshPreview()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    // MARK: - Само меню

    private func part(title: String, ids: [String], inExtra: Bool, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if ids.isEmpty {
                        Text(empty).font(.caption).foregroundColor(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
                        menuRow(id, index: index, inExtra: inExtra, count: ids.count)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 145)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func menuRow(_ id: String, index: Int, inExtra: Bool, count: Int) -> some View {
        HStack(spacing: 6) {
            if id == ContextMenuLayout.separatorID {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(height: 1)
                    .padding(.vertical, 7)
            } else {
                Image(systemName: ContextMenuCatalogue.symbol(for: id))
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                Text(title(of: id))
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            button("chevron.up", help: L("tunnel.menu.moveUp"), enabled: index > 0) {
                layout.move(at: index, up: true, inExtra: inExtra); refreshPreview()
            }
            button("chevron.down", help: L("tunnel.menu.moveDown"), enabled: index < count - 1) {
                layout.move(at: index, up: false, inExtra: inExtra); refreshPreview()
            }
            button(inExtra ? "arrow.up.to.line" : "arrow.down.to.line",
                   help: inExtra ? L("settings.contextMenu.toMain") : L("settings.contextMenu.toExtra")) {
                layout.transfer(at: index, fromExtra: inExtra); refreshPreview()
            }
            button("xmark", help: L("settings.contextMenu.remove")) {
                layout.remove(at: index, fromExtra: inExtra); refreshPreview()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    /// Название записи: штатный пункт зовётся своей строкой, команда — своим названием в
    /// строке меню. Команда, которой в меню больше нет, показывается собственным именем —
    /// врать, что её нет вовсе, хуже: человек не поймёт, откуда в его меню пусто.
    private func title(of id: String) -> String {
        if let entry = ContextMenuCatalogue.entry(id) { return entry.title }
        if let command = CommandRegistry.command(id: id) { return command.title }
        return id
    }

    private func button(_ symbol: String, help: String, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(enabled ? accent : .secondary.opacity(0.35))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// Everything the preview's look depends on, in one comparable value — one onChange
    /// instead of nine.
    private var previewFingerprint: [Double] {
        [fontSize, rowHeight, iconSize, padding, cornerRadius, minWidth]
    }

    private var mainController: MainWindowController? {
        NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
    }

    /// Rebuilt after a short quiet moment, not on every tick of a slider drag: the menu's
    /// "Open with" list asks LaunchServices, and doing that sixty times a second is how a
    /// slider starts to stutter.
    private func refreshPreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { mainController?.showContextMenuPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value.snapped(to: step), in: range)
        }
    }
}
