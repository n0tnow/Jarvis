import Foundation

/// A Unity editor JARVIS started itself. Only such an editor is ever closed by JARVIS; a user's editor is never touched.
@MainActor
protocol UnityOwnedEditor: AnyObject {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    /// Sanitized tail of the editor's own output (diagnostics for a failed launch; never persisted).
    var outputTail: String { get }
    func terminate() async
    /// Fires once when the process ends.
    var onExit: (() -> Void)? { get set }
}

@MainActor
protocol UnityLaunching: AnyObject {
    func launch(editor: UnityEditorInstall, projectRoot: String) throws -> any UnityOwnedEditor
}

/// Starts a headless editor with a FIXED argument list: the project path is the only variable part, and it is the already-validated
/// workspace. No model-supplied argument, no `-executeMethod`, no shell, no environment secrets (allowlisted environment).
@MainActor
final class UnityProcessLauncher: UnityLaunching {
    static func arguments(projectRoot: String) -> [String] {
        ["-batchmode", "-nographics", "-projectPath", projectRoot, "-logFile", "-", "-disable-assembly-updater", "-jarvisOwned"]
    }

    func launch(editor: UnityEditorInstall, projectRoot: String) throws -> any UnityOwnedEditor {
        guard editor.available, FileManager.default.isExecutableFile(atPath: editor.executablePath) else { throw UnityBridgeError.notConnected("The Unity editor \(editor.version) is not available.") }
        let env = ProviderEnvironment.make()
        let proc = ManagedProcess(executable: editor.executablePath, arguments: Self.arguments(projectRoot: projectRoot), environment: env, workingDirectory: projectRoot, mergeStderr: true)
        let owned = ProcessOwnedEditor(process: proc)
        try owned.start()
        return owned
    }
}

@MainActor
final class ProcessOwnedEditor: UnityOwnedEditor {
    private let process: ManagedProcess
    private let sink = SafeToolOutput(runID: nil, hub: nil)
    var onExit: (() -> Void)?
    private(set) var pid: pid_t = 0
    private var pump: Task<Void, Never>?

    init(process: ManagedProcess) { self.process = process }

    var isRunning: Bool { process.isRunning }
    var outputTail: String { String(sink.tail.suffix(1500)) }

    func start() throws {
        let stream = try process.start(stdin: nil)
        pid = process.processIdentifier
        // The editor's own output is drained through the sanitizer (bounded tail) so the pipe never blocks; nothing is stored.
        pump = Task { @MainActor [weak self] in
            for await line in stream { self?.sink.feed(String(decoding: line, as: UTF8.self)) }
            _ = await self?.process.waitForExit()
            self?.sink.finish()
            self?.onExit?()
        }
    }

    func terminate() async {
        await process.cancel()
        pump?.cancel()
    }
}
