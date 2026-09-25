import AppKit
import SwiftUI

/// Что человек выбрал в окне «Новое подключение».
enum NewConnectionChoice {
    /// Облако, доступ к которому уже получен: имя хранилища и служба.
    case cloud(name: String, service: RcloneCloudService)
    /// Обычный сервер — дальше открывается привычная форма с адресом и паролем.
    case server(RemoteProtocol)
    /// Хранилище, заведённое в самом rclone: для тех, у кого их десятки.
    case rcloneManual
}

/// Окно «Новое подключение»: плитки служб, как их знает человек.
///
/// Здесь нет и не должно быть слова «rclone». Человек приходит за Google Drive, нажимает
/// «Google Drive» — и разрешает доступ в браузере. Чем именно программа с ним разговаривает,
/// его не касается: это наша кухня.
@MainActor
enum NewConnectionController {

    static func show() -> NewConnectionChoice? {
        FCXLDialog.runModal(size: NSSize(width: 520, height: 560)) { session in
            NewConnectionDialogView(session: session)
        }
    }
}

struct NewConnectionDialogView: View {

    let session: FCXLDialogSession<NewConnectionChoice>

    @State private var waitingFor: RcloneCloudService?
    @State private var link: URL?
    @State private var trouble: String?
    @State private var work: Task<Void, Never>?

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    /// Обычные серверы — те, где нужен адрес и пароль, а не браузер.
    ///
    /// Значок у плитки свой, не протокольный: в полосе дисков и во вкладках протоколы
    /// различают по соседям и подписи, а здесь плитки стоят рядом, и два одинаковых
    /// глобуса (WebDAV и общая папка) человек различал бы только чтением.
    private static let servers: [(proto: RemoteProtocol, title: String, icon: String)] = [
        (.sftp, "SFTP", "lock.shield.fill"),
        (.ftp, "FTP", "arrow.up.arrow.down.circle.fill"),
        (.s3, "S3-совместимое", "externaldrive.fill.badge.icloud"),
        (.webdavs, "WebDAV", "globe"),
        (.smb, "Общая папка", "folder.fill.badge.person.crop")
    ]

    private var busy: Bool { waitingFor != nil }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("network.newConnection"))

            ScrollView { chooser }

            // Одна кнопка, и та «Отмена»: выбор здесь делают сами плитки, а кнопка
            // «Продолжить» была бы лишним щелчком ни за чем.
            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("button.cancel"), action: cancel)
            ])
        }
    }

    /// Сами плитки, отдельно от окна: так их можно нарисовать в картинку и посмотреть,
    /// не поднимая программу.
    var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
                    section(L("network.kind.clouds"))
                    grid(RcloneCloudService.popular.map { item in
                        Tile(id: item.type, title: item.title, icon: item.icon,
                             logo: item.logoImage, color: item.color,
                             action: { begin(item) })
                    })

                    if busy || trouble != nil { statusCard }

                    section(L("network.kind.servers"))
                    grid(Self.servers.map { server in
                        Tile(id: server.proto.rawValue, title: server.title,
                             icon: server.icon, color: .secondary,
                             action: { session.finish(.server(server.proto)) })
                    })

            Button(L("network.kind.rcloneManual")) {
                session.finish(.rcloneManual)
            }
            .buttonStyle(FCXLToolbarButtonStyle())
            .disabled(busy)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    // MARK: - Части окна

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private struct Tile: Identifiable {
        let id: String
        let title: String
        let icon: String
        /// Настоящий логотип службы, если он есть. У серверов его не бывает — там значок.
        var logo: NSImage?
        let color: Color
        let action: () -> Void
    }

    /// Плитки в два столбца — так их и разглядывают: глазами, а не читая список.
    ///
    /// Кладка руками, а не `LazyVGrid`: ленивая сетка строит только то, что попало на
    /// экран, и на отрисовке окна в картинку (проверка внешности) отдавала пустоту.
    /// Плиток тут дюжина — лениться не на чем.
    private func grid(_ tiles: [Tile]) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { row in
                HStack(spacing: 10) {
                    TileButton(tile: tiles[row], accent: accent, disabled: busy)
                    if row + 1 < tiles.count {
                        TileButton(tile: tiles[row + 1], accent: accent, disabled: busy)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private struct TileButton: View {
        let tile: Tile
        let accent: Color
        let disabled: Bool
        @State private var hovering = false

        var body: some View {
            Button(action: tile.action) {
                HStack(spacing: 10) {
                    Group {
                        if let logo = tile.logo {
                            // Логотип рисуется как есть, своими цветами: в этом весь смысл —
                            // человек узнаёт службу в лицо.
                            Image(nsImage: logo)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: tile.icon)
                                .font(.system(size: 20))
                                .foregroundStyle(tile.color)
                        }
                    }
                    .frame(width: 30, height: 30)
                    Text(tile.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(hovering && !disabled ? accent.opacity(0.12) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovering && !disabled ? accent.opacity(0.5)
                                                        : Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
            .onHover { hovering = $0 }
        }
    }

    private var statusCard: some View {
        FCXLFormCard {
            FCXLFormRow(label: "") {
                VStack(alignment: .leading, spacing: 8) {
                    if let waitingFor {
                        Text(L("rclone.add.browserOpened", waitingFor.title))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        if let link {
                            HStack(spacing: 8) {
                                Button(L("rclone.add.openAgain")) { NSWorkspace.shared.open(link) }
                                    .buttonStyle(FCXLToolbarButtonStyle())
                                Button(L("rclone.add.copyLink")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(link.absoluteString,
                                                                   forType: .string)
                                }
                                .buttonStyle(FCXLToolbarButtonStyle())
                            }
                        }
                    } else if let trouble {
                        Text(trouble)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - Действия

    /// Нажали на облако — сразу уводим в браузер. Промежуточная кнопка «продолжить»
    /// здесь была бы лишним щелчком ни за чем.
    private func begin(_ service: RcloneCloudService) {
        trouble = nil
        link = nil
        waitingFor = service

        work = Task {
            do {
                let taken = (try? await RcloneRemoteFileSystem.availableRemotes()) ?? []
                let name = RcloneCloudSetup.freeName(basedOn: service.title, among: taken)
                let token = try await RcloneCloudSetup.authorize(service: service) { url in
                    link = url
                    NSWorkspace.shared.open(url)
                }
                try Task.checkCancellation()
                try await RcloneCloudSetup.createRemote(named: name, service: service,
                                                        token: token)
                session.finish(.cloud(name: name, service: service))
            } catch is CancellationError {
                waitingFor = nil
            } catch let error as RemoteFileSystemError {
                waitingFor = nil
                if case .transferCancelled = error { return }
                trouble = error.errorDescription
            } catch {
                waitingFor = nil
                trouble = error.localizedDescription
            }
        }
    }

    private func cancel() {
        // Ждущий пропуска rclone держит свой порт и сам никуда не денется — снимаем.
        work?.cancel()
        work = nil
        session.cancel()
    }
}
