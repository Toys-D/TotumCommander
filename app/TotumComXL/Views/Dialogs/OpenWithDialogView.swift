import AppKit
import SwiftUI

/// Чем открыть этот файл — со списком программ и одной галочкой.
///
/// Раньше это было меню, и «всегда открывать» пришлось делать вторым, вложенным подменю:
/// меню закрывается от первого же щелчка, поэтому галочку, которую надо поставить ДО выбора
/// программы, в нём просто негде поставить. В своём окне это одно движение — выбрал
/// программу, при желании отметил «Открывать всегда», нажал «Открыть».
struct OpenWithChoice {
    let application: URL
    /// Отмечено — правило меняется во всей системе, как «Изменить для всех» в Finder.
    let always: Bool
}

struct OpenWithDialogView: View {

    let session: FCXLDialogSession<OpenWithChoice>
    let fileName: String
    /// Тип файла человеческим словом — «документ PDF». Пусто, если система его не знает:
    /// тогда и менять правило не для чего, и галочки не будет.
    let kindLabel: String?
    let applications: [URL]

    @State private var selected: URL?
    @State private var always = false
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""

    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FCXLDialogHeader(title: L("context.openWith.title"))

            Text(fileName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(applications, id: \.self) { app in
                        row(app)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                // Таблетка, а не полоса во всю ширину: выбор программы вручную — запасной
                // путь, а растянутая кнопка читается как главное действие окна.
                Button(L("context.openWith.other")) { pickAnother() }
                    .buttonStyle(FCXLChipButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            if let kindLabel {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        FCXLSwitch(isOn: $always)
                        Text(String(format: L("context.openWith.alwaysCheckbox"), kindLabel))
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    Text(L("context.openWith.alwaysNote"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                // Воздух перед кнопками: пояснение стояло к ним вплотную и читалось как их
                // подпись, а не как пояснение к переключателю над ним.
                .padding(.bottom, 26)
            }

            FCXLDialogButtonBar(
                primaryTitle: L("context.openWith.open"),
                primaryEnabled: selected != nil,
                primaryAction: {
                    guard let selected else { return }
                    session.finish(OpenWithChoice(application: selected, always: always))
                },
                cancelAction: { session.cancel() })
        }
        .onAppear { selected = applications.first }
    }

    // MARK: - Строка списка

    private func row(_ app: URL) -> some View {
        let isSelected = selected == app
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 20, height: 20)
        return HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
            // Без «.app»: у того, кто показывает расширения, список выглядел как перечень
            // файлов, а не программ.
            Text(FileManager.default.displayName(atPath: app.path)
                .replacingOccurrences(of: ".app", with: ""))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? accent.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = app }
        // Двойной щелчок — то же, что «Открыть»: так открывают списки везде.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selected = app
            session.finish(OpenWithChoice(application: app, always: always))
        })
    }

    private func pickAnother() {
        guard let chosen = DialogService.shared.showFilePicker(
            title: L("context.openWith.select"),
            defaultPath: "/Applications",
            allowedTypes: [.application]) else { return }
        session.finish(OpenWithChoice(application: URL(fileURLWithPath: chosen), always: always))
    }
}
