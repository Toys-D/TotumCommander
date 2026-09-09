import AppKit
import SwiftUI

/// Цвета имён по типам файлов и по свежести.
///
/// Порядок значим — красит первое подошедшее правило, поэтому «Только что появились» стоит
/// наверху: иначе свежий архив достался бы правилу про архивы и ничем не отличался бы от
/// прошлогоднего.
struct SettingsFileColorsView: View {

    @ObservedObject private var store = FileColorRulesStore.shared
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    /// В какой теме сейчас рисуют. Образец цвета один, а правит он цвет ТОЙ темы, которая
    /// включена: переключил тему — в окошке цвет для неё, и меняется тоже он.
    @State private var isDark = FileColorRulesStore.isDarkNow

    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        // Свой макет, а не Form: сетка Form раскладывает каждую строку как «подпись слева,
        // контрол справа» — поля разъезжались по краям, а подсказка внутри поля вылезала
        // наружу отдельной надписью. FCXLFormCard для таких мест и заведён.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("colors.rules.section"))
                    .font(.system(size: 13, weight: .semibold))

                Text(L("colors.rules.hint") + " " + L("colors.rules.hint.themes"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.rules.isEmpty {
                    Text(L("colors.rules.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    columnHeader
                    FCXLFormCard {
                        ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                            row(rule)
                            if index < store.rules.count - 1 {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button(L("colors.rules.add")) {
                        // Новое правило получает один цвет в обе темы — дальше человек
                        // разведёт их, если понадобится.
                        store.add(FileColorRule(mask: "*.txt", colorHex: "#34C759",
                                                darkColorHex: "#30D158"))
                    }
                    .buttonStyle(FCXLChipButtonStyle())
                    Button(L("colors.rules.reset")) {
                        store.replaceAll(FileColorRulesStore.starterRules)
                    }
                    .buttonStyle(FCXLChipButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fcxlAppearanceChanged)) { _ in
            isDark = FileColorRulesStore.isDarkNow
        }
    }

    // MARK: - Строка правила

    /// Подписи колонок — иначе три поля подряд читаются как одна свалка.
    private var columnHeader: some View {
        HStack(spacing: 10) {
            // Отступ считается по строке правила: 14 внешних + переключатель + цвет и
            // промежутки между ними. Иначе подпись стоит над чужим полем.
            Text(isDark ? L("colors.rules.column.colorDark")
                        : L("colors.rules.column.colorLight"))
                .frame(width: 62, alignment: .leading)
            Text(L("colors.rules.column.mask"))
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.leading, 58)
        .padding(.trailing, 14)
        .padding(.bottom, 2)
    }

    private func row(_ rule: FileColorRule) -> some View {
        let live = current(rule)
        return VStack(alignment: .leading, spacing: 0) {
            // Промежутки заданы поштучно, а не одним spacing: выключатель, цвет и маска —
            // три разных вопроса к правилу, и слипшись в ряд они читались как одна деталь.
            HStack(spacing: 0) {
                FCXLSwitch(isOn: binding(rule, \.isEnabled), size: .mini)
                    .padding(.trailing, 16)

                // Образец один, а цветов у правила два: правится тот, что относится к
                // включённой сейчас теме. Два окошка в строке — это ещё и лишняя ширина,
                // отнятая у маски, ради второго цвета, который нужен раз в жизни.
                FCXLColorPicker(hex: themeColorBinding(rule))
                    .frame(width: 30)
                    .padding(.trailing, 16)
                    .help(isDark ? L("colors.rules.column.colorDark")
                                 : L("colors.rules.column.colorLight"))

                // Названия у правила нет: маска и есть его имя. Отдельная колонка «Архивы»
                // только отнимала ширину у самой маски — а мешать в одно правило mp4 и json
                // никто не запрещает, и никакое название этого уже не опишет.
                TextField("", text: binding(rule, \.mask),
                          prompt: Text(L("colors.rules.maskAll")))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusEffectDisabled()   // синей системной обводки в программе нет нигде
                    .help(L("colors.rules.maskHint"))
                    .padding(.trailing, 14)

                // Срок прячется, пока он не нужен: строка «Только для недавних» под каждым
                // правилом превращала список в кашу, а нужна она одному правилу из десяти.
                Button {
                    var updated = live
                    updated.freshMinutes = live.isFreshness ? nil : 24 * 60
                    if updated.freshMinutes != nil { updated.fades = true }
                    store.update(updated)
                } label: {
                    Image(systemName: live.isFreshness ? "clock.fill" : "clock")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(live.isFreshness ? accent : Color.secondary)
                .help(L("colors.rules.freshness"))
                .padding(.trailing, 12)

                Button {
                    store.remove(id: rule.id)
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("colors.rules.remove"))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)

            if let minutes = live.freshMinutes {
                freshnessRow(rule, minutes: minutes)
            }
        }
    }

    /// Вторая строка — только у правила со сроком.
    ///
    /// Срок пишется числом и единицей, а не одними часами: «двадцать минут» — обычная
    /// просьба при разборе загрузок, а «две недели» в часах читается как загадка.
    private func freshnessRow(_ rule: FileColorRule, minutes: Double) -> some View {
        let unit = FreshnessUnit.best(for: minutes)
        return HStack(spacing: 8) {
            Text(L("colors.rules.freshness"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("", value: Binding(
                get: { (minutes / unit.minutes).rounded() },
                set: { value in
                    var updated = current(rule)
                    updated.freshMinutes = max(1, min(60 * 24 * 365, value * unit.minutes))
                    store.update(updated)
                }), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focusEffectDisabled()
                .frame(width: 56)

            FCXLDropdown(selection: Binding(
                get: { unit },
                set: { newUnit in
                    // Число остаётся тем же, меняется его единица: «24» из часов в дни —
                    // это 24 дня, а не те же сутки в других словах.
                    var updated = current(rule)
                    let amount = (minutes / unit.minutes).rounded()
                    updated.freshMinutes = max(1, min(60 * 24 * 365, amount * newUnit.minutes))
                    store.update(updated)
                }),
                options: FreshnessUnit.allCases.map { ($0, $0.title) })
                .frame(width: 96)

            FCXLSwitch(isOn: binding(rule, \.fades), size: .mini)
                .padding(.leading, 8)
            Text(L("colors.rules.fades"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 58)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
    }

    /// Цвет правила для ТЕКУЩЕЙ темы: читается и пишется то поле, которое сейчас в деле.
    private func themeColorBinding(_ rule: FileColorRule) -> Binding<String> {
        Binding(
            get: {
                let live = current(rule)
                if isDark { return live.darkColorHex.isEmpty ? live.colorHex : live.darkColorHex }
                return live.colorHex
            },
            set: { newValue in
                var updated = current(rule)
                if isDark { updated.darkColorHex = newValue } else { updated.colorHex = newValue }
                store.update(updated)
            })
    }

    private func current(_ rule: FileColorRule) -> FileColorRule {
        store.rules.first { $0.id == rule.id } ?? rule
    }

    /// Правка идёт сразу в хранилище — отдельной кнопки «Применить» в настройках нет нигде.
    private func binding<Value>(_ rule: FileColorRule,
                                _ keyPath: WritableKeyPath<FileColorRule, Value>)
    -> Binding<Value> {
        Binding(
            get: { current(rule)[keyPath: keyPath] },
            set: { newValue in
                var updated = current(rule)
                updated[keyPath: keyPath] = newValue
                store.update(updated)
            })
    }
}
