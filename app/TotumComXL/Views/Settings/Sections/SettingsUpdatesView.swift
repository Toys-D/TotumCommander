import AppKit
import SwiftUI

/// "Updates" section: which version is installed, whether a newer one is out and the button
/// that installs it, the automatic check, and what changed in every version the person has
/// missed — so the red count beside the section has its explanation right here.
struct SettingsUpdatesView: View {
    /// Подменяется в тестах вида; в программе — общая проверка.
    @ObservedObject var updates = UpdateChecker.shared
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage(UpdateChecker.enabledKey) private var checkUpdates: Bool = true

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("updates.installed")) {
                    Text("\(version) (\(L("about.build")) \(APP_BUILD))").monospacedDigit()
                }
                LabeledContent(L("updates.status")) {
                    if let release = updates.available {
                        updateRow(release)
                    } else {
                        HStack(spacing: 10) {
                            Text(updates.lastChecked == nil ? L("updates.never") : L("updates.upToDate"))
                                .foregroundStyle(.secondary)
                            Button(L("updates.checkNow")) { Task { await updates.checkNow() } }
                                .buttonStyle(FCXLChipButtonStyle(compact: true))
                        }
                    }
                }
                if let checked = updates.lastChecked {
                    LabeledContent(L("updates.lastCheck")) {
                        Text(Self.dateTime.string(from: checked)).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle(L("settings.updates.check"), isOn: $checkUpdates).settingAnchor("settings.updates.check")
                Text(L("settings.updates.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Новые сверху: первым — то, что поставит «Обновить».
            if !updates.newer.isEmpty {
                Section(L("updates.whatsNew")) {
                    ForEach(updates.newer, id: \.version) { release in
                        releaseNotes(release)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Обновить

    /// Новая версия: кнопка «Обновить», ход дела, а после срыва — объяснение и повтор.
    /// Ссылка на страницу выпуска остаётся всегда: ручной путь никуда не делся.
    @ViewBuilder
    private func updateRow(_ release: UpdateChecker.Release) -> some View {
        switch updater.stage {
        case .idle:
            HStack(spacing: 10) {
                // Красная: вышла новая версия — кнопка должна бросаться в глаза.
                Button(String(format: L("updates.install"), release.version)) {
                    Task { await updater.update(to: release) }
                }
                .buttonStyle(FCXLChipButtonStyle(compact: true, fill: .red))
                releasePageLink(release)
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: L("updates.stage.downloading"), Int((fraction * 100).rounded())))
                    .foregroundStyle(.secondary).monospacedDigit()
                ProgressView(value: fraction)
                    .tint(PanelAppearanceSettings.accentColor)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
            }
        case .verifying, .installing, .relaunching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stageTitle).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(L("updates.retry")) { updater.reset() }
                        .buttonStyle(FCXLChipButtonStyle(compact: true))
                    releasePageLink(release)
                }
            }
        }
    }

    private var stageTitle: String {
        switch updater.stage {
        case .verifying: return L("updates.stage.verifying")
        case .installing: return L("updates.stage.installing")
        case .relaunching: return L("updates.stage.relaunching")
        default: return ""
        }
    }

    private func releasePageLink(_ release: UpdateChecker.Release) -> some View {
        Link(L("updates.page"), destination: release.url)
            .font(.system(size: 12))
            .pointerStyle(.link)
    }

    // MARK: - Что нового

    private static let dateTime = DateFormatter.fcxlDisplay(date: .medium, time: .short)
    private static let dateOnly = DateFormatter.fcxlDisplay(date: .long, time: .none)

    /// Одна версия: номер, дата выхода, страница выпуска и половина заметок на языке программы.
    private func releaseNotes(_ release: UpdateChecker.Release) -> some View {
        let lines = ReleaseNotes.lines(of: release.notes, russian: AppLanguage.current.resolvedCode == "ru")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(release.version).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                if let published = release.published {
                    Text(Self.dateOnly.string(from: published))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                releasePageLink(release)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .group(let title):
                    Text(Self.inline(title)).font(.system(size: 12, weight: .semibold))
                        .padding(.top, 4)
                case .item(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                case .text(let text):
                    Text(Self.inline(text)).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Жирное и ссылки внутри строки заметок.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
