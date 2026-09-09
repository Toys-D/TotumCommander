import AppKit
import SwiftUI

/// Connection Manager dialog — manages saved remote connections.
/// Restyled to the shared FCXLDialog kit (settings-window look): a floating
/// chrome-less panel with a grouped list card, a small action toolbar, and the
/// accent Connect bar at the bottom. The editor is a second FCXLDialog with the
/// canonical grouped-form rows. The synchronous return contract is preserved:
/// `showAndConnect()` blocks (like the old NSAlert) and returns the chosen
/// connection, or nil on cancel.
@MainActor
final class ConnectionManagerController {
    static let shared = ConnectionManagerController()

    /// Show the connection manager and return the selected connection (or nil).
    func showAndConnect() -> RemoteConnection? {
        let model = ConnectionManagerListModel()
        return FCXLDialog.runModal(size: NSSize(width: 540, height: 480)) { session in
            ConnectionManagerListView(model: model, session: session)
        }
    }

    /// Show the connection editor for a new or existing connection.
    /// Returns the edited connection plus its password, or nil on cancel.
    static func showEditor(existing: RemoteConnection? = nil,
                           preset: RemoteProtocol? = nil) -> (RemoteConnection, String)? {
        return FCXLDialog.runModal(size: NSSize(width: 470, height: 540)) { session in
            ConnectionEditorView(existing: existing, preset: preset, session: session)
        }
    }
}

// MARK: - List model

@MainActor
final class ConnectionManagerListModel: ObservableObject {
    @Published var connections: [RemoteConnection]
    @Published var selection: RemoteConnection.ID?

    init() {
        let conns = ConnectionManagerService.shared.connections
        connections = conns
        selection = conns.first?.id
    }

    /// Reload from the service, keeping (or moving) the cursor sensibly.
    func reload(select id: RemoteConnection.ID? = nil) {
        connections = ConnectionManagerService.shared.connections
        if let id, connections.contains(where: { $0.id == id }) {
            selection = id
        } else if selection == nil || !connections.contains(where: { $0.id == selection }) {
            selection = connections.first?.id
        }
    }

    var selectedConnection: RemoteConnection? {
        guard let selection else { return nil }
        return connections.first { $0.id == selection }
    }
}

// MARK: - List view

private struct ConnectionManagerListView: View {
    @ObservedObject var model: ConnectionManagerListModel
    let session: FCXLDialogSession<RemoteConnection>
    @FocusState private var listFocused: Bool
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    private var hasSelection: Bool { model.selectedConnection != nil }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("network.manager"))

            VStack(spacing: 10) {
                listCard
                actionRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 14)

            FCXLDialogButtonBar(
                primaryTitle: L("network.connect"),
                primaryEnabled: hasSelection,
                primaryAction: connect,
                cancelAction: { session.cancel() }
            )
        }
    }

    private var listCard: some View {
        // Deliberately NOT a List: macOS List forces both its own selection colour (ignores .tint)
        // and its own row insets (ignores .listRowInsets), so rows are laid out manually here —
        // giving a full-bleed accent highlight with no side gaps.
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.connections) { conn in
                    ConnectionRow(conn: conn, isSelected: model.selection == conn.id, accent: accent)
                        .contentShape(Rectangle())
                        // Оба жеста ОДНОВРЕМЕННЫЕ, а не по очереди. Обычные
                        // `.onTapGesture` рядом с `count: 2` выстраиваются в очередь:
                        // одиночный ждёт, пока система убедится, что второго щелчка не
                        // будет, — и выделение прыгает на строку с задержкой в полсекунды,
                        // а у того, кто увеличил интервал двойного нажатия в настройках
                        // мака, и в пару секунд. Одновременные жесты друг друга не ждут.
                        .simultaneousGesture(TapGesture(count: 2)
                            .onEnded { session.finish(conn) })
                        .simultaneousGesture(TapGesture()
                            .onEnded { model.selection = conn.id })
                }
            }
        }
        .focusable()
        .focusEffectDisabled()   // keep keyboard focus for ↑/↓ but drop the system blue focus ring
        .focused($listFocused)
        .onMoveCommand { moveSelection($0) }
        .clipShape(RoundedRectangle(cornerRadius: 10))   // keep full-bleed rows inside the card
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .frame(maxHeight: .infinity)
        .onAppear { listFocused = true }
    }

    /// Arrow-key navigation (List's own selection is disabled — see listCard).
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !model.connections.isEmpty else { return }
        let idx = model.connections.firstIndex { $0.id == model.selection } ?? 0
        switch direction {
        case .up:   model.selection = model.connections[max(0, idx - 1)].id
        case .down: model.selection = model.connections[min(model.connections.count - 1, idx + 1)].id
        default:    break
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: addAction) {
                Label(L("network.newConnection"), systemImage: "plus")
            }
            .buttonStyle(FCXLToolbarButtonStyle())

            Button(action: editAction) {
                Label(L("network.editConnection"), systemImage: "pencil")
            }
            .buttonStyle(FCXLToolbarButtonStyle())
            .disabled(!hasSelection)

            Button(action: duplicateAction) {
                Label(L("network.duplicateConnection"), systemImage: "plus.square.on.square")
            }
            .buttonStyle(FCXLToolbarButtonStyle())
            .disabled(!hasSelection)

            Spacer()

            Button(action: deleteAction) {
                Label(L("network.deleteConnection"), systemImage: "trash")
            }
            .buttonStyle(FCXLToolbarButtonStyle(destructive: true))
            .disabled(!hasSelection)
        }
    }

    // MARK: Actions

    private func connect() {
        guard let conn = model.selectedConnection else { return }
        session.finish(conn)
    }

    private func addAction() {
        // Editor opens a nested modal → schedule via runloop callout so the busy
        // main queue never starves it (see fcxlPresentModal).
        fcxlPresentModal {
            // Сначала — что это будет: человек выбирает службу по имени и значку,
            // а не протокол из списка. Слова «rclone» он видеть не должен.
            guard let choice = NewConnectionController.show() else { return }
            switch choice {
            case .cloud(let name, let service):
                // Доступ уже получен, спрашивать больше нечего — подключение готово.
                let conn = RemoteConnection(label: service.title, proto: .rclone,
                                            rcloneRemote: name, cloudService: service.type)
                ConnectionManagerService.shared.addConnection(conn)
                model.reload(select: conn.id)
            case .server(let proto):
                addByHand(preset: proto)
            case .rcloneManual:
                addByHand(preset: .rclone)
            }
        }
    }

    /// Обычный путь: форма с адресом, именем входа и паролем.
    private func addByHand(preset: RemoteProtocol) {
        fcxlPresentModal {
            guard let (conn, password) =
                    ConnectionManagerController.showEditor(preset: preset) else { return }
            ConnectionManagerService.shared.addConnection(conn)
            ConnectionManagerService.shared.setPassword(password, for: conn.id)
            model.reload(select: conn.id)
        }
    }

    private func editAction() {
        guard let existing = model.selectedConnection else { return }
        fcxlPresentModal {
            guard let (conn, password) = ConnectionManagerController.showEditor(existing: existing) else { return }
            ConnectionManagerService.shared.updateConnection(conn)
            ConnectionManagerService.shared.setPassword(password, for: conn.id)
            model.reload(select: conn.id)
        }
    }

    private func duplicateAction() {
        guard let original = model.selectedConnection else { return }
        let copy = RemoteConnection(
            label: original.label + " " + L("network.duplicateSuffix"),
            proto: original.proto,
            host: original.host,
            port: original.port,
            username: original.username,
            initialPath: original.initialPath,
            useKeyAuth: original.useKeyAuth,
            keyPath: original.keyPath,
            passiveMode: original.passiveMode
        )
        ConnectionManagerService.shared.addConnection(copy)
        if let password = ConnectionManagerService.shared.password(for: original.id) {
            ConnectionManagerService.shared.setPassword(password, for: copy.id)
        }
        model.reload(select: copy.id)
    }

    private func deleteAction() {
        guard let sel = model.selectedConnection else { return }
        ConnectionManagerService.shared.removeConnection(sel.id)
        model.reload()
    }
}

// MARK: - List row

private struct ConnectionRow: View {
    let conn: RemoteConnection
    var isSelected: Bool = false
    var accent: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            Group {
                // У облака — его логотип: в списке из пяти подключений он опознаётся
                // раньше, чем прочитано название.
                if let logo = conn.kindLogo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: conn.kindIcon)
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
            }
            .frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(conn.label.isEmpty ? conn.host : conn.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(conn.kindTitle): \(conn.displayAddress)")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? accent : Color.clear)
    }
}

// MARK: - Editor view

private struct ConnectionEditorView: View {
    let existing: RemoteConnection?
    let session: FCXLDialogSession<(RemoteConnection, String)>

    @State private var label: String
    @State private var proto: RemoteProtocol
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var showPassword = false
    @State private var path: String
    @State private var passiveMode: Bool
    @State private var bucket: String
    @State private var region: String
    @State private var usePathStyle: Bool
    @State private var usesTLS: Bool
    @State private var rcloneRemote: String
    /// Что настроено у rclone на этой машине. Спрашивается у него самого — наизусть имя
    /// хранилища никто не помнит.
    @State private var rcloneRemotes: [String] = []
    @State private var rcloneProblem: String?
    @State private var rcloneAsking = false

    init(existing: RemoteConnection?, preset: RemoteProtocol? = nil,
         session: FCXLDialogSession<(RemoteConnection, String)>) {
        self.existing = existing
        self.session = session
        let c = existing ?? RemoteConnection()
        _label = State(initialValue: c.label)
        _proto = State(initialValue: preset ?? c.proto)
        _host = State(initialValue: c.host)
        _port = State(initialValue: c.port > 0 ? "\(c.port)" : "")
        _username = State(initialValue: c.username)
        let savedPass = existing.flatMap { ConnectionManagerService.shared.password(for: $0.id) } ?? ""
        _password = State(initialValue: savedPass)
        _path = State(initialValue: c.initialPath)
        _passiveMode = State(initialValue: c.passiveMode)
        _bucket = State(initialValue: c.s3Bucket)
        _region = State(initialValue: c.s3Region)
        _usePathStyle = State(initialValue: c.s3UsePathStyle)
        _usesTLS = State(initialValue: c.s3UsesTLS)
        _rcloneRemote = State(initialValue: c.rcloneRemote)
    }

    private var isNew: Bool { existing == nil }

    /// Что предлагать в списке протоколов.
    ///
    /// Облака сюда не попадают: человек заводит их плиткой в окне «Новое подключение», а
    /// строка «rclone» в этом списке для него — бессмыслица. Показывается она только тогда,
    /// когда подключение уже такое: иначе, открыв его на правку, он не увидел бы, что это.
    private var choosableProtocols: [RemoteProtocol] {
        RemoteProtocol.allCases.filter { $0 != .rclone || proto == .rclone }
    }

    /// У S3 без бакета подключаться некуда: он и есть корень. У rclone нет ни адреса, ни
    /// имени входа — всё это знает он сам, нужно только имя хранилища.
    private var canSave: Bool {
        if proto == .rclone { return !rcloneRemote.isEmpty }
        guard RemoteConnection.isUsableHost(host) else { return false }
        if proto == .s3 { return !bucket.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: isNew ? L("network.newConnection") : L("network.editConnection"))

            ScrollView {
                FCXLFormCard {
                    FCXLFormRow(label: L("network.field.label")) {
                        FCXLDialogTextField(text: $label, placeholder: "My Server",
                                            focusOnAppear: true, initialSelection: .all)
                    }
                    FCXLFormRow(label: L("network.field.protocol")) {
                        FCXLDialogMenuPicker(items: choosableProtocols,
                                             selection: $proto,
                                             title: \.displayName)
                        Spacer()
                    }
                    // У rclone ни адреса, ни имени входа не спрашивают: он сам знает, куда
                    // идти и с каким ключом. Показывать пустые поля значило бы предлагать
                    // заполнить то, что никуда не пойдёт.
                    if proto == .rclone {
                        rcloneSection
                    } else {
                    FCXLFormRow(label: L("network.field.host")) {
                        FCXLDialogTextField(text: $host, placeholder: "ftp.example.com")
                    }
                    FCXLFormRow(label: L("network.field.port")) {
                        FCXLDialogTextField(text: $port, placeholder: "0 = auto")
                    }
                    // У S3 те же два поля значат другое: ключ доступа и секретный ключ.
                    // Подписи меняются вместе с протоколом, чтобы человек не гадал, что
                    // сюда писать.
                    FCXLFormRow(label: proto == .s3 ? L("network.field.accessKey")
                                                    : L("network.field.username")) {
                        FCXLDialogTextField(text: $username,
                                            placeholder: proto == .s3 ? "AKIA…" : "anonymous")
                    }
                    FCXLFormRow(label: proto == .s3 ? L("network.field.secretKey")
                                                    : L("network.field.password")) {
                        passwordField
                    }
                    }
                    if proto == .s3 {
                        FCXLFormRow(label: L("network.field.bucket")) {
                            FCXLDialogTextField(text: $bucket, placeholder: "my-bucket")
                        }
                        FCXLFormRow(label: L("network.field.region")) {
                            FCXLDialogTextField(text: $region, placeholder: "us-east-1")
                        }
                    }
                    FCXLFormRow(label: L("network.field.path")) {
                        FCXLDialogTextField(text: $path, placeholder: "/")
                    }
                    if proto == .s3 {
                        FCXLToggleRow(label: L("network.field.pathStyle"), isOn: $usePathStyle)
                        FCXLToggleRow(label: L("network.field.https"),
                                      isOn: $usesTLS, showDivider: false)
                    } else if proto != .rclone {
                        FCXLToggleRow(label: L("network.field.passiveMode"),
                                      isOn: $passiveMode, showDivider: false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }

            FCXLDialogButtonBar(
                primaryTitle: L("button.save"),
                primaryEnabled: canSave,
                primaryAction: save,
                cancelAction: { session.cancel() }
            )
        }
    }

    /// Выбор хранилища rclone: список того, что человек уже настроил, и внятный ответ,
    /// если настраивать пока нечего или самой программы на машине нет.
    @ViewBuilder
    private var rcloneSection: some View {
        FCXLFormRow(label: L("rclone.remote.title")) {
            if rcloneRemotes.isEmpty {
                Text(rcloneAsking ? L("rclone.remote.asking")
                                  : (rcloneProblem ?? L("rclone.remote.none")))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                FCXLDialogMenuPicker(items: rcloneRemotes,
                                     selection: $rcloneRemote,
                                     title: { $0 })
                Spacer()
            }
        }
        FCXLFormRow(label: "") {
            Text(L("rclone.remote.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .task(id: proto) { await loadRcloneRemotes() }
    }

    /// Название подключения, если человек его не задал, идёт следом за облаком: пустая
    /// строка в списке подключений не говорит ни о чём.
    private func nameHasBeenSet() {
        if label.trimmingCharacters(in: .whitespaces).isEmpty { label = rcloneRemote }
    }

    private func loadRcloneRemotes(select wanted: String? = nil) async {
        guard proto == .rclone, !rcloneAsking else { return }
        rcloneAsking = true
        defer { rcloneAsking = false }
        do {
            let found = try await RcloneRemoteFileSystem.availableRemotes()
            rcloneRemotes = found
            rcloneProblem = found.isEmpty ? L("rclone.remote.none") : nil
            if let wanted, found.contains(wanted) {
                rcloneRemote = wanted
            } else if rcloneRemote.isEmpty || !found.contains(rcloneRemote) {
                // Ничего не выбрано — берём первое: одно хранилище встречается чаще всего,
                // и лишний щелчок в этом случае не нужен.
                rcloneRemote = found.first ?? ""
            }
            nameHasBeenSet()
        } catch {
            rcloneRemotes = []
            rcloneProblem = error.localizedDescription
        }
    }

    private var passwordField: some View {
        HStack(spacing: 6) {
            Group {
                if showPassword {
                    FCXLDialogTextField(text: $password, placeholder: "")
                } else {
                    // Наше поле, а не системный SecureField: тот живёт со своей привязкой
                    // сам по себе, и знак, набранный вторым, из пароля пропадал.
                    FCXLDialogTextField(text: $password, placeholder: "", isSecure: true)
                }
            }
            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func save() {
        var c = existing ?? RemoteConnection()
        c.label = label.trimmingCharacters(in: .whitespaces)
        c.proto = proto
        c.host = host.trimmingCharacters(in: .whitespaces)
        c.port = UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 0
        c.username = username.trimmingCharacters(in: .whitespaces)
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        c.initialPath = trimmedPath.isEmpty ? "/" : trimmedPath
        c.passiveMode = passiveMode
        c.s3Bucket = bucket.trimmingCharacters(in: .whitespaces)
        c.s3Region = region.trimmingCharacters(in: .whitespaces).isEmpty
            ? "us-east-1" : region.trimmingCharacters(in: .whitespaces)
        c.s3UsePathStyle = usePathStyle
        c.s3UsesTLS = usesTLS
        c.rcloneRemote = rcloneRemote
        // У rclone адреса нет вовсе — требовать его значило бы не дать сохранить ничего.
        guard proto == .rclone ? !c.rcloneRemote.isEmpty : !c.host.isEmpty else { return }
        // У ключей S3 пробельных символов не бывает, а из буфера они приезжают постоянно.
        // Пароли остальных протоколов не трогаем: там пробел может быть частью пароля.
        let secret = proto == .s3
            ? password.trimmingCharacters(in: .whitespacesAndNewlines)
            : password
        session.finish((c, secret))
    }
}
