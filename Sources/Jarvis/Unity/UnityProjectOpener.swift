import AppKit
import Foundation

// MARK: - Opening a Unity project for the USER (V1.0 decision milestone, Phase B)
//
// "Jarvis, Hamam projesini aç." for a Unity project means: find the project's own editor version, open the project in a normal (windowed) Unity Editor, and prove that THAT project is open.
// This is NOT the headless agent editor of `UnityProcessLauncher` (that one is JARVIS-owned, `-batchmode`, and closed by JARVIS); an editor started here belongs to the user and JARVIS never closes it.
//   · the path comes from the project registry and is re-validated here (Assets/ + ProjectSettings/ProjectVersion.txt exist);
//   · the editor version comes from the project's own `ProjectVersion.txt` and `UnityDiscovery` (no version is hard-coded); a different version is NEVER opened silently (it would migrate the project);
//   · an editor that already has this project open is brought forward, not duplicated; an editor with another project is left alone;
//   · evidence of "open": a running Unity process whose `-projectPath` is this project (process table), the project's `Temp/UnityLockfile` (Unity creates it while it holds the project) AND
//     `Library/EditorInstance.json` naming THAT process (the editor writes it once it has the project open);
//   · no JARVIS file is written into the project; opening a project in Unity necessarily lets Unity itself update its own Library/Temp folders.

enum UnityOpenOutcome: Equatable, Sendable {
    /// A windowless editor (a JARVIS agent task's) holds the project: Unity cannot open it twice, so nothing was started.
    case heldHeadless(pid: Int32)
    /// An editor already had the project open; `frontmost` tells whether it is now the frontmost application.
    case alreadyOpen(pid: Int32, version: String?, frontmost: Bool)
    /// Started now; `lockfile` = the editor holds the project: Temp/UnityLockfile exists AND Library/EditorInstance.json names this process.
    case launched(pid: Int32, version: String, lockfile: Bool)
    case notAUnityProject
    case noEditorInstalled(declared: String?)
    case needsUpgradeApproval(declared: String, candidate: String)
    case unknownDeclaredVersion
    case launchFailed(String)
    /// The launch call returned but no editor with this project appeared within the time limit.
    case processNotFound
}

@MainActor
protocol UnityProjectOpening: AnyObject {
    func open(projectRoot: String) async -> UnityOpenOutcome
}

/// The system seams (all injectable, so the decision logic is tested without Unity).
struct UnityOpenEnvironment {
    var isUnityProject: (String) -> Bool = { UnityProjectDetector.isUnityProject(root: $0) }
    var declaredVersion: (String) -> (raw: String, version: UnityVersion?)? = { UnityProjectDetector.declaredVersion(root: $0) }
    var installs: () -> [UnityEditorInstall] = { UnityDiscovery.discover() }
    var editors: () -> [UnityProcessScanner.Editor] = { UnityProcessScanner.editors() }
    var canonical: (String) -> String = { UnityProcessScanner.canonical($0) }
    /// Opens the editor application with `-projectPath <project>` through Launch Services (a new instance, a normal window).
    var launch: (_ appPath: String, _ projectRoot: String) async -> String? = { app, project in await SystemUnityLaunch.launch(appPath: app, projectRoot: project) }
    var activate: (Int32) -> Void = { NSRunningApplication(processIdentifier: $0)?.activate() }
    var frontmostPID: () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var lockfileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/Temp/UnityLockfile") }
    /// `Library/EditorInstance.json` is written by the editor once it has the project open; it names the editor's process. nil = not there (yet).
    var editorInstancePID: (String) -> Int32? = { root in
        guard let data = FileManager.default.contents(atPath: root + "/Library/EditorInstance.json"), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (obj["process_id"] as? NSNumber)?.int32Value
    }
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    /// Bounded waits: how long the editor may take to appear and to hold the project (a cold start with an import can take minutes; the answer then is honest, not hopeful).
    var processTimeout: TimeInterval = 30
    var readyTimeout: TimeInterval = 120
    var poll: TimeInterval = 0.5
}

enum SystemUnityLaunch {
    @MainActor static func launch(appPath: String, projectRoot: String) async -> String? {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["-projectPath", projectRoot]
        config.activates = true
        config.createsNewApplicationInstance = true
        do { _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config); return nil }
        catch { return String("\(error.localizedDescription)".prefix(160)) }
    }
}

@MainActor
final class SystemUnityProjectOpener: UnityProjectOpening {
    var env: UnityOpenEnvironment
    init(env: UnityOpenEnvironment = UnityOpenEnvironment()) { self.env = env }

    func open(projectRoot: String) async -> UnityOpenOutcome {
        guard env.isUnityProject(projectRoot) else { return .notAUnityProject }
        let root = env.canonical(projectRoot)
        let declared = env.declaredVersion(root)

        // 1. already open: bring it forward, do not start a second editor on the same project (Unity would refuse it anyway)
        if let running = UnityProcessScanner.editor(for: root, among: env.editors()) {
            if running.isBatchMode { return .heldHeadless(pid: running.pid) }
            env.activate(running.pid)
            var front = false
            let deadline = env.processTimeout
            var waited = 0.0
            while waited <= min(deadline, 4) {
                if env.frontmostPID() == running.pid { front = true; break }
                await env.sleep(env.poll); waited += env.poll
            }
            return .alreadyOpen(pid: running.pid, version: declared?.raw, frontmost: front)
        }

        // 2. the project's own editor version — never another one silently
        guard let declaredVersion = declared?.version else { return .unknownDeclaredVersion }
        switch UnityDiscovery.choose(for: declaredVersion, among: env.installs()) {
        case .noEditor: return .noEditorInstalled(declared: declared?.raw)
        case .unknownDeclaredVersion: return .unknownDeclaredVersion
        case .needsUpgradeApproval(let want, let candidate): return .needsUpgradeApproval(declared: want.description, candidate: candidate.version.description)
        case .exact(let install):
            if let failure = await env.launch(install.appPath, root) { return .launchFailed(failure) }
            // 3. evidence: an editor process with THIS -projectPath …
            var waited = 0.0
            var found: UnityProcessScanner.Editor?
            while waited <= env.processTimeout {
                if let e = UnityProcessScanner.editor(for: root, among: env.editors()) { found = e; break }
                await env.sleep(env.poll); waited += env.poll
            }
            guard let editor = found else { return .processNotFound }
            // … that holds the project (lock file), within the readiness limit
            func holds() -> Bool { env.lockfileExists(root) && env.editorInstancePID(root) == editor.pid }
            while waited <= env.readyTimeout {
                if holds() { return .launched(pid: editor.pid, version: install.version.description, lockfile: true) }
                await env.sleep(env.poll); waited += env.poll
            }
            return .launched(pid: editor.pid, version: install.version.description, lockfile: holds())
        }
    }
}
