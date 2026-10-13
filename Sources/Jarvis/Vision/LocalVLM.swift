import Foundation
import Observation
import CoreGraphics

// MARK: - The local vision-language model (V0.13): on-demand, offline, unloaded when idle or under memory pressure, never a daemon.

/// The models JARVIS can run for general visual grounding. Chosen by measurement (docs/VISUAL_GROUNDING.md): both are Apache-2.0, 4-bit MLX, pinned by revision.
enum LocalVLMModel: String, CaseIterable, Sendable {
    case qwen3VL4B = "Qwen3-VL-4B-Instruct-4bit"
    case qwen3VL2B = "Qwen3-VL-2B-Instruct-4bit"

    var repository: String { "mlx-community/" + rawValue }
    var revision: String { self == .qwen3VL4B ? "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b" : "9c4f5209e57b31f4b9dfba735de3fb983739c9cc" }
    var license: String { "Apache-2.0" }
    var sizeBytes: Int { self == .qwen3VL4B ? 3_110_000_000 : 1_800_000_000 }
    /// Measured resident memory of the helper while the model is loaded.
    var residentMegabytes: Int { self == .qwen3VL4B ? 3_240 : 1_990 }
    var directory: String { NSHomeDirectory() + "/AI/models/vision/" + rawValue }
    var requiredFiles: [String] { ["config.json", "model.safetensors.index.json"] }
    var label: String { self == .qwen3VL4B ? "Qwen3-VL 4B (accurate)" : "Qwen3-VL 2B (light)" }
}

enum LocalVLMError: Error, Equatable, CustomStringConvertible {
    case unavailable(String), timedOut, badResponse, helperError(String)
    var description: String {
        switch self {
        case .unavailable(let w): "the local vision model is unavailable: \(w)"
        case .timedOut: "the local vision model timed out"
        case .badResponse: "the local vision model sent an invalid answer"
        case .helperError(let m): "the local vision model reported: \(m)"
        }
    }
}

struct RawGround: Sendable {
    var found: Bool
    var ambiguous: Bool
    var candidates: [(label: String, box: [Double])]
    var seconds: Double
    var peakMegabytes: Int?
}

@MainActor
@Observable
final class LocalVLMRuntime {
    struct Config: Sendable {
        var executable: String
        var worker: String
        var modelDirectory: String
        var workingDirectory: String
        var environment: [String: String]
        var idleUnloadSeconds: TimeInterval = 45
        var requestTimeout: TimeInterval = 60
        var startTimeout: TimeInterval = 90
        var modelName: String

        static func standard(paths: JarvisPaths, model: LocalVLMModel = .qwen3VL4B, environmentBase: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            var env = ProviderEnvironment.make(base: environmentBase)
            env["PYTHONDONTWRITEBYTECODE"] = "1"; env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"
            return Config(executable: paths.runtime.appendingPathComponent("vision-venv/bin/python").path, worker: paths.runtime.appendingPathComponent("jarvis_vision_worker.py").path,
                          modelDirectory: model.directory, workingDirectory: paths.runtime.path, environment: env, modelName: model.rawValue)
        }
    }

    struct Metrics: Equatable, Sendable { var requests = 0; var loads = 0; var loadSeconds: Double?; var lastRequestSeconds: Double?; var peakMegabytes: Int? }

    private final class Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        var watchdog: Task<Void, Never>?
        init(_ c: CheckedContinuation<[String: Any], Error>) { continuation = c }
    }

    let host: HelperHost
    private(set) var metrics = Metrics()
    @ObservationIgnored let config: Config
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored var onEvent: ((String) -> Void)?
    /// Memory pressure right now (the runtime refuses to LOAD under pressure and unloads when it rises).
    @ObservationIgnored var pressureNormal: () -> Bool = { true }

    init(config: Config) {
        self.config = config
        host = HelperHost(config: HelperConfig(name: "Visual grounding", executable: config.executable, arguments: [config.worker, "--model-dir", config.modelDirectory], environment: config.environment,
                                               workingDirectory: config.workingDirectory, requiredPaths: [config.worker, config.modelDirectory + "/config.json"], startTimeout: config.startTimeout))
        host.onMessage = { [weak self] m in self?.handle(m) }
        host.onEvent = { [weak self] s in self?.onEvent?(s) }
        host.onUnexpectedExit = { [weak self] in self?.failAll(LocalVLMError.helperError("the helper stopped")) }
    }

    var state: HelperState { host.state }
    var isInstalled: Bool { host.inspect(); if case .notInstalled = host.state { return false }; return true }
    var installProblem: String? { host.inspect(); if case .notInstalled(let why) = host.state { return why }; return nil }
    var isResident: Bool { host.isRunning }

    func ground(png: Data, query: String) async throws -> RawGround {
        let o = try await request(["op": "ground", "query": String(query.prefix(300))], png: png)
        let cands = (o["candidates"] as? [[String: Any]] ?? []).compactMap { c -> (String, [Double])? in
            guard let b = (c["box"] as? [NSNumber])?.map(\.doubleValue), b.count == 4 else { return nil }
            return (c["label"] as? String ?? "", b)
        }
        return RawGround(found: o["found"] as? Bool ?? false, ambiguous: o["ambiguous"] as? Bool ?? false, candidates: cands, seconds: (o["seconds"] as? NSNumber)?.doubleValue ?? 0, peakMegabytes: (o["peak_mb"] as? NSNumber)?.intValue)
    }

    func describe(png: Data, question: String) async throws -> (text: String, seconds: Double) {
        let o = try await request(["op": "describe", "question": String(question.prefix(300))], png: png)
        return (o["text"] as? String ?? "", (o["seconds"] as? NSNumber)?.doubleValue ?? 0)
    }

    private func request(_ body: [String: Any], png: Data) async throws -> [String: Any] {
        guard pressureNormal() || host.isRunning else { throw LocalVLMError.unavailable("memory pressure: the vision model is not loaded now") }
        idleTask?.cancel()
        let wasResident = host.isRunning
        do { try await host.ensureStarted() } catch { throw LocalVLMError.unavailable(installProblem ?? "the helper could not be started") }
        if !wasResident { metrics.loads += 1; metrics.loadSeconds = host.lastLoadSeconds }
        nextID += 1
        let id = String(nextID)
        var req = body; req["id"] = id; req["image"] = png.base64EncodedString()
        let started = Date()
        let answer: [String: Any] = try await withCheckedThrowingContinuation { cont in
            let p = Pending(cont)
            pending[id] = p
            p.watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.config.requestTimeout ?? 60))
                guard !Task.isCancelled, let self, let p = self.pending.removeValue(forKey: id) else { return }
                p.continuation.resume(throwing: LocalVLMError.timedOut)
                self.host.shutdownNow()                                        // a hung helper is killed; it restarts on demand
            }
            host.send(req)
        }
        metrics.requests += 1; metrics.lastRequestSeconds = Date().timeIntervalSince(started)
        if let mb = (answer["peak_mb"] as? NSNumber)?.intValue { metrics.peakMegabytes = mb }
        scheduleIdleUnload()
        return answer
    }

    private func handle(_ o: [String: Any]) {
        guard let id = o["id"] as? String, let p = pending.removeValue(forKey: id) else { return }
        p.watchdog?.cancel()
        switch o["type"] as? String {
        case "ground", "describe": p.continuation.resume(returning: o)
        case "error": p.continuation.resume(throwing: LocalVLMError.helperError(String((o["message"] as? String ?? "error").prefix(120))))
        default: p.continuation.resume(throwing: LocalVLMError.badResponse)
        }
    }

    private func failAll(_ error: Error) {
        let all = pending; pending = [:]
        for (_, p) in all { p.watchdog?.cancel(); p.continuation.resume(throwing: error) }
    }

    /// One sleeping task (not a poll): after the idle period the multi-GB model leaves memory.
    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let seconds = config.idleUnloadSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.pending.isEmpty else { return }
            await self.host.stop()
        }
    }

    func unloadNow() async { idleTask?.cancel(); guard pending.isEmpty else { return }; await host.stop() }
    func shutdownNow() { idleTask?.cancel(); failAll(LocalVLMError.unavailable("shutting down")); host.shutdownNow() }
    var residentBytes: UInt64? { host.residentBytes }
}

// MARK: The provider

/// Perception through the local model. The model's boxes are validated, cross-checked against the text actually printed in each region (on-device OCR) and classified with the
/// SAME consequence classes as the rest of Computer Use; instruction-like text in an answer is noted and never obeyed.
final class LocalVLMProvider: VisualProvider, @unchecked Sendable {
    let id: String
    let providerClass = VisualProviderClass.onDevice
    let capabilities: Set<VisualCapability> = [.locateText, .locateControl, .locateObject, .describe]
    let runtime: LocalVLMRuntime
    private let config: LocalVLMRuntime.Config
    init(runtime: LocalVLMRuntime) { self.runtime = runtime; config = runtime.config; id = "local-vlm:" + runtime.config.modelName }

    var isAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: config.executable) && fm.fileExists(atPath: config.worker) && fm.fileExists(atPath: config.modelDirectory + "/config.json")
    }

    func analyze(png: Data, image: CGImage, query: VisualQuery) async throws -> VisualAnswer {
        var a = VisualAnswer(); a.provider = id; a.pictureHash = VisualImageCoding.hash(png)
        do {
            switch query {
            case .describe(let q):
                let r = try await runtime.describe(png: png, question: q)
                let v = VisualOutputValidator.text(r.text)
                a.text = v.text; a.injectionNotes = v.notes; a.found = !v.text.isEmpty; a.seconds = r.seconds
            case .locate(let q):
                let raw = try await runtime.ground(png: png, query: q)
                a.seconds = raw.seconds; a.peakMegabytes = raw.peakMegabytes
                let regions = VisualOutputValidator.regions(raw.candidates)
                var cands: [VisualTargetCandidate] = []
                for (label, region) in regions {
                    let printed = AppleVisionProvider.text(in: region, of: image)
                    let notes = UntrustedContent.scan(label + " " + (printed ?? ""))
                    a.injectionNotes += notes.map { "instruction-like text near “\(label.prefix(20))”: \($0)" }
                    cands.append(VisualTargetCandidate(label: label.isEmpty ? q : label, region: region, confidence: regions.count == 1 && !raw.ambiguous ? .medium : .low,
                                                       safety: VisualOutputValidator.safety(label: label, printedText: printed, requested: q), sources: [id], printedText: printed))
                }
                a.candidates = cands
                a.found = raw.found && !cands.isEmpty
                a.ambiguous = a.found && (raw.ambiguous || cands.count > 1)
                if !a.found { a.abstainReason = "nothing matching “\(q.prefix(40))” was found in the picture" }
                else if a.ambiguous { a.abstainReason = "\(cands.count) places match “\(q.prefix(40))”" }
            }
        } catch let e as LocalVLMError { throw VisualProviderError.unavailable(e.description) }
        return a
    }
}
