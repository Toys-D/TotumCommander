import Darwin
import DiskArbitration
import Foundation
import IOKit

/// Detected volume interface info.
struct VolumeInterfaceInfo {
    enum BusType: String {
        case nvme = "NVMe"
        case thunderbolt = "Thunderbolt"
        case usb3 = "USB 3.x"
        case usb2 = "USB 2.0"
        case usb1 = "USB 1.x"
        case sata = "SATA"
        case appleInternal = "Internal"
        case network = "Network"
        case diskImage = "Disk Image"
        case unknown = "Unknown"
    }

    let busType: BusType
    let isFast: Bool
    let displayName: String
    let modeDescription: String
    let filesystem: String
    let isReadOnlyNTFS: Bool

    static let internalSSD = VolumeInterfaceInfo(
        busType: .appleInternal, isFast: true,
        displayName: L("volume.iface.internalSSD"),
        modeDescription: L("volume.iface.internalSSD.mode"),
        filesystem: "APFS", isReadOnlyNTFS: false)
    static let unknown = VolumeInterfaceInfo(
        busType: .unknown, isFast: false,
        displayName: L("volume.iface.unknown"),
        modeDescription: L("volume.iface.unknown.mode"),
        filesystem: "Unknown", isReadOnlyNTFS: false)
}

/// Detects the physical interface (USB 2.0, USB 3.x, Thunderbolt, NVMe, etc.)
/// for a mounted volume by walking the IOKit registry tree.
///
/// Classification rule: ONLY Internal + Thunderbolt 3/4 = fast.
/// Everything below Thunderbolt (all USB, SATA, network) = slow.
enum VolumeInterfaceDetector {
    private static var cache: [String: VolumeInterfaceInfo] = [:]

    static func clearCache() {
        cache.removeAll()
    }

    static func detect(forPath path: String) -> VolumeInterfaceInfo {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeURLKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return .unknown
        }

        // Internal drive → fast
        if values.volumeIsInternal == true {
            return .internalSSD
        }

        // Network drive → slow
        if values.volumeIsLocal == false {
            return VolumeInterfaceInfo(
                busType: .network, isFast: false,
                displayName: L("volume.iface.network"),
                modeDescription: L("volume.iface.network.mode"),
                filesystem: "Network", isReadOnlyNTFS: false)
        }

        // Get mount point for caching
        let mountPoint = values.volume?.path ?? path
        if let cached = cache[mountPoint] {
            return cached
        }

        let fsType = filesystemType(path: path)
        // Образ диска (хранилище, смонтированный .dmg) лежит на настоящем диске, а не за
        // шиной: обход IOKit шины не находил и записывал его в «медленные» — панель читала
        // его по частям и не ставила наблюдателя, так что скопированное в хранилище не
        // появлялось, пока не перечитаешь руками.
        if let bsdName = bsdDeviceName(forPath: path), isDiskImageDevice(bsdName) {
            let info = VolumeInterfaceInfo(
                busType: .diskImage, isFast: true,
                displayName: L("volume.iface.diskImage", fsType),
                modeDescription: L("volume.iface.diskImage.mode"),
                filesystem: fsType, isReadOnlyNTFS: false)
            cache[mountPoint] = info
            return info
        }

        // External + local → IOKit to detect interface, then classify
        let busInfo = detectBusViaIOKit(path: path)
        let readOnlyNTFS = isNTFSReadOnly(path: path)
        let info = classify(bus: busInfo, filesystem: fsType, isReadOnlyNTFS: readOnlyNTFS)
        cache[mountPoint] = info
        return info
    }

    // MARK: - Classification

    /// Only Thunderbolt 3/4 external is fast. Everything else external is slow.
    private static func classify(bus: BusDetectionResult, filesystem: String, isReadOnlyNTFS: Bool = false) -> VolumeInterfaceInfo {
        switch bus.type {
        case .thunderbolt:
            return VolumeInterfaceInfo(
                busType: .thunderbolt, isFast: true,
                displayName: "Thunderbolt (\(filesystem))",
                modeDescription: L("volume.iface.thunderbolt.mode"),
                filesystem: filesystem, isReadOnlyNTFS: isReadOnlyNTFS)

        case .usb3:
            let speedLabel = bus.speedLabel ?? "5+ Gbps"
            return VolumeInterfaceInfo(
                busType: .usb3, isFast: false,
                displayName: "USB 3.x \(speedLabel) (\(filesystem))",
                modeDescription: L("volume.iface.usb3.mode"),
                filesystem: filesystem, isReadOnlyNTFS: isReadOnlyNTFS)

        case .usb2:
            return VolumeInterfaceInfo(
                busType: .usb2, isFast: false,
                displayName: "USB 2.0 480 Mbps (\(filesystem))",
                modeDescription: L("volume.iface.usb2.mode"),
                filesystem: filesystem, isReadOnlyNTFS: isReadOnlyNTFS)

        case .usb1:
            return VolumeInterfaceInfo(
                busType: .usb1, isFast: false,
                displayName: "USB 1.x 12 Mbps (\(filesystem))",
                modeDescription: L("volume.iface.usb1.mode"),
                filesystem: filesystem, isReadOnlyNTFS: isReadOnlyNTFS)

        case .sata:
            return VolumeInterfaceInfo(
                busType: .sata, isFast: false,
                displayName: "SATA (\(filesystem))",
                modeDescription: L("volume.iface.sata.mode"),
                filesystem: filesystem, isReadOnlyNTFS: isReadOnlyNTFS)

        case .unknown:
            return VolumeInterfaceInfo(
                busType: .unknown, isFast: false,
                displayName: L("volume.iface.external", filesystem),
                modeDescription: L("volume.iface.external.mode"),
                filesystem: filesystem, isReadOnlyNTFS: isReadOnlyNTFS)
        }
    }

    /// Образ ли это диска — по описанию DiskArbitration: модель устройства «Disk Image».
    static func isDiskImageDevice(_ bsdName: String) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String ?? ""
        let proto = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        return model == "Disk Image" || proto == "Virtual Interface"
    }

    // MARK: - Bus detection result

    private enum DetectedBus {
        case thunderbolt, usb3, usb2, usb1, sata, unknown
    }

    private struct BusDetectionResult {
        let type: DetectedBus
        let speedLabel: String?
    }

    // MARK: - Filesystem type

    private static func filesystemType(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let desc = try? url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription {
            return desc
        }
        return "Unknown FS"
    }

    /// Checks if path is on a read-only NTFS volume using statfs.
    static func isNTFSReadOnly(path: String) -> Bool {
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: 1)
        defer { buf.deallocate() }
        guard statfs(path, buf) == 0 else { return false }
        let s = buf.pointee

        let fsType = withUnsafePointer(to: s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0).lowercased()
            }
        }
        let isReadOnly = (s.f_flags & UInt32(MNT_RDONLY)) != 0
        return fsType == "ntfs" && isReadOnly
    }

    // MARK: - IOKit detection

    private static func detectBusViaIOKit(path: String) -> BusDetectionResult {
        guard let bsdName = bsdDeviceName(forPath: path) else {
            return BusDetectionResult(type: .unknown, speedLabel: nil)
        }

        let matching = IOServiceMatching("IOMedia") as NSMutableDictionary
        matching["BSD Name"] = bsdName
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            return BusDetectionResult(type: .unknown, speedLabel: nil)
        }
        defer { IOObjectRelease(service) }

        return walkRegistryForBus(from: service)
    }

    /// Returns the full BSD device path (e.g. "/dev/disk4s1") for a mounted volume.
    static func bsdDevicePath(forVolume path: String) -> String {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return "" }
        return withUnsafePointer(to: &buf.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private static func bsdDeviceName(forPath path: String) -> String? {
        let full = bsdDevicePath(forVolume: path)
        guard !full.isEmpty else { return nil }
        return full.replacingOccurrences(of: "/dev/", with: "")
    }

    private static func walkRegistryForBus(from service: io_service_t) -> BusDetectionResult {
        var current = service
        IOObjectRetain(current)

        for _ in 0..<20 {
            let className = ioClassName(of: current)

            if className.contains("NVMe") {
                if current != service { IOObjectRelease(current) }
                return BusDetectionResult(type: .thunderbolt, speedLabel: "NVMe over TB")
            }

            if className.contains("Thunderbolt") {
                if current != service { IOObjectRelease(current) }
                return BusDetectionResult(type: .thunderbolt, speedLabel: nil)
            }

            if className.contains("USB") || className.contains("usb") {
                let result = detectUSBSpeed(from: current, original: service)
                if current != service { IOObjectRelease(current) }
                return result
            }

            if className.contains("AHCI") || className.contains("SATA") {
                if current != service { IOObjectRelease(current) }
                return BusDetectionResult(type: .sata, speedLabel: nil)
            }

            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if current != service { IOObjectRelease(current) }
            guard kr == KERN_SUCCESS, parent != IO_OBJECT_NULL else { break }
            current = parent
        }

        if current != service { IOObjectRelease(current) }
        return BusDetectionResult(type: .unknown, speedLabel: nil)
    }

    /// USB speed constants from IOKit:
    /// 0 = Low Speed (1.5 Mbps), 1 = Full Speed (12 Mbps),
    /// 2 = High Speed (480 Mbps / USB 2.0), 3 = SuperSpeed (5 Gbps / USB 3.0),
    /// 4 = SuperSpeed+ (10 Gbps / USB 3.1), 5 = SuperSpeed20 (20 Gbps / USB 3.2)
    private static func detectUSBSpeed(from entry: io_registry_entry_t, original: io_service_t) -> BusDetectionResult {
        var current = entry
        IOObjectRetain(current)

        let speedKeys = ["Device Speed", "kUSBDeviceSpeed", "UsbDeviceSpeed"]

        for _ in 0..<10 {
            for key in speedKeys {
                if let speedRef = IORegistryEntryCreateCFProperty(current, key as CFString, kCFAllocatorDefault, 0) {
                    let speed = (speedRef.takeRetainedValue() as? NSNumber)?.intValue ?? 0
                    if current != entry { IOObjectRelease(current) }
                    return classifyUSBSpeed(speed)
                }
            }

            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            let prev = current
            guard kr == KERN_SUCCESS, parent != IO_OBJECT_NULL else { break }
            current = parent
            if prev != entry { IOObjectRelease(prev) }
        }

        if current != entry { IOObjectRelease(current) }
        return BusDetectionResult(type: .usb2, speedLabel: "speed unknown")
    }

    private static func classifyUSBSpeed(_ speed: Int) -> BusDetectionResult {
        switch speed {
        case 5: return BusDetectionResult(type: .usb3, speedLabel: "20 Gbps")
        case 4: return BusDetectionResult(type: .usb3, speedLabel: "10 Gbps")
        case 3: return BusDetectionResult(type: .usb3, speedLabel: "5 Gbps")
        case 2: return BusDetectionResult(type: .usb2, speedLabel: "480 Mbps")
        case 1: return BusDetectionResult(type: .usb1, speedLabel: "12 Mbps")
        default: return BusDetectionResult(type: .usb1, speedLabel: "1.5 Mbps")
        }
    }

    private static func ioClassName(of entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        let kr = IOObjectGetClass(entry, &name)
        guard kr == KERN_SUCCESS else { return "" }
        return String(cString: name)
    }
}
