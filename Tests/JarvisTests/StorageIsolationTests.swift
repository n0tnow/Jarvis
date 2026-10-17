import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 3 — release gate: tests and developer launches can never touch the user's real storage.
// Incident: a live test left `jarvis-continuity-fixture` as the production project selection (shared UserDefaults domain, no restore after a SIGKILL scenario).

@Suite("Fix 3 · storage isolation (tests cannot mutate real user state)")
@MainActor
struct StorageIsolationTests {
    private let production = UserDefaults(suiteName: "dev.jarvis.Jarvis")        // the installed app's real preferences domain (read only here)

    @Test("a test process is a protected run; Preferences() never uses the production domain")
    func preferencesAreIsolated() {
        #expect(StorageIsolation.isProtectedRun && StorageIsolation.isTestProcess)
        let p = Preferences()
        #expect(p.defaults !== UserDefaults.standard)
        #expect(StorageIsolation.defaultsForRun(tag: nil) !== UserDefaults.standard)
        #expect(StorageIsolation.defaultsForRun(tag: "live-test-daily") !== UserDefaults.standard)
    }

    @Test("an AppContext built the way a live test builds it writes its project selection to an isolated suite — the production domain is unchanged")
    func liveTestContextCannotChangeProduction() {
        let before = production?.string(forKey: "prefs.tasks.projectRoot")
        let beforeVoice = production?.object(forKey: "prefs.voice.enabled") as? Bool
        let dir = JarvisPaths.liveTestsRoot.appendingPathComponent("unit-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir); StorageIsolation.wipe(tag: dir.lastPathComponent) }
        let app = AppContext(stubIntelligence: true, dataDirectory: dir)
        app.preferences.projectRoot = NSTemporaryDirectory() + "jarvis-continuity-fixture"
        app.preferences.voiceEnabled = true
        #expect(app.preferences.defaults !== UserDefaults.standard)
        #expect(production?.string(forKey: "prefs.tasks.projectRoot") == before, "the production project selection must not change")
        #expect(production?.object(forKey: "prefs.voice.enabled") as? Bool == beforeVoice)
        #expect(!JarvisPaths.isInside(app.paths.root, directory: JarvisPaths.standard().root) || JarvisPaths.isInside(app.paths.root, directory: JarvisPaths.liveTestsRoot))
    }

    @Test("the production data directory is recognised; the live-test root and temporary folders are not")
    func dataRootRule() {
        #expect(StorageIsolation.isProductionDataRoot(JarvisPaths.standard().root))
        #expect(StorageIsolation.isProductionDataRoot(JarvisPaths.standard().root.appendingPathComponent("anything")))
        #expect(!StorageIsolation.isProductionDataRoot(JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-daily")))
        #expect(!StorageIsolation.isProductionDataRoot(URL(fileURLWithPath: NSTemporaryDirectory())))
        #expect(!JarvisPaths.isInside(JarvisPaths.liveTestsRoot, directory: JarvisPaths.standard().root), "live-test data lives beside, not inside, the production folder")
    }

    @Test("a fixture project selection is recognised by provenance; a genuine project is never touched")
    func fixtureProvenance() {
        let temp = NSTemporaryDirectory()
        #expect(StorageIsolation.isTestFixturePath("/private/var/folders/ml/abc/T/jarvis-continuity-fixture"))
        #expect(StorageIsolation.isTestFixturePath(temp + "jarvis-task-demo-3F2A"))
        #expect(!StorageIsolation.isTestFixturePath("/Users/someone/Games/Hamam"))
        #expect(!StorageIsolation.isTestFixturePath("/Users/someone/jarvis-notes"))                 // a jarvis-named folder OUTSIDE the temporary area is a user folder
        #expect(!StorageIsolation.isTestFixturePath(temp + "MyRealProject"))
        #expect(!StorageIsolation.isTestFixturePath(""))
    }

    @Test("source guard: production storage is named only by the files that own it")
    func sourceGuard() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { url.deleteLastPathComponent() }
        let root = url.appendingPathComponent("Sources/Jarvis")
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        var offenders: [String] = []
        for case let f as URL in en where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            let name = f.lastPathComponent
            if text.contains("UserDefaults.standard"), !["StorageIsolation.swift", "Preferences.swift", "Log.swift"].contains(name), !text.contains("// storage-isolation: reviewed") { offenders.append("\(name): UserDefaults.standard") }
            if text.contains("Preferences(defaults: .standard)") { offenders.append("\(name): Preferences(defaults: .standard)") }
            if name.hasSuffix("LiveTest.swift") || name == "AppDelegate.swift", text.contains("JarvisPaths.standard().root.appendingPathComponent(\"live-test") { offenders.append("\(name): live-test data under the production folder") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
