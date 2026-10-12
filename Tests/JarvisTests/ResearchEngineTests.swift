import Testing
import Foundation
@testable import Jarvis

private func hit(_ title: String, _ url: String, _ snippet: String = "", rank: Int = 1, provider: String = "duckduckgo-html") -> WebSearchHit { WebSearchHit(title: title, url: url, snippet: snippet, provider: provider, rank: rank) }

@MainActor
private struct Rig {
    let h: TaskHarness
    let env: ResearchFixtureEnv
    let web: ResearchServices

    init(hits: @escaping @Sendable (String) -> [WebSearchHit], model: ((AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) throws {
        h = TaskHarness(script: model ?? { _, _ in .fail(.generic) })        // no model unless a test supplies one: the research must work without
        env = try ResearchFixtureEnv()
        web = ResearchServices(client: env.client, providers: [FixtureSearchProvider(id: "duckduckgo-html", results: hits)], persistence: SQLiteResearchPersistence(repository: h.repo, artifacts: h.artifacts), paths: h.paths)
        h.engine.web = web
    }

    func run(_ goal: String) async -> TaskView {
        let req = ResearchIntake.parse(goal: goal)
        guard case .success(let id) = await h.engine.submitResearch(req) else { fatalError("submit") }
        await h.engine.waitUntilFinished(id)
        return h.engine.view(id)!
    }
}

private let docHits: @Sendable (String) -> [WebSearchHit] = { _ in [hit("Manual", "https://docs.unity3d.com/docs/boxcollider"), hit("Thread", "https://discussions.unity.com/community/thread1", rank: 2)] }
private let assetHits: @Sendable (String) -> [WebSearchHit] = { _ in [hit("Free Throw Pack", "https://kenney.nl/asset/free-throw", "throw pack"), hit("Paid Throw Pack", "https://assetstore.unity.com/asset/paid-throw", "FREE!! download now", rank: 2)] }

@MainActor
@Suite("Research · tasks on the V0.4 engine", .serialized)
struct ResearchTaskTests {
    @Test func aResearchGoalBecomesAnOrdinaryTaskWithOnlyTheWebCapability() async throws {
        let r = try Rig(hits: docHits)
        let v = await r.run("research unity BoxCollider documentation and community workarounds")
        #expect(v.task.kind == .research && v.task.state == .completed && v.task.category == .research)
        #expect(v.task.capabilities.granted == [.researchWeb])
        #expect(!v.task.capabilities.allows(.readProject) && !v.task.capabilities.allows(.writeProject) && !v.task.capabilities.allows(.downloadToQuarantine) && !v.task.capabilities.allows(.importIntoProject))
        #expect(v.steps.map(\.type) == [.researchSearch, .researchRead, .researchExtract, .researchReport] && v.steps.allSatisfy { $0.state == .passed && ($0.validationEvidence ?? "").count > 5 })
        #expect(v.task.workspaceRoot?.hasSuffix("research-workspace") == true)
        #expect(r.h.fileChanges(v.id).isEmpty)                                                  // research changes nothing on disk
        #expect(r.h.engine.researchSummary(for: v)?.contains("Research finished") == true)
        #expect(r.h.persistedActiveLeases == 0)
    }

    @Test func everythingResearchedIsPersistedWithProvenanceAndAReport() async throws {
        let r = try Rig(hits: docHits)
        let v = await r.run("research unity BoxCollider documentation and community workarounds")
        let session = try #require(try r.h.repo.researchSession(v.id))
        #expect(session.status == .completed && session.reportArtifactID != nil && session.markdownArtifactID != nil)
        let sources = try r.h.repo.researchSources(v.id)
        #expect(sources.filter { $0.method != .searchSnippet }.count == 2 && sources.allSatisfy { !$0.url.isEmpty && !$0.domain.isEmpty })
        let read = sources.first { $0.domain == "docs.unity3d.com" && $0.method == .http }
        #expect(read?.official == .official && read?.contentHash?.count == 64 && read?.httpStatus == 200 && read?.title.contains("BoxCollider") == true)
        #expect(try r.h.repo.researchQueries(v.id).count >= 1)
        let mdID = try #require(session.markdownArtifactID)
        let mdArtifact = try #require(try r.h.artifacts.artifact(mdID))
        let md = String(decoding: try r.h.artifacts.read(mdArtifact), as: UTF8.self)
        #expect(md.contains("## Sources") && md.contains("docs.unity3d.com") && md.contains("retrieved") && md.contains("## Searched"))
        // no page body is stored anywhere: only bounded excerpts
        #expect(sources.allSatisfy { $0.excerpt.count <= 520 })
        let dbText = try String(contentsOf: r.h.paths.database, encoding: .isoLatin1)
        #expect(!dbText.contains("A box-shaped primitive collider. The BoxCollider component is a basic cube-shaped collision primitive. Use Physics.IgnoreCollision to ignore pairs."))
    }

    @Test func aModelThatIsAvailableIsUsedForFactsAndItsInventionsAreDropped() async throws {
        let seen = Box<[String]>([])
        let r = try Rig(hits: docHits, model: { job, _ in
            seen.value.append(job.type + ":" + job.title)
            guard job.type == "ResearchAgent" else { return .fail(.generic) }
            if job.title.contains("queryPlanning") { return .text("{\"queries\": [\"unity boxcollider documentation\", \"boxcollider scaled child workaround\"]}") }
            return .text("{\"candidates\": [], \"claims\": [{\"subject\":\"BoxCollider\",\"kind\":\"workaround\",\"statement\":\"Use continuous detection.\",\"source\":\"S2\",\"excerpt\":\"set the Rigidbody to continuous collision detection\",\"community_reported\":true},{\"subject\":\"BoxCollider\",\"kind\":\"apiBehavior\",\"statement\":\"Invented fact.\",\"source\":\"S1\",\"excerpt\":\"this sentence is not on the page at all\"}], \"instruction_attempts\": []}")
        })
        let v = await r.run("research why unity BoxCollider is not colliding on a scaled child, error and workarounds")
        #expect(v.task.state == .completed)
        #expect(seen.value.contains { $0.contains("queryPlanning") } && seen.value.contains { $0.contains("extraction") })
        let claims = try r.h.repo.researchClaims(v.id)
        #expect(claims.contains { $0.statement.contains("continuous detection") } && !claims.contains { $0.statement.contains("Invented") })
        #expect(r.h.runner.jobs("ResearchAgent").allSatisfy { $0.job.prompt.contains("SECURITY RULES") || $0.job.title.contains("queryPlanning") })
        #expect(r.h.runner.jobs("PlannerAgent").isEmpty)                                          // research plans are deterministic: no model plans them
    }

    @Test func assetResearchEndsWithVerifiedCandidatesAndARankedRecommendation() async throws {
        let r = try Rig(hits: assetHits)
        let v = await r.run("find a free commercial throw animation for our game")
        #expect(v.task.state == .completed && v.steps.map(\.type) == [.researchSearch, .researchRead, .researchExtract, .researchVerify, .researchReport])
        let cands = try r.h.repo.researchCandidates(v.id)
        let free = try #require(cands.first { $0.name.contains("Free Throw") })
        #expect(free.verdict == .preferred && free.price.state == .freeVerified && free.license.state == .permissive && free.rank == 1)
        #expect(cands.first { $0.name.contains("Paid") }?.verdict == .notRecommended)
        let claims = try r.h.repo.researchClaims(v.id)
        #expect(claims.filter { $0.kind == .price }.count == 2 && claims.filter { $0.kind == .price && $0.status == .verified }.allSatisfy { !$0.evidence.isEmpty })
        // research proposes an acquisition but performs none
        #expect(try r.h.repo.acquisitions(limit: 10).isEmpty)
        #expect(try r.h.repo.engineTasks(limit: 20).filter { $0.kind == .acquisition }.isEmpty)
    }

    @Test func stoppingAResearchTaskStopsItAndLeavesAnHonestPartialRecord() async throws {
        let hits: @Sendable (String) -> [WebSearchHit] = { _ in (0..<5).map { hit("Slow \($0)", "https://docs.unity3d.com/slow/page?n=\($0)", rank: $0 + 1) } }
        let r = try Rig(hits: hits)
        let req = ResearchIntake.parse(goal: "research unity documentation boxcollider")
        guard case .success(let id) = await r.h.engine.submitResearch(req) else { Issue.record("submit"); return }
        _ = await r.h.waitUntil(8) { r.h.engine.view(id)?.steps.contains { $0.type == .researchRead && $0.state == .running } == true }
        let t0 = Date(); r.h.engine.cancel(id)
        await r.h.engine.waitUntilFinished(id)
        #expect(Date().timeIntervalSince(t0) < 5)
        let v = try #require(r.h.engine.view(id))
        #expect(v.task.state == .cancelled)
        #expect(!v.steps.contains { $0.state == .running || $0.state == .verifying })
        #expect(try r.h.repo.researchSession(id)?.status != .completed)
    }

    @Test func aRestartInterruptsResearchAndOnlyAnExplicitResumeContinuesIt() async throws {
        let slow: @Sendable (String) -> [WebSearchHit] = { _ in [hit("Slow", "https://docs.unity3d.com/slow/page?n=1"), hit("Doc", "https://docs.unity3d.com/docs/boxcollider", rank: 2)] }
        let r = try Rig(hits: slow)
        let req = ResearchIntake.parse(goal: "research unity documentation boxcollider")
        guard case .success(let id) = await r.h.engine.submitResearch(req) else { Issue.record("submit"); return }
        _ = await r.h.waitUntil(8) { r.h.engine.view(id)?.steps.contains { $0.type == .researchRead && $0.state == .running } == true }
        r.h.engine.contexts[id]?.terminating = true                                              // "kill -9": the old process writes nothing more
        r.h.engine.cancelAllRunnersForTests()
        await r.h.engine.waitUntilIdle()
        r.h.restart()
        let web2 = ResearchServices(client: r.env.client, providers: [FixtureSearchProvider(id: "duckduckgo-html", results: slow)], persistence: SQLiteResearchPersistence(repository: r.h.repo, artifacts: r.h.artifacts), paths: r.h.paths)
        r.h.engine.web = web2
        _ = try r.h.repo.reconcileResearchAfterRestart()
        #expect(r.h.task(id).state == .interrupted)
        #expect(try r.h.repo.researchSession(id)?.status == .interrupted)
        #expect(r.h.engine.activeCount == 0)                                                      // nothing resumed by itself
        #expect(r.env.transport.log.filter { $0.contains("slow/page") }.count <= 2)
        #expect(r.h.engine.resume(id))
        await r.h.engine.waitUntilFinished(id)
        #expect(r.h.engine.view(id)?.task.state == .completed)
    }

    @Test func researchIsRefusedTruthfullyWhenTheServicesAreMissing() async throws {
        let h = TaskHarness()
        let res = await h.engine.submitResearch(ResearchIntake.parse(goal: "research something"))
        if case .failure(let e) = res { #expect(e.description.contains("not available")) } else { Issue.record("no services → no task") }
    }

    @Test func offlineAndBlockedWebsAreReportedNotInvented() async throws {
        let r = try Rig(hits: { _ in [hit("Gone", "https://docs.unity3d.com/does-not-exist"), hit("Private", "http://192.168.1.10/admin")] })
        let v = await r.run("research unity documentation boxcollider")
        #expect(v.task.state == .failed)
        let failed = v.steps.first { $0.state == .failed }
        #expect(failed?.type == .researchRead || failed?.type == .researchSearch)
        #expect(["no readable sources", "blocked by the network policy", "tool failed"].contains(v.task.failureCategory?.label ?? ""))
        #expect(!r.env.transport.log.contains { $0.contains("192.168") })
    }

    @Test func theResearchPlansAreSoundDagsWithinTheStepLimit() {
        for type in ResearchType.allCases {
            var req = ResearchIntake.parse(goal: "x"); req.type = type
            let plan = ResearchPlanner.plan(for: req)
            #expect(plan.steps.count <= PlanValidator.maxSteps && PlanValidator.findCycle(plan.steps) == nil && plan.steps.first?.dependsOn.isEmpty == true)
            #expect(plan.steps.allSatisfy { $0.type.isResearch && $0.validation == .default(for: $0.type) })
        }
    }

    @Test func webAndImportAuthorityIsSeparatedInTheCapabilityModel() {
        #expect(CapabilitySet.for(.research).granted == [.researchWeb] && CapabilitySet.for(.acquisition).granted == [.researchWeb, .downloadToQuarantine])
        #expect(!CapabilitySet.development.allows(.importIntoProject) && !CapabilitySet.development.allows(.researchWeb) && !CapabilitySet.development.allows(.downloadToQuarantine))
        #expect(!StepType.importAsset.requiredCapabilities.isSubset(of: CapabilitySet.development.granted))
        for c in [TaskCapability.useNetwork, .useBrowser, .purchase, .gitCommit, .gitPush] { #expect(!CapabilitySet(granted: [c]).allows(c)) }
        #expect(AuthorityLevel.research < AuthorityLevel.acquisition && AuthorityLevel.acquisition < AuthorityLevel.projectImport && !AuthorityLevel.accountAction.isImplemented && !AuthorityLevel.commercial.isImplemented)
        #expect(AcquisitionClass.paidPurchase.requiredAuthority == .commercial && AcquisitionClass.accountRequiredFree.requiredAuthority == .accountAction && AcquisitionClass.publicDirectDownload.requiredAuthority == .acquisition)
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var _v: T
    init(_ v: T) { _v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _v } set { lock.lock(); _v = newValue; lock.unlock() } }
}

@MainActor
@Suite("Acquisition · tasks on the V0.4 engine", .serialized)
struct AcquisitionTaskTests {
    private func candidate(license: LicenseAssessment? = nil, acq: AcquisitionClass = .publicDirectDownload, url: String = "https://kenney.nl/files/good.zip", price: PriceState = .freeVerified, listing: String = "https://kenney.nl/asset/free-throw") -> CandidateRecord {
        var c = CandidateRecord(researchID: UUID(), name: "Free Throw Pack", url: listing)
        c.price = PriceAssessment(state: price, amount: 0, currency: "USD", evidence: [], verifiedAt: Date(), note: nil)
        c.license = license ?? LicenseAssessment(state: .permissive, identifier: "MIT", commercialUse: .yes, modification: .yes, redistribution: .yes, attribution: .yes, evidence: [], needsReview: false, note: nil)
        c.acquisition = acq; c.downloadURL = url; c.accountRequired = acq == .publicDirectDownload ? .no : .yes; c.sourceTrust = 5; c.kind = .animation
        return c
    }

    private func submit(_ r: Rig, _ c: CandidateRecord, approved: Bool = false) async -> UUID {
        guard case .success(let id) = await r.h.engine.submitAcquisition(candidate: c, request: nil, approved: approved) else { fatalError("submit") }
        return id
    }

    @Test func aVerifiedFreeArtifactIsQuarantinedAndNeverImported() async throws {
        let r = try Rig(hits: { _ in [] })
        let c = candidate()
        // the listing must say what the candidate says, because the engine re-verifies price and licence NOW
        let id = await submit(r, c)
        await r.h.engine.waitUntilFinished(id)
        let v = try #require(r.h.engine.view(id))
        #expect(v.task.kind == .acquisition && v.task.capabilities.granted == [.researchWeb, .downloadToQuarantine])
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        let rec = try #require(try r.h.repo.acquisition(id))
        #expect(rec.state == .readyForImport && rec.sha256?.count == 64 && rec.finalHost == "kenney.nl" && rec.priceState == .freeVerified && rec.importedTo == nil)
        #expect(rec.quarantinePath?.hasPrefix(id.uuidString.lowercased()) == true)
        #expect(FileManager.default.fileExists(atPath: r.h.paths.acquisitions.appendingPathComponent(rec.quarantinePath!).path))
        #expect(r.h.fileChanges(id).isEmpty)                                                      // no project file exists or changed
    }

    @Test func anUnknownLicenceWaitsForTheUserAndAnApprovalDoesNotGrantMore() async throws {
        let r = try Rig(hits: { _ in [] })
        let id = await submit(r, candidate(license: .unknown, listing: "https://kenney.nl/asset/unknown-license"))
        #expect(await r.h.waitUntil(10) { !r.h.engine.pendingApprovals.isEmpty })
        let approval = try #require(r.h.engine.pendingApprovals.first)
        #expect(approval.action.contains("quarantine") && approval.reason.contains("No payment") && approval.reason.contains("nothing is imported"))
        #expect(r.h.engine.decide(approval.id, approved: true))
        await r.h.engine.waitUntilFinished(id)
        let rec = try #require(try r.h.repo.acquisition(id))
        #expect(rec.state == .readyForImport && r.h.engine.view(id)?.task.state == .completed)
        // the approval covered ONE download into the quarantine: still no import, no project change
        #expect(rec.importedTo == nil && r.h.fileChanges(id).isEmpty)
    }

    @Test func aDeniedDownloadFetchesNothing() async throws {
        let r = try Rig(hits: { _ in [] })
        let id = await submit(r, candidate(license: .unknown, listing: "https://kenney.nl/asset/unknown-license"))
        _ = await r.h.waitUntil(10) { !r.h.engine.pendingApprovals.isEmpty }
        r.h.engine.decide(try #require(r.h.engine.pendingApprovals.first).id, approved: false)
        await r.h.engine.waitUntilFinished(id)
        #expect(r.h.engine.view(id)?.task.state == .failed && r.h.engine.view(id)?.task.failureCategory == .approvalDenied)
        #expect(!r.env.transport.log.contains { $0.contains("/files/") })
        #expect(try r.h.repo.acquisition(id)?.sha256 == nil)
    }

    @Test func accountBoundPaidAndStaleListingsAreRefusedNotAutomated() async throws {
        let r = try Rig(hits: { _ in [] })
        for c in [candidate(acq: .accountRequiredFree), candidate(acq: .paidPurchase), candidate(acq: .marketplaceClaim)] {
            let id = await submit(r, c, approved: true)                                           // even a pre-approval cannot unlock an account or a payment
            await r.h.engine.waitUntilFinished(id)
            #expect(r.h.engine.view(id)?.task.state == .failed && r.h.engine.view(id)?.task.failureCategory == .acquisitionRefused)
            #expect(try r.h.repo.acquisition(id)?.state == .rejected)
        }
        #expect(!r.env.transport.log.contains { $0.contains("/files/") })
        // a listing that now says PAID overrides an old "free" claim: the engine re-verified it
        let paidNow = candidate()
        var c2 = paidNow; c2.url = "https://assetstore.unity.com/asset/paid-throw"
        let id = await submit(r, c2)
        await r.h.engine.waitUntilFinished(id)
        #expect(r.h.engine.view(id)?.task.state == .failed)
        #expect(!r.env.transport.log.contains { $0.contains("/files/good.zip") })
    }

    @Test func aHostileArtifactIsRejectedAndLeavesNothingBehind() async throws {
        let r = try Rig(hits: { _ in [] })
        let id = await submit(r, candidate(url: "https://kenney.nl/files/traversal.zip"))
        await r.h.engine.waitUntilFinished(id)
        let rec = try #require(try r.h.repo.acquisition(id))
        #expect(rec.state == .rejected && rec.trust == .rejected && (rec.failure ?? "").contains("traversal"))
        #expect(r.h.engine.view(id)?.task.state == .failed)
        let dir = r.web.acquisition.quarantineDirectory(id)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "provenance.json" }.isEmpty)
    }

    @Test func cancellingADownloadTaskLeavesNoValidArtifact() async throws {
        let r = try Rig(hits: { _ in [] })
        var c = candidate(url: "https://kenney.nl/files/slow.bin")
        c.name = "Slow thing"
        let id = await submit(r, c, approved: true)
        _ = await r.h.waitUntil(10) { r.h.engine.view(id)?.task.activity.contains("Downloading") == true }
        r.h.engine.cancel(id)
        await r.h.engine.waitUntilFinished(id)
        #expect(r.h.engine.view(id)?.task.state == .cancelled)
        let rec = try? r.h.repo.acquisition(id)
        #expect(rec?.state != .readyForImport && rec?.sha256 == nil)
        let dir = r.web.acquisition.quarantineDirectory(id)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "provenance.json" }.isEmpty)
    }
}

@MainActor
@Suite("Import · a normal V0.4 development task", .serialized)
struct ImportTaskTests {
    private func readyArtifact(_ r: Rig, zip: Data = ResearchFixtureSite.goodZip()) async throws -> AcquisitionRecord {
        var c = CandidateRecord(researchID: UUID(), name: "Kitchen Props", url: "https://kenney.nl/asset/free-throw")
        c.price = PriceAssessment(state: .freeVerified, amount: 0, currency: "USD", evidence: [], verifiedAt: Date(), note: nil)
        c.license = LicenseAssessment(state: .permissive, identifier: "CC0-1.0", commercialUse: .yes, modification: .yes, redistribution: .yes, attribution: .no, evidence: [], needsReview: false, note: nil)
        c.acquisition = .publicDirectDownload; c.downloadURL = "https://kenney.nl/files/good.zip"; c.sourceTrust = 5; c.accountRequired = .no
        let rec = await r.web.acquisition.acquire(c, researchID: nil, taskID: nil, approved: false)
        try #require(rec.state == .readyForImport)
        return rec
    }

    private func unityProject() throws -> String {
        let root = NSTemporaryDirectory() + "unityproj-\(UUID().uuidString)"
        for d in ["Assets", "ProjectSettings", "Packages"] { try FileManager.default.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
        try "m_EditorVersion: 6000.0.23f1\n".write(toFile: root + "/ProjectSettings/ProjectVersion.txt", atomically: true, encoding: .utf8)
        try "{\"dependencies\":{\"com.unity.render-pipelines.universal\":\"17.0.3\"}}".write(toFile: root + "/Packages/manifest.json", atomically: true, encoding: .utf8)
        return root
    }

    @Test func importNeedsItsOwnApprovalAndCopiesOnlyTheInspectedFiles() async throws {
        let r = try Rig(hits: { _ in [] })
        let rec = try await readyArtifact(r)
        let project = try unityProject()
        guard case .success(let id) = await r.h.engine.submitImport(rec, projectRoot: project) else { Issue.record("submit"); return }
        #expect(await r.h.waitUntil(10) { !r.h.engine.pendingApprovals.isEmpty })
        let a = try #require(r.h.engine.pendingApprovals.first)
        #expect(a.action.contains("Assets/ThirdParty/Kitchen-Props-") && a.reason.contains("licence CC0-1.0") && a.reason.contains("Nothing is executed") && a.risk == .high)
        // nothing is in the project yet
        #expect(!FileManager.default.fileExists(atPath: project + "/Assets/ThirdParty"))
        #expect(r.h.engine.decide(a.id, approved: true))
        await r.h.engine.waitUntilFinished(id)
        let dest = try #require(try FileManager.default.contentsOfDirectory(atPath: project + "/Assets/ThirdParty").first)
        #expect(FileManager.default.fileExists(atPath: project + "/Assets/ThirdParty/\(dest)/Throw/throw_a.fbx") && FileManager.default.fileExists(atPath: project + "/Assets/ThirdParty/\(dest)/JARVIS-PROVENANCE.json"))
        let steps = r.h.steps(id)
        #expect(steps.first?.type == .importAsset && steps.first?.state == .passed)
        #expect(r.h.fileChanges(id).count >= 3 && r.h.fileChanges(id).allSatisfy { $0.changeType == "created" && $0.afterHash != nil })
        #expect(try r.h.repo.acquisition(rec.id)?.importedTo?.hasPrefix("Assets/ThirdParty/") == true)
        // the unityCompile step belongs to V0.6; here it fails truthfully because no editor is connected
        #expect(steps.contains { $0.type == .unityCompile })
    }

    @Test func aDeniedImportWritesNothingIntoTheProject() async throws {
        let r = try Rig(hits: { _ in [] })
        let rec = try await readyArtifact(r)
        let project = try unityProject()
        guard case .success(let id) = await r.h.engine.submitImport(rec, projectRoot: project) else { Issue.record("submit"); return }
        _ = await r.h.waitUntil(10) { !r.h.engine.pendingApprovals.isEmpty }
        r.h.engine.decide(try #require(r.h.engine.pendingApprovals.first).id, approved: false)
        await r.h.engine.waitUntilFinished(id)
        #expect(r.h.engine.view(id)?.task.state == .failed && r.h.engine.view(id)?.task.failureCategory == .approvalDenied)
        #expect(!FileManager.default.fileExists(atPath: project + "/Assets/ThirdParty"))
    }

    @Test func aTamperedQuarantineFileIsNeverImported() async throws {
        let r = try Rig(hits: { _ in [] })
        let rec = try await readyArtifact(r)
        try Data("tampered".utf8).write(to: r.h.paths.acquisitions.appendingPathComponent(rec.quarantinePath!))
        let project = try unityProject()
        guard case .success(let id) = await r.h.engine.submitImport(rec, projectRoot: project) else { Issue.record("submit"); return }
        await r.h.engine.waitUntilFinished(id)
        #expect(r.h.engine.view(id)?.task.state == .failed && r.h.engine.view(id)?.task.failureCategory == .securityBlocked)
        #expect(r.h.engine.pendingApprovals.isEmpty && !FileManager.default.fileExists(atPath: project + "/Assets/ThirdParty"))
    }

    @Test func onlyReadyArtifactsCanBeSubmittedForImport() async throws {
        let r = try Rig(hits: { _ in [] })
        var rec = try await readyArtifact(r)
        rec.state = .rejected
        if case .failure(let e) = await r.h.engine.submitImport(rec, projectRoot: try unityProject()) { #expect(e.description.contains("not ready")) } else { Issue.record("a rejected artifact must not be importable") }
    }
}

@MainActor
@Suite("Research · V0.5 proposals", .serialized)
struct ResearchProposalTests {
    private func assessment(_ caps: Set<TaskCapability>) -> OpportunityAssessment {
        OpportunityAssessment(relevance: 0.9, confidence: 0.9, scopeSize: .small, affectedFileCount: 0, relation: .direct, risk: .low, reversibility: .reversible, destructiveness: .none, designImpact: .none,
                              externalEffects: [], requiredCapabilities: caps, evidenceStrength: .strong)
    }

    @Test func webResearchIsProposedNeverAutomaticInAnyMode() {
        for mode in AutonomyMode.allCases {
            var ctx = PolicyContext(mode: mode); ctx.originIsUserTask = true
            let out = OpportunityPolicy.decide(assessment([.researchWeb]), category: .maintenance, context: ctx)
            #expect(out.decision != .autoAction, "mode \(mode): \(out.reasons)")
            #expect(mode == .observeOnly ? out.decision == .record : out.decision == .propose)
        }
    }

    @Test func acquisitionAndImportAreAlwaysASeparateUserDecision() {
        for caps in [Set<TaskCapability>([.downloadToQuarantine]), [.importIntoProject], [.researchWeb, .downloadToQuarantine]] {
            let out = OpportunityPolicy.decide(assessment(caps), category: .maintenance, context: PolicyContext(mode: .lowRiskAutonomous))
            #expect(out.decision == .requireApproval && out.reasons.contains("separateDecisionRequired"))
        }
        #expect(!OpportunityPolicy.autoCapabilities.contains(.researchWeb) && !OpportunityPolicy.autoCapabilities.contains(.downloadToQuarantine))
    }

    @Test func anApprovedResearchProposalStartsAnOrdinaryReadOnlyResearchTask() async throws {
        let project = TaskFixtures.calculatorProject()
        let h = ProactiveHarness(mode: .lowRiskAutonomous, script: { _, _ in .fail(.generic) })
        let env = try ResearchFixtureEnv()
        h.engine.web = ResearchServices(client: env.client, providers: [FixtureSearchProvider(id: "duckduckgo-html") { _ in [hit("Manual", "https://docs.unity3d.com/docs/boxcollider")] }], persistence: SQLiteResearchPersistence(repository: h.repo, artifacts: h.base.artifacts), paths: h.base.paths)
        let r = await h.opportunities.proposeResearch(goal: "research unity BoxCollider documentation", reason: "The projectile code has no documentation reference.", projectRoot: project)
        guard case .proposed(let oppID, let propID) = r else { Issue.record("expected a proposal, got \(r)"); return }
        #expect(h.allTasks().isEmpty, "nothing starts before the user approves — not even in Low-Risk Autonomous mode")
        let prop = try #require(h.proposal(propID))
        #expect(prop.proposedAction.taskKind == .research && !prop.critical)
        #expect(await h.proposals.approve(propID, source: .test) != .notPending)
        await h.settle(5) { !h.allTasks().isEmpty }
        let task = try #require(h.allTasks().first)
        #expect(task.kind == .research && task.origin == .approvedProposal && task.originOpportunityID == oppID && task.capabilities.granted == [.researchWeb])
        await h.engine.waitUntilFinished(task.id)
        #expect(h.engine.view(task.id)?.task.state == .completed)
        #expect(h.allTasks().filter { $0.kind == .acquisition }.isEmpty)
    }
}
