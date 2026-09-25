import Foundation
import SwiftUI
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// One live sample of the machine's state, everything the monitor UI reads from.
struct SystemSnapshot: Equatable {
    var cpuTotal: Double = 0              // 0…100 (whole machine)
    var cpuPerCore: [Double] = []        // 0…100 per logical core
    var cpuUser: Double = 0              // 0…100 breakdown
    var cpuSystem: Double = 0
    var cpuIdle: Double = 100

    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    var memWiredBytes: UInt64 = 0
    var memCompressedBytes: UInt64 = 0
    var memAppBytes: UInt64 = 0          // active + inactive (app memory, roughly)
    var memCachedBytes: UInt64 = 0       // file-backed / cached
    var memPressure: Double = 0          // 0…1 (used / total) — bar height
    var memPressureLevel: Int = 1        // real kernel signal: 1 normal, 2 warning, 4 critical
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0

    var disks: [DiskUsage] = []
    var diskReadBytesPerSec: Double = 0
    var diskWriteBytesPerSec: Double = 0
    var diskReadsPerSec: Double = 0
    var diskWritesPerSec: Double = 0
    var diskReadBytesTotal: UInt64 = 0
    var diskWriteBytesTotal: UInt64 = 0

    var netInBytesPerSec: Double = 0
    var netOutBytesPerSec: Double = 0
    var netInBytesTotal: UInt64 = 0
    var netOutBytesTotal: UInt64 = 0
    var netInPacketsPerSec: Double = 0
    var netOutPacketsPerSec: Double = 0
    var netInPacketsTotal: UInt64 = 0
    var netOutPacketsTotal: UInt64 = 0

    var battery: BatteryInfo?            // nil on desktops / when unavailable

    // GPU — read from IORegistry (IOAccelerator PerformanceStatistics), no privilege required.
    var gpuUtilization: Double = 0       // Device Utilization %
    var gpuCoreCount: Int = 0
    var gpuInUseMemBytes: UInt64 = 0
    var gpuAllocMemBytes: UInt64 = 0
    var thermalState: Int = 0            // ProcessInfo: 0 nominal, 1 fair, 2 serious, 3 critical

    // Real power draw in watts — only when the user opts in; needs powermetrics (root).
    var powerCPUWatts: Double = 0
    var powerGPUWatts: Double = 0
    var powerTotalWatts: Double = 0
    var powerAvailable = false           // false when powermetrics is off or not permitted

    var processes: [ProcessSample] = []  // full list, sorted by the current sort key
}

struct DiskUsage: Equatable, Identifiable {
    let name: String
    let freeBytes: UInt64
    let totalBytes: UInt64
    var id: String { name }
    var usedBytes: UInt64 { totalBytes >= freeBytes ? totalBytes - freeBytes : 0 }
    var fraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
}

struct BatteryInfo: Equatable {
    let percent: Double                  // 0…100
    let isCharging: Bool
    let isPluggedIn: Bool
    let minutesRemaining: Int            // -1 when unknown / calculating
}

struct ProcessSample: Equatable, Identifiable {
    let pid: Int32
    let name: String
    let cpuPercent: Double               // can exceed 100 on multi-core (like Activity Monitor)
    let cpuTimeSeconds: Double           // cumulative user+system CPU time (Activity Monitor "CPU Time")
    let memBytes: UInt64                 // phys_footprint — Activity Monitor's default "Memory" column
    let residentBytes: UInt64            // resident size — Activity Monitor's "Real Mem"
    let diskReadBytesPerSec: Double
    let diskWriteBytesPerSec: Double
    let diskReadTotal: UInt64            // cumulative bytes read (AM Disk tab "Bytes Read")
    let diskWriteTotal: UInt64           // cumulative bytes written (AM Disk tab "Bytes Written")
    let idleWakeupsPerSec: Double        // AM "Idle Wake Ups"
    let energyImpact: Double             // approximate: cpu% weighted + idle wake-ups
    // Filled in only for the rows actually shown (threads/owner/parent are extra syscalls we skip
    // for the hundreds of processes nobody looks at) — 0 until enriched.
    var parentPID: Int32 = 0
    var threads: Int = 0
    var uid: uid_t = 0
    // Per-process network — merged from `nettop`, only while the Network tab is open.
    var netInBytesPerSec: Double = 0
    var netOutBytesPerSec: Double = 0
    var netInBytesTotal: UInt64 = 0
    var netOutBytesTotal: UInt64 = 0
    var netInPacketsTotal: UInt64 = 0
    var netOutPacketsTotal: UInt64 = 0
    // Extra columns
    var wiredBytes: UInt64 = 0
    var pageins: UInt64 = 0
    var isTranslated = false             // running under Rosetta → "Intel" vs "Apple"
    var preventingSleep = false          // holds a power assertion
    /// False for processes owned by root or another user: the kernel refuses proc_pid_rusage and
    /// proc_pidinfo(TASKINFO) to unprivileged callers, so CPU/memory/threads are simply unknowable
    /// for them (Activity Monitor reads them through a private Apple entitlement). They are still
    /// listed — with name, pid, parent and owner — and their metric cells render as "—".
    var metricsAvailable = true
    var id: Int32 { pid }
    var diskTotalBytesPerSec: Double { diskReadBytesPerSec + diskWriteBytesPerSec }
    var netTotalBytesPerSec: Double { netInBytesPerSec + netOutBytesPerSec }
}

/// Extra per-process statistics for the inspector, fetched on demand for one pid (proc_taskinfo).
struct ProcStat: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// Everything the process-inspector window shows about one process. Gathered on demand.
struct ProcessDetails: Equatable {
    let pid: Int32
    let name: String
    let executablePath: String     // readable even for root processes (proc_pidpath)
    let parentPID: Int32
    let parentName: String
    let userName: String
    let processGroup: Int32
    let cpuPercent: Double
    let residentBytes: UInt64
    let virtualBytes: UInt64
    let footprintBytes: UInt64
    let wiredBytes: UInt64
    /// False for processes we may not measure (root / other users) — their metric rows read "—".
    let metricsAvailable: Bool
    let stats: [ProcStat]
    let openFiles: [String]
    /// The kernel refuses the descriptor list for processes we do not own.
    let openFilesAvailable: Bool
}

/// Per-second rate between two cumulative counter readings, or 0 when the counter went BACKWARDS.
///
/// Counters here are not monotonic: `if_data` uses 32-bit fields that wrap every 4 GiB, and both the
/// interface set (VPN tunnels, USB Ethernet) and the disk-driver set (ejecting a DMG or USB volume)
/// change at runtime, which drops the summed total. Wrapping subtraction would turn that into ~1.8e19
/// and the formatters' Int64()/Int() conversions would TRAP — an outright crash. Report 0 instead and
/// let the next sample resume from the new baseline.
func counterRate(_ current: UInt64, _ previous: UInt64, _ dt: TimeInterval) -> Double {
    guard dt > 0, current >= previous else { return 0 }
    return Double(current - previous) / dt
}

/// One process's network counters from `nettop`, plus the byte rates we derive between samples.
struct NetPerProcess {
    var inBytes: UInt64
    var outBytes: UInt64
    var inPackets: UInt64
    var outPackets: UInt64
    var inRate: Double
    var outRate: Double
}

/// Sort a process list by a column and direction. Shared by the background sampler (each sample)
/// and the service (instant re-sort when a header is clicked, without waiting for the next sample).
func sortProcessSamples(_ samples: inout [ProcessSample],
                        by column: SystemMonitorService.ProcessColumn, descending desc: Bool) {
    switch column {
    case .name:
        samples.sort {
            let r = $0.name.localizedCaseInsensitiveCompare($1.name)
            return desc ? r == .orderedDescending : r == .orderedAscending
        }
    default:
        // Every other column sorts on a Double key, so one comparator covers them all.
        let key = numericSortKey(for: column)
        samples.sort { desc ? key($0) > key($1) : key($0) < key($1) }
    }
}

/// Numeric sort key per column — one place so adding a column cannot forget its sort.
private func numericSortKey(for column: SystemMonitorService.ProcessColumn) -> (ProcessSample) -> Double {
    switch column {
    case .name:            return { _ in 0 }   // handled by the string comparator above
    case .pid:             return { Double($0.pid) }
    case .parentPID:       return { Double($0.parentPID) }
    case .user:            return { Double($0.uid) }
    case .kind:            return { $0.isTranslated ? 1 : 0 }
    case .cpu:             return { $0.cpuPercent }
    case .cpuTime:         return { $0.cpuTimeSeconds }
    case .threads:         return { Double($0.threads) }
    case .idleWakeups:     return { $0.idleWakeupsPerSec }
    case .energy:          return { $0.energyImpact }
    case .preventingSleep: return { $0.preventingSleep ? 1 : 0 }
    case .memory:          return { Double($0.memBytes) }
    case .realMemory:      return { Double($0.residentBytes) }
    case .wired:           return { Double($0.wiredBytes) }
    case .pageins:         return { Double($0.pageins) }
    case .diskRead:        return { $0.diskReadBytesPerSec }
    case .diskWrite:       return { $0.diskWriteBytesPerSec }
    case .bytesRead:       return { Double($0.diskReadTotal) }
    case .bytesWritten:    return { Double($0.diskWriteTotal) }
    case .netIn:           return { $0.netInBytesPerSec }
    case .netOut:          return { $0.netOutBytesPerSec }
    case .sentBytes:       return { Double($0.netOutBytesTotal) }
    case .rcvdBytes:       return { Double($0.netInBytesTotal) }
    case .sentPackets:     return { Double($0.netOutPacketsTotal) }
    case .rcvdPackets:     return { Double($0.netInPacketsTotal) }
    }
}

/// Does the actual machine sampling. Lives OFF the main thread: every method here is called only
/// from the service's serial sampling queue, so its per-sample delta state needs no locking. CPU,
/// network, disk I/O and per-process CPU/disk are computed from deltas between consecutive samples,
/// so the first sample after creation reports 0 for those and real values from the second on.
/// Marked @unchecked Sendable: the invariant "touched only on one serial queue" is enforced by the
/// service, not the type system.
final class SystemSampler: @unchecked Sendable {
    // Per-sample deltas need the previous reading.
    private var prevCPUTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var prevNet: (inB: UInt64, outB: UInt64, inP: UInt64, outP: UInt64, time: TimeInterval)?
    private var prevDisk: (read: UInt64, write: UInt64, reads: UInt64, writes: UInt64, time: TimeInterval)?
    private var prevProcCPU: [Int32: UInt64] = [:]     // pid -> cumulative cpu ns
    private var prevProcDiskR: [Int32: UInt64] = [:]   // pid -> cumulative disk bytes read
    private var prevProcDiskW: [Int32: UInt64] = [:]   // pid -> cumulative disk bytes written
    private var prevProcWakeups: [Int32: UInt64] = [:] // pid -> cumulative idle wake-ups
    private var prevProcTime: TimeInterval?

    // Process names change almost never; cache them by pid instead of a proc_name() syscall per
    // process per tick. Pruned to live pids each sample so a reused pid gets a fresh lookup.
    private var nameCache: [Int32: String] = [:]
    // uid/ppid never change for a live pid — cache them too (pruned with the name cache).
    private var ownerCache: [Int32: (uid: uid_t, ppid: Int32)] = [:]
    /// How many rows to enrich with thread counts (one extra syscall each). Set from the user's row
    /// limit so we never pay for rows that are not displayed.
    var enrichLimit = 80

    // Per-process network via `nettop` — cumulative bytes per pid from the previous run, for deltas.
    // Only populated while the Network tab is open (spawning nettop costs a subprocess per tick).
    private var prevNettop: [Int32: NetPerProcess] = [:]
    private var prevNettopTime: TimeInterval?
    // P_TRANSLATED never changes for a live pid.
    private var translatedCache: [Int32: Bool] = [:]

    // proc_pid_rusage reports CPU time in mach ticks, not nanoseconds. On Apple Silicon a tick is
    // ~41.67 ns (timebase 125/3); on Intel it is 1 ns (1/1). Convert with the machine's timebase,
    // otherwise per-process CPU% comes out ~41x too low next to Activity Monitor.
    private var timebase = mach_timebase_info_data_t()

    init() { mach_timebase_info(&timebase) }

    /// Produce one full snapshot. Call only on the sampling queue. `searchQuery` (lowercased) and
    /// `selectedPID` let us enrich only the rows the UI will actually show. `perProcessNet` runs
    /// `nettop` for per-process throughput — only true while the Network tab is open.
    func sample(sortColumn: SystemMonitorService.ProcessColumn, sortDescending: Bool,
                searchQuery: String, selectedPID: Int32?, perProcessNet: Bool,
                powerMetrics: Bool, filter: SystemMonitorService.ProcessFilter) -> SystemSnapshot {
        var s = SystemSnapshot()
        sampleCPU(into: &s)
        sampleMemory(into: &s)
        sampleDisks(into: &s)
        sampleDiskIO(into: &s)
        sampleNetwork(into: &s)
        sampleBattery(into: &s)
        sampleGPU(into: &s)
        s.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        if powerMetrics { samplePower(into: &s) }
        let netRates = perProcessNet ? sampleNettop() : nil
        if !perProcessNet { prevNettop.removeAll(); prevNettopTime = nil }
        sampleProcesses(into: &s, sortColumn: sortColumn, sortDescending: sortDescending,
                        searchQuery: searchQuery, selectedPID: selectedPID, netRates: netRates,
                        filter: filter)
        return s
    }

    /// Per-process network throughput via `nettop -P -x -l 1`. Returns per-pid byte rates, computed
    /// as deltas of cumulative counters between consecutive runs (like our other counters).
    private func sampleNettop() -> [Int32: NetPerProcess] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-x", "-J", "bytes_in,bytes_out,packets_in,packets_out", "-l", "1"]
        let out = Pipe()
        p.standardOutput = out
        // Discard stderr to /dev/null rather than into a Pipe nobody reads: an unread pipe fills at
        // ~64 KiB and then BLOCKS the child forever, which would wedge this serial queue for good.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        // `nettop -x` prints whitespace-aligned columns, but it emits them in ITS OWN order (not the
        // order we passed to -J), so read the header to learn where each metric sits. The header is
        // "time  packets_in  bytes_in  packets_out  bytes_out"; data rows insert "name.pid" after
        // the timestamp, so a data row has exactly one extra leading token.
        let lines = text.split(separator: "\n")
        var order: [String] = []
        for line in lines {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if toks.first == "time" { order = Array(toks.dropFirst()); break }
        }
        guard !order.isEmpty else { return [:] }
        let idxIn = order.firstIndex(of: "bytes_in")
        let idxOut = order.firstIndex(of: "bytes_out")
        let idxPIn = order.firstIndex(of: "packets_in")
        let idxPOut = order.firstIndex(of: "packets_out")

        var cur: [Int32: NetPerProcess] = [:]
        for line in lines {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Data row = timestamp + name.pid + one value per header column. The name may contain
            // spaces ("Google Chrome"), so index the metrics from the END, where they are fixed.
            guard toks.count >= order.count + 2 else { continue }
            let metrics = Array(toks.suffix(order.count))
            let nameTok = toks[toks.count - order.count - 1]     // "…name.pid"
            guard let dot = nameTok.lastIndex(of: "."),
                  let pid = Int32(nameTok[nameTok.index(after: dot)...]) else { continue }
            func val(_ i: Int?) -> UInt64 { i.flatMap { UInt64(metrics[$0]) } ?? 0 }
            cur[pid] = NetPerProcess(inBytes: val(idxIn), outBytes: val(idxOut),
                                     inPackets: val(idxPIn), outPackets: val(idxPOut),
                                     inRate: 0, outRate: 0)
        }

        let now = Date().timeIntervalSinceReferenceDate
        let dt = prevNettopTime.map { now - $0 } ?? 0
        if dt > 0 {
            for (pid, v) in cur {
                guard let prev = prevNettop[pid] else { continue }
                cur[pid]?.inRate = v.inBytes >= prev.inBytes ? Double(v.inBytes - prev.inBytes) / dt : 0
                cur[pid]?.outRate = v.outBytes >= prev.outBytes ? Double(v.outBytes - prev.outBytes) / dt : 0
            }
        }
        prevNettop = cur
        prevNettopTime = now
        return cur
    }

    /// Power assertions by process — which pids are keeping the machine awake (IOKit, no privilege).
    private func sleepPreventingPIDs() -> Set<Int32> {
        var result = Set<Int32>()
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let raw = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return result }
        // The assertion-type constants are C string macros, not exposed to Swift — use their values.
        let sleepBlockers: Set<String> = ["PreventUserIdleSystemSleep",
                                          "PreventUserIdleDisplaySleep",
                                          "PreventSystemSleep",
                                          "NoIdleSleepAssertion",
                                          "NoDisplaySleepAssertion"]
        for (pidNum, assertions) in raw {
            let keeps = assertions.contains { a in
                guard let type = a["AssertType"] as? String else { return false }
                return sleepBlockers.contains(type)
            }
            if keeps { result.insert(pidNum.int32Value) }
        }
        return result
    }

    /// Is the process running translated under Rosetta ("Intel" vs "Apple" in the Kind column)?
    /// From kinfo_proc's P_TRANSLATED flag; cached because it never changes for a live pid.
    private func cachedTranslated(_ pid: Int32) -> Bool {
        if let t = translatedCache[pid] { return t }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var translated = false
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 {
            translated = (info.kp_proc.p_flag & P_TRANSLATED) != 0
        }
        translatedCache[pid] = translated
        return translated
    }

    // MARK: - CPU (host_processor_info per-core tick deltas)

    private func sampleCPU(into s: inout SystemSnapshot) {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let infoArray else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let n = Int(cpuCount)
        var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        current.reserveCapacity(n)
        infoArray.withMemoryRebound(to: UInt32.self, capacity: n * Int(CPU_STATE_MAX)) { ptr in
            for i in 0..<n {
                let base = i * Int(CPU_STATE_MAX)
                current.append((user: ptr[base + Int(CPU_STATE_USER)],
                                system: ptr[base + Int(CPU_STATE_SYSTEM)],
                                idle: ptr[base + Int(CPU_STATE_IDLE)],
                                nice: ptr[base + Int(CPU_STATE_NICE)]))
            }
        }

        guard prevCPUTicks.count == current.count else {
            prevCPUTicks = current
            s.cpuPerCore = Array(repeating: 0, count: n)
            return
        }

        var perCore: [Double] = []
        var sumBusy = 0.0, sumTotal = 0.0, sumUser = 0.0, sumSys = 0.0, sumIdle = 0.0
        for i in 0..<n {
            let du = Double(current[i].user &- prevCPUTicks[i].user)
            let ds = Double(current[i].system &- prevCPUTicks[i].system)
            let di = Double(current[i].idle &- prevCPUTicks[i].idle)
            let dn = Double(current[i].nice &- prevCPUTicks[i].nice)
            let total = du + ds + di + dn
            let busy = du + ds + dn
            perCore.append(total > 0 ? busy / total * 100 : 0)
            sumBusy += busy; sumTotal += total; sumUser += du + dn; sumSys += ds; sumIdle += di
        }
        prevCPUTicks = current
        s.cpuPerCore = perCore
        s.cpuTotal = sumTotal > 0 ? sumBusy / sumTotal * 100 : 0
        s.cpuUser = sumTotal > 0 ? sumUser / sumTotal * 100 : 0
        s.cpuSystem = sumTotal > 0 ? sumSys / sumTotal * 100 : 0
        s.cpuIdle = sumTotal > 0 ? sumIdle / sumTotal * 100 : 100
    }

    // MARK: - Memory (host_statistics64 + sysctl)

    private func sampleMemory(into s: inout SystemSnapshot) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        s.memTotalBytes = total

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let cached = UInt64(stats.external_page_count) * page
        s.memWiredBytes = wired
        s.memCompressedBytes = compressed
        s.memAppBytes = active + inactive
        s.memCachedBytes = cached
        // "Used" the way Activity Monitor shows it: app memory + wired + compressed.
        s.memUsedBytes = active + inactive + wired + compressed
        s.memPressure = total > 0 ? min(1, Double(wired + compressed + active) / Double(total)) : 0

        // Real memory-pressure signal the kernel exposes (same one Activity Monitor's coloured graph
        // uses): 1 = normal, 2 = warning, 4 = critical. Drives the gauge colour honestly.
        var level: Int32 = 1
        var lsz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsz, nil, 0) == 0 {
            s.memPressureLevel = Int(level)
        }

        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &xswSize, nil, 0) == 0 {
            s.swapUsedBytes = xsw.xsu_used
            s.swapTotalBytes = xsw.xsu_total
        }
    }

    // MARK: - Disks (mounted local volumes)

    private func sampleDisks(into s: inout SystemSnapshot) {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
                                      .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]) else { return }
        var disks: [DiskUsage] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable == true, v.volumeIsLocal == true,
                  let total = v.volumeTotalCapacity, total > 0,
                  let avail = v.volumeAvailableCapacity else { continue }
            disks.append(DiskUsage(name: v.volumeName ?? url.lastPathComponent,
                                   freeBytes: UInt64(max(0, avail)),
                                   totalBytes: UInt64(total)))
        }
        s.disks = disks
    }

    // MARK: - Disk I/O (IOBlockStorageDriver statistics deltas)

    private func sampleDiskIO(into s: inout SystemSnapshot) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                            IOServiceMatching("IOBlockStorageDriver"),
                                            &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0, totalWrite: UInt64 = 0
        var opsRead: UInt64 = 0, opsWrite: UInt64 = 0
        var drive = IOIteratorNext(iterator)
        while drive != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let statistics = dict["Statistics"] as? [String: Any] {
                totalRead  += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                totalWrite += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                opsRead    += (statistics["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
                opsWrite   += (statistics["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(drive)
            drive = IOIteratorNext(iterator)
        }

        let now = Date().timeIntervalSinceReferenceDate
        s.diskReadBytesTotal = totalRead
        s.diskWriteBytesTotal = totalWrite
        if let prev = prevDisk, now > prev.time {
            let dt = now - prev.time
            s.diskReadBytesPerSec  = counterRate(totalRead,  prev.read,   dt)
            s.diskWriteBytesPerSec = counterRate(totalWrite, prev.write,  dt)
            s.diskReadsPerSec      = counterRate(opsRead,    prev.reads,  dt)
            s.diskWritesPerSec     = counterRate(opsWrite,   prev.writes, dt)
        }
        prevDisk = (totalRead, totalWrite, opsRead, opsWrite, now)
    }

    // MARK: - Network (getifaddrs byte-counter deltas)

    private func sampleNetwork(into s: inout SystemSnapshot) {
        var inTotal: UInt64 = 0, outTotal: UInt64 = 0
        var inPkts: UInt64 = 0, outPkts: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: cur.pointee.ifa_name)
                if !name.hasPrefix("lo"), let data = cur.pointee.ifa_data {
                    let net = data.assumingMemoryBound(to: if_data.self).pointee
                    inTotal += UInt64(net.ifi_ibytes)
                    outTotal += UInt64(net.ifi_obytes)
                    inPkts += UInt64(net.ifi_ipackets)
                    outPkts += UInt64(net.ifi_opackets)
                }
            }
            ptr = cur.pointee.ifa_next
        }
        let now = Date().timeIntervalSinceReferenceDate
        s.netInBytesTotal = inTotal
        s.netOutBytesTotal = outTotal
        s.netInPacketsTotal = inPkts
        s.netOutPacketsTotal = outPkts
        if let prev = prevNet, now > prev.time {
            let dt = now - prev.time
            s.netInBytesPerSec = counterRate(inTotal, prev.inB, dt)
            s.netOutBytesPerSec = counterRate(outTotal, prev.outB, dt)
            s.netInPacketsPerSec = counterRate(inPkts, prev.inP, dt)
            s.netOutPacketsPerSec = counterRate(outPkts, prev.outP, dt)
        }
        prevNet = (inTotal, outTotal, inPkts, outPkts, now)
    }

    // MARK: - Battery (IOKit power sources)

    private func sampleBattery(into s: inout SystemSnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        else { s.battery = nil; return }

        let cur = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
        let mx  = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
        let state = desc[kIOPSPowerSourceStateKey] as? String
        let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        let plugged = state == kIOPSACPowerValue
        let toEmpty = (desc[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue ?? -1
        let toFull = (desc[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue ?? -1
        let remaining = charging ? toFull : toEmpty
        s.battery = BatteryInfo(percent: mx > 0 ? cur / mx * 100 : 0,
                                isCharging: charging, isPluggedIn: plugged,
                                minutesRemaining: remaining)
    }

    // MARK: - GPU (IOAccelerator PerformanceStatistics — no privilege)

    private func sampleGPU(into s: inout SystemSnapshot) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var entry = IOIteratorNext(it)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                if let perf = dict["PerformanceStatistics"] as? [String: Any] {
                    if let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                        s.gpuUtilization = max(s.gpuUtilization, util)
                    }
                    if let mem = (perf["In use system memory"] as? NSNumber)?.uint64Value { s.gpuInUseMemBytes = mem }
                    if let alloc = (perf["Alloc system memory"] as? NSNumber)?.uint64Value { s.gpuAllocMemBytes = alloc }
                }
                if let cores = (dict["gpu-core-count"] as? NSNumber)?.intValue { s.gpuCoreCount = cores }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(it)
        }
    }

    // MARK: - Power in watts (powermetrics — needs root; strictly opt-in)

    /// Read CPU/GPU power via `sudo -n powermetrics`. `-n` means "never prompt": if the user has not
    /// granted passwordless rights this fails immediately rather than hanging on a password prompt.
    /// We never ask for a password ourselves — the user enables this deliberately.
    private func samplePower(into s: inout SystemSnapshot) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/powermetrics", "--samplers", "cpu_power,gpu_power",
                       "-i", "200", "-n", "1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // see sampleNettop: an unread pipe deadlocks
        do { try p.run() } catch { s.powerAvailable = false; return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            s.powerAvailable = false; return
        }
        // Lines look like "CPU Power: 1234 mW" / "GPU Power: 567 mW" / "Combined Power (CPU + GPU + ANE): ..."
        func watts(_ label: String) -> Double? {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(label) }),
                  let mw = line.split(separator: " ").compactMap({ Double($0) }).last else { return nil }
            return mw / 1000
        }
        s.powerCPUWatts = watts("CPU Power") ?? 0
        s.powerGPUWatts = watts("GPU Power") ?? 0
        s.powerTotalWatts = watts("Combined Power") ?? (s.powerCPUWatts + s.powerGPUWatts)
        s.powerAvailable = true
    }

    // MARK: - Processes (libproc: memory, CPU%, disk I/O, threads, energy)

    private func sampleProcesses(into s: inout SystemSnapshot,
                                 sortColumn: SystemMonitorService.ProcessColumn, sortDescending: Bool,
                                 searchQuery: String, selectedPID: Int32?,
                                 netRates: [Int32: NetPerProcess]?,
                                 filter: SystemMonitorService.ProcessFilter) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(count) + 16)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return }
        pids = Array(pids.prefix(Int(filled)))

        let now = Date().timeIntervalSinceReferenceDate
        let dt = prevProcTime.map { now - $0 } ?? 0
        var nextCPU: [Int32: UInt64] = [:]
        var nextDiskR: [Int32: UInt64] = [:]
        var nextDiskW: [Int32: UInt64] = [:]
        var nextWk: [Int32: UInt64] = [:]
        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)
        var live = Set<Int32>(); live.reserveCapacity(pids.count)

        let numer = UInt64(timebase.numer == 0 ? 1 : timebase.numer)
        let denom = UInt64(timebase.denom == 0 ? 1 : timebase.denom)
        let awakePIDs = sleepPreventingPIDs()   // one IOKit call for the whole list

        // Cheap pass over ALL processes: rusage (cpu/mem/disk/wakeups) + a cached name. No per-process
        // proc_pidinfo here — that (threads/owner/parent) is done below only for the visible rows.
        for pid in pids where pid > 0 {
            var usage = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard ok == 0 else {
                // Not ours: rusage is denied. Still list the process from proc_bsdshortinfo, which
                // IS permitted and carries the name, owner and parent — otherwise ~40% of the
                // machine (every root daemon) would be invisible and the "System processes" filter
                // would always come up empty. Metrics stay unknown.
                if let info = deniedProcess(pid) {
                    live.insert(pid)
                    samples.append(info)
                }
                continue
            }
            live.insert(pid)
            let cpuNS = usage.ri_user_time + usage.ri_system_time
            let diskR = usage.ri_diskio_bytesread
            let diskW = usage.ri_diskio_byteswritten
            let wakeups = usage.ri_pkg_idle_wkups
            nextCPU[pid] = cpuNS
            nextDiskR[pid] = diskR
            nextDiskW[pid] = diskW
            nextWk[pid] = wakeups
            // Cumulative CPU time (mach ticks → seconds) — Activity Monitor's "CPU Time" column.
            let cpuTimeSeconds = Double(cpuNS) * Double(numer) / Double(denom) / 1_000_000_000

            var cpuPercent = 0.0
            if dt > 0, let prev = prevProcCPU[pid], cpuNS >= prev {
                let deltaNS = (cpuNS - prev) * numer / denom   // mach ticks → nanoseconds
                cpuPercent = Double(deltaNS) / (dt * 1_000_000_000) * 100
            }
            var readRate = 0.0, writeRate = 0.0, wkRate = 0.0
            if dt > 0 {
                if let p = prevProcDiskR[pid], diskR >= p { readRate = Double(diskR - p) / dt }
                if let p = prevProcDiskW[pid], diskW >= p { writeRate = Double(diskW - p) / dt }
                if let p = prevProcWakeups[pid], wakeups >= p { wkRate = Double(wakeups - p) / dt }
            }
            // Approximate energy impact: CPU dominates, idle wake-ups add a small penalty.
            let energy = cpuPercent + wkRate * 0.02

            var sample = ProcessSample(pid: pid, name: cachedName(pid),
                                       cpuPercent: cpuPercent, cpuTimeSeconds: cpuTimeSeconds,
                                       memBytes: usage.ri_phys_footprint,
                                       residentBytes: usage.ri_resident_size,
                                       diskReadBytesPerSec: readRate,
                                       diskWriteBytesPerSec: writeRate,
                                       diskReadTotal: diskR, diskWriteTotal: diskW,
                                       idleWakeupsPerSec: wkRate, energyImpact: energy)
            // uid/ppid come from a cached lookup — the owner of a pid never changes, so this is one
            // proc_pidinfo per NEW process, not per process per tick. Needed by the My/System filters.
            let owner = cachedOwner(pid)
            sample.uid = owner.uid
            sample.parentPID = owner.ppid
            sample.wiredBytes = usage.ri_wired_size
            sample.pageins = usage.ri_pageins
            sample.isTranslated = cachedTranslated(pid)
            sample.preventingSleep = awakePIDs.contains(pid)
            samples.append(sample)
        }
        prevProcCPU = nextCPU
        prevProcDiskR = nextDiskR
        prevProcDiskW = nextDiskW
        prevProcWakeups = nextWk
        prevProcTime = now
        nameCache = nameCache.filter { live.contains($0.key) }
        ownerCache = ownerCache.filter { live.contains($0.key) }
        translatedCache = translatedCache.filter { live.contains($0.key) }

        // Merge per-process network (from nettop) before sorting so the net columns sort correctly.
        if let netRates {
            for i in samples.indices {
                guard let r = netRates[samples[i].pid] else { continue }
                samples[i].netInBytesPerSec = r.inRate
                samples[i].netOutBytesPerSec = r.outRate
                samples[i].netInBytesTotal = r.inBytes
                samples[i].netOutBytesTotal = r.outBytes
                samples[i].netInPacketsTotal = r.inPackets
                samples[i].netOutPacketsTotal = r.outPackets
            }
        }

        // Sorting BY threads needs every row's thread count up front — enriching only the top rows
        // after the sort would mean sorting a column that is still all zeros (an arbitrary order).
        if sortColumn == .threads {
            for i in samples.indices { samples[i].threads = threadCount(samples[i].pid) }
        }

        sortProcessSamples(&samples, by: sortColumn, descending: sortDescending)

        // Enrich only the rows the UI will actually render. The view filters first and then takes
        // the top `displayLimit`, so we must apply the SAME filter here — otherwise, with a filter
        // active, the visible rows can all sit beyond the enrich window and show 0 threads forever.
        var indices: [Int] = []
        let me = getuid()
        func passesFilter(_ p: ProcessSample) -> Bool {
            switch filter {
            case .all:    return true
            case .mine:   return p.uid == me
            case .system: return p.uid == 0
            case .active: return p.cpuPercent > 0.1
            }
        }
        for (i, p) in samples.enumerated() {
            guard passesFilter(p) else { continue }
            if !searchQuery.isEmpty,
               !(p.name.lowercased().contains(searchQuery) || String(p.pid).contains(searchQuery)) { continue }
            indices.append(i)
            if indices.count >= enrichLimit { break }
        }
        if let sel = selectedPID, let i = samples.firstIndex(where: { $0.pid == sel }), !indices.contains(i) {
            indices.append(i)
        }
        if sortColumn != .threads {                      // already filled for every row above
            for i in indices {
                samples[i].threads = threadCount(samples[i].pid)   // uid/ppid come from the cache
            }
        }
        s.processes = samples
    }

    /// A process we may not measure (root / another user), described from proc_bsdshortinfo alone:
    /// name, owner and parent are readable; CPU, memory and threads are not.
    private func deniedProcess(_ pid: Int32) -> ProcessSample? {
        var bsd = proc_bsdshortinfo()
        let sz = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, sz) == sz else { return nil }
        // pbsi_comm is a fixed-size C char array (up to 16 chars of the executable name).
        let name = withUnsafePointer(to: &bsd.pbsi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
        }
        var s = ProcessSample(pid: pid, name: name.isEmpty ? "pid \(pid)" : name,
                              cpuPercent: 0, cpuTimeSeconds: 0, memBytes: 0, residentBytes: 0,
                              diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0,
                              diskReadTotal: 0, diskWriteTotal: 0,
                              idleWakeupsPerSec: 0, energyImpact: 0)
        s.uid = bsd.pbsi_uid
        s.parentPID = Int32(bitPattern: bsd.pbsi_ppid)
        s.metricsAvailable = false
        return s
    }

    private func cachedName(_ pid: Int32) -> String {
        if let n = nameCache[pid] { return n }
        let n = processName(pid)
        nameCache[pid] = n
        return n
    }

    /// Owner uid + parent pid, cached: neither changes over a process's life, so this costs one
    /// proc_pidinfo per newly-seen pid rather than one per process per tick.
    private func cachedOwner(_ pid: Int32) -> (uid: uid_t, ppid: Int32) {
        if let o = ownerCache[pid] { return o }
        var bsd = proc_bsdshortinfo()
        let bsz = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        var o: (uid: uid_t, ppid: Int32) = (0, 0)
        if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsz) == bsz {
            o = (bsd.pbsi_uid, Int32(bitPattern: bsd.pbsi_ppid))
        }
        ownerCache[pid] = o
        return o
    }

    /// Live thread count for a pid (changes over time, so not cacheable — unlike uid/ppid).
    private func threadCount(_ pid: Int32) -> Int {
        var tinfo = proc_taskinfo()
        let tsz = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &tinfo, tsz) == tsz else { return 0 }
        return Int(tinfo.pti_threadnum)
    }

    private func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 {
            let name = String(cString: buf)
            if !name.isEmpty { return name }
        }
        return "pid \(pid)"
    }
}

/// Drives the sampler on a timer and publishes the latest `SystemSnapshot` for the UI. The heavy
/// sampling runs on a background serial queue (`sampleQueue`); only the finished, immutable snapshot
/// crosses back to the main actor. This keeps the UI smooth and the cadence steady — sampling all
/// processes on the main thread was what made updates stutter next to Activity Monitor.
@MainActor
final class SystemMonitorService: ObservableObject {
    /// Active tab / column set — mirrors Activity Monitor's five tabs and drives the process sort.
    enum Tab: String, CaseIterable { case cpu, memory, energy, disk, network }
    /// Sortable process-table columns; which are shown depends on the active tab.
    /// Every column the process table can show — the same set Activity Monitor offers in its
    /// column menu (minus per-process GPU, which has no public source). `name` is always shown.
    enum ProcessColumn: String, CaseIterable, Codable {
        case name, pid, parentPID, user, kind
        case cpu, cpuTime, threads, idleWakeups, energy, preventingSleep
        case memory, realMemory, wired, pageins
        case diskRead, diskWrite, bytesRead, bytesWritten
        case netIn, netOut, sentBytes, rcvdBytes, sentPackets, rcvdPackets
    }

    @Published private(set) var snapshot = SystemSnapshot()
    @Published var tab: Tab = .cpu {
        didSet {
            guard tab != oldValue else { return }
            sortColumn = Self.defaultColumn(for: tab)
            sortDescending = Self.defaultDescending(for: sortColumn)
            resortSnapshot()   // instant; the next background sample refreshes the values
        }
    }
    /// Which processes to list — mirrors Activity Monitor's View menu.
    enum ProcessFilter: String, CaseIterable { case all, mine, system, active }

    @Published var searchText = ""
    @Published var selectedPID: Int32?
    @Published var processFilter: ProcessFilter = .all
    @Published var isRunning = false
    /// Opt-in: read real watts via powermetrics (needs passwordless sudo). Off by default — we never
    /// prompt for a password, and if the rights are missing we simply say so and switch back off.
    /// Deliberately @Published backed by UserDefaults rather than @AppStorage: @AppStorage only
    /// publishes from a View, so inside an ObservableObject the toggle would appear stuck.
    @Published var powerMetricsEnabled: Bool = UserDefaults.standard.bool(forKey: "monitor.powerMetricsEnabled") {
        didSet {
            UserDefaults.standard.set(powerMetricsEnabled, forKey: "monitor.powerMetricsEnabled")
            if powerMetricsEnabled { powerMetricsDenied = false }
        }
    }

    // Process-table sort: which column and direction. Changed by clicking a column header.
    @Published private(set) var sortColumn: ProcessColumn = .cpu
    @Published private(set) var sortDescending = true

    // Rolling history for the live graphs (most-recent last), one point per sample.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var netInHistory: [Double] = []
    @Published private(set) var netOutHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var memPressureHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var cpuUserHistory: [Double] = []
    @Published private(set) var cpuSystemHistory: [Double] = []
    /// Per-core rolling history: coreHistory[core] is that core's last `historyLength` samples.
    @Published private(set) var coreHistory: [[Double]] = []
    private let historyLength = 60

    /// Sampling period; changing it live re-arms the timer (Activity Monitor's "Update Frequency").
    @Published var updateInterval: TimeInterval {
        didSet { if isRunning, updateInterval != oldValue { armTimer() } }
    }

    private var sampler = SystemSampler()
    private let sampleQueue = DispatchQueue(label: "com.fcxl.monitor.sampler", qos: .utility)
    private var timer: Timer?
    /// A sample is in flight — the timer skips a beat instead of stacking work up.
    private var isSampling = false

    /// How many process rows to show. 0 = every process. Fewer rows means fewer thread-count
    /// syscalls and fewer views to build; the per-process CPU/memory pass over all pids is
    /// unavoidable either way, since sorting "biggest first" needs every process measured.
    @Published var rowLimit: Int = UserDefaults.standard.object(forKey: "monitor.rowLimit") as? Int ?? 50 {
        didSet { UserDefaults.standard.set(rowLimit, forKey: "monitor.rowLimit") }
    }
    static let rowLimitChoices = [50, 100, 200, 0]   // 0 = all
    /// powermetrics was tried and refused; shown in the UI instead of retrying every second.
    @Published private(set) var powerMetricsDenied = false

    init(interval: TimeInterval = 1.0) { self.updateInterval = interval }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Start from a clean sampler. Its delta state (previous CPU ticks, byte counters, per-process
        // CPU time) would otherwise survive a stop/start, and the first sample after reopening would
        // divide the whole closed interval by one tick — e.g. a 2 GB download while the monitor was
        // shut reported as an instantaneous 17 MB/s spike that also skews every graph's scale.
        sampler = SystemSampler()
        cpuHistory = []; netInHistory = []; netOutHistory = []
        diskReadHistory = []; diskWriteHistory = []; memPressureHistory = []
        gpuHistory = []; cpuUserHistory = []; cpuSystemHistory = []; coreHistory = []
        isSampling = false
        tick()        // prime (deltas are 0 on the first sample)
        armTimer()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        isRunning = false
    }

    private func armTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Kick off one background sample; publish the finished snapshot back on the main actor.
    private func tick() {
        // Never queue a second sample while one is still running. A sample can outlast the timer
        // interval (nettop and powermetrics are subprocesses; an unresponsive network mount stalls
        // the volume scan), and without this guard every tick would pile another block — and another
        // subprocess — onto the serial queue, making the backlog worse the busier the machine gets.
        guard !isSampling else { return }
        isSampling = true

        let col = sortColumn
        let desc = sortDescending
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let selected = selectedPID
        let currentFilter = processFilter
        let perProcessNet = needsPerProcessNetwork   // nettop only when net columns are on screen
        let power = powerMetricsEnabled && tab == .energy   // powermetrics: opt-in, Energy tab only
        // Only enrich what will be displayed (plus a little slack for filtering).
        sampler.enrichLimit = rowLimit == 0 ? 400 : min(400, rowLimit + 20)
        let sampler = self.sampler
        sampleQueue.async {
            let snap = sampler.sample(sortColumn: col, sortDescending: desc,
                                      searchQuery: query, selectedPID: selected,
                                      perProcessNet: perProcessNet, powerMetrics: power,
                                      filter: currentFilter)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSampling = false
                guard self.isRunning else { return }
                self.snapshot = snap
                self.appendHistory(from: snap)
                // powermetrics failed (no passwordless sudo): turn the option back off instead of
                // re-spawning sudo — and logging an auth failure — once every second, forever.
                if power && !snap.powerAvailable {
                    self.powerMetricsEnabled = false
                    self.powerMetricsDenied = true
                }
            }
        }
    }

    /// True when any per-process network column is visible on the current tab — only then is it
    /// worth spawning `nettop`. Tied to the columns, not the tab, because the column chooser lets
    /// net columns be added to any tab (where they would otherwise read zero forever).
    private var needsPerProcessNetwork: Bool {
        let netCols: Set<ProcessColumn> = [.netIn, .netOut, .sentBytes, .rcvdBytes,
                                           .sentPackets, .rcvdPackets]
        return !netCols.isDisjoint(with: visibleColumns)
    }

    private func appendHistory(from s: SystemSnapshot) {
        func push(_ arr: inout [Double], _ v: Double) {
            arr.append(v)
            if arr.count > historyLength { arr.removeFirst(arr.count - historyLength) }
        }
        push(&cpuHistory, s.cpuTotal)
        push(&netInHistory, s.netInBytesPerSec)
        push(&netOutHistory, s.netOutBytesPerSec)
        push(&diskReadHistory, s.diskReadBytesPerSec)
        push(&diskWriteHistory, s.diskWriteBytesPerSec)
        push(&memPressureHistory, s.memPressure * 100)
        push(&gpuHistory, s.gpuUtilization)
        push(&cpuUserHistory, s.cpuUser)
        push(&cpuSystemHistory, s.cpuSystem)
        if coreHistory.count != s.cpuPerCore.count {
            coreHistory = s.cpuPerCore.map { [$0] }
        } else {
            for i in s.cpuPerCore.indices { push(&coreHistory[i], s.cpuPerCore[i]) }
        }
    }

    /// Click a column header: toggle direction if already sorted by it, otherwise switch to it.
    func sort(by column: ProcessColumn) {
        if sortColumn == column {
            sortDescending.toggle()
        } else {
            sortColumn = column
            sortDescending = Self.defaultDescending(for: column)
        }
        resortSnapshot()
    }

    /// Re-sort the currently displayed processes in place for instant feedback (no re-sampling).
    private func resortSnapshot() {
        var procs = snapshot.processes
        sortProcessSamples(&procs, by: sortColumn, descending: sortDescending)
        snapshot.processes = procs
    }

    private static func defaultColumn(for tab: Tab) -> ProcessColumn {
        switch tab {
        case .cpu:     return .cpu
        case .memory:  return .memory
        case .energy:  return .energy
        case .disk:    return .diskRead
        case .network: return .netIn
        }
    }
    // Numeric columns default to descending (biggest first); the name column to A→Z.
    private static func defaultDescending(for column: ProcessColumn) -> Bool { column != .name }

    // MARK: - Visible columns (per tab, persisted — Activity Monitor's column menu)

    /// Columns shown by default on each tab, matching Activity Monitor's out-of-the-box layout.
    static func defaultColumns(for tab: Tab) -> [ProcessColumn] {
        switch tab {
        case .cpu:     return [.cpu, .cpuTime, .threads, .idleWakeups, .pid, .user]
        case .memory:  return [.memory, .realMemory, .threads, .pid, .user]
        case .energy:  return [.energy, .cpu, .preventingSleep, .pid, .user]
        case .disk:    return [.bytesRead, .bytesWritten, .diskRead, .diskWrite, .pid]
        case .network: return [.rcvdBytes, .sentBytes, .netIn, .netOut, .pid]
        }
    }

    /// Visible columns for the active tab, persisted per tab in UserDefaults.
    var visibleColumns: [ProcessColumn] {
        get {
            let key = Self.columnsKey(for: tab)
            guard let raw = UserDefaults.standard.string(forKey: key) else {
                return Self.defaultColumns(for: tab)
            }
            let cols = raw.split(separator: ",").compactMap { ProcessColumn(rawValue: String($0)) }
            return cols.isEmpty ? Self.defaultColumns(for: tab) : cols
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue).joined(separator: ","),
                                      forKey: Self.columnsKey(for: tab))
            objectWillChange.send()
        }
    }

    private static func columnsKey(for tab: Tab) -> String { "monitor.columns.\(tab.rawValue)" }

    /// Toggle one column on the current tab, keeping the canonical column order.
    func toggleColumn(_ column: ProcessColumn) {
        var cols = visibleColumns
        if let i = cols.firstIndex(of: column) {
            guard cols.count > 1 else { return }   // never hide the last metric column
            cols.remove(at: i)
            if sortColumn == column { sortColumn = cols[0]; resortSnapshot() }
        } else {
            cols.append(column)
            cols.sort { a, b in
                let all = ProcessColumn.allCases
                return (all.firstIndex(of: a) ?? 0) < (all.firstIndex(of: b) ?? 0)
            }
        }
        visibleColumns = cols
    }

    /// Restore this tab's default column set.
    func resetColumns() {
        UserDefaults.standard.removeObject(forKey: Self.columnsKey(for: tab))
        objectWillChange.send()
    }

    /// User name for a uid, for the process inspector. Cheap; called on demand from the UI.
    func userName(_ uid: uid_t) -> String {
        if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
            return String(cString: name)
        }
        return "\(uid)"
    }

    /// Extra kernel statistics for the inspector's Statistics section — one proc_pidinfo for the
    /// selected pid, on demand. Mirrors Activity Monitor's Inspect › Statistics tab.
    func processStatistics(pid: Int32) -> [ProcStat] {
        var ti = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sz) == sz else { return [] }
        func num(_ v: Int64) -> String {
            NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
        }
        return [
            ProcStat(label: L("monitor.stat.csw"), value: num(Int64(ti.pti_csw))),
            ProcStat(label: L("monitor.stat.faults"), value: num(Int64(ti.pti_faults))),
            ProcStat(label: L("monitor.stat.pageins"), value: num(Int64(ti.pti_pageins))),
            ProcStat(label: L("monitor.stat.cowFaults"), value: num(Int64(ti.pti_cow_faults))),
            ProcStat(label: L("monitor.stat.syscallsMach"), value: num(Int64(ti.pti_syscalls_mach))),
            ProcStat(label: L("monitor.stat.syscallsUnix"), value: num(Int64(ti.pti_syscalls_unix))),
            ProcStat(label: L("monitor.stat.messagesSent"), value: num(Int64(ti.pti_messages_sent))),
            ProcStat(label: L("monitor.stat.messagesReceived"), value: num(Int64(ti.pti_messages_received))),
        ]
    }

    /// Gather everything the inspector window shows for one process. Called on demand (on opening
    /// the window and once per second while it is up), never in the per-sample loop.
    func processDetails(pid: Int32) -> ProcessDetails? {
        let sample = snapshot.processes.first { $0.pid == pid }

        var pathBuf = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0
            ? String(cString: pathBuf) : ""

        var bsd = proc_bsdshortinfo()
        let bsz = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let haveBSD = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsz) == bsz
        guard haveBSD || sample != nil else { return nil }

        let ppid = haveBSD ? Int32(bitPattern: bsd.pbsi_ppid) : (sample?.parentPID ?? 0)
        let pgid = haveBSD ? Int32(bitPattern: bsd.pbsi_pgid) : 0
        let uid = haveBSD ? bsd.pbsi_uid : (sample?.uid ?? 0)

        var parentName = "—"
        if ppid > 0 {
            if let p = snapshot.processes.first(where: { $0.pid == ppid }) {
                parentName = "\(p.name) (\(ppid))"
            } else {
                var pb = [CChar](repeating: 0, count: 256)
                let n = proc_name(ppid, &pb, UInt32(pb.count)) > 0 ? String(cString: pb) : "pid \(ppid)"
                parentName = "\(n) (\(ppid))"
            }
        }

        var ti = proc_taskinfo()
        let tsz = Int32(MemoryLayout<proc_taskinfo>.size)
        let haveTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tsz) == tsz

        let (files, filesOK) = openFiles(pid: pid)

        return ProcessDetails(
            pid: pid,
            name: sample?.name ?? (path as NSString).lastPathComponent,
            executablePath: path,
            parentPID: ppid,
            parentName: parentName,
            userName: userName(uid),
            processGroup: pgid,
            cpuPercent: sample?.cpuPercent ?? 0,
            residentBytes: haveTask ? ti.pti_resident_size : (sample?.residentBytes ?? 0),
            virtualBytes: haveTask ? ti.pti_virtual_size : 0,
            footprintBytes: sample?.memBytes ?? 0,
            wiredBytes: sample?.wiredBytes ?? 0,
            metricsAvailable: sample?.metricsAvailable ?? haveTask,
            stats: processStatistics(pid: pid),
            openFiles: files,
            openFilesAvailable: filesOK)
    }

    /// Open files and sockets for a process, in the spirit of `lsof`. Only permitted for processes
    /// we own; for anything else the kernel refuses the descriptor list and we say so.
    private func openFiles(pid: Int32) -> ([String], Bool) {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return ([], false) }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard used > 0 else { return ([], false) }

        var out: [String] = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) {
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var vi = vnode_fdinfowithpath()
                let vsz = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, vsz) == vsz {
                    let p = withUnsafePointer(to: &vi.pvip.vip_path) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                    }
                    if !p.isEmpty { out.append(p) }
                }
            case PROX_FDTYPE_SOCKET:
                out.append("[\(L("monitor.inspector.socket"))]")
            case PROX_FDTYPE_PIPE:
                out.append("[\(L("monitor.inspector.pipe"))]")
            default:
                break
            }
        }
        return (out, true)
    }

    /// Run `/usr/bin/sample` on a process and return the path of the report it wrote, or nil.
    /// Sampling another user's process needs privileges we do not have; that simply fails.
    ///
    /// `nonisolated` on purpose: it touches no service state, and it BLOCKS for several seconds.
    /// As a main-actor method the call would hop back to the main thread — which is parked in the
    /// inspector's modal loop — and the sample would never start at all.
    nonisolated func sampleProcess(pid: Int32, seconds: Int = 3) -> URL? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-\(pid).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(pid)", "\(seconds)", "-f", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else { return nil }
        return out
    }

    /// Ask a process to quit (SIGTERM) or force-kill it (SIGKILL). Returns false if not permitted
    /// or refused. Refuses to signal ourselves (the row for this app is right there in the table and
    /// clicking ✕ on it would kill the file manager mid-operation), launchd, or a whole process
    /// group / every process (pid <= 0, which `kill` interprets as a broadcast).
    @discardableResult
    func terminate(pid: Int32, force: Bool) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}
