import AppKit
import SwiftUI

/// One documented feature: a title, an introduction and a list of sections.
///
/// Every string here is a localisation KEY, and the keys are the same ones the in-place "?" popovers
/// render. The help window and the popovers therefore always say the same thing — editing the text
/// in one place changes both, and neither can drift into describing an older version of the tool.
struct HelpTopic: Identifiable {
    let id: String
    let titleKey: String
    let systemImage: String
    let introKey: String?
    /// (section title key, section body key)
    let sections: [(String, String)]

    /// Полная справка по программе — Markdown из бандла на языке программы (HelpGuide).
    static let guideID = "guide"

    static let all: [HelpTopic] = [
        HelpTopic(id: guideID, titleKey: "help.guide.title", systemImage: "book",
                  introKey: nil, sections: []),
        HelpTopic(
            id: "compare",
            titleKey: "menu.tools.compare",
            systemImage: "arrow.left.arrow.right",
            introKey: "compare.help.intro",
            sections: [
                ("compare.help.what.title", "compare.help.what.body"),
                ("compare.help.arrows.title", "compare.help.arrows.body"),
                ("compare.help.paths.title", "compare.help.paths.body"),
                ("compare.help.columns.title", "compare.help.columns.body"),
                ("compare.help.filter.title", "compare.help.filter.body"),
                ("compare.help.content.title", "compare.help.content.body"),
                ("compare.help.ignoredate.title", "compare.help.ignoredate.body"),
                ("compare.help.mask.title", "compare.help.mask.body"),
                ("compare.help.copy.title", "compare.help.copy.body"),
                ("compare.help.move.title", "compare.help.move.body"),
                ("compare.help.exclude.title", "compare.help.exclude.body"),
                ("compare.help.delete.title", "compare.help.delete.body"),
                ("compare.help.folders.title", "compare.help.folders.body"),
                ("compare.help.safety.title", "compare.help.safety.body"),
                ("compare.help.summary.title", "compare.help.summary.body"),
                ("compare.help.example.title", "compare.help.example.body"),
            ]),

        HelpTopic(
            id: "checksum",
            titleKey: "menu.tools.checksum",
            systemImage: "number",
            introKey: "checksum.help.intro",
            sections: [
                ("checksum.help.what.title", "checksum.help.what.body"),
                ("checksum.help.algorithms.title", "checksum.help.algorithms.body"),
                ("checksum.help.verify.title", "checksum.help.verify.body"),
                ("checksum.help.save.title", "checksum.help.save.body"),
                ("checksum.help.example.title", "checksum.help.example.body"),
            ]),

        HelpTopic(
            id: "tags",
            titleKey: "context.tags",
            systemImage: "tag",
            introKey: "tags.help.intro",
            sections: [
                ("tags.help.set.title", "tags.help.set.body"),
                ("tags.help.see.title", "tags.help.see.body"),
                ("tags.help.finder.title", "tags.help.finder.body"),
            ]),

        HelpTopic(
            id: "pdf",
            titleKey: "pdf.help.topic",
            systemImage: "doc.richtext",
            introKey: "pdf.help.intro",
            sections: [
                ("pdf.help.make.title", "pdf.help.make.body"),
                ("pdf.help.pageSize.title", "pdf.help.pageSize.body"),
                ("pdf.help.merge.title", "pdf.help.merge.body"),
                ("pdf.help.order.title", "pdf.help.order.body"),
                ("pdf.help.split.title", "pdf.help.split.body"),
                ("pdf.help.ranges.title", "pdf.help.ranges.body"),
                ("pdf.help.rotate.title", "pdf.help.rotate.body"),
                ("pdf.help.replace.title", "pdf.help.replace.body"),
                ("pdf.help.where.title", "pdf.help.where.body"),
            ]),

        HelpTopic(
            id: "rules",
            titleKey: "rules.editor.title",
            systemImage: "slider.horizontal.3",
            introKey: "rules.help.intro",
            sections: [
                ("rules.help.order.title", "rules.help.order.body"),
                ("rules.help.head.title", "rules.help.head.body"),
                ("rules.help.conditions.title", "rules.help.conditions.body"),
                ("rules.help.tests.title", "rules.help.tests.body"),
                ("rules.help.actions.title", "rules.help.actions.body"),
                ("rules.help.destination.title", "rules.help.destination.body"),
                ("rules.help.masks.title", "rules.help.masks.body"),
                ("rules.help.apply.title", "rules.help.apply.body"),
                ("rules.help.safety.title", "rules.help.safety.body"),
            ]),

        HelpTopic(
            id: "git",
            titleKey: "settings.git.title",
            systemImage: "arrow.triangle.branch",
            introKey: "git.help.intro",
            sections: [
                ("git.help.letters.title", "git.help.letters.body"),
                ("git.help.folders.title", "git.help.folders.body"),
                ("git.help.branch.title", "git.help.branch.body"),
                ("git.help.where.title", "git.help.where.body"),
                ("git.help.source.title", "git.help.source.body"),
                ("git.help.off.title", "git.help.off.body"),
            ]),

        HelpTopic(
            id: "split",
            titleKey: "menu.tools.split",
            systemImage: "scissors",
            introKey: "split.help.intro",
            sections: [
                ("split.help.how.title", "split.help.how.body"),
                ("split.help.names.title", "split.help.names.body"),
                ("split.help.join.title", "split.help.join.body"),
                ("split.help.checksum.title", "split.help.checksum.body"),
            ]),

        HelpTopic(
            id: "multirename",
            titleKey: "menu.tools.multiRename",
            systemImage: "textformat.abc",
            introKey: "mrt.help.intro",
            sections: [
                ("mrt.help.masks.title", "mrt.help.masks.body"),
                ("mrt.help.counter.title", "mrt.help.counter.body"),
                ("mrt.help.date.title", "mrt.help.date.body"),
                ("mrt.help.search.title", "mrt.help.search.body"),
                ("mrt.help.switches.title", "mrt.help.switches.body"),
                ("mrt.help.case.title", "mrt.help.case.body"),
                ("mrt.help.subfolder.title", "mrt.help.subfolder.body"),
                ("mrt.help.preview.title", "mrt.help.preview.body"),
                ("mrt.help.tags.name.title", "mrt.help.tags.name.body"),
                ("mrt.help.tags.counter.title", "mrt.help.tags.counter.body"),
                ("mrt.help.tags.date.title", "mrt.help.tags.date.body"),
                ("mrt.help.tags.path.title", "mrt.help.tags.path.body"),
                ("mrt.help.tags.meta.title", "mrt.help.tags.meta.body"),
                ("mrt.help.tags.case.title", "mrt.help.tags.case.body"),
            ]),

        HelpTopic(
            id: "monitor",
            titleKey: "monitor.title",
            systemImage: "waveform.path.ecg",
            introKey: "monitor.help.intro",
            sections: [
                ("monitor.help.tabs.title", "monitor.help.tabs.body"),
                ("monitor.help.columns.title", "monitor.help.columns.body"),
                ("monitor.help.actions.title", "monitor.help.actions.body"),
                ("monitor.help.limits.title", "monitor.help.limits.body"),
            ]),
    ]
}

/// The Help window: topics down the side, the chosen one on the right. Same shape and the same
/// accent selection pill as the Settings window, so it feels like part of the app rather than a
/// system help viewer.
struct HelpWindowView: View {
    @State private var selection: String = HelpTopic.all.first?.id ?? ""
    @State private var search = ""
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""

    private var topic: HelpTopic {
        HelpTopic.all.first { $0.id == selection } ?? HelpTopic.all[0]
    }

    /// Sections matching the search box. Titles AND bodies are searched, because the thing a user
    /// remembers is usually a word from the explanation, not the heading.
    private var visibleSections: [(String, String)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return topic.sections }
        return topic.sections.filter {
            L($0.0).lowercased().contains(q) || L($0.1).lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var sidebar: some View {
        let accent = PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
        let onAccent = PanelAppearanceSettings.contrastingTextColor(on: accent)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(HelpTopic.all) { t in
                let isSelected = t.id == selection
                Button { selection = t.id } label: {
                    HStack(spacing: 8) {
                        Image(systemName: t.systemImage)
                            .frame(width: 18)
                            .foregroundStyle(isSelected ? onAccent : accent)
                        Text(L(t.titleKey).replacingOccurrences(of: "…", with: ""))
                            .foregroundStyle(isSelected ? onAccent : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focusable(false)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 220)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L(topic.titleKey).replacingOccurrences(of: "…", with: ""))
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    FCXLDialogTextField(text: $search, placeholder: L("help.search"))
                        .frame(width: 160)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            Divider()

            if topic.id == HelpTopic.guideID {
                HelpGuideView(query: search)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let introKey = topic.introKey, search.isEmpty {
                        Text(L(introKey))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if visibleSections.isEmpty {
                        Text(L("help.noResults")).font(.system(size: 12))
                            .foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(visibleSections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L(section.0)).font(.system(size: 13, weight: .semibold))
                            Text(L(section.1)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }
    }
}
