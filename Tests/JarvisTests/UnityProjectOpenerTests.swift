import Testing
import Foundation
@testable import Jarvis

/// V1.0 Phase B — opening a Unity project for the user: version from the project, evidence from the process table + lock file, never a silent upgrade, never a duplicate editor.
@MainActor
@Suite("V1.0 Phase B · Unity project open")
struct UnityProjectOpenerTests {
    private func makeProject(version: String = "6000.0.23f1") -> String {
        let dir = NSTemporaryDirectory() + "unity-open-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir + "/Assets", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: dir + "/ProjectSettings", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/ProjectSettings/ProjectVersion.txt", contents: Data("m_EditorVersion: \(version)\nm_EditorVersionWithRevision: \(version) (abc)\n".utf8))
        return UnityProcessScanner.canonical(dir)
    }
    private func install(_ v: String) -> UnityEditorInstall {
        UnityEditorInstall(version: UnityVersion(v)!, appPath: "/Applications/Unity/Hub/Editor/\(v)/Unity.app", executablePath: "/Applications/Unity/Hub/Editor/\(v)/Unity.app/Contents/MacOS/Unity", available: true, lastCheckedAt: Date())
    }

    final class World {
        var editors: [UnityProcessScanner.Editor] = []
        var installs: [UnityEditorInstall] = []
        var launched: [(String, String)] = []
        var activated: [Int32] = []
        var front: Int32?
        var lock = false
        var launchError: String?
        var spawnsEditor = true
        var projectForSpawn = ""
    }

    private func opener(_ w: World) -> SystemUnityProjectOpener {
        var env = UnityOpenEnvironment()
        env.installs = { w.installs }
        env.editors = { w.editors }
        env.launch = { app, project in
            w.launched.append((app, project))
            if let e = w.launchError { return e }
            if w.spawnsEditor { w.editors.append(.init(pid: 4242, executable: app + "/Contents/MacOS/Unity", projectPath: project)); w.lock = true }
            return nil
        }
        env.activate = { w.activated.append($0); w.front = $0 }
        env.frontmostPID = { w.front }
        env.lockfileExists = { _ in w.lock }
        env.sleep = { _ in }
        env.processTimeout = 1; env.readyTimeout = 2; env.poll = 0.5
        return SystemUnityProjectOpener(env: env)
    }

    @Test("the project's own editor version is launched with -projectPath, and the evidence is the process + the lock file")
    func launches() async {
        let w = World(); w.installs = [install("6000.0.23f1"), install("2022.3.1f1")]
        let root = makeProject()
        let o = await opener(w).open(projectRoot: root)
        #expect(o == .launched(pid: 4242, version: "6000.0.23f1", lockfile: true))
        #expect(w.launched.count == 1 && w.launched[0].0.contains("6000.0.23f1") && w.launched[0].1 == root)
    }

    @Test("an editor that already has the project is brought forward — no second editor")
    func alreadyOpen() async {
        let w = World(); w.installs = [install("6000.0.23f1")]
        let root = makeProject()
        w.editors = [.init(pid: 777, executable: "/x/Unity.app/Contents/MacOS/Unity", projectPath: root)]
        let o = await opener(w).open(projectRoot: root)
        #expect(o == .alreadyOpen(pid: 777, version: "6000.0.23f1", frontmost: true))
        #expect(w.launched.isEmpty && w.activated == [777])
    }

    @Test("an editor with ANOTHER project is left alone; this project gets its own editor")
    func otherProjectUntouched() async {
        let w = World(); w.installs = [install("6000.0.23f1")]
        let root = makeProject()
        w.editors = [.init(pid: 100, executable: "/x/Unity.app/Contents/MacOS/Unity", projectPath: "/somewhere/else")]
        let o = await opener(w).open(projectRoot: root)
        if case .launched(let pid, _, true) = o { #expect(pid == 4242) } else { #expect(Bool(false), Comment(rawValue: "\(o)")) }
        #expect(w.editors.contains { $0.pid == 100 }, "the other editor is still there; nothing was closed")
    }

    @Test("a different editor version is never opened silently (it would upgrade the project); no editor at all is reported")
    func versions() async {
        let w = World(); w.installs = [install("2022.3.1f1")]
        let root = makeProject()
        let o = await opener(w).open(projectRoot: root)
        #expect(o == .needsUpgradeApproval(declared: "6000.0.23f1", candidate: "2022.3.1f1") && w.launched.isEmpty)
        w.installs = []
        #expect(await opener(w).open(projectRoot: root) == .noEditorInstalled(declared: "6000.0.23f1") && w.launched.isEmpty)
    }

    @Test("not a Unity project / unreadable version / launch refused / process never appears")
    func failures() async {
        let w = World(); w.installs = [install("6000.0.23f1")]
        #expect(await opener(w).open(projectRoot: NSTemporaryDirectory()) == .notAUnityProject)
        let root = makeProject()
        w.launchError = "no permission"
        #expect(await opener(w).open(projectRoot: root) == .launchFailed("no permission"))
        w.launchError = nil; w.spawnsEditor = false
        #expect(await opener(w).open(projectRoot: root) == .processNotFound)
    }

    @Test("a started editor that does not hold the project yet is reported as started, not as open")
    func notReady() async {
        let w = World(); w.installs = [install("6000.0.23f1")]
        let root = makeProject()
        var env = UnityOpenEnvironment()
        env.installs = { w.installs }; env.editors = { w.editors }
        env.launch = { app, project in w.editors.append(.init(pid: 9, executable: app, projectPath: project)); return nil }
        env.lockfileExists = { _ in false }; env.sleep = { _ in }; env.processTimeout = 1; env.readyTimeout = 2
        let o = await SystemUnityProjectOpener(env: env).open(projectRoot: root)
        #expect(o == .launched(pid: 9, version: "6000.0.23f1", lockfile: false))
    }

    @Test("the receipt: verified only with the process AND the lock file; the sentence says Unity; an unverified start never says open")
    func receipts() async {
        final class Fake: UnityProjectOpening { var outcome: UnityOpenOutcome; init(_ o: UnityOpenOutcome) { outcome = o }; func open(projectRoot: String) async -> UnityOpenOutcome { outcome } }
        let windows = HUDFakeWindows()
        let service = ActionService(launcher: FakeAppLauncher(), windows: windows, selfState: { SelfUIState(section: windows.hud.section, fullOpen: windows.isFullHUDOpen, compactOpen: windows.isCompactHUDOpen) })
        let root = makeProject()
        service.isUnityProject = { _ in true }
        let fake = Fake(.launched(pid: 1, version: "6000.0.23f1", lockfile: true))
        service.unityOpener = fake
        let ok = await service.perform(.openProject(name: "Hamam", path: root))
        #expect(ok.successIsClaimable && ActionPhrasebook.render(ok, language: .tr) == "Hamam Unity'de açık." && ok.executor.hasPrefix("Unity"))
        fake.outcome = .launched(pid: 1, version: "6000.0.23f1", lockfile: false)
        let notYet = await service.perform(.openProject(name: "Hamam", path: root))
        #expect(!notYet.successIsClaimable && !ActionPhrasebook.render(notYet, language: .tr).contains("açık."))
        fake.outcome = .needsUpgradeApproval(declared: "6000.0.23f1", candidate: "2022.3.1f1")
        let up = await service.perform(.openProject(name: "Hamam", path: root))
        #expect(up.status == .failed && ActionPhrasebook.render(up, language: .tr).contains("2022.3.1f1"))
    }
}
