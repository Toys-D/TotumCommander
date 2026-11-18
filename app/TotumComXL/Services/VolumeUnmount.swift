import DiskArbitration
import Foundation

/// Отключение тома через Disk Arbitration — той же дорогой, что и Finder.
///
/// Раньше том отключал `diskutil unmount`: отдельный процесс, который сначала поднимается,
/// договаривается с диспетчером дисков и лишь потом просит о том же самом — 350–700 мс
/// сверх самого отключения, которое занимает 150–250 мс. Прямая просьба к диспетчеру
/// обходится без посредника и к тому же отвечает ясно: занят — или не вышло, и почему.
enum VolumeUnmount {

    enum Outcome: Equatable {
        case done
        /// Кто-то держит файлы на томе — можно повторить чуть позже или отключать силой.
        case busy
        case failed(String)
    }

    private static let queue = DispatchQueue(label: "fcxl.volume-unmount")
    /// Отключения идут по одному. Закрытие вкладки и кнопка извлечения могут просить об одном
    /// томе разом: вторая просьба получала «не подключён» и принималась за отказ — человек
    /// видел вопрос «отключить силой?» про том, который как раз благополучно отключался.
    private static let turn = NSLock()
    /// Сетевой том отвечает «занят» кодом системы — unix_err(EBUSY), — а не диспетчера.
    static let busyErrno = DAReturn(0xC000 | EBUSY)

    /// Отключить том по пути к его корню. Ждёт ответа диспетчера, поэтому зовётся не с
    /// главного потока. Том, которого диспетчер не знает (его уже нет), считается
    /// отключённым.
    static func unmount(path: String, force: Bool = false, timeout: TimeInterval = 30) -> Outcome {
        turn.lock()
        defer { turn.unlock() }
        // Не точка подключения (том уже отключён, осталась папка или её нет) — делать нечего.
        // И спрашивать диспетчер о ней нельзя: он мог бы принять её за том, где она лежит.
        guard MountTable.isMountPoint(path) else { return .done }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return .failed("DASessionCreate")
        }
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session,
                                                    URL(fileURLWithPath: path) as CFURL) else {
            return FileManager.default.fileExists(atPath: path) ? .failed("DADiskCreateFromVolumePath") : .done
        }

        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        box.signal = done   // до просьбы: ответ может прийти раньше, чем вернётся вызов
        let options = force ? DADiskUnmountOptions(kDADiskUnmountOptionForce)
                            : DADiskUnmountOptions(kDADiskUnmountOptionDefault)
        DADiskUnmount(disk, options, { _, dissenter, context in
            let box = Unmanaged<OutcomeBox>.fromOpaque(context!).takeUnretainedValue()
            box.outcome = dissenter.map { VolumeUnmount.outcome(of: $0) } ?? .done
            box.signal?.signal()
        }, Unmanaged.passUnretained(box).toOpaque())
        guard done.wait(timeout: .now() + timeout) == .success else {
            return .failed("timeout")
        }
        // Что бы ни ответил диспетчер: тома на месте уже нет — значит, он отключён.
        if box.outcome != .done, !MountTable.isMountPoint(path) { return .done }
        return box.outcome
    }

    /// Просьба с короткими повторами, пока том занят: панель отпускает папку не мгновенно, и
    /// вторая-третья попытка обычно проходит. `note` — для ленты подключений.
    static func unmountPatiently(path: String, attempts: Int = 3, pause: TimeInterval = 0.4,
                                 note: (Outcome, Int) -> Void = { _, _ in }) -> Outcome {
        var outcome = Outcome.busy
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { Thread.sleep(forTimeInterval: pause) }
            outcome = unmount(path: path)
            note(outcome, attempt + 1)
            if outcome != .busy { break }
        }
        return outcome
    }

    private static func outcome(of dissenter: DADissenter) -> Outcome {
        outcome(status: DADissenterGetStatus(dissenter),
                text: DADissenterGetStatusString(dissenter) as String? ?? "")
    }

    /// Ответ диспетчера словами программы. «Занят» приходит в двух видах — своим кодом и кодом
    /// системы; «не подключён» — это уже отключён.
    static func outcome(status: DAReturn, text: String) -> Outcome {
        if status == DAReturn(kDAReturnBusy) || status == busyErrno { return .busy }
        if status == DAReturn(kDAReturnNotMounted) { return .done }
        return .failed(text.isEmpty ? String(format: "0x%08X", status) : text)
    }

    private final class OutcomeBox: @unchecked Sendable {
        var outcome: Outcome = .done
        var signal: DispatchSemaphore?
    }
}
