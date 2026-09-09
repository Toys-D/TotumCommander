import AppKit
import SwiftUI

/// Query and highlighted row, owned outside the view.
///
/// The window drives the arrow keys — the text field is first responder and would otherwise eat
/// them as caret movement — so the selection cannot live in the View struct: the key monitor holds
/// a copy, and mutating a copy would move a selection nobody can see.
@MainActor
final class CommandPaletteModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selection = 0 } } }
    @Published var selection = 0
    let commands: [PaletteCommand]

    init(commands: [PaletteCommand]) { self.commands = commands }

    var matches: [PaletteCommand] { CommandMatcher.rank(commands, query: query) }
    /// Long lists are pointless in a palette; the ranking already put the best first.
    var visibleMatches: [PaletteCommand] { Array(matches.prefix(60)) }

    func move(by delta: Int) {
        let count = visibleMatches.count
        guard count > 0 else { return }
        selection = max(0, min(count - 1, selection + delta))
    }

    var selectedCommand: PaletteCommand? {
        visibleMatches.indices.contains(selection) ? visibleMatches[selection] : nil
    }
}

/// The Cmd+P palette: type a fragment of a command's name, pick it, run it.
struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel
    let onRun: (PaletteCommand) -> Void

    @FocusState private var fieldFocused: Bool
    /// Палитра следит за туннелем: нажал плюс — галочка в строке загорается сразу.
    @ObservedObject private var tunnel = TunnelStore.shared
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentHex: String = ""

    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentHex, fallback: .purple) }
    private var matches: [PaletteCommand] { model.visibleMatches }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            if matches.isEmpty {
                Text(L("palette.noMatches"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 18)
            } else {
                list
            }
            Divider()
            hints
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            // A plain field, no border: the window itself is the search box.
            TextField(L("palette.prompt"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .onSubmit { if let command = model.selectedCommand { onRun(command) } }
            Text(L("palette.count", matches.count))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        // Identity comes from ForEach alone. Adding .id(index) here gave every row
                        // a SECOND, competing identity, and SwiftUI kept row 0's old contents while
                        // the match behind it had changed — the list showed a command that had not
                        // been searched for.
                        row(command, index: index)
                            .onTapGesture { onRun(command) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
            .onChange(of: model.selection) { _, _ in
                guard let target = model.selectedCommand?.id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private func row(_ command: PaletteCommand, index: Int) -> some View {
        let isSelected = index == model.selection
        let enabled = CommandRegistry.isEnabled(command)
        // Unavailable commands stay listed but dimmed: hiding them makes the palette look as though
        // the app cannot do the thing at all, when it only needs a file selected first.
        return HStack(spacing: 12) {
            Image(systemName: command.symbolName ?? "circle.dashed")
                .font(.system(size: 15))
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color(nsColor: PanelAppearanceSettings.contrastingTextColor(on: NSColor(accent))) : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(.system(size: 14)).lineLimit(1)
                Text(command.group).font(.system(size: 11)).opacity(0.75)
            }
            Spacer(minLength: 12)
            tunnelButton(for: command, isSelected: isSelected)
            if !command.shortcut.isEmpty {
                Text(command.shortcut).font(.system(size: 12, design: .rounded)).opacity(0.7)
            }
        }
        .foregroundStyle(isSelected
                         ? Color(nsColor: PanelAppearanceSettings.contrastingTextColor(on: NSColor(accent)))
                         : Color.primary)
        .opacity(enabled ? 1 : 0.4)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? accent : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    /// Плюсик «в туннель»: команда встаёт кнопкой в низ туннеля, рядом с Копир. и Удалить.
    /// Уже стоящая показывается галочкой — и второй раз не встаёт.
    @ViewBuilder
    private func tunnelButton(for command: PaletteCommand, isSelected: Bool) -> some View {
        let inTunnel = tunnel.actions
            .contains { $0.key == "menu:\(command.group)▸\(command.title)" }
        Button {
            _ = tunnel.addMenuAction(group: command.group, title: command.title,
                                     icon: command.symbolName)
        } label: {
            Image(systemName: inTunnel ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(isSelected
                    ? Color(nsColor: PanelAppearanceSettings.contrastingTextColor(on: NSColor(accent)))
                    : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inTunnel)
        .help(inTunnel ? L("palette.inTunnel") : L("palette.addToTunnel"))

    }

    private var hints: some View {
        HStack(spacing: 16) {
            Label(L("palette.hint.move"), systemImage: "arrow.up.arrow.down")
            Label(L("palette.hint.run"), systemImage: "return")
            Label(L("palette.hint.tunnel"), systemImage: "plus.circle")
            Label(L("palette.hint.close"), systemImage: "escape")
            Spacer()
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

}

/// A panel that can take the keyboard.
///
/// NSPanel refuses key status by default unless it is a utility window, and a palette whose text
/// field never gets focus is a palette you cannot type into.
private final class PaletteWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The window the palette lives in: a floating panel centred on the main window.
@MainActor
final class CommandPaletteController {
    static let shared = CommandPaletteController()
    private var panel: NSPanel?
    private var model: CommandPaletteModel?
    private var monitor: Any?

    func toggle() {
        if panel != nil { close() } else { show() }
    }

    func show() {
        guard panel == nil else { return }
        let commands = CommandRegistry.commands()
        guard !commands.isEmpty else { return }

        let model = CommandPaletteModel(commands: commands)
        let view = CommandPaletteView(model: model) { [weak self] command in
            // A dimmed row must not run: the row's own validation said the command is unavailable
            // right now, and a real menu never fires a disabled item either. Without this, Return
            // on a dimmed "Paste" inside an archive would start a paste the app cannot perform.
            guard CommandRegistry.isEnabled(command) else { NSSound.beep(); return }
            // Close FIRST: the command may open a modal dialog of its own, and running it from
            // under a panel that is still up leaves that dialog behind the palette.
            self?.close()
            DispatchQueue.main.async { CommandRegistry.run(command) }
        }
        self.model = model
        let hosting = NSHostingView(rootView: view)
        let panel = PaletteWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                  styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior.insert(.moveToActiveSpace)
        // A fixed size, not hosting.fittingSize: the SwiftUI view has not been laid out yet, so
        // fittingSize is still zero here and the panel would open invisible.
        panel.setContentSize(NSSize(width: 520, height: 420))

        // Centred on the app's window, a third of the way down — where the eye already is.
        if let host = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            let frame = host.frame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: frame.midY - size.height / 2 + frame.height * 0.12))
        } else {
            panel.center()
        }

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // Arrows and Esc belong to the list, but the text field is first responder and would treat
        // them as caret movement. A local monitor claims them before the field sees them.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let current = self.panel, event.window === current else { return event }
            // Cmd+Return — «в туннель» для выбранной команды, не выходя из палитры.
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                if let chosen = self.model?.selectedCommand {
                    _ = TunnelStore.shared.addMenuAction(group: chosen.group,
                                                         title: chosen.title,
                                                         icon: chosen.symbolName)
                }
                return nil
            }
            switch event.keyCode {
            case 126: self.model?.move(by: -1); return nil    // Up
            case 125: self.model?.move(by: 1); return nil     // Down
            case 116: self.model?.move(by: -8); return nil    // Page Up
            case 121: self.model?.move(by: 8); return nil     // Page Down
            case 53:  self.close(); return nil                // Esc
            default:  return event
            }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
