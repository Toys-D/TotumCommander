import AppKit
import SwiftUI

/// Окно «Сочетания клавиш»: команды строки меню с их клавишами.
///
/// Сразу открывается список команд, у которых клавиша уже есть, — за ними сюда и приходят;
/// вкладка «Все команды» даёт назначить клавишу той, у которой её нет. Справа у каждой
/// команды кнопка с её сочетанием: щёлкнуть — и следующее нажатие станет новым.
@MainActor
enum KeyBindingsEditor {
    static func show() {
        _ = FCXLDialog.runModal(size: NSSize(width: 660, height: 680)) { (session: FCXLDialogSession<Bool>) in
            KeyBindingsEditorView(session: session)
        }
    }
}

struct KeyBindingsEditorView: View {
    let session: FCXLDialogSession<Bool>

    enum Scope { case assigned, all }

    @State private var scope: Scope = .assigned
    @State private var query = ""
    /// Команда, которая ждёт нажатия.
    @State private var recording: String?
    /// Что случилось после последнего нажатия — строкой над списком.
    @State private var note: String?
    @State private var noteIsWarning = false
    /// Перерисовать строки после правки: сочетания живут в настройках, не в состоянии вида.
    @State private var version = 0
    @State private var monitor = EventMonitorBox()
    @State private var commands: [PaletteCommand]

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    /// `commands` — снаружи только для проверки внешности; окно читает строку меню само.
    /// Читается сразу, а не в `onAppear`: в модальном окне список, заполненный «потом»,
    /// так и оставался пустым.
    init(session: FCXLDialogSession<Bool>, commands: [PaletteCommand]? = nil) {
        self.session = session
        let all = commands ?? CommandRegistry.commands()
        var seen: Set<String> = []
        _commands = State(initialValue: all.filter {
            !KeyBindings.excluded.contains($0.stableID) && seen.insert($0.stableID).inserted
        })
    }

    private var assignedCount: Int {
        _ = version
        return commands.filter { KeyBindings.current(for: $0.stableID) != nil }.count
    }

    private var shown: [PaletteCommand] {
        _ = version
        var list = commands
        if scope == .assigned { list = list.filter { KeyBindings.current(for: $0.stableID) != nil } }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter {
            $0.currentTitle.lowercased().contains(needle) || $0.group.lowercased().contains(needle)
                || (KeyBindings.current(for: $0.stableID)?.text.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("settings.keys.editor.title"), icon: "keyboard")
            VStack(alignment: .leading, spacing: 10) {
                steps
                HStack(spacing: 8) {
                    scopeButton(.assigned, String(format: L("settings.keys.editor.assigned"), assignedCount))
                    scopeButton(.all, String(format: L("settings.keys.editor.all"), commands.count))
                    FCXLDialogTextField(text: $query, placeholder: L("settings.keys.editor.search"))
                }
                if let note {
                    Label(note, systemImage: noteIsWarning ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(noteIsWarning ? Color.orange : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            Divider()
            commandList
            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("settings.keys.reset"), enabled: !KeyBindings.overrides.isEmpty) {
                    stopRecording()
                    KeyBindings.resetAll()
                    say(L("settings.keys.editor.didReset"), warning: false)
                },
                FCXLDialogBarButton(title: L("button.close"), role: .primary) {
                    stopRecording()
                    session.finish(true)
                },
            ])
        }
        .onDisappear(perform: stopRecording)
    }

    /// Как пользоваться — тремя шагами, словами, а не значками.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array([L("settings.keys.editor.step1"), L("settings.keys.editor.step2"),
                           L("settings.keys.editor.step3")].enumerated()), id: \.offset) { index, text in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(accent))
                    Text(text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var commandList: some View {
        ScrollView { listContent }
    }

    /// Строки списка — отдельно от прокрутки, чтобы их можно было нарисовать в картинку
    /// в проверке: прокрутку отрисовка в картинку не разворачивает.
    var listContent: some View {
        let rows = shown
        return VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("settings.keys.editor.command"))
                    Spacer()
                    Text(L("settings.keys.editor.shortcut")).frame(width: 150, alignment: .center)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)
                if rows.isEmpty {
                    Text(L("settings.keys.editor.nothing"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, command in
                    if index == 0 || rows[index - 1].group != command.group {
                        Text(command.group)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.top, index == 0 ? 2 : 12)
                            .padding(.bottom, 2)
                    }
                    row(command)
                    Divider().opacity(0.5)
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func scopeButton(_ value: Scope, _ title: String) -> some View {
        let selected = scope == value
        return Button { scope = value } label: {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? accent.opacity(0.18) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? accent.opacity(0.55) : Color.secondary.opacity(0.25), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func row(_ command: PaletteCommand) -> some View {
        let id = command.stableID
        let combo = KeyBindings.current(for: id)
        let original = KeyBindings.programDefaults[id]
        let changed = KeyBindings.overrides[id] != nil
        let waiting = recording == id
        return HStack(spacing: 8) {
            Text(command.currentTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            if changed {
                Text(original.map { String(format: L("settings.keys.editor.was"), $0.text) }
                     ?? L("settings.keys.editor.wasNone"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    KeyBindings.assign(original, to: id)
                    say(String(format: L("settings.keys.editor.restored"), command.currentTitle), warning: false)
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L("settings.keys.editor.restore"))
            }
            Spacer(minLength: 8)
            if waiting {
                Button(L("button.cancel")) { stopRecording() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            Button { waiting ? stopRecording() : startRecording(id) } label: {
                keyCap(waiting ? L("settings.keys.editor.press") : (combo?.text ?? L("settings.keys.editor.assign")),
                       waiting: waiting, empty: combo == nil)
            }
            .buttonStyle(.plain)
            .help(L("settings.keys.editor.capTip"))
        }
        .padding(.vertical, 5)
        .background(waiting ? accent.opacity(0.08) : Color.clear)
    }

    /// Сочетание в виде клавиши: так видно, что на него можно нажать.
    private func keyCap(_ text: String, waiting: Bool, empty: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: empty || waiting ? .regular : .medium))
            .foregroundStyle(waiting ? accent : empty ? Color.secondary : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: 150, height: 26)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(waiting ? accent.opacity(0.15) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(waiting ? accent : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: waiting ? 1.5 : 1, dash: empty && !waiting ? [3, 2] : [])))
            .contentShape(Rectangle())
    }

    private func say(_ text: String, warning: Bool) {
        note = text
        noteIsWarning = warning
        version += 1
    }

    private func title(of id: String) -> String {
        commands.first { $0.stableID == id }?.currentTitle ?? id
    }

    private func startRecording(_ id: String) {
        note = nil
        recording = id
        monitor.remove()
        // Перехватчик — раньше строки меню: иначе ⌘-сочетание, которое уже чьё-то, не
        // записалось бы, а выполнилось.
        monitor.install(matching: .keyDown) { event in
            guard let id = recording else { return event }
            let flags = event.modifierFlags.intersection(KeyCombo.relevant)
            if event.keyCode == 53, flags.isEmpty {          // Esc — передумал
                stopRecording()
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty {   // Delete — без клавиши
                KeyBindings.assign(nil, to: id)
                stopRecording()
                say(String(format: L("settings.keys.editor.removed"), title(of: id)), warning: false)
                return nil
            }
            guard let combo = KeyCombo(event: event), combo.isAssignable else {
                say(L("settings.keys.editor.notAssignable"), warning: true)
                return nil
            }
            let loser = KeyBindings.assign(combo, to: id)
            stopRecording()
            if let loser {
                say(String(format: L("settings.keys.editor.taken"), title(of: id), combo.text, title(of: loser)),
                    warning: true)
            } else {
                say(String(format: L("settings.keys.editor.done"), title(of: id), combo.text), warning: false)
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = nil
        monitor.remove()
    }
}
