import Foundation
import IOKit
import Metal

/// One-shot read of this Mac's hardware, used to gate GPU-heavy "beauty" effects
/// (blur, glow, …). The bar is Apple Silicon at the MacBook-Pro tier or above, which
/// in power terms means an M-Pro / Max / Ultra class GPU (≥ 14 GPU cores).
enum MacCapabilities {
    /// Minimum GPU cores for beauty mode — 14 = the M-Pro tier. Base M chips have 7–10.
    static let beautyMinGPUCores = 14

    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    /// e.g. "Apple M3 Max" or "Intel(R) Core(TM) i7…".
    static let chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "—"
        }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    /// Physical RAM rounded to the nearest whole GB.
    static let physicalMemoryGB: Int = {
        Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) / (1 << 30))
    }()

    static let gpuName: String = {
        MTLCreateSystemDefaultDevice()?.name ?? "—"
    }()

    /// GPU core count from the IORegistry (0 on Intel / when unavailable).
    static let gpuCoreCount: Int = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator
        ) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var cores = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let value = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Int {
                cores = value
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return cores
    }()

    /// Fallback when the GPU core count can't be read: does the chip name carry a
    /// Pro / Max / Ultra suffix?
    private static var chipIsProClass: Bool {
        let n = chipName.lowercased()
        return n.contains("pro") || n.contains("max") || n.contains("ultra")
    }

    /// Beauty mode requires Apple Silicon at the MacBook-Pro tier or above.
    static var supportsBeautyMode: Bool {
        guard isAppleSilicon else { return false }
        if gpuCoreCount > 0 { return gpuCoreCount >= beautyMinGPUCores }
        return chipIsProClass
    }
}
