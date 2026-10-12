import Foundation
import Observation

/// A local text embedder. The ONLY implementations: the supervised helper below (production) and deterministic fakes (tests). No network embedder exists (DEC-118).
protocol TextEmbedder: Sendable {
    var modelID: String { get }
    var revision: String { get }
    var dimension: Int { get }
    /// Installed and startable (nothing is started or downloaded by asking).
    var isAvailable: Bool { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

enum EmbeddingError: Error, Equatable, CustomStringConvertible {
    case unavailable(String), badResponse, timedOut, helperError(String)
    var description: String {
        switch self {
        case .unavailable(let w): "semantic search is unavailable: \(w)"
        case .badResponse: "the embedding helper sent an invalid answer"
        case .timedOut: "the embedding helper timed out"
        case .helperError(let m): "the embedding helper reported: \(m)"
        }
    }
}

/// The selected model (DEC-115): sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2, int8 ONNX for arm64. Measured, not assumed — `docs/PROJECT_MEMORY.md`.
enum EmbeddingModel {
    static let id = "paraphrase-multilingual-MiniLM-L12-v2-int8"
    static let repository = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    static let revision = "e8f8c211226b894fcb81acc59f3b34ba3efd5f42"
    static let license = "Apache-2.0"
    static let dimension = 384
    static let sizeBytes = 118_412_398
    static let defaultDirectory = NSHomeDirectory() + "/AI/models/memory-minilm-l12"
    static let requiredFiles = ["model.onnx", "tokenizer.json"]
}

/// Supervises the embedding helper: started on demand, unloaded after an idle period (a single sleeping task, not a poll) and under memory pressure, killed with its
/// process tree at quit. Output is untrusted: sizes, finiteness and norm are validated before a vector is used.
@MainActor
@Observable
final class EmbeddingHostController {
    struct Config: Sendable {
        var executable: String
        var worker: String
        var modelDirectory: String
        var workingDirectory: String
        var environment: [String: String]
        var idleUnloadSeconds: TimeInterval = 120
        var requestTimeout: TimeInterval = 30

        static func standard(paths: JarvisPaths, modelDirectory: String = EmbeddingModel.defaultDirectory, environmentBase: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            var env = ProviderEnvironment.make(base: environmentBase)
            env["PYTHONDONTWRITEBYTECODE"] = "1"; env["HF_HUB_OFFLINE"] = "1"; env["JARVIS_EMBED_THREADS"] = "2"
            return Config(executable: paths.runtime.appendingPathComponent("memory-venv/bin/python").path, worker: paths.runtime.appendingPathComponent("jarvis_embed_worker.py").path,
                          modelDirectory: modelDirectory, workingDirectory: paths.runtime.path, environment: env)
        }
    }

    struct Metrics: Equatable, Sendable { var requests = 0; var vectors = 0; var loadSeconds: Double?; var lastBatchSeconds: Double? }

    private final class Pending {
        let continuation: CheckedContinuation<[[Float]], Error>
        let count: Int
        var watchdog: Task<Void, Never>?
        init(_ c: CheckedContinuation<[[Float]], Error>, count: Int) { continuation = c; self.count = count }
    }

    let host: HelperHost
    private(set) var metrics = Metrics()
    @ObservationIgnored let config: Config
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored var onEvent: ((String) -> Void)?

    init(config: Config) {
        self.config = config
        let required = [config.worker] + EmbeddingModel.requiredFiles.map { config.modelDirectory + "/" + $0 }
        host = HelperHost(config: HelperConfig(name: "Memory embeddings", executable: config.executable, arguments: [config.worker, "--model-dir", config.modelDirectory],
                                               environment: config.environment, workingDirectory: config.workingDirectory, requiredPaths: required, startTimeout: 60))
        host.onMessage = { [weak self] m in self?.handle(m) }
        host.onEvent = { [weak self] s in self?.onEvent?(s) }
        host.onUnexpectedExit = { [weak self] in self?.failAll(EmbeddingError.helperError("the helper stopped")) }
    }

    var state: HelperState { host.state }
    func inspect() { host.inspect() }
    var isInstalled: Bool { host.inspect(); if case .notInstalled = host.state { return false }; return true }
    var installProblem: String? { host.inspect(); if case .notInstalled(let why) = host.state { return why }; return nil }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        idleTask?.cancel()
        do { try await host.ensureStarted() } catch { throw EmbeddingError.unavailable(installProblem ?? "the helper could not be started") }
        nextID += 1
        let id = String(nextID)
        let started = Date()
        let vectors: [[Float]] = try await withCheckedThrowingContinuation { cont in
            let p = Pending(cont, count: texts.count)
            pending[id] = p
            p.watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.config.requestTimeout ?? 30))
                guard !Task.isCancelled, let self, let p = self.pending.removeValue(forKey: id) else { return }
                p.continuation.resume(throwing: EmbeddingError.timedOut)
                self.host.shutdownNow()                                        // a hung helper is killed; it restarts on demand
            }
            host.send(["op": "embed", "id": id, "texts": texts])
        }
        metrics.requests += 1; metrics.vectors += texts.count; metrics.lastBatchSeconds = Date().timeIntervalSince(started); metrics.loadSeconds = host.lastLoadSeconds
        scheduleIdleUnload()
        return vectors
    }

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "embedding":
            guard let id = o["id"] as? String, let p = pending.removeValue(forKey: id) else { return }
            p.watchdog?.cancel()
            guard let dim = (o["dim"] as? NSNumber)?.intValue, dim == EmbeddingModel.dimension, let count = (o["count"] as? NSNumber)?.intValue, count == p.count,
                  let b64 = o["vectors"] as? String, let data = Data(base64Encoded: b64), data.count == count * dim * MemoryLayout<Float>.size else {
                p.continuation.resume(throwing: EmbeddingError.badResponse); return
            }
            let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var out: [[Float]] = []
            for i in 0..<count {
                let v = Array(all[(i * dim)..<((i + 1) * dim)])
                let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
                guard v.allSatisfy({ $0.isFinite }), abs(norm - 1) < 0.05 else { p.continuation.resume(throwing: EmbeddingError.badResponse); return }
                out.append(v)
            }
            p.continuation.resume(returning: out)
        case "error":
            guard let id = o["id"] as? String, let p = pending.removeValue(forKey: id) else { return }
            p.watchdog?.cancel()
            p.continuation.resume(throwing: EmbeddingError.helperError(String((o["message"] as? String ?? "error").prefix(120))))
        default: break
        }
    }

    private func failAll(_ error: Error) {
        let all = pending; pending = [:]
        for (_, p) in all { p.watchdog?.cancel(); p.continuation.resume(throwing: error) }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let seconds = config.idleUnloadSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.pending.isEmpty else { return }
            await self.host.stop()
        }
    }

    /// Memory pressure / user switch: unload now (semantic search then degrades to lexical + structured until the next request starts it again).
    func unloadNow() async {
        idleTask?.cancel()
        guard pending.isEmpty else { return }
        await host.stop()
    }
    func shutdownNow() { idleTask?.cancel(); failAll(EmbeddingError.unavailable("shutting down")); host.shutdownNow() }
}

/// The production embedder: a thin Sendable facade over the main-actor controller.
final class LocalEmbedder: TextEmbedder, @unchecked Sendable {
    let controller: EmbeddingHostController
    private let config: EmbeddingHostController.Config
    init(controller: EmbeddingHostController) { self.controller = controller; config = controller.config }
    var modelID: String { EmbeddingModel.id }
    var revision: String { EmbeddingModel.revision }
    var dimension: Int { EmbeddingModel.dimension }
    var isAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: config.executable) && fm.fileExists(atPath: config.worker) && EmbeddingModel.requiredFiles.allSatisfy { fm.fileExists(atPath: config.modelDirectory + "/" + $0) }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { try await controller.embed(texts) }
}
