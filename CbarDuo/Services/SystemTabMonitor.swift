import Foundation

/// Samples everything the popover's System tab shows, every 2 seconds, only
/// while the tab is visible. Kernel and IOKit reads run on a background queue.
@MainActor
final class SystemTabMonitor: ObservableObject {
    static let shared = SystemTabMonitor()

    struct Snapshot: Equatable {
        var cpuTemperature: Double?
        var gpuTemperature: Double?
        var cpuUsage: Double?
        var gpuUsage: Double?
        var memory: MemoryBreakdown?
        var pressure: MemoryPressureLevel?
        var swapUsed: UInt64?
        var uptime: TimeInterval?
        var devices: [String] = []
    }

    @Published private(set) var snapshot = Snapshot()
    /// Memory used (0…1), oldest first, up to `historyLength` samples.
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var processes: [ProcessUsageSampler.Usage] = []
    @Published private(set) var gpuProcesses: [GPUProcessSampler.Usage] = []
    /// False until the GPU list has two samples to compare.
    @Published private(set) var gpuProcessesMeasured = false

    /// Set while a row listing apps is expanded.
    var wantsProcesses = false {
        didSet { if wantsProcesses && !oldValue { tick() } }
    }

    /// Set while the GPU row is expanded.
    var wantsGPUProcesses = false {
        didSet {
            guard wantsGPUProcesses != oldValue else { return }
            gpuProcesses = []
            gpuProcessesMeasured = false
            if wantsGPUProcesses { tick() }
        }
    }

    static let historyLength = 90
    private var visibleViews = 0
    private var timer: Timer?
    private var isRecordingHistory = false
    private var historySlots = HistorySlots(slotLength: 2, capacity: historyLength)
    private let core = SamplerCore()

    private init() {}

    /// Records memory used in 2 s slots from launch (one cheap kernel call per
    /// `HistoryClock` tick), so the graph already covers the last 3 minutes
    /// when the tab opens.
    func startHistory() {
        guard !isRecordingHistory else { return }
        isRecordingHistory = true
        HistoryClock.shared.subscribe { [weak self] elapsed in
            guard let self else { return }
            let count = elapsed == 0 ? 1 : historySlots.advance(by: elapsed)
            if count > 0 { recordHistory(slots: count) }
        }
    }

    private func recordHistory(slots: Int) {
        guard let used = SystemUsageMonitor.readMemoryBreakdown()?.usedFraction else { return }
        memoryHistory.append(contentsOf: repeatElement(used, count: slots))
        if memoryHistory.count > Self.historyLength {
            memoryHistory.removeFirst(memoryHistory.count - Self.historyLength)
        }
    }

    func viewAppeared() {
        visibleViews += 1
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func viewDisappeared() {
        visibleViews = max(visibleViews - 1, 0)
        guard visibleViews == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let includeProcesses = wantsProcesses
        let includeGPU = wantsGPUProcesses
        core.sample(includeProcesses: includeProcesses, includeGPU: includeGPU) { [weak self] snapshot, processes, gpu in
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snapshot
                if !self.isRecordingHistory, let used = snapshot.memory?.usedFraction {
                    self.memoryHistory.append(used)
                    if self.memoryHistory.count > Self.historyLength {
                        self.memoryHistory.removeFirst(self.memoryHistory.count - Self.historyLength)
                    }
                }
                if includeProcesses { self.processes = processes }
                if includeGPU, self.wantsGPUProcesses, let gpu {
                    self.gpuProcesses = gpu
                    self.gpuProcessesMeasured = true
                }
            }
        }
    }
}

/// Sampler state that lives on the background queue.
private final class SamplerCore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cojonesnaut.cbarduo.system-sampler", qos: .utility)
    private var cpu = CPULoadSampler()
    private var processes = ProcessUsageSampler()
    private var gpuProcesses = GPUProcessSampler()

    func sample(
        includeProcesses: Bool,
        includeGPU: Bool,
        completion: @escaping @Sendable (SystemTabMonitor.Snapshot, [ProcessUsageSampler.Usage], [GPUProcessSampler.Usage]?) -> Void
    ) {
        queue.async { [self] in
            let smc = SMCTemperatureReader.shared
            let snapshot = SystemTabMonitor.Snapshot(
                cpuTemperature: smc?.cpuTemperature(),
                gpuTemperature: smc?.gpuTemperature(),
                cpuUsage: cpu.sample(),
                gpuUsage: GPULoadReader.read(),
                memory: SystemUsageMonitor.readMemoryBreakdown(),
                pressure: MemoryPressureLevel.read(),
                swapUsed: SystemCounters.swapUsed(),
                uptime: SystemCounters.uptime(),
                devices: USBDeviceReader.connectedDevices()
            )
            let apps = includeProcesses ? processes.sample() : []
            var gpu: [GPUProcessSampler.Usage]?
            if includeGPU {
                gpu = gpuProcesses.sample()
            } else {
                gpuProcesses = GPUProcessSampler()
            }
            completion(snapshot, apps, gpu)
        }
    }
}
