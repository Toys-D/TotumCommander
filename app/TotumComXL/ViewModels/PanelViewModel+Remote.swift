import Foundation
import os

// MARK: - Remote filesystem navigation extension

extension PanelViewModel {

    /// Whether the panel is currently in remote (network) browsing mode.
    /// Uses the explicit flag, NOT remoteSession != nil (session can be parked).
    var insideRemote: Bool { isActivelyRemote }

    // MARK: - Enter / Exit remote mode

    /// Switch the panel to remote mode with the given session.
    func enterRemote(session: RemoteSession) {
        if insideArchive {
            insideArchive = false
            archivePath = nil
        }
        // Панель держит ровно одно хранилище. Подключаясь к другому, прежнее надо
        // отпустить, а не просто забыть о нём: иначе за ним остаются и живое соединение,
        // и место у помощника rclone, и скачанные копии — до самого выхода из программы.
        if let previous = remoteSession, previous.id != session.id {
            if !RemoteEditWatcher.shared.dirtyNames(for: previous.connection.id).isEmpty {
                // Правки в копиях прежнего хранилища отправляются сами, без вопроса:
                // человек их сохранил — значит хотел сохранить, а спрашивать посреди
                // перехода в другое облако значило бы перегородить дорогу диалогом.
                let leaving = previous
                Task { @MainActor in
                    await RemoteEditWatcher.shared.uploadDirty(for: leaving)
                    RemoteEditWatcher.shared.forget(connectionID: leaving.connection.id)
                    leaving.disconnect()
                    RemoteFileCache.shared.release(connectionID: leaving.connection.id)
                }
            } else {
                RemoteEditWatcher.shared.forget(connectionID: previous.connection.id)
                previous.disconnect()
                RemoteFileCache.shared.release(connectionID: previous.connection.id)
            }
        }
        remoteSession = session
        isActivelyRemote = true
        RemoteFileCache.shared.hold(connectionID: session.connection.id)
        currentPath = session.currentRemotePath
        // Entering a server is navigation: a filter typed for the local folder must not survive it.
        clearQuickFilter()
        allItems = []
        selectedPaths.removeAll()
        cursorIndex = 0
        errorMessage = nil

        startRemoteLoad(at: session.currentRemotePath)
    }

    /// Suspend remote mode (keep session alive for tab switching).
    /// Saves current remote path in session so it can be restored later.
    func suspendRemote() {
        remoteLoadTask?.cancel()
        remoteLoadTask = nil
        if let session = remoteSession {
            session.currentRemotePath = currentPath
        }
        isActivelyRemote = false
    }

    /// Resume remote mode from a parked session.
    func resumeRemote() {
        guard let session = remoteSession else { return }
        isActivelyRemote = true
        // Clear stale items from the previous tab so the panel is clean while loading
        clearQuickFilter()
        allItems = []
        selectedPaths.removeAll()
        cursorIndex = 0
        currentPath = session.currentRemotePath
        startRemoteLoad(at: session.currentRemotePath)
    }

    /// Exit remote mode completely — disconnect and destroy session.
    func exitRemote() {
        guard let session = remoteSession else { return }

        // Правки в открытых копиях, не отправленные в облако, погибнут вместе с копиями.
        // Спросить надо сейчас, пока связь ещё жива: после отключения отправлять нечем.
        let dirty = RemoteEditWatcher.shared.dirtyNames(for: session.connection.id)
        if !dirty.isEmpty {
            let choice = FCXLMessageDialog.run(FCXLMessageConfig(
                title: L("remoteEdit.exit.title"),
                message: L("remoteEdit.exit.message", dirty.joined(separator: "\n")),
                icon: "exclamationmark.icloud",
                iconColor: .orange,
                buttons: [
                    FCXLMessageButton(title: L("remoteEdit.exit.discard")),
                    FCXLMessageButton(title: L("remoteEdit.exit.send"), kind: .primary)
                ]))
            if choice.buttonIndex == 1 {
                Task { @MainActor in
                    await RemoteEditWatcher.shared.uploadDirty(for: session)
                    self.finishExitRemote(session)
                }
                return
            }
        }
        finishExitRemote(session)
    }

    private func finishExitRemote(_ session: RemoteSession) {
        remoteLoadTask?.cancel()
        remoteLoadTask = nil
        RemoteEditWatcher.shared.forget(connectionID: session.connection.id)
        session.disconnect()
        // Скачанные ради просмотра копии уходят вместе с последней панелью, которая
        // смотрела в это хранилище: чужие файлы на диске после отключения не нужны.
        RemoteFileCache.shared.release(connectionID: session.connection.id)
        isActivelyRemote = false
        remoteSession = nil
        // Reload last local path
        loadDirectory()
    }

    // MARK: - Remote directory loading

    /// Load a remote directory listing and populate `items`.
    /// Стоит ли пробовать связаться заново. Оборванная связь — да; «нет такой папки» и
    /// «доступ запрещён» — нет: сервер жив и уже ответил, повтор ничего не изменит.
    static func worthReconnecting(_ error: Error) -> Bool {
        guard let remote = error as? RemoteFileSystemError else { return false }
        switch remote {
        case .notConnected, .connectionFailed, .timeout: return true
        default: return false
        }
    }

    /// Единственная дверь к чтению удалённой папки: новое чтение отменяет предыдущее.
    ///
    /// Раньше каждый вызов заводил свою задачу — вход в папку, «наверх», обновление после
    /// удаления, — и в полёте их бывало несколько. Побеждало то, что ЗАКОНЧИЛОСЬ последним,
    /// а не то, что человек просил последним. На местном хранилище это невидимо, а Google
    /// Drive отвечает по полсекунды и дольше — человека выбрасывало на уровень вверх, и
    /// курсор прыгал из папки в папку.
    func startRemoteLoad(at path: String, preferredCursorName: String? = nil) {
        remoteLoadTask?.cancel()
        remoteLoadTask = Task {
            await loadRemoteDirectory(at: path, preferredCursorName: preferredCursorName)
        }
    }

    func loadRemoteDirectory(at path: String, preferredCursorName: String? = nil,
                             retrying: Bool = false) async {
        guard isActivelyRemote, let session = remoteSession else { return }

        errorMessage = nil
        let remotePath = path.isEmpty ? "/" : path
        let isNavigation = remotePath != currentPath

        do {
            let remoteItems = try await session.fileSystem.listDirectory(at: remotePath)

            // Tab might have switched while we were waiting for the network response
            guard isActivelyRemote, !Task.isCancelled else { return }

            // Filter hidden files according to user setting
            let filtered = isShowingHiddenFiles
                ? remoteItems
                : remoteItems.filter { !$0.isHidden }

            // Build sorted items with ".." entry
            var sorted = sortItemsForDisplay(filtered)

            // Add ".." entry at the top if not at root
            if remotePath != "/" && remotePath != session.fileSystem.rootPath {
                let parentPath = session.fileSystem.parentPath(for: remotePath)
                let parentItem = FileItem(
                    path: parentPath,
                    name: "..",
                    fileExtension: "",
                    size: 0,
                    isDirectory: true,
                    isHidden: false,
                    isSymlink: false,
                    permissions: "",
                    dateModified: Date.distantPast,
                    dateCreated: nil,
                    owner: ""
                )
                sorted.insert(parentItem, at: 0)
            }

            let oldPath = currentPath
            currentPath = remotePath
            session.currentRemotePath = remotePath
            if isNavigation { clearQuickFilter() }
            allItems = sorted

            if isNavigation {
                // Place cursor on the folder we came from (goUp), or reset to top
                if let name = preferredCursorName,
                   let idx = sorted.firstIndex(where: { $0.name == name }) {
                    setCursor(index: idx)
                } else {
                    cursorIndex = 0
                }
                scrollResetToken &+= 1
                pushHistory(from: oldPath, to: remotePath)
            }
        } catch {
            // Связь могла оборваться, пока панель стояла открытой: помощник ушёл вместе с
            // перезапуском программы, сервер закрыл простаивающее соединение. Один раз
            // подключаемся заново и повторяем — человеку незачем знать, что где-то там
            // порвалось и срослось.
            if Self.worthReconnecting(error), !retrying, !Task.isCancelled {
                do {
                    try await session.fileSystem.connect()
                    session.revive()
                    await loadRemoteDirectory(at: path,
                                              preferredCursorName: preferredCursorName,
                                              retrying: true)
                    return
                } catch {
                    // Не вышло — дальше по общему пути, с честным сообщением.
                }
            }
            errorMessage = error.localizedDescription
            Self.logger.error("Remote listing failed: \(error.localizedDescription)")
            // A transport-level failure means the server stopped responding: mark the session
            // dead so later operations are refused up front instead of each one hanging.
            // "Not found" / "permission denied" prove the server IS alive — don't kill those.
            if case RemoteFileSystemError.connectionFailed = error {
                session.markDead(error.localizedDescription)
            } else if case RemoteFileSystemError.notConnected = error {
                session.markDead(L("network.error.connectionLost"))
            }
        }
    }

    // MARK: - Remote navigation

    /// Open a remote item: navigate into directory or signal for download+open.
    /// Returns true if handled.
    func openRemoteItem(_ item: FileItem) -> Bool {
        if item.name == ".." {
            goUpRemote()
            return true
        }

        if item.isDirectory {
            startRemoteLoad(at: item.path)
            return true
        }

        // Non-directory: will be handled by MainWindowController for download+open
        return false
    }

    /// Navigate up in remote directory tree.
    func goUpRemote() {
        guard let session = remoteSession else { return }
        let parent = session.fileSystem.parentPath(for: currentPath)
        if parent == currentPath {
            exitRemote()
            return
        }
        // Remember the folder name we're leaving so cursor lands on it
        let leavingFolderName = (currentPath as NSString).lastPathComponent
        startRemoteLoad(at: parent, preferredCursorName: leavingFolderName)
    }

    /// Breadcrumb components for a remote path.
    var remoteBreadcrumbs: [(name: String, path: String)] {
        guard let session = remoteSession else { return [] }

        var components: [(name: String, path: String)] = []
        var path = currentPath

        while path != "/" && !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            components.append((name: name, path: path))
            path = session.fileSystem.parentPath(for: path)
        }

        // Root entry with protocol label
        components.append((
            name: session.connection.proto.displayName + "://" + session.connection.host,
            path: "/"
        ))

        return components.reversed()
    }

    /// Whether the panel should navigate to a remote directory on container open.
    func shouldOpenAsRemoteContainer(_ item: FileItem) -> Bool {
        guard insideRemote else { return false }
        return item.name == ".." || item.isDirectory
    }
}
