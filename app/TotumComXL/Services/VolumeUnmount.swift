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

    /// Отключить том по пути к его корню. Ждёт ответа диспетчера, поэтому зовётся не с
    /// главного потока. Том, которого диспетчер не знает (его уже нет), считается
    /// отключённым.
    static func unmount(path: String, force: Bool = false, timeout: TimeInterval = 30) -> Outcome {
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
        return box.outcome
    }

    private static func outcome(of dissenter: DADissenter) -> Outcome {
        let status = DADissenterGetStatus(dissenter)
        if status == DAReturn(kDAReturnBusy) { return .busy }
        let text = DADissenterGetStatusString(dissenter) as String? ?? ""
        return .failed(text.isEmpty ? String(format: "0x%08X", status) : text)
    }

    private final class OutcomeBox: @unchecked Sendable {
        var outcome: Outcome = .done
        var signal: DispatchSemaphore?
    }
}
