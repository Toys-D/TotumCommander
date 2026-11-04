import AppKit
import SwiftUI

/// Найденная настройка: раздел и подпись строки.
struct SettingsSearchHit: Identifiable, Equatable {
    let section: SettingsSection
    let key: String
    let title: String
    var id: String { section.rawValue + "|" + key }
}

/// Поиск по настройкам: подписи всех разделов из `SettingsSearchIndex`, сравнение без учёта
/// регистра и диакритики, все слова запроса должны встретиться.
enum SettingsSearch {
    /// Та же строка, что EXCLUDED в scripts/gen_settings_index.py: подсказки, кнопки и тексты
    /// диалогов — не настройки.
    static let excludedKeyPattern =
        #"(?i)(hint|message|restart|failed|placeholder|browse|\.now$|\.later$|^unit\.|^button\.|^common\.|^dialog|\.title$|\.ok$|\.cancel$|\.remove$|\.add$|\.delete$|\.reset|\.help$|\.verdict|\.summary|\.stage\.|\.error\.|\.obstacle\.|\.page$|\.install$|\.link$|\.example|\.none$|\.tooltip$)"#

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }

    static func matches(_ title: String, query: String) -> Bool {
        let words = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return false }
        let haystack = normalized(title)
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Совпадения в порядке разделов и строк внутри раздела.
    static func hits(for query: String,
                     index: [SettingsSection: [(key: String, group: String?)]] = SettingsSearchIndex.entries,
                     title: (String) -> String = { L($0) }) -> [SettingsSearchHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var result: [SettingsSearchHit] = []
        for section in SettingsSection.allCases {
            for entry in index[section] ?? [] {
                let text = title(entry.key)
                if matches(text, query: query) {
                    result.append(SettingsSearchHit(section: section, key: entry.key, title: text))
                }
            }
        }
        return result
    }
}

/// Список найденных настроек вместо страницы раздела, пока в поле что-то набрано.
struct SettingsSearchResultsView: View {
    let query: String
    let accent: Color
    let onOpen: (SettingsSearchHit) -> Void

    var body: some View {
        let hits = SettingsSearch.hits(for: query)
        VStack(alignment: .leading, spacing: 0) {
            Text(L("settings.search.title"))
                .font(.title2).fontWeight(.semibold)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
            if hits.isEmpty {
                Text(L("settings.search.noResults"))
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hits) { hit in
                            Button { onOpen(hit) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: hit.section.systemImage)
                                        .foregroundStyle(accent)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.title)
                                        Text(hit.section.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 6).padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Якорь строки настройки: по нему страница прокручивается к найденному и обводит строку.
/// Ставится на Toggle или подпись строки; ключ — тот же ключ строки, что в индексе поиска.
struct SettingAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func settingAnchor(_ key: String) -> some View {
        self.id(key)
            .anchorPreference(key: SettingAnchorKey.self, value: .bounds) { [key: $0] }
    }
}

/// Прокрутка к найденной строке и полоса подсветки поверх страницы, гаснущая сама.
struct SettingsSpotlightOverlay: ViewModifier {
    let hit: SettingsSearchHit?
    let accent: Color
    @State private var lit: String?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .overlayPreferenceValue(SettingAnchorKey.self) { anchors in
                    GeometryReader { geo in
                        if let lit, let anchor = anchors[lit] {
                            let box = geo[anchor]
                            RoundedRectangle(cornerRadius: 6)
                                .fill(accent.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: 2))
                                .frame(width: geo.size.width - 24, height: box.height + 10)
                                .position(x: geo.size.width / 2, y: box.midY)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                }
                .onAppear { reveal(proxy) }
                .onChange(of: hit) { _ in reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let hit else { return }
        // Страница только что появилась: дать ей разложиться, потом прокручивать.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(hit.key, anchor: .center) }
            withAnimation(.easeIn(duration: 0.15)) { lit = hit.key }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.6)) { if lit == hit.key { lit = nil } }
            }
        }
    }
}
