import Foundation
import Observation

// MARK: - Typed, allowlisted setup (V0.15, DEC-242)
//
// The ONLY way the app installs anything. A `SetupAction` maps to ONE script that ships inside JARVIS.app (Contents/Resources/setup/scripts — the same pinned, hash-checked scripts the repository
// has had since V0.3.1), run directly (no shell string, no argument from anywhere else), with the provider environment allowlist (no keys, no tokens), after a disk-space check, with progress,
// cancellation and a one-at-a-time rule. There is no generic installer, no URL field, no sudo, and nothing here installs an external CLI (Claude Code, Codex, OpenCode) or an MCP server.
// Models and runtimes are pinned by revision inside the scripts, which download only when the user presses the button; an existing valid installation is reused and never downloaded again.

struct SetupPlan: Equatable, Sendable {
    var action: SetupAction
    var script: String                  // file name under <resources>/scripts
    var arguments: [String]
    var title: String
    var source: String                  // where the files come from (shown before the click)
    var downloadBytes: Int64            // estimate
    var installedBytes: Int64           // estimate
    var destination: String             // human-readable
}

enum SetupCatalog {
    static func plan(for action: SetupAction) -> SetupPlan? {
        let gb: Int64 = 1_000_000_000, mb: Int64 = 1_000_000
        switch action {
        case .installLocalModelRuntime:
            return SetupPlan(action: action, script: "setup_local_ai.sh", arguments: [], title: "Local model runtime (MLX)", source: "PyPI packages pinned in scripts/local-ai/requirements.txt (no model is downloaded; an existing Qwen folder is reused)",
                             downloadBytes: 500 * mb, installedBytes: 700 * mb, destination: "~/Library/Application Support/JARVIS/runtime")
        case .installSpeechRecognizer:
            return SetupPlan(action: action, script: "setup_voice_ai.sh", arguments: [], title: "Whisper speech recognition", source: "PyPI pinned packages + mlx-community/whisper-small-mlx at a pinned revision (≈ 460 MB model)",
                             downloadBytes: 1 * gb, installedBytes: Int64(1.4 * Double(gb)), destination: "~/Library/Application Support/JARVIS/runtime and ~/AI/models/whisper-small-mlx")
        case .installNaturalVoice:
            return SetupPlan(action: action, script: "setup_voice_ai.sh", arguments: ["--natural"], title: "Natural JARVIS voice and wake-word detector", source: "PyPI pinned packages; openWakeWord v0.5.1 release files (SHA-256 verified); Supertone/supertonic-3 at a pinned revision",
                             downloadBytes: 600 * mb, installedBytes: Int64(1.0 * Double(gb)), destination: "~/Library/Application Support/JARVIS/runtime and ~/AI/models/supertonic-3")
        case .installVisionHelper:
            return SetupPlan(action: action, script: "setup_vision_ai.sh", arguments: ["--model", "4b"], title: "Visual model (Qwen3-VL 4B, 4-bit)", source: "PyPI pinned packages + mlx-community/Qwen3-VL-4B-Instruct-4bit at a pinned revision (≈ 3.1 GB)",
                             downloadBytes: Int64(3.7 * Double(gb)), installedBytes: Int64(4.2 * Double(gb)), destination: "~/Library/Application Support/JARVIS/runtime and ~/AI/models/vision")
        case .installMemoryHelper:
            return SetupPlan(action: action, script: "setup_memory_ai.sh", arguments: [], title: "Memory search helper", source: "PyPI pinned packages + sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2 at a pinned revision, SHA-256 verified (118 MB)",
                             downloadBytes: 300 * mb, installedBytes: 500 * mb, destination: "~/Library/Application Support/JARVIS/runtime and ~/AI/models/memory-minilm-l12")
        default:
            return nil
        }
    }
}

enum SetupRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case notAnInstallAction, noPackagedScripts, scriptNotSafe(String), alreadyRunning, notEnoughSpace(needed: Int64, available: Int64), uvMissing, stubbedRun
    var description: String {
        switch self {
        case .notAnInstallAction: "That is not an install action."
        case .noPackagedScripts: "This copy of JARVIS has no packaged setup scripts (a development build). Run the matching scripts/setup_*.sh from the repository instead."
        case .scriptNotSafe(let why): "The packaged setup script was not used: \(why)."
        case .alreadyRunning: "A setup is already running. Wait for it to finish or cancel it."
        case .notEnoughSpace(let n, let a): "Not enough free disk space: about \(Self.gb(n)) needed, \(Self.gb(a)) available. Nothing was started."
        case .uvMissing: "The Python tool “uv” is required and was not found (see docs.astral.sh/uv). Nothing was started."
        case .stubbedRun: "Setup is disabled in automated runs."
        }
    }
    static func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1_000_000_000) }
}

@MainActor @Observable
final class SetupRunner {
    enum State: Equatable {
        case idle
        case running(SetupAction)
        case finished(SetupAction, ok: Bool, summary: String)
        case cancelled(SetupAction)
    }
    private(set) var state: State = .idle
    private(set) var log: [String] = []
    private(set) var lastRefusal: SetupRefusal?
    private(set) var startedAt: Date?

    // Seams (production defaults; tests inject fakes).
    @ObservationIgnored var resourceRoot: () -> URL? = { Bundle.main.resourceURL?.appendingPathComponent("setup", isDirectory: true) }
    @ObservationIgnored var freeBytes: () -> Int64 = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }
    @ObservationIgnored var findTool: (String) -> Bool = { name in
        let dirs = ExecutableLocator.forThisMac().extraPathDirectories() + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }
    @ObservationIgnored var environment: () -> [String: String] = {
        ProviderEnvironment.make(extraPath: ExecutableLocator.forThisMac().extraPathDirectories())
    }
    @ObservationIgnored var stubbed = false
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    @ObservationIgnored var onFinished: ((SetupAction, Bool) -> Void)?
    /// Starts the process and streams its output; returns the exit code. Replaced by tests with a fake.
    @ObservationIgnored var launch: (URL, [String], [String: String], @escaping @MainActor (String) -> Void, @escaping @MainActor (ManagedProcess?) -> Void) async -> Int32 = { script, args, env, line, process in
        let p = ManagedProcess(executable: script.path, arguments: args, environment: env, workingDirectory: NSTemporaryDirectory(), mergeStderr: true)
        guard let stream = try? p.start(stdin: nil) else { return 127 }
        process(p)
        for await lineData in stream { await line(String(decoding: lineData, as: UTF8.self)) }          // the stream yields COMPLETE lines (LineSplitter)
        return await p.waitForExit()
    }
    @ObservationIgnored private var process: ManagedProcess?
    @ObservationIgnored private var wasCancelled = false

    var isRunning: Bool { if case .running = state { return true }; return false }
    var runningAction: SetupAction? { if case .running(let a) = state { return a }; return nil }

    // MARK: Preflight (pure checks; nothing starts)

    func preflight(_ action: SetupAction) -> Result<(plan: SetupPlan, script: URL), SetupRefusal> {
        if stubbed { return .failure(.stubbedRun) }
        guard let plan = SetupCatalog.plan(for: action) else { return .failure(.notAnInstallAction) }
        if isRunning { return .failure(.alreadyRunning) }
        guard let root = resourceRoot() else { return .failure(.noPackagedScripts) }
        let script = root.appendingPathComponent("scripts", isDirectory: true).appendingPathComponent(plan.script)
        let fm = FileManager.default
        // The script must be a regular, executable file that really lives inside the packaged setup folder (no symlink, no traversal).
        guard let attrs = try? fm.attributesOfItem(atPath: script.path), (attrs[.type] as? FileAttributeType) == .typeRegular else { return .failure(.noPackagedScripts) }
        guard !plan.script.contains("/"), !plan.script.contains("..") else { return .failure(.scriptNotSafe("unexpected file name")) }
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path, realScript = script.resolvingSymlinksInPath().standardizedFileURL.path
        guard realScript.hasPrefix(realRoot + "/") else { return .failure(.scriptNotSafe("it resolves outside the packaged setup folder")) }
        guard fm.isExecutableFile(atPath: script.path) else { return .failure(.scriptNotSafe("it is not executable")) }
        let needed = Int64(Double(plan.installedBytes) * 1.25), available = freeBytes()
        if available < needed { return .failure(.notEnoughSpace(needed: needed, available: available)) }
        guard findTool("uv") else { return .failure(.uvMissing) }
        return .success((plan, script))
    }

    // MARK: Run

    /// Returns nil when the setup ran to completion (success or failure is in `state`), or the refusal.
    @discardableResult
    func start(_ action: SetupAction) async -> SetupRefusal? {
        let checked = preflight(action)
        guard case .success(let (plan, script)) = checked else {
            if case .failure(let r) = checked { lastRefusal = r; onEvent?("Setup refused: \(r)", .warning) }
            return lastRefusal
        }
        lastRefusal = nil; log = []; wasCancelled = false; startedAt = Date()
        state = .running(action)
        onEvent?("Setup started: \(plan.title)", .info)
        let code = await launch(script, plan.arguments, environment(), { [weak self] l in self?.append(l) }, { [weak self] p in self?.process = p })
        process = nil
        if wasCancelled {
            state = .cancelled(action); onEvent?("Setup cancelled: \(plan.title)", .warning)
            onFinished?(action, false)
        } else if code == 0 {
            state = .finished(action, ok: true, summary: "\(plan.title) is ready."); onEvent?("Setup finished: \(plan.title)", .success)
            onFinished?(action, true)
        } else {
            let why = log.last { !$0.isEmpty } ?? "exit code \(code)"
            state = .finished(action, ok: false, summary: "\(plan.title) did not finish (\(why)). Nothing is half-installed that a rerun cannot repair — the script is safe to run again.")
            onEvent?("Setup failed: \(plan.title)", .error)
            onFinished?(action, false)
        }
        return nil
    }

    /// Stops the running setup (the script's whole process tree). Pinned downloads resume or restart cleanly on the next run.
    func cancel() async {
        guard isRunning, let p = process else { return }
        wasCancelled = true
        await p.cancel()
    }

    private func append(_ raw: String) {
        // Progress bars redraw one line with carriage returns: only the latest state is kept.
        let latest = raw.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? raw
        let line = OutputSanitizer.sanitize(latest).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        log.append(String(line.prefix(300)))
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }
}

// MARK: - Existing model folders

/// “Select Existing Model Folder”: a model that is already on disk is referenced where it is — never copied or downloaded again.
enum ModelFolderValidator {
    enum Verdict: Equatable { case ok(String), refused(String) }

    static func validate(_ url: URL, home: String = NSHomeDirectory()) -> Verdict {
        let fm = FileManager.default
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { return .refused("That is not a folder.") }
        let homeReal = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.path.hasPrefix(homeReal + "/") || resolved.path.hasPrefix("/Volumes/") else { return .refused("The model folder must be inside your home folder or on an external volume.") }
        // A link inside the folder that leads somewhere else is how a "model" could point at private files.
        guard let items = try? fm.contentsOfDirectory(atPath: resolved.path) else { return .refused("The folder cannot be read.") }
        for name in items.prefix(500) {
            let p = resolved.appendingPathComponent(name)
            if let t = (try? fm.attributesOfItem(atPath: p.path))?[.type] as? FileAttributeType, t == .typeSymbolicLink {
                let target = p.resolvingSymlinksInPath().standardizedFileURL.path
                if !target.hasPrefix(resolved.path + "/") { return .refused("“\(name)” is a link that leads outside the folder.") }
            }
        }
        guard items.contains("config.json") else { return .refused("No config.json — this does not look like a model folder.") }
        guard items.contains(where: { $0.hasSuffix(".safetensors") || $0.hasSuffix(".npz") || $0.hasSuffix(".gguf") }) else { return .refused("No model weights (.safetensors / .npz / .gguf) were found.") }
        return .ok(resolved.path)
    }
}
