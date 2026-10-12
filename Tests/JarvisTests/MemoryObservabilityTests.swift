import Testing
import Foundation
@testable import Jarvis

@Suite("Memory · observability, restart and diagnostics")
@MainActor
struct MemoryObservabilityTests {
    private func doc(_ type: MemoryType, _ text: String, ref: String = "d") -> MemoryCandidate {
        MemoryCandidate(type: type, subject: String(text.prefix(18)), summary: text, strength: .strong, origin: .document, sources: [MemorySource(kind: .document, ref: ref, label: ref)])
    }

    @Test func everyLifecycleStepLeavesABoundedContentFreeEvent() async throws {
        let r = try MemRig()
        final class Box: @unchecked Sendable { var kinds: [String] = []; var details: [String] = [] }
        let box = Box()
        r.service.onEvent = { e in box.kinds.append(e.kind); box.details.append(e.detail) }
        guard case .created(let id) = r.service.admit(doc(.decision, "Camera architecture must not change without new evidence."), projectKey: r.project) else { return }
        _ = r.service.admit(doc(.decision, "Camera architecture must not change without new evidence.", ref: "d2"), projectKey: r.project)
        _ = r.service.admit(doc(.episode, "ok"), projectKey: r.project)
        _ = r.service.admit(doc(.constraint, "Use key sk-abcdefghijklmnopqrstuvwxyz0123 in the build."), projectKey: r.project)
        _ = try r.service.correct(id, with: "We changed the camera architecture after new evidence appeared")
        try r.service.forget(id)
        for k in ["proposed", "accepted", "merged", "rejected", "corrected", "forgotten"] { #expect(box.kinds.contains(k), "\(k) missing in \(box.kinds)") }
        #expect(box.details.allSatisfy { $0.count <= 240 && !$0.contains("sk-abcdef") })
        let persisted = try r.repo.memoryEvents(projectKey: r.project, limit: 50)
        #expect(!persisted.isEmpty && persisted.allSatisfy { !$0.detail.contains("sk-abcdef") })
    }

    @Test func retrievalAndContextBuildingAreObservable() async throws {
        let rr = try await RetrievalRig(loadCorpus: false)
        _ = rr.rig.service.admit(doc(.decision, "Camera architecture must not change without new evidence."), projectKey: rr.project)
        _ = await rr.rank("camera architecture", semantic: false)
        let builder = ProjectContextBuilder(service: rr.rig.service, retriever: rr.retriever)
        _ = await builder.build(ContextRequest(goal: "edit camera architecture", agent: .coding, projectKey: rr.project, projectRoot: nil))
        let kinds = Set(try rr.rig.repo.memoryEvents(projectKey: rr.project, limit: 100).map(\.kind))
        #expect(kinds.isSuperset(of: ["retrieved", "context"]))
    }

    @Test func theEventLogIsBounded() throws {
        let r = try MemRig()
        for i in 0..<3_040 { try r.repo.insertMemoryEvent(MemoryEvent(projectKey: r.project, kind: "retrieved", memoryID: nil, detail: "event \(i)")) }
        let n = try r.repo.database.readOne("SELECT count(*) AS n FROM memory_events")?.int("n") ?? 0
        #expect(n <= 3_001)
    }

    @Test func aRestartedStackStillKnowsEverythingAndStaysProjectScoped() throws {
        let r = try MemRig()
        _ = r.service.admit(doc(.decision, "Camera architecture must not change without new evidence."), projectKey: r.project)
        _ = r.service.admit(doc(.decision, "Voice recognition uses the local recogniser first."), projectKey: "git:other")
        let reopened = JarvisRepository(database: try JarvisDatabase(url: r.paths.database))
        let mine = try reopened.memories(projectKey: r.project), other = try reopened.memories(projectKey: "git:other")
        #expect(mine.count == 1 && other.count == 1 && mine[0].summary.contains("Camera") && !mine[0].sources.isEmpty)
    }

    @Test func temporalAndWhyQuestionsAreAnsweredFromHistoryAndAdmitMissingReasons() async throws {
        let rr = try await RetrievalRig(loadCorpus: false)
        func fact(_ s: String, ref: String, hint: MemoryStatus? = nil) -> MemoryCandidate { var c = MemoryCandidate(type: .decision, subject: "multiplayer", key: "decision:mp", value: s, summary: s, strength: .strong, area: "multiplayer", origin: .document, sources: [MemorySource(kind: .decisionDoc, ref: ref, label: ref)]); c.statusHint = hint; return c }
        _ = rr.rig.service.admit(fact("Multiplayer used Mirror with a dedicated server before the switch.", ref: "DEC-A"), projectKey: rr.project)
        _ = rr.rig.service.admit(fact("Multiplayer uses Netcode for GameObjects with a host client topology.", ref: "DEC-B"), projectKey: rr.project)
        guard case .question(let q) = MemoryIntentParser.parse("What did we use before NGO for multiplayer?") else { Issue.record("not a question"); return }
        #expect(q.historical)
        let res = await rr.retriever.search(RetrievalRequest(query: q.raw, projectKey: rr.project, mode: .historical, limit: 5, useSemantic: false, intent: q.kind))
        let a = MemoryAnswerer.compose(question: q, result: res, language: .en, projectName: "p")
        #expect(a.text.contains("Mirror") && a.text.contains("superseded") && a.text.contains("Sources:"))
        // a decision without a recorded rationale
        guard case .question(let why) = MemoryIntentParser.parse("Why did we decide on Netcode for GameObjects?") else { Issue.record("not a question"); return }
        let wres = await rr.retriever.search(RetrievalRequest(query: why.raw, projectKey: rr.project, mode: .current, limit: 5, useSemantic: false, intent: why.kind))
        #expect(MemoryAnswerer.compose(question: why, result: wres, language: .en, projectName: "p").text.contains("not a verified reason"))
    }

    @Test func projectPreferencesNeedDurableWordingAndTaskLocalOnesAreNeverStored() throws {
        let r = try MemRig()
        if case .created(let id) = r.service.remember("We prefer a stylized cartoon look for all characters in this project", projectKey: r.project) {
            let m = try #require(try r.repo.memory(id)); #expect(m.type == .preference && m.scope == .project)
        } else { Issue.record("preference not stored") }
        for t in ["Use the faster model for this task", "Just for now skip the long tests", "bu görev için ücretsiz modeli kullan"] { #expect(r.service.remember(t, projectKey: r.project) == .rejected(.taskLocal), "\(t)") }
    }

    @Test func theMemoryScreensReadModelListsFiltersAndActsThroughTheCurator() async throws {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "jarvis-memvm-\(UUID().uuidString)")!)
        let paths = JarvisPaths.temporary("memvm"); try paths.ensureDirectories()
        let repo = JarvisRepository(database: try JarvisDatabase(url: paths.database))
        let memory = ProjectMemory(repository: repo, preferences: prefs, embedding: nil)
        let root = NSTemporaryDirectory() + "jarvis-memvm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        prefs.projectRoot = root
        let project = try #require(await memory.refreshCurrentProject())
        _ = memory.service.admit(doc(.decision, "Camera architecture must not change without new evidence.", ref: "DEC-C"), projectKey: project.key)
        _ = memory.service.admit(doc(.failure, "Voice Processing I/O echo cancellation was rejected: fifteen percent of a core.", ref: "F-V"), projectKey: project.key)
        let vm = MemoryViewModel(memory: memory, preferences: prefs)
        vm.refresh(); try await Task.sleep(for: .milliseconds(300))
        #expect(vm.rows.count == 2 && vm.project?.key == project.key)
        vm.typeFilter = .failure; await vm.reload()
        #expect(vm.rows.count == 1 && vm.rows[0].item.type == .failure)
        vm.typeFilter = nil; vm.query = "camera architecture"; await vm.reload()
        #expect(vm.rows.first?.item.type == .decision && !(vm.rows.first?.reasons.isEmpty ?? true))
        let id = try #require(vm.rows.first?.id)
        vm.selectedID = id
        #expect(vm.detail?.sources.first?.label == "DEC-C")
        vm.pin(id, true); try await Task.sleep(for: .milliseconds(200))
        #expect(try repo.memory(id)?.pinned == true)
        vm.forget(id); try await Task.sleep(for: .milliseconds(300))
        vm.query = ""; vm.statusFilter = .forgotten; await vm.reload()
        #expect(vm.rows.map(\.id) == [id])
        vm.restore(id); try await Task.sleep(for: .milliseconds(300))
        let restored = try repo.memory(id)
        #expect(restored?.status == .current)
        let diag = try #require(await memory.diagnostics())
        #expect(diag.total == 2 && diag.byType[.decision] == 1 && diag.schemaVersion >= 8 && diag.helperState == "NOT CONFIGURED")
    }
}

@Suite("Memory · project identity")
struct MemoryIdentityTests {
    private func git(_ args: [String], in dir: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir); p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }
    private func repo(_ name: String, commitMessage: String = "initial") throws -> String {
        let dir = NSTemporaryDirectory() + "jarvis-ident-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        git(["init", "-q", "-b", "main"], in: dir); git(["add", "-A"], in: dir); git(["commit", "-q", "-m", commitMessage], in: dir)
        return dir
    }

    @Test func gitProjectsAreIdentifiedByTheirRootCommitAcrossMovesAndClones() async throws {
        let a = try repo("a")
        let resolver = ProjectIdentityResolver(repository: nil)
        let first = await resolver.resolve(root: a)
        #expect(first.kind == "git" && first.key.hasPrefix("git:"))
        // a move: same repository, new folder
        let moved = NSTemporaryDirectory() + "jarvis-ident-moved-\(UUID().uuidString)"
        try FileManager.default.moveItem(atPath: a, toPath: moved)
        resolver.forgetCache()
        let after = await resolver.resolve(root: moved)
        #expect(after.key == first.key)
        // a clone shares the identity
        let clone = NSTemporaryDirectory() + "jarvis-ident-clone-\(UUID().uuidString)"
        git(["clone", "-q", moved, clone], in: NSTemporaryDirectory())
        resolver.forgetCache()
        let cloned = await resolver.resolve(root: clone)
        #expect(cloned.key == first.key)
        // an unrelated history never shares it
        let other = try repo("b", commitMessage: "different root")
        let otherKey = await resolver.resolve(root: other).key
        #expect(otherKey != first.key)
    }

    @Test func nonGitFoldersFallBackToTheUnityGuidThenThePath() async throws {
        let unity = NSTemporaryDirectory() + "jarvis-ident-unity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: unity + "/ProjectSettings", withIntermediateDirectories: true)
        try "PlayerSettings:\n  productGUID: 0a1b2c3d4e5f60718293a4b5c6d7e8f9\n".write(toFile: unity + "/ProjectSettings/ProjectSettings.asset", atomically: true, encoding: .utf8)
        let resolver = ProjectIdentityResolver(repository: nil)
        let u = await resolver.resolve(root: unity)
        #expect(u.kind == "unity" && u.key == "unity:0a1b2c3d4e5f60718293a4b5c6d7e8f9")
        let plain = NSTemporaryDirectory() + "jarvis-ident-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let p = await resolver.resolve(root: plain)
        #expect(p.kind == "path" && p.key.hasPrefix("path:"))
    }

    @Test func aMovedProjectKeepsItsPathAliasesInTheRegistry() async throws {
        let paths = JarvisPaths.temporary("ident"); try paths.ensureDirectories()
        let repo = JarvisRepository(database: try JarvisDatabase(url: paths.database))
        let a = try self.repo("c")
        let originalPath = ProjectIdentityResolver.realPath(a)               // as the registry will have recorded it (before the folder disappears)
        let r = ProjectIdentityResolver(repository: repo)
        let key = await r.resolve(root: a).key
        let moved = NSTemporaryDirectory() + "jarvis-ident-moved2-\(UUID().uuidString)"
        try FileManager.default.moveItem(atPath: a, toPath: moved)
        r.forgetCache()
        _ = await r.resolve(root: moved)
        let row = try #require(try repo.memoryProject(key))
        #expect(row.rootPath == ProjectIdentityResolver.realPath(moved) && row.aliases.contains(originalPath))
    }
}
