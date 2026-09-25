import AppKit
import Foundation
import SwiftUI

/// Следит за копиями облачных файлов, открытыми во внешних программах.
///
/// Enter на файле из облака открывает не сам файл, а его временную копию на диске —
/// иначе никак: Word не умеет читать из Google Drive. Человек правит и сохраняет, Word
/// честно пишет — в копию. Облако об этом не знает, и правки молча пропадали при
/// отключении. Теперь за копией следят: сохранил — спросим, отправить ли обратно.
///
/// Слежение — это один взгляд на время правки файла раз в две секунды, не дороже.
/// Сохранение замечается по изменившемуся времени, но спрашиваем не сразу, а когда оно
/// устоялось: программы сохраняют не в один приём, и спросить на середине значило бы
/// отправить полфайла.
@MainActor
final class RemoteEditWatcher {

    static let shared = RemoteEditWatcher()

    /// Как часто заглядывать. Две секунды: незаметно для машины, быстро для человека.
    var interval: TimeInterval = 2

    /// Спросить человека, отправлять ли. Подменяется в тестах: модальному окну там
    /// взяться неоткуда.
    var askToSend: (_ fileName: String, _ storageName: String) -> Bool = { file, storage in
        let choice = FCXLMessageDialog.run(FCXLMessageConfig(
            title: L("remoteEdit.changed.title"),
            message: L("remoteEdit.changed.message", file, storage),
            icon: "icloud.and.arrow.up",
            iconColor: PanelAppearanceSettings.accentColor,
            buttons: [
                FCXLMessageButton(title: L("remoteEdit.keepLocal")),
                FCXLMessageButton(title: L("remoteEdit.send"), kind: .primary)
            ]))
        return choice.buttonIndex == 1
    }

    /// Полоса отправки. В тестах подменяется на «без полосы».
    var makeProgress: (_ name: String, _ cancel: CancelBox) -> OperationProgressReporter? = {
        name, cancel in
        DialogService.shared.showProgress(title: L("remoteEdit.uploading", name),
                                          message: name,
                                          cancelHandler: { cancel.raise() })
    }

    /// Жалоба на неудавшуюся отправку. В тестах — молчит.
    var complain: (_ fileName: String, _ why: String) -> Void = { file, why in
        DialogService.shared.showError(title: L("remoteEdit.uploadFailed.title"),
                                       message: "\(file): \(why)")
    }

    private struct Watch {
        let localPath: String
        let item: FileItem
        let session: RemoteSession
        /// Время правки копии, совпадающее с облаком: что новее — то не отправлено.
        var baseline: Date
        /// Последнее замеченное время правки — чтобы дождаться, пока сохранение утихнет.
        var seen: Date?
        /// Время правки, про которое человек уже ответил (или отправка не удалась):
        /// то же самое не переспрашиваем — иначе вопрос долбил бы каждые две секунды.
        var answered: Date?
        var busy = false
    }

    private var watches: [String: Watch] = [:]
    private var timer: Timer?

    // MARK: - Кого сторожить

    /// Копия открыта во внешней программе — с этого мгновения она под присмотром.
    func watch(localPath: String, item: FileItem, session: RemoteSession) {
        guard watches[localPath] == nil else { return }
        watches[localPath] = Watch(localPath: localPath, item: item, session: session,
                                   baseline: Self.stamp(localPath) ?? Date())
        startTimerIfNeeded()
    }

    /// Подключение закрыто — его копии уже не наши.
    func forget(connectionID: UUID) {
        watches = watches.filter { $0.value.session.connection.id != connectionID }
        stopTimerIfIdle()
    }

    /// Имена файлов с правками, ещё не отправленными в это хранилище.
    func dirtyNames(for connectionID: UUID) -> [String] {
        watches.values
            .filter { $0.session.connection.id == connectionID && isDirty($0) }
            .map(\.item.name)
            .sorted()
    }

    // MARK: - Присмотр

    /// Один обход. Таймер зовёт его сам; тесты — руками, без ожидания.
    func checkNow() async {
        for key in Array(watches.keys) {
            guard var watch = watches[key], !watch.busy else { continue }
            guard let current = Self.stamp(key) else {
                // Копии больше нет — кэш прибрали, сторожить нечего.
                watches.removeValue(forKey: key)
                continue
            }
            guard isDirty(watch) else { continue }
            if let answered = watch.answered, abs(current.timeIntervalSince(answered)) < 0.5 {
                continue        // про это сохранение уже спрашивали
            }
            guard let seen = watch.seen, abs(current.timeIntervalSince(seen)) < 0.5 else {
                // Первое известие об изменении: запомним и дадим сохранению дописаться.
                watch.seen = current
                watches[key] = watch
                continue
            }

            watch.busy = true
            watches[key] = watch
            if askToSend(watch.item.name, watch.session.connection.label.isEmpty
                            ? watch.session.connection.kindTitle
                            : watch.session.connection.label) {
                await send(key)
            } else {
                // Человек решил оставить правки при себе — копия его, вопрос снят.
                // Правки живут, пока живёт копия, и уйдут вместе с отключением: об этом
                // сказано прямо в вопросе.
                watches.removeValue(forKey: key)
            }
        }
        stopTimerIfIdle()
    }

    /// Отправить всё несданное этого подключения — перед его закрытием.
    func uploadDirty(for session: RemoteSession) async {
        for key in Array(watches.keys) {
            guard let watch = watches[key],
                  watch.session.connection.id == session.connection.id,
                  isDirty(watch), !watch.busy else { continue }
            watches[key]?.busy = true
            await send(key)
        }
    }

    // MARK: - Отправка

    private func send(_ key: String) async {
        guard var watch = watches[key] else { return }
        let cancel = CancelBox()
        let progress = makeProgress(watch.item.name, cancel)
        defer { progress?.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: key))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
        do {
            try await watch.session.fileSystem.upload(
                localPath: key, to: watch.item.path,
                progress: { done, known in
                    let whole = size > 0 ? size : known
                    if let progress {
                        Task { @MainActor in
                            progress.update(currentFile: key, progress:
                                whole > 0 ? Double(done) / Double(whole) : 0,
                                bytesDone: done, bytesTotal: whole,
                                filesDone: 0, filesTotal: 1)
                        }
                    }
                    return cancel.raised || (progress?.isCancelled ?? false)
                })
            watch.baseline = Self.stamp(key) ?? Date()
            watch.seen = nil
            watch.answered = nil
            watch.busy = false
            watches[key] = watch
            // Панель, показывающая эту папку, перечитает её и увидит свежую дату.
            NotificationCenter.default.post(
                name: .fcxlRemoteFileUploaded, object: nil,
                userInfo: ["connectionID": watch.session.connection.id,
                           "folder": Self.parentFolder(of: watch.item.path)])
        } catch {
            // Неудача не снимает присмотра: правки всё ещё не в облаке, и при отключении
            // об этом спросят. Но то же сохранение не переспрашиваем — иначе вопрос
            // долбил бы каждые две секунды.
            watch.answered = Self.stamp(key)
            watch.busy = false
            watches[key] = watch
            if let remote = error as? RemoteFileSystemError,
               case .transferCancelled = remote { return }
            complain(watch.item.name,
                     (error as? RemoteFileSystemError)?.errorDescription
                        ?? error.localizedDescription)
        }
    }

    // MARK: - Мелочи

    private func isDirty(_ watch: Watch) -> Bool {
        guard let current = Self.stamp(watch.localPath) else { return false }
        return abs(current.timeIntervalSince(watch.baseline)) > 0.5
    }

    static func parentFolder(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private static func stamp(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await RemoteEditWatcher.shared.checkNow() }
        }
    }

    private func stopTimerIfIdle() {
        guard watches.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}

extension Notification.Name {
    /// Правки из местной копии отправлены обратно в хранилище.
    static let fcxlRemoteFileUploaded = Notification.Name("fcxlRemoteFileUploaded")
}
