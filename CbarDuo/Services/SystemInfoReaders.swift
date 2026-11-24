import AppKit
import Darwin
import Foundation
import IOKit

// Readers for the popover's System tab. Each is a small, independent call
// into public kernel/IOKit interfaces; the System tab samples them every
// 2 seconds only while it is visible.

// MARK: - SMC temperatures

/// Minimal client for the System Management Controller, used to read
/// temperature and power sensors. Keys are enumerated once; values are read
/// per sample. One shared connection serves every sampler.
final class SMCTemperatureReader: @unchecked Sendable {
    /// Opened on first use; nil on Macs without an accessible SMC.
    static let shared = SMCTemperatureReader()

    /// Layout of the SMC user-client parameter block (80 bytes).
    struct Parameters {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PowerLimits { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0 }

        var key: UInt32 = 0
        var version = Version()
        var powerLimits = PowerLimits()
        var keyInfo = KeyInfo()
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readKey = 5
        case keyFromIndex = 8
        case keyInfo = 9
    }

    private struct SensorKey {
        let name: String
        let code: UInt32
        let size: UInt32
        let type: UInt32
    }

    private var connection: io_connect_t = 0
    private var cpuKeys: [SensorKey] = []
    private var gpuKeys: [SensorKey] = []
    private var batteryKeys: [SensorKey] = []
    private var namedKeys: [String: SensorKey?] = [:]
    private let lock = NSLock()

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        discoverKeys()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// CPU temperature, °C: the hottest die sensor. On Apple Silicon each
    /// core cluster reports several Tp…/Te… keys; the ones ending in "a" are
    /// the die readings, while the b/x/z variants run 10–25 °C hotter. Macs
    /// without such keys fall back to the hottest CPU sensor.
    func cpuTemperature() -> Double? {
        let dieKeys = cpuKeys.filter { $0.name.hasSuffix("a") }
        return hottest(dieKeys) ?? hottest(cpuKeys)
    }

    /// Hottest plausible reading among GPU sensors (Tg…), °C; nil when the Mac has none.
    func gpuTemperature() -> Double? { hottest(gpuKeys) }

    /// Hottest battery sensor (TB…), °C; nil on Macs without a battery.
    func batteryTemperature() -> Double? { hottest(batteryKeys) }

    /// A power sensor in watts, e.g. "PSTR" (system total) or "PDTR" (adapter
    /// input); nil when the Mac has no such key or reports an implausible value.
    func watts(_ name: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let key: SensorKey?
        if let cached = namedKeys[name] {
            key = cached
        } else {
            let code = Self.fourCC(name)
            key = info(for: code).flatMap { info in
                info.dataType == Self.fourCC("flt ") || info.dataType == Self.fourCC("sp78")
                    ? SensorKey(name: name, code: code, size: info.dataSize, type: info.dataType) : nil
            }
            namedKeys[name] = key
        }
        guard let key, let value = read(key), value > 0, value < 1000 else { return nil }
        return value
    }

    private func hottest(_ keys: [SensorKey]) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return keys.compactMap(read).filter(Self.isPlausible).max()
    }

    static func isPlausible(_ value: Double) -> Bool { value > 5 && value < 125 }


    private func discoverKeys() {
        guard let countKey = info(for: Self.fourCC("#KEY")),
              let countBytes = readBytes(code: Self.fourCC("#KEY"), size: countKey.dataSize),
              countBytes.count >= 4
        else { return }
        let count = countBytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let flt = Self.fourCC("flt "), sp78 = Self.fourCC("sp78")
        for index in 0..<min(count, 4096) {
            var input = Parameters()
            input.command = Command.keyFromIndex.rawValue
            input.data32 = index
            guard let output = call(&input) else { continue }
            let name = Self.string(output.key)
            guard name.hasPrefix("T"), let keyInfo = info(for: output.key),
                  keyInfo.dataType == flt || keyInfo.dataType == sp78 else { continue }
            let key = SensorKey(name: name, code: output.key, size: keyInfo.dataSize, type: keyInfo.dataType)
            if name.hasPrefix("Tp") || name.hasPrefix("Te") {
                cpuKeys.append(key)
            } else if name.hasPrefix("Tg") {
                gpuKeys.append(key)
            } else if name.hasPrefix("TB") {
                batteryKeys.append(key)
            }
        }
    }

    private func read(_ key: SensorKey) -> Double? {
        guard let bytes = readBytes(code: key.code, size: key.size) else { return nil }
        if key.type == Self.fourCC("flt "), bytes.count >= 4 {
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float32(bitPattern: bits))
        }
        if bytes.count >= 2 {
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        }
        return nil
    }

    private func info(for code: UInt32) -> Parameters.KeyInfo? {
        var input = Parameters()
        input.key = code
        input.command = Command.keyInfo.rawValue
        return call(&input)?.keyInfo
    }

    private func readBytes(code: UInt32, size: UInt32) -> [UInt8]? {
        var input = Parameters()
        input.key = code
        input.keyInfo.dataSize = size
        input.command = Command.readKey.rawValue
        guard var output = call(&input) else { return nil }
        return withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(min(size, 32)))) }
    }

    private func call(_ input: inout Parameters) -> Parameters? {
        var output = Parameters()
        var outputSize = MemoryLayout<Parameters>.stride
        let result = IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<Parameters>.stride, &output, &outputSize
        )
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }
}

// MARK: - CPU and GPU load

/// Whole-machine CPU load from successive HOST_CPU_LOAD_INFO samples.
struct CPULoadSampler {
    private var previous: host_cpu_load_info?

    mutating func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let previous else { return nil }
        func ticks(_ t: (UInt32, UInt32, UInt32, UInt32)) -> [Double] { [Double(t.0), Double(t.1), Double(t.2), Double(t.3)] }
        let now = ticks(info.cpu_ticks), before = ticks(previous.cpu_ticks)
        let delta = zip(now, before).map { $0 - $1 }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        // Order: user, system, idle, nice.
        return min(max((delta[0] + delta[1] + delta[3]) / total, 0), 1)
    }
}

enum GPULoadReader {
    /// "Device Utilization %" published by the graphics accelerator, 0…1.
    static func read() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let utilization = (stats["Device Utilization %"] as? NSNumber)?.intValue
            else { continue }
            best = max(best ?? 0, utilization)
        }
        return best.map { min(max(Double($0) / 100, 0), 1) }
    }
}

/// Per-app GPU share: each GPU client publishes the GPU time it has used
/// ("accumulatedGPUTime", nanoseconds), so the change between two samples
/// over the elapsed time is that client's share. Helper processes count
/// toward the app responsible for them, like Activity Monitor.
struct GPUProcessSampler {
    struct Usage: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        let percent: Double
        var id: pid_t { pid }
    }

    private var previous: (time: TimeInterval, perPid: [pid_t: Double])?

    /// nil on the first call (it only records a baseline) or after a long gap.
    mutating func sample() -> [Usage]? {
        let now = ProcessInfo.processInfo.systemUptime
        var creatorNames: [pid_t: String] = [:]
        let current = Self.gpuTimePerPid(names: &creatorNames)
        defer { previous = (now, current) }
        guard let previous, now > previous.time, now - previous.time < 30 else { return nil }
        let elapsedNanos = (now - previous.time) * 1_000_000_000

        var perOwner: [pid_t: Double] = [:]
        for (pid, total) in current {
            guard let before = previous.perPid[pid], total > before else { continue }
            perOwner[ResponsibleProcess.owner(of: pid), default: 0] += (total - before) / elapsedNanos * 100
        }
        return perOwner
            .filter { $0.value >= 0.05 }
            .map { owner, percent in
                Usage(pid: owner,
                      name: ResponsibleProcess.name(of: owner, fallback: creatorNames[owner]),
                      percent: min(percent, 100))
            }
            .sorted { $0.percent > $1.percent }
    }

    static func gpuTimePerPid() -> [pid_t: Double] {
        var names: [pid_t: String] = [:]
        return gpuTimePerPid(names: &names)
    }

    /// Also collects each client's process name from its creator string,
    /// which names system processes libproc will not.
    static func gpuTimePerPid(names: inout [pid_t: String]) -> [pid_t: Double] {
        var perPid: [pid_t: Double] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return perPid
        }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != IO_OBJECT_NULL {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != IO_OBJECT_NULL {
                defer { IOObjectRelease(client) }
                func property(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(client, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                // "pid 437, WindowServer"
                guard let creator = property("IOUserClientCreator") as? String,
                      let pid = Self.pid(fromCreator: creator),
                      let usage = property("AppUsage") as? [[String: Any]]
                else { continue }
                if let comma = creator.firstIndex(of: ",") {
                    let name = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { names[pid] = name }
                }
                for entry in usage {
                    if let time = entry["accumulatedGPUTime"] as? NSNumber {
                        perPid[pid, default: 0] += time.doubleValue
                    }
                }
            }
        }
        return perPid
    }

    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        return pid_t(creator.dropFirst(4).prefix { $0.isNumber })
    }
}

/// Maps helper processes to the app that launched them.
enum ResponsibleProcess {
    private typealias Function = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is not in a public header
    /// but has been stable since macOS 10.14; without it each helper stands alone.
    private static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func owner(of pid: pid_t) -> pid_t {
        guard let function else { return pid }
        let owner = function(pid)
        return owner > 0 ? owner : pid
    }

    static func name(of pid: pid_t, fallback: String? = nil) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        if !name.isEmpty { return name }
        return fallback ?? "pid \(pid)"
    }
}

// MARK: - Memory pressure, swap, uptime

enum MemoryPressureLevel: Equatable, Sendable {
    case normal, warning, critical

    static func read() -> MemoryPressureLevel? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}

enum SystemCounters {
    /// Swap in use, bytes.
    static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// Seconds since boot (wall clock, includes sleep).
    static func uptime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return max(Date().timeIntervalSince1970 - Double(boot.tv_sec), 0)
    }

    /// "1d 16h", "3h 5m", "12m".
    static func formatUptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return localized("%dd %dh", days, hours) }
        if hours > 0 { return localized("%dh %dm", hours, mins) }
        return localized("%dm", mins)
    }
}

// MARK: - USB devices

enum USBDeviceReader {
    /// Names of connected USB devices, hubs left out.
    static func connectedDevices() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if (property("bDeviceClass") as? NSNumber)?.intValue == 9 { continue } // hub
            let name = (property("USB Product Name") as? String)
                ?? (property("kUSBProductString") as? String)
                ?? localized("USB Device")
            names.append(name.trimmingCharacters(in: .whitespaces))
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Top processes

/// Per-app CPU and memory from libproc, for the expandable rows. CPU share is
/// the change in CPU time between two samples, like Activity Monitor's % CPU.
struct ProcessUsageSampler {
    struct Usage: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        let cpu: Double      // percent of one core
        let memory: UInt64   // physical footprint, bytes
        var id: pid_t { pid }
    }

    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousTime: UInt64?
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    mutating func sample() -> [Usage] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let now = mach_absolute_time()
        let elapsed = previousTime.map { Double(now - $0) * Double(Self.timebase.numer) / Double(Self.timebase.denom) }
        var cpuNow: [pid_t: UInt64] = [:]
        var result: [Usage] = []
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
                }
            }
            guard ok else { continue }
            let cpuTime = info.ri_user_time + info.ri_system_time
            cpuNow[pid] = cpuTime
            var cpu = 0.0
            if let elapsed, elapsed > 0, let before = previousCPU[pid], cpuTime >= before {
                let nanos = Double(cpuTime - before) * Double(Self.timebase.numer) / Double(Self.timebase.denom)
                cpu = nanos / elapsed * 100
            }
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            let name = String(cString: buffer)
            guard !name.isEmpty else { continue }
            result.append(Usage(pid: pid, name: name, cpu: cpu, memory: info.ri_phys_footprint))
        }
        previousCPU = cpuNow
        previousTime = now
        return result
    }
}
