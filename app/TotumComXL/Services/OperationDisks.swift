import Darwin
import Foundation

/// Какие диски занимает операция очереди: две операции на одном внешнем или сетевом диске
/// мешают друг другу — на USB делят полосу, на жёстком диске гоняют головку — и вместе выходят
/// не быстрее, а медленнее. Такие идут по одной, на разных дисках — вместе. Внутренний SSD с
/// параллельной работой справляется: там операции идут вместе, как и раньше, — иначе долгая
/// упаковка с него держала бы любое копирование часами.
///
/// Диск узнаётся по таблице подключённых томов из памяти ядра, без обращения к самим дискам:
/// очередь решает это на главном потоке, а занятый внешний диск отвечал бы ей секундами.
enum OperationDisks {
    struct Mount: Equatable {
        let point: String
        let device: String
    }

    static func mountTable() -> [Mount] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, let table else { return [] }
        return (0..<Int(count)).map { index in
            var entry = table[index]
            let point = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let device = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return Mount(point: point, device: device)
        }
    }

    /// «/dev/disk32s2» → «disk32»: разделы одного диска — один диск. Сетевой том — его адрес.
    static func wholeDisk(_ device: String) -> String {
        let prefix = "/dev/disk"
        guard device.hasPrefix(prefix) else { return device }
        return "disk" + device.dropFirst(prefix.count).prefix(while: \.isNumber)
    }

    /// Внешний или сетевой диск, на котором лежит путь; nil — внутренний или неизвестно где.
    static func exclusiveDisk(for path: String, mounts: [Mount]) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let mount = mounts
            .filter { $0.point.hasPrefix("/Volumes/") && (path == $0.point || path.hasPrefix($0.point + "/")) }
            .max { $0.point.count < $1.point.count }
        return mount.map { wholeDisk($0.device) }
    }

    /// Внешние и сетевые диски, которые операция читает или пишет.
    static func exclusiveDisks(of operation: QueuedOperation, mounts: [Mount]) -> Set<String> {
        var paths = operation.items.map(\.path)
        if let destination = operation.destinationPath { paths.append(destination) }
        if let archive = operation.archiveParams?.archivePath { paths.append(archive) }
        if let rename = operation.renameParams, !rename.isRemote, let step = rename.steps.first {
            paths.append(step.from)
        }
        return Set(paths.compactMap { exclusiveDisk(for: $0, mounts: mounts) })
    }
}
