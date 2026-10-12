import Foundation
import Observation
import Dispatch

/// Conservative concurrency limits for a 16 GB Apple-silicon laptop that also runs Unity / Xcode / a browser.
/// Reasoning (DEC-027): the local model peaks at ≈3.2 GB GPU/unified memory and one job saturates the GPU → ONE local job;
/// each OpenCode/Claude/Codex CLI is a ≈300 MB Node/Bun process plus network → two free-cloud workers at most;
/// heavy (premium, development) agents also share the user's subscription limits → ONE; and never more than 3 agents in total.
struct ConcurrencyLimits: Equatable, Sendable {
    var maxBackgroundAgents = 3
    var maxConcurrentFreeCloudAgents = 2
    var maxLocalInferenceJobs = 1
    var maxHeavyCodingAgents = 1
    /// No agent may spawn children of its own (no recursive explosion); a parent may have a few direct children.
    var maxDepth = 1
    var maxChildrenPerParent = 3
}

/// Event-driven system-pressure awareness: macOS memory-pressure dispatch source, thermal-state and low-power
/// notifications. Nothing polls (idle cost ≈ 0).
@MainActor
@Observable
final class ResourceManager {
    private(set) var pressure = ResourcePressure()
    var limits = ConcurrencyLimits()
    @ObservationIgnored private var source: DispatchSourceMemoryPressure?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Called when memory pressure rises (the supervisor unloads the local model).
    @ObservationIgnored var onPressureRise: ((MemoryPressureLevel) -> Void)?
    /// Additional listeners (V0.7: the voice layer unloads its speech helper). Same event, no polling.
    @ObservationIgnored private var pressureObservers: [(MemoryPressureLevel) -> Void] = []
    func observePressureRise(_ f: @escaping (MemoryPressureLevel) -> Void) { pressureObservers.append(f) }

    init() { refreshStatic() }

    func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self, let data = self.source?.data else { return }
            let level: MemoryPressureLevel = data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
            MainActor.assumeIsolated { self.setMemory(level) }
        }
        s.resume()
        source = s
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatic() }
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatic() }
        })
    }

    func stop() {
        source?.cancel(); source = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }

    func setMemory(_ level: MemoryPressureLevel) {
        let rose = (level == .warning && pressure.memory == .normal) || (level == .critical && pressure.memory != .critical)
        pressure.memory = level
        if rose { onPressureRise?(level); pressureObservers.forEach { $0(level) } }
    }

    func refreshStatic() {
        let info = ProcessInfo.processInfo
        pressure.thermalSerious = info.thermalState == .serious || info.thermalState == .critical
        pressure.lowPowerMode = info.isLowPowerModeEnabled
    }

    /// Job counters are owned by `AgentRunManager`/local runtime and mirrored here for routing decisions.
    func setActivity(localJobs: Int, heavyAgents: Int, backgroundAgents: Int) {
        pressure.localJobsRunning = localJobs
        pressure.heavyAgentsRunning = heavyAgents
        pressure.backgroundAgentsRunning = backgroundAgents
    }

    /// On-demand sample (not polled): physical memory and an approximate free amount, for the System panel.
    static func memorySnapshot() -> (totalGB: Double, freeGB: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (total, 0) }
        let page = Double(vm_kernel_page_size)
        return (total, Double(stats.free_count + stats.inactive_count) * page / 1_073_741_824)
    }
}
