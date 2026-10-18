import Foundation
import Testing
@testable import Jarvis

// V1.0 reliability pass — project discovery (bounded, read-only, explicit roots, candidates are not registrations) and exact alias resolution (fuzzy only suggests). Real temporary folders only: the
// user's projects are never an automated target and no project name is hard-coded in the code under test.

private func makeTree(_ build: (String) throws -> Void) throws -> String {
    let root = NSTemporaryDirectory() + "jarvis-discovery-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    try build(root)
    return root
}
private func dir(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
private func file(_ path: String, _ text: String = "x") throws {
    try dir((path as NSString).deletingLastPathComponent)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

@Suite("V1.0 reliability · project discovery")
struct ProjectDiscoveryTests {
    private func home() -> String { NSTemporaryDirectory() + "no-such-home" }

    @Test("Unity, Xcode, SwiftPM and Git folders are found by their markers; plain folders are not")
    func markers() throws {
        let root = try makeTree { r in
            try file(r + "/GameOne/ProjectSettings/ProjectVersion.txt"); try dir(r + "/GameOne/Assets")
            try dir(r + "/ToolTwo/ToolTwo.xcodeproj")
            try file(r + "/PackThree/Package.swift")
            try dir(r + "/RepoFour/.git")
            try dir(r + "/Documents/notes")
            try dir(r + "/HalfUnity/Assets")                                    // Assets without ProjectSettings is not a Unity project
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = ProjectDiscovery.scan(roots: [root], home: home())
        let byName = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.folderName, $0) })
        #expect(byName["GameOne"]?.kind == .unity && byName["GameOne"]?.verified == true && byName["GameOne"]?.markers.contains("ProjectSettings/ProjectVersion.txt") == true)
        #expect(byName["ToolTwo"]?.kind == .xcode && byName["PackThree"]?.kind == .swiftPackage && byName["RepoFour"]?.kind == .git)
        #expect(byName["Documents"] == nil && byName["HalfUnity"] == nil)
        #expect(!report.truncated && report.refusedRoots.isEmpty)
    }

    @Test("a candidate is not a registration; the registry only marks it, and nothing is written")
    func candidatesAreNotRegistered() throws {
        let root = try makeTree { r in try file(r + "/GameOne/ProjectSettings/ProjectVersion.txt"); try dir(r + "/GameOne/Assets"); try dir(r + "/Other/.git") }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let seen = Date(timeIntervalSince1970: 123)
        let report = ProjectDiscovery.scan(roots: [root], registered: [root + "/GameOne": seen], home: home())
        #expect(report.candidates.first { $0.folderName == "GameOne" }?.registered == true && report.candidates.first { $0.folderName == "GameOne" }?.lastOpened == seen)
        #expect(report.candidates.first { $0.folderName == "Other" }?.registered == false)
        #expect(FileManager.default.fileExists(atPath: root + "/GameOne/jarvis.json") == false)
    }

    @Test("a project's own subfolders are not separate projects, build / cache / hidden folders are skipped, symlinks are not followed")
    func boundaries() throws {
        let root = try makeTree { r in
            try file(r + "/Outer/Package.swift"); try dir(r + "/Outer/Sub/.git")
            try dir(r + "/node_modules/pkg/.git"); try dir(r + "/.hidden/Proj/.git"); try dir(r + "/Library/Proj/.git")
            try dir(r + "/Real/.git")
            try FileManager.default.createSymbolicLink(atPath: r + "/Link", withDestinationPath: r + "/Real")
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let names = Set(ProjectDiscovery.scan(roots: [root], home: home()).candidates.map(\.folderName))
        #expect(names == ["Outer", "Real"], "\(names)")
    }

    @Test("budgets: depth, directories and candidates are bounded and the report says when it stopped early")
    func budgets() throws {
        let root = try makeTree { r in for i in 0..<30 { try dir(r + "/p\(i)/.git") } ; try dir(r + "/a/b/c/d/Deep/.git") }
        defer { try? FileManager.default.removeItem(atPath: root) }
        var limits = DiscoveryLimits(); limits.maxCandidates = 10
        let capped = ProjectDiscovery.scan(roots: [root], limits: limits, home: home())
        #expect(capped.candidates.count == 10 && capped.truncated)
        var shallow = DiscoveryLimits(); shallow.maxDepth = 1; shallow.maxCandidates = 100
        #expect(!ProjectDiscovery.scan(roots: [root], limits: shallow, home: home()).candidates.contains { $0.folderName == "Deep" })
        var tiny = DiscoveryLimits(); tiny.maxDirectories = 3
        #expect(ProjectDiscovery.scan(roots: [root], limits: tiny, home: home()).truncated)
    }

    @Test("roots that are not 'a place the user keeps projects' are refused: /, the home folder itself, system folders, relative paths")
    func refusedRoots() {
        let h = "/Users/someone"
        for r in ["/", "/Users/someone", "/System", "/Library/Foo", "/usr/local", "/private", "/var", "/tmp", "relative/path", "/Applications"] { #expect(ProjectDiscovery.isRefusedRoot(r, home: h), r) }
        #expect(!ProjectDiscovery.isRefusedRoot("/Users/someone/Projects", home: h))
        #expect(!ProjectDiscovery.isRefusedRoot("/var/folders/ab/cd/T/work", home: h), "a per-user temp folder is a legitimate root")
        let report = ProjectDiscovery.scan(roots: ["/", "/nonexistent-dir-\(UUID().uuidString)"], home: h)
        #expect(report.refusedRoots == ["/"] && report.missingRoots.count == 1 && report.candidates.isEmpty)
    }

    @Test("suggested aliases come from the folder's own name and are suggestions only; no name is hard-coded")
    func aliases() {
        #expect(ProjectDiscovery.suggestedAliases(forFolder: "TurkishHammamSimulator") == ["Turkish Hammam Simulator"])
        #expect(ProjectDiscovery.suggestedAliases(forFolder: "hammam-sim") == ["hammam sim"])
        #expect(ProjectDiscovery.suggestedAliases(forFolder: "Arena").isEmpty)
        #expect(ProjectDiscovery.suggestedAliases(forFolder: "My_Project 2") == ["My Project 2"])
    }
}

@Suite("V1.0 reliability · exact alias resolution")
struct AliasResolutionTests {
    private let entries = [AliasEntry(key: "a", name: "Hamam", aliases: ["Turkish Hammam Simulator"]), AliasEntry(key: "b", name: "Arena", aliases: []), AliasEntry(key: "c", name: "Arena Two", aliases: ["arena"])]

    @Test("exact name or alias plus a closed suffix chain resolves; nothing else does")
    func exact() {
        #expect(ProjectAliasResolver.resolve(spoken: "Hamamı", among: entries) == .exact("a"))
        #expect(ProjectAliasResolver.resolve(spoken: "hamamda", among: entries) == .exact("a"))
        #expect(ProjectAliasResolver.resolve(spoken: "Turkish Hammam Simulator", among: entries) == .exact("a"))
        if case .exact = ProjectAliasResolver.resolve(spoken: "ham", among: entries) { Issue.record("no prefix guessing") }
        if case .exact = ProjectAliasResolver.resolve(spoken: "Hammam", among: entries) { Issue.record("a different spelling is not an alias") }
    }

    @Test("a collision asks")
    func collisions() {
        #expect(ProjectAliasResolver.resolve(spoken: "Arena", among: entries) == .ambiguous(["b", "c"]))
    }

    @Test("a near miss is a suggestion for a question, never a match; short words suggest nothing")
    func suggestions() {
        if case .none(let s) = ProjectAliasResolver.resolve(spoken: "Hammam", among: entries) { #expect(s == ["Hamam"]) } else { Issue.record("a near miss must not resolve") }
        if case .none(let s) = ProjectAliasResolver.resolve(spoken: "Hamamm", among: entries) { #expect(s.contains("Hamam")) } else { Issue.record("a near miss must not resolve") }
        if case .none(let s) = ProjectAliasResolver.resolve(spoken: "xyz", among: entries) { #expect(s.isEmpty) } else { Issue.record("expected none") }
        #expect(ProjectAliasResolver.distance("kitten", "sitting") == 3 && ProjectAliasResolver.distance("", "ab") == 2)
    }

    @Test("the planner turns a near miss into a question and still opens nothing")
    func plannerHint() {
        var f = DecisionFacts(language: .en, source: .typed, voice: VoiceStatusFacts(voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeRunning: false, microphone: .unknown, recogniserReady: true, heardViaVoice: false))
        f.projects = [KnownProject(key: "k", name: "Hamam", rootPath: "/tmp", kind: "unity", lastSeen: Date())]
        f.pathExists = { _ in true }; f.isKind = { _, _ in false }
        let d = Decision(intent: .projectOpen, confidence: 0.95, normalized: "", target: "hammam", action: "open", execution: true, projectResolution: true)
        guard case .answer(let text, _) = DecisionPlanner.plan(d, text: "Open the Hammam project", facts: f) else { Issue.record("a near miss must answer, not open"); return }
        #expect(text.contains("Did you mean Hamam"))
    }
}
