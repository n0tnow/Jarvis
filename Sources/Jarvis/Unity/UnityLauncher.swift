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
    /// V0.13: an editor WITH a graphics device (still `-batchmode`: no window) for tasks that render the camera. Launchers that cannot tell the difference fall back to `launch`.
    func launch(editor: UnityEditorInstall, projectRoot: String, rendering: Bool) throws -> any UnityOwnedEditor
}

extension UnityLaunching {
    func launch(editor: UnityEditorInstall, projectRoot: String, rendering: Bool) throws -> any UnityOwnedEditor { try launch(editor: editor, projectRoot: projectRoot) }
}

/// Starts a headless editor with a FIXED argument list: the project path is the only variable part, and it is the already-validated
/// workspace. No model-supplied argument, no `-executeMethod`, no shell, no environment secrets (allowlisted environment).
@MainActor
final class UnityProcessLauncher: UnityLaunching {
    /// `rendering` only drops `-nographics` (a graphics device is needed to render a camera); the editor stays `-batchmode`, windowless, and the list stays fixed.
    static func arguments(projectRoot: String, rendering: Bool = false) -> [String] {
        ["-batchmode"] + (rendering ? [] : ["-nographics"]) + ["-projectPath", projectRoot, "-logFile", "-", "-disable-assembly-updater", "-jarvisOwned"]
    }

    func launch(editor: UnityEditorInstall, projectRoot: String) throws -> any UnityOwnedEditor { try launch(editor: editor, projectRoot: projectRoot, rendering: false) }

    func launch(editor: UnityEditorInstall, projectRoot: String, rendering: Bool) throws -> any UnityOwnedEditor {
        guard editor.available, FileManager.default.isExecutableFile(atPath: editor.executablePath) else { throw UnityBridgeError.notConnected("The Unity editor \(editor.version) is not available.") }
        let env = ProviderEnvironment.make()
        let proc = ManagedProcess(executable: editor.executablePath, arguments: Self.arguments(projectRoot: projectRoot, rendering: rendering), environment: env, workingDirectory: projectRoot, mergeStderr: true)
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
