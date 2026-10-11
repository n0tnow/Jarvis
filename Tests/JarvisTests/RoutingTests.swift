import Testing
import Foundation
@testable import Jarvis

// MARK: - Fixtures

enum RouteFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func freeModel(_ id: String, policy: DataPolicy = .zeroRetention, verifiedAgo: TimeInterval = 60, context: Int? = 200_000) -> ModelRecord {
        var m = ModelRecord(id: "opencode/\(id)", engine: .openCode, provider: "opencode", providerModelID: id, displayName: id)
        m.availability = .available; m.pricingStatus = .verifiedZero; m.inputPrice = 0; m.outputPrice = 0
        m.freeVerified = true; m.freeVerifiedAt = now.addingTimeInterval(-verifiedAgo); m.freeVerificationSource = "test"
        m.dataPolicy = policy; m.contextLimit = context
        return m
    }

    static func summary(_ g: BenchmarkGroup, passed: Int, total: Int, latency: Double = 1000) -> BenchmarkSummary {
        BenchmarkSummary(group: g, total: total, passed: passed, malformed: 0, medianLatencyMS: latency, lastRanAt: now.addingTimeInterval(-3600))
    }

    /// Everything ready, one benchmarked zero-retention free model.
    static func snapshot(_ pref: ProviderPreference = .auto, local: ProviderState = .ready, openCode: ProviderState = .ready,
                         claude: ProviderState = .ready, codex: ProviderState = .ready,
                         models: [ModelRecord]? = nil, benchmarks: [String: [BenchmarkGroup: BenchmarkSummary]]? = nil) -> RouterSnapshot {
        var s = RouterSnapshot()
        s.now = now; s.preference = pref
        s.engines = [.local: EngineAvailability(.local, state: local), .openCode: EngineAvailability(.openCode, state: openCode),
                     .claudeCode: EngineAvailability(.claudeCode, state: claude), .codex: EngineAvailability(.codex, state: codex)]
        s.models = models ?? [freeModel("alpha-free")]
        s.benchmarks = benchmarks ?? ["opencode/alpha-free": [.general: summary(.general, passed: 3, total: 3), .coding: summary(.coding, passed: 4, total: 4),
                                                              .testing: summary(.testing, passed: 3, total: 3), .research: summary(.research, passed: 3, total: 3)]]
        return s
    }

    static func profile(_ prompt: String) -> TaskProfile { TaskClassifier.profile(for: prompt) }
}

// MARK: - Classifier + local policy

@Suite("Task classification and the local-model policy")
struct ClassifierAndLocalPolicyTests {
    @Test(arguments: [
        "hi", "thanks!", "Summarize in one sentence: The cat sat on the mat and then slept.", "Classify this as positive or negative: I love this phone.",
        "Format as JSON: name Bob, age 4", "Extract the names from: Alice met Bob in Paris.", "Merhaba",
    ])
    func lightweightTasksAreLocalEligible(prompt: String) {
        let p = RouteFixtures.profile(prompt)
        #expect(LocalModelPolicy.evaluate(p).eligible, "\(prompt) → \(p.category) \(p.complexity) \(LocalModelPolicy.evaluate(p).violations)")
    }

    @Test(arguments: [
        "Fix my Unity multiplayer system. Run it and keep working until it passes.",
        "Write unit tests for this function:\n```swift\nfunc add(_ a: Int, _ b: Int) -> Int { a + b }\n```",
        "Why is this crashing?\n```csharp\nvar x = player.GetComponent<Rigidbody>();\nx.AddForce(Vector3.up);\n```",
        "Review this code for bugs and suggest improvements", "Refactor NetworkPlayer.cs to use a state machine",
        "Write a Python script that renames all files in a folder", "The failing test says null reference exception in PlayerController.cs",
        "Design the architecture for a scalable multiplayer backend", "Is my OAuth login flow secure? List vulnerabilities.",
        "Explain how neural networks work.", "Edit the file Package.swift and commit the change",
        "Unity çok oyunculu sistemimi düzelt", "Bu kodu incele ve hataları düzelt", "testleri çalıştır ve hataları düzelt",
        "Compare PostgreSQL and SQLite for a desktop app and give pros and cons",
    ])
    func developmentAndKnowledgeWorkIsNeverLocalEligible(prompt: String) {
        let p = RouteFixtures.profile(prompt)
        let v = LocalModelPolicy.evaluate(p)
        #expect(!v.eligible, "\(prompt) → \(p.category) \(p.complexity)")
    }

    @Test func eachForbiddenClassIndependentlyBlocksTheLocalModel() {
        func blocked(_ edit: (inout TaskProfile) -> Void, _ expect: String) {
            var p = TaskProfile(category: .conversation, complexity: .trivial)
            edit(&p)
            let v = LocalModelPolicy.evaluate(p)
            #expect(!v.eligible && v.violations.contains { $0.contains(expect) }, "\(expect): \(v.violations)")
        }
        blocked({ $0.requiresCoding = true }, "requiresCoding")
        blocked({ $0.requiresTesting = true }, "requiresTesting")
        blocked({ $0.requiresRepositoryModification = true }, "requiresRepositoryModification")
        blocked({ $0.requiresTechnicalReview = true }, "requiresTechnicalReview")
        blocked({ $0.requiresComplexReasoning = true }, "requiresComplexReasoning")
        blocked({ $0.requiresTools = true }, "requiresTools")
        blocked({ $0.domainTags = ["unity"] }, "domain:unity")
        blocked({ $0.domainTags = ["multiplayer"] }, "domain:multiplayer")
        blocked({ $0.domainTags = ["security"] }, "domain:security")
        blocked({ $0.complexity = .moderate }, "complexity")
        blocked({ $0.estimatedContextTokens = 5000 }, "context")
        blocked({ $0.containsProjectCode = true }, "containsProjectCode")
        for c in LocalModelPolicy.forbiddenCategories { blocked({ $0.category = c }, "category:\(c.rawValue)") }
        #expect(LocalModelPolicy.evaluate(TaskProfile(category: .conversation, complexity: .trivial)).eligible)
    }

    @Test func secretsAndSensitiveWordsMarkTheTaskSensitive() {
        #expect(RouteFixtures.profile("my password is hunter2, remind me later").privacy == .sensitive)
        #expect(RouteFixtures.profile("here: sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456 what is it?").privacy == .sensitive)
        #expect(RouteFixtures.profile("What's the capital of France?").privacy == .normal)
        #expect(RouteFixtures.profile("Explain the function in Player.cs").containsProjectCode)
    }

    @Test func workerStyleRequestsRequireToolsAndRepositoryWork() {
        let p = RouteFixtures.profile("Fix my Unity multiplayer system. Run it and keep working until it passes.")
        #expect(p.requiresRepositoryModification && p.requiresTools && p.requiresCoding)
        #expect(p.domainTags.isSuperset(of: ["unity", "multiplayer"]))
    }
}

// MARK: - Catalog / registry / free verification

private let verboseFixture = """
opencode/big-pickle
{
  "id": "big-pickle", "providerID": "opencode", "name": "Big Pickle", "status": "active",
  "api": { "id": "big-pickle", "url": "https://opencode.ai/zen/v1" },
  "cost": { "input": 0, "output": 0, "cache": { "read": 0, "write": 0 } },
  "limit": { "context": 200000, "output": 32000 },
  "capabilities": { "toolcall": true, "reasoning": true }
}
opencode/sneaky-free
{
  "id": "sneaky-free", "providerID": "opencode", "name": "Sneaky Free", "status": "active",
  "api": { "url": "https://opencode.ai/zen/v1" },
  "cost": { "input": 0.5, "output": 2 }, "limit": { "context": 100000 }, "capabilities": { "toolcall": true }
}
opencode/mystery
{ "id": "mystery", "providerID": "opencode", "name": "Mystery", "status": "active", "api": { "url": "https://opencode.ai/zen/v1" } }
opencode/cache-priced
{
  "id": "cache-priced", "providerID": "opencode", "name": "Cache Priced", "status": "active",
  "api": { "url": "https://opencode.ai/zen/v1" }, "cost": { "input": 0, "output": 0, "cache": { "read": 0.1, "write": 0 } }
}
opencode/retired-free
{
  "id": "retired-free", "providerID": "opencode", "name": "Retired", "status": "deprecated",
  "api": { "url": "https://opencode.ai/zen/v1" }, "cost": { "input": 0, "output": 0 }
}
opencode-go/space-bunny-free
{
  "id": "space-bunny-free", "providerID": "opencode-go", "name": "Space Bunny Free", "status": "active",
  "api": { "url": "https://opencode.ai/zen/go/v1" }, "cost": { "input": 0, "output": 0, "cache": { "read": 0, "write": 0 } }
}
opencode-go/glm-5.3
{
  "id": "glm-5.3", "providerID": "opencode-go", "name": "GLM 5.3", "status": "active",
  "api": { "url": "https://opencode.ai/zen/go/v1" }, "cost": { "input": 1.4, "output": 4.4 }
}
opencode/wrong-host-free
{
  "id": "wrong-host-free", "providerID": "opencode", "name": "Wrong Host", "status": "active",
  "api": { "url": "https://evil.example.com/v1" }, "cost": { "input": 0, "output": 0 }
}
"""

@Suite("OpenCode catalog and the free-price rule")
struct CatalogTests {
    private func records() -> [String: ModelRecord] {
        let when = RouteFixtures.now
        return Dictionary(uniqueKeysWithValues: OpenCodeCatalog.parse(verboseFixture).map {
            ($0.fullID, OpenCodeModelRegistry.record(from: $0, verifiedAt: when, source: "fixture"))
        })
    }

    @Test func parsesEveryBlockOfTheVerboseListing() {
        let infos = OpenCodeCatalog.parse(verboseFixture)
        #expect(infos.count == 8)
        let pickle = infos.first { $0.fullID == "opencode/big-pickle" }
        #expect(pickle?.costInput == 0 && pickle?.contextLimit == 200000 && pickle?.supportsTools == true)
        #expect(OpenCodeCatalog.parseIDs("opencode/big-pickle\nopencode-go/glm-5.3\n\nnoise line\n") == ["opencode/big-pickle", "opencode-go/glm-5.3"])
    }

    @Test func onlyVerifiedZeroPriceOnTheKeylessTierIsFree() {
        let r = records()
        #expect(r["opencode/big-pickle"]?.isFreePoolMember == true)                  // free WITHOUT "free" in its name
        #expect(r["opencode/big-pickle"]?.freeVerificationSource == "fixture")
        #expect(r["opencode/sneaky-free"]?.pricingStatus == .paid && r["opencode/sneaky-free"]?.isFreePoolMember == false)   // "free" in the name, price > 0
        #expect(r["opencode/mystery"]?.pricingStatus == .unknown && r["opencode/mystery"]?.isFreePoolMember == false)        // unknown price ≠ free
        #expect(r["opencode/cache-priced"]?.pricingStatus == .paid && r["opencode/cache-priced"]?.isFreePoolMember == false) // any non-zero component
        #expect(r["opencode/retired-free"]?.isFreePoolMember == false)                                                         // zero price but not active
        #expect(r["opencode-go/space-bunny-free"]?.pricingStatus == .verifiedZero)
        #expect(r["opencode-go/space-bunny-free"]?.isFreePoolMember == false)        // credentialed plan, not the keyless tier
        #expect(r["opencode-go/space-bunny-free"]?.blockedReason?.contains("credentialed") == true)
        #expect(r["opencode-go/glm-5.3"]?.pricingStatus == .paid && r["opencode-go/glm-5.3"]?.blockedReason?.contains("price > 0") == true)
        #expect(r["opencode/wrong-host-free"]?.isFreePoolMember == false)           // zero price from an unexpected endpoint
    }

    @Test func aPriceChangeRevokesFreeStatusOnTheNextRefresh() {
        var info = OpenCodeCatalog.parse(verboseFixture).first { $0.fullID == "opencode/big-pickle" }!
        let first = OpenCodeModelRegistry.record(from: info, verifiedAt: RouteFixtures.now, source: "a")
        #expect(first.isFreePoolMember)
        info.costOutput = 0.2                                                            // provider starts charging
        let second = OpenCodeModelRegistry.record(from: info, verifiedAt: RouteFixtures.now.addingTimeInterval(100), source: "b", existing: first)
        #expect(!second.isFreePoolMember && !second.freeVerified && second.pricingStatus == .paid)
    }

    @Test func verificationExpiresAfterADay() {
        let m = RouteFixtures.freeModel("x", verifiedAgo: 3600)
        #expect(OpenCodeModelRegistry.isVerificationFresh(m, now: RouteFixtures.now))
        #expect(!OpenCodeModelRegistry.isVerificationFresh(m, now: RouteFixtures.now.addingTimeInterval(24 * 3600)))
    }

    @Test func dataPoliciesFollowTheZenDocsAndUnknownIsNotZeroRetention() {
        #expect(OpenCodeModelRegistry.dataPolicy(forProviderModel: "space-bunny-free") == .zeroRetention)
        #expect(OpenCodeModelRegistry.dataPolicy(forProviderModel: "big-pickle") == .mayTrain)
        #expect(OpenCodeModelRegistry.dataPolicy(forProviderModel: "nemotron-3-ultra-free") == .trialLogged)
        #expect(OpenCodeModelRegistry.dataPolicy(forProviderModel: "brand-new-free") == .unknown)
    }

    @Test func aSpecCanOnlyBeBuiltForACurrentVerifiedFreeModel() {
        let ok = RouteFixtures.freeModel("alpha-free")
        #expect(OpenCodeSpec.make(for: ok, now: RouteFixtures.now)?.modelID == "opencode/alpha-free")
        var paid = ok; paid.pricingStatus = .paid; paid.freeVerified = false
        var unknown = ok; unknown.pricingStatus = .unknown; unknown.freeVerified = false
        var disabled = ok; disabled.enabled = false
        var go = ok; go.provider = "opencode-go"
        let stale = RouteFixtures.freeModel("old", verifiedAgo: 3 * 24 * 3600)
        for bad in [paid, unknown, disabled, go, stale] { #expect(OpenCodeSpec.make(for: bad, now: RouteFixtures.now) == nil, "\(bad.id)") }
    }

    @Test func openCodeArgumentsAreSafeAndPinned() {
        let spec = OpenCodeSpec(modelID: "opencode/alpha-free")
        let args = spec.arguments(sessionID: nil, newSessionID: "x", workingDirectory: "/tmp")
        #expect(args == ["run", "--pure", "--format", "json", "-m", "opencode/alpha-free"])
        #expect(spec.arguments(sessionID: "ses_abc", newSessionID: "x", workingDirectory: "/tmp").suffix(2) == ["-s", "ses_abc"])
        for forbidden in ["--auto", "--attach", "--share", "--password", "serve", "web"] { #expect(!args.contains(forbidden)) }
        #expect(OpenCodeWorkspace.configJSON.contains("\"*\":\"ask\""))
        #expect(OpenCodeWorkspace.configJSON.contains("\"external_directory\":\"deny\"") && OpenCodeWorkspace.configJSON.contains("\"edit\":\"deny\""))
        #expect(!OpenCodeWorkspace.configJSON.contains("\"bash\":\"deny\""))          // would trigger the free-tier 403 (docs/OPENCODE_RESEARCH.md)
        #expect(!OpenCodeWorkspace.configJSON.contains("\"allow\""))
        #expect((try? JSONSerialization.jsonObject(with: Data(OpenCodeWorkspace.configJSON.utf8))) != nil)
    }

    @Test func workspacePreparationWritesOnlyTheRestrictiveConfig() throws {
        let dir = NSTemporaryDirectory() + "oc-ws-\(UUID().uuidString)"
        let path = try OpenCodeWorkspace.prepare(under: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: path)
        #expect(files == ["opencode.json"])
        #expect(try String(contentsOfFile: path + "/opencode.json", encoding: .utf8) == OpenCodeWorkspace.configJSON)
    }
}

@Suite("OpenCode event parsing")
struct OpenCodeParserTests {
    private func feed(_ lines: [String], exit: Int32 = 0) -> (events: [ProviderStreamEvent], failure: ProviderError?) {
        let p = OpenCodeEventParser()
        let ev = lines.flatMap { p.parse(line: Data($0.utf8)) }
        return (ev, ev.contains(.finished) ? nil : p.finalFailure(exitCode: exit, stderrTail: ""))
    }

    @Test func aNormalRunYieldsSessionTextUsageAndFinish() {
        let r = feed([
            #"{"type":"step_start","sessionID":"ses_abc123","part":{"type":"step-start"}}"#,
            #"{"type":"text","sessionID":"ses_abc123","part":{"type":"text","text":"JARVIS_OPENCODE_OK"}}"#,
            #"{"type":"step_finish","sessionID":"ses_abc123","part":{"reason":"stop","tokens":{"total":8183,"input":6371,"output":8,"reasoning":12}}}"#,
        ])
        #expect(r.events == [.session("ses_abc123"), .text("JARVIS_OPENCODE_OK"), .usage(input: 6371, output: 8), .finished])
        #expect(r.failure == nil)
    }

    @Test func rejectedToolAttemptsAreReportedButNeverExecuted() {
        let r = feed([
            #"{"type":"step_start","sessionID":"ses_t","part":{}}"#,
            #"{"type":"tool_use","sessionID":"ses_t","part":{"tool":"bash","state":{"status":"error","error":"The user rejected permission to use this specific tool call."}}}"#,
            #"{"type":"step_finish","sessionID":"ses_t","part":{"reason":"tool-calls"}}"#,
        ])
        #expect(r.events.contains(.toolAttempt("bash")))
        #expect(!r.events.contains(.finished))
        if case .unavailable(.openCode, _)? = r.failure {} else { Issue.record("a tool-only turn is a failure, got \(String(describing: r.failure))") }
    }

    @Test func theFreeTier403IsATypedFailureNotAnAnswer() {
        let r = feed([#"{"type":"error","sessionID":"ses_e","error":{"name":"APIError","data":{"message":"OpenCode's free tier can only be used from within OpenCode","statusCode":403}}}"#], exit: 1)
        if case .failure(.unavailable(.openCode, _)) = r.events.last! {} else { Issue.record("expected unavailable, got \(r.events)") }
        #expect(!r.events.contains { if case .text = $0 { return true }; return false })
    }

    @Test func statusCodesMapToTypedErrors() {
        func map(_ code: Int) -> ProviderError { OpenCodeEventParser.map(error: ["data": ["statusCode": code, "message": "x"]], id: .openCode) }
        #expect(map(401) == .authenticationRequired(.openCode))
        #expect(map(429) == .rateLimited(.openCode, resetsAt: nil))
        if case .unavailable = map(503) {} else { Issue.record("503") }
    }

    @Test func malformedOrEmptyOutputIsAFailure() {
        #expect(feed(["not json at all", "{broken"]).failure == .malformedOutput(.openCode))
        #expect(feed([]).failure == .malformedOutput(.openCode))
        #expect(feed([#"{"type":"text","sessionID":"s1","part":{"text":"half an answer"}}"#]).failure == .malformedOutput(.openCode))
    }

    @Test func unsafeSessionIdsAreIgnored() {
        #expect(feed([#"{"type":"step_start","sessionID":"--yolo","part":{}}"#]).events.isEmpty)
    }

    @Test func multipleTextPartsAreJoinedWithABlankLine() {
        let r = feed([#"{"type":"text","sessionID":"s1","part":{"text":"one"}}"#, #"{"type":"text","sessionID":"s1","part":{"text":"two"}}"#,
                      #"{"type":"step_finish","sessionID":"s1","part":{"reason":"stop"}}"#])
        #expect(r.events.filter { if case .text = $0 { return true }; return false } == [.text("one"), .text("\n\ntwo")])
    }
}
