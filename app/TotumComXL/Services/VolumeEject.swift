import AppKit

/// Извлечение диска — одно на всю программу.
///
/// Вопросы перед извлечением (идёт копирование, не сохранён файл), уход панелей с тома,
/// образ, который снимается целиком через hdiutil, занятый диск с перечнем тех, кто его
/// держит, и извлечение силой — всё это одинаково для кнопки на полосе дисков и для
/// «Размонтировать» у файла образа, поэтому живёт здесь, а не в самой полосе.
@MainActor
enum VolumeEject {

    /// Извлечь диск: кнопка и меню полосы дисков, «Размонтировать» у файла образа.
    /// `label` — как диск назовут вопросы и ошибки.
    static func eject(path: String, label: String) {
        let volumeRoot = normalizePath(path)
        let isNetwork = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        )?.first(where: { normalizePath($0.path) == volumeRoot })
            .flatMap { try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal }
            == false

        let controller = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first

        // Actually start the eject: stop watchers, navigate both panels away, then unmount after
        // a short delay so file handles close first. Network volumes need a longer delay.
        let clicked = Date()
        MountTrace.log("Извлечение «\(label)» (\(isNetwork ? "сетевой" : "локальный")): нажато")
        let startEject = {
            controller?.prepareForVolumeEject(volumeRoot)
            MountTrace.log("Извлечение «\(label)»: панели уведены с тома", since: clicked)
            if isNetwork {
                // Сразу: сетевой том отключается через диспетчер дисков, и если какой-то
                // файл ещё не успел закрыться, диспетчер так и скажет — тогда повторим.
                // Пауза в секунду «чтобы файлы закрылись» стояла здесь раньше и была
                // большей частью того, за что эту кнопку звали задумчивой.
                unmountNetworkVolume(path: volumeRoot, label: label, since: clicked)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    ejectLocalVolume(volumeRoot: volumeRoot, label: label)
                }
            }
        }

        // Pre-flight: is OUR OWN app holding this volume? An active copy/move touching it, or an
        // unsaved editor backed by a file on it. Force-unmounting mid-write corrupts data, and
        // ejecting orphans an unsaved editor (its Save would then fail). Warn before proceeding.
        let busyOps = controller?.activeOperationTitles(onVolume: volumeRoot) ?? []
        let unsavedDocs = controller?.unsavedEditorPaths(onVolume: volumeRoot) ?? []
        guard !busyOps.isEmpty || !unsavedDocs.isEmpty else {
            startEject()
            return
        }

        var lines: [String] = []
        if !busyOps.isEmpty {
            lines.append(L("volume.eject.busy.operations"))
            lines.append(contentsOf: busyOps.map { "  • " + $0 })
        }
        if !unsavedDocs.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(L("volume.eject.busy.unsaved"))
            lines.append(contentsOf: unsavedDocs.map { "  • " + ($0 as NSString).lastPathComponent })
        }
        let detail = lines.joined(separator: "\n")

        fcxlPresentModal {
            if DialogService.shared.showDestructiveConfirmation(
                title: L("volume.eject.busy.title"),
                message: L("volume.eject.busy.message", label, detail),
                confirmTitle: L("volume.eject.busy.forceButton")) {
                startEject()
            }
        }
    }

    /// Eject a local disk. If it's busy, identify the blocking apps and offer
    /// a force eject instead of failing with a raw system error.
    private static func ejectLocalVolume(volumeRoot: String, label: String) {
        // A disk image's volume: detach the IMAGE, as Finder does. NSWorkspace's eject leaves
        // the image attached with no volume, and macOS then refuses to open it a second time.
        if let image = FileOperationsService.imagePath(forMountPoint: volumeRoot,
                                                        info: FileOperationsService.hdiutilInfoPlist()) {
            detachImage(image, volumeRoot: volumeRoot, label: label, force: false)
            return
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volumeRoot))
            NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
        } catch {
            // Most likely "disk in use". Find what's holding it open.
            let procs = Self.blockingProcessNames(volumeRoot: volumeRoot)
            let detail = procs.isEmpty
                ? L("volume.eject.inUse.unknown")
                : procs.joined(separator: ", ")
            // This runs inside an asyncAfter (main-queue) block, which parks the queue and
            // would kill the FCXLDialog's buttons — enter the confirmation via a runloop
            // callout. The result is used right here, so no need to return it.
            fcxlPresentModal {
                if DialogService.shared.showDestructiveConfirmation(
                    title: L("volume.eject.inUse.title"),
                    message: L("volume.eject.inUse.message", label, detail),
                    confirmTitle: L("volume.eject.forceButton")) {
                    Self.forceEject(volumeRoot: volumeRoot, label: label)
                }
            }
        }
    }

    /// What is holding the volume: each blocker as "App — file", or just the app when the file
    /// cannot be told. Ourselves included — being told "Totum Commander is holding it" is worth
    /// far more than being told nothing.
    ///
    /// NB: lsof lives in /usr/sbin on macOS. It was being run from /usr/bin, which does not
    /// exist, so the launch threw and every disk reported "could not determine the processes".
    nonisolated static func blockingProcessNames(volumeRoot: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // +c0 = full command names; -Fcn = field output (c=command, n=name).
        // -b avoids kernel calls that can block on a stalled network mount.
        proc.arguments = ["-w", "-b", "+c0", "-Fcn"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak proc] in if proc?.isRunning == true { proc?.terminate() } }
        timer.resume()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timer.cancel()

        return parseBlockers(lsofOutput: String(data: data, encoding: .utf8) ?? "",
                             volumeRoot: volumeRoot)
    }

    /// Turn lsof's field output into one readable line per blocker.
    nonisolated static func parseBlockers(lsofOutput: String, volumeRoot: String) -> [String] {
        let prefix = volumeRoot.hasSuffix("/") ? volumeRoot : volumeRoot + "/"
        // First file seen per process — one line each, so a process with 40 open files does not
        // fill the dialog.
        var firstFile: [String: String] = [:]
        var order: [String] = []
        var current = ""
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("c") {
                current = String(line.dropFirst())
            } else if line.hasPrefix("n"), !current.isEmpty {
                let path = String(line.dropFirst())
                guard path == volumeRoot || path.hasPrefix(prefix) else { continue }
                let app = current == "TotumComXL" ? "Totum Commander" : current
                if firstFile[app] == nil {
                    order.append(app)
                    // The volume root itself is just "somebody is standing in it" — no file to name.
                    firstFile[app] = path == volumeRoot ? "" : String(path.dropFirst(prefix.count))
                }
            }
        }
        return order.sorted().prefix(12).map { app in
            let file = firstFile[app] ?? ""
            return file.isEmpty ? app : "\(app) — \(file)"
        }
    }

    /// Detach a mounted image OFF the main thread: diskarbitrationd asks this very app to
    /// approve the unmount, on the main run loop — waiting for hdiutil there is a 14 s stall
    /// (see VaultService.lockOffMain). A busy image asks before being forced, like a disk.
    private static func detachImage(_ image: String, volumeRoot: String, label: String, force: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try FileOperationsService.detachImage(at: image, force: force) } catch { failure = error }
            DispatchQueue.main.async {
                guard let failure else {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                    return
                }
                guard !force else {
                    DialogService.shared.showOperationError(title: L("volume.eject.failed.title"),
                                                            error: failure)
                    return
                }
                let procs = Self.blockingProcessNames(volumeRoot: volumeRoot)
                let detail = procs.isEmpty ? L("volume.eject.inUse.unknown")
                                           : procs.joined(separator: ", ")
                fcxlPresentModal {
                    if DialogService.shared.showDestructiveConfirmation(
                        title: L("volume.eject.inUse.title"),
                        message: L("volume.eject.inUse.message", label, detail),
                        confirmTitle: L("volume.eject.forceButton")) {
                        detachImage(image, volumeRoot: volumeRoot, label: label, force: true)
                    }
                }
            }
        }
    }

    /// Force-unmount then eject via diskutil.
    private static func forceEject(volumeRoot: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            func run(_ args: [String]) -> Int32 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                p.arguments = args
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
                catch { return -1 }
            }
            _ = run(["unmount", "force", volumeRoot])
            let ejectStatus = run(["eject", volumeRoot])
            DispatchQueue.main.async {
                if ejectStatus == 0 || !FileManager.default.fileExists(atPath: volumeRoot) {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                } else {
                    DialogService.shared.showError(
                        title: L("volume.eject.failed.title"),
                        message: L("volume.eject.forceFailed", label))
                }
            }
        }
    }

    /// Unmount a network volume using diskutil (more reliable than NSWorkspace for SMB/AFP).
    /// If the graceful unmount fails (the share is busy), ASK before force-unmounting — a silent
    /// force can tear the share out from under an in-flight transfer and corrupt data.
    private static func unmountNetworkVolume(path: String, label: String, since clicked: Date) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Занят — значит, панель ещё не отпустила папку: две короткие повторные попытки
            // укладываются в то время, что раньше стояло паузой, а обычно не нужны вовсе.
            var outcome = VolumeUnmount.Outcome.busy
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
                outcome = VolumeUnmount.unmount(path: path)
                MountTrace.log("Отключение «\(label)»: диспетчер ответил \(outcome) (попытка \(attempt + 1))",
                               since: clicked)
                if outcome != .busy { break }
            }
            if outcome == .done {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                    MountTrace.log("Отключение «\(label)»: полоса дисков обновлена", since: clicked)
                }
                return
            }

            // Graceful unmount failed — the share is busy. Name the blocking apps and ask for
            // confirmation (same flow as a local disk) instead of forcing silently.
            let procs = Self.blockingProcessNames(volumeRoot: path)
            let detail = procs.isEmpty
                ? L("volume.eject.inUse.unknown")
                : procs.joined(separator: ", ")
            DispatchQueue.main.async {
                fcxlPresentModal {
                    guard DialogService.shared.showDestructiveConfirmation(
                        title: L("volume.eject.inUse.title"),
                        message: L("volume.eject.inUse.message", label, detail),
                        confirmTitle: L("volume.eject.forceButton")) else { return }
                    Self.forceUnmountNetwork(path: path, label: label)
                }
            }
        }
    }

    /// Force-unmount a busy network share (network mounts are unmounted, never ejected).
    private static func forceUnmountNetwork(path: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = VolumeUnmount.unmount(path: path, force: true)
            MountTrace.log("Отключение «\(label)» силой: диспетчер ответил \(outcome)")
            DispatchQueue.main.async {
                if outcome == .done || !FileManager.default.fileExists(atPath: path) {
                    NotificationCenter.default.post(name: .volumeBarNeedsRefresh, object: nil)
                } else {
                    let reason: String
                    if case .failed(let text) = outcome, !text.isEmpty { reason = text }
                    else { reason = L("volume.eject.forceFailed", label) }
                    DialogService.shared.showError(title: L("volume.eject.failed.title"), message: reason)
                }
            }
        }
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
