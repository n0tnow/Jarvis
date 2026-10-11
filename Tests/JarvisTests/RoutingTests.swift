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

    @Test func aModelTheApiReportedAsRemovedStaysBlockedForADayEvenIfTheCatalogStillListsItFree() {
        let info = OpenCodeCatalog.parse(verboseFixture).first { $0.fullID == "opencode/big-pickle" }!
        var gone = OpenCodeModelRegistry.record(from: info, verifiedAt: RouteFixtures.now, source: "a")
        gone.availability = .unavailable; gone.freeVerified = false; gone.blockedReason = OpenCodeModelRegistry.removedMarker; gone.lastHealthCheck = RouteFixtures.now
        let soon = OpenCodeModelRegistry.record(from: info, verifiedAt: RouteFixtures.now.addingTimeInterval(3600), source: "b", existing: gone)
        #expect(!soon.isFreePoolMember && soon.blockedReason == OpenCodeModelRegistry.removedMarker)
        let later = OpenCodeModelRegistry.record(from: info, verifiedAt: RouteFixtures.now.addingTimeInterval(25 * 3600), source: "c", existing: gone)
        #expect(later.isFreePoolMember && later.blockedReason == nil)                           // re-evaluated after a day
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

    @Test func aDeprecatedModelStillListedAsActiveIsATypedRemovalNotAGenericFailure() {
        for code in [404, 410] {
            let e = OpenCodeEventParser.map(error: ["data": ["statusCode": code, "message": "Model exo-free has been deprecated."]], id: .openCode)
            #expect(e == .unavailable(.openCode, OpenCodeModelRegistry.removedErrorText))
        }
    }

    @Test func v2ErrorEventsAreMappedFromTheirOwnShape() {
        func map(_ status: Int, _ message: String) -> ProviderError { OpenCodeEventParser.map(error: ["type": "provider.invalid-request", "status": status, "message": message], id: .openCode) }
        #expect(map(410, "Model exo-free has been deprecated.") == .unavailable(.openCode, OpenCodeModelRegistry.removedErrorText))     // real 1.19.0 sample
        #expect(map(400, "Upstream request failed: Model is unavailable.") == .unavailable(.openCode, "model unavailable"))                // real 1.19.0 sample
        #expect(OpenCodeEventParser.map(error: ["type": "provider.auth", "status": 403, "message": "OpenCode's free tier can only be used from within OpenCode"], id: .openCode) == .unavailable(.openCode, "free tier refused the request"))
        #expect(map(429, "slow down") == .rateLimited(.openCode, resetsAt: nil) && map(401, "x") == .authenticationRequired(.openCode))
        if case .unavailable = map(503, "x") {} else { Issue.record("503") }
        let p = OpenCodeEventParser()
        let events = p.parse(line: Data(#"{"type":"error","sessionID":"ses_x","error":{"type":"provider.invalid-request","message":"Model exo-free has been deprecated.","status":410}}"#.utf8))
        #expect(events.contains(.failure(.unavailable(.openCode, OpenCodeModelRegistry.removedErrorText))))
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
        // Text but the process died abnormally (killed / crashed): NOT a complete answer.
        #expect(feed([#"{"type":"text","sessionID":"s1","part":{"text":"half an answer"}}"#], exit: 143).failure != nil)
    }

    @Test func v2MayEndTheStreamWithoutAStepFinishSoACleanExitWithTextIsComplete() {
        let p = OpenCodeEventParser()
        _ = p.parse(line: Data(#"{"type":"step_start","sessionID":"ses_v2","part":{}}"#.utf8))
        _ = p.parse(line: Data(#"{"type":"text","sessionID":"ses_v2","part":{"text":"JARVIS_OK"}}"#.utf8))
        #expect(p.completedOnCleanExit(exitCode: 0) && p.finalFailure(exitCode: 0, stderrTail: "") == nil)
        #expect(!p.completedOnCleanExit(exitCode: 1) && p.finalFailure(exitCode: 1, stderrTail: "") != nil)
        // An error event, or no text at all, never counts as complete.
        let e = OpenCodeEventParser()
        _ = e.parse(line: Data(#"{"type":"text","sessionID":"s","part":{"text":"x"}}"#.utf8))
        _ = e.parse(line: Data(#"{"type":"error","sessionID":"s","error":{"data":{"statusCode":503,"message":"x"}}}"#.utf8))
        #expect(!e.completedOnCleanExit(exitCode: 0))
        #expect(!OpenCodeEventParser().completedOnCleanExit(exitCode: 0))
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


// MARK: - OpenCode CLI generations (real --help texts captured on this Mac)

private let classicModelsHelp = """
opencode models [provider]

list all available models

Options:
  -h, --help        show help
      --verbose     use more verbose model output (includes metadata like costs)
      --refresh     refresh the models cache from models.dev
"""
private let classicRunHelp = """
opencode run [message..]
Options:
      --pure         run without external plugins
  -m, --model        model to use in the format of provider/model
      --format       format: default (formatted) or json (raw JSON events)
      --auto         auto-approve permissions that are not explicitly denied (dangerous!)
"""
private let v2ModelsHelp = """
DESCRIPTION
  List all available models

USAGE
  opencode models [flags]

FLAGS
  --standalone       Run with a private server instead of the background service
  --server string    Connect to a server URL instead of the background service
"""
private let v2RunHelp = """
USAGE
  opencode run [flags] [<message...>]

FLAGS
  --standalone            Run with a private server instead of the background service
  --server string         Connect to a server URL instead of the background service
  --model, -m string      Model to use in the format provider/model#variant
  --format choice         Output format (choices: default, json)
  --auto                  Auto-approve permissions that are not explicitly denied
"""

private let v2ApiHelp = """
USAGE
  opencode api [flags] <operation | method path...>
ARGUMENTS
  operation | method path... string    OpenAPI operation ID, or an HTTP method followed by a path
"""

/// Real-format `opencode api model.list` output (Model.Info with tiered `cost[]`), trimmed.
private let v2ModelListJSON = """
{"location":{"directory":"/x"},"data":[
 {"id":"big-pickle","providerID":"opencode","name":"Big Pickle","status":"active","enabled":true,"cost":[{"input":0,"output":0,"cache":{"read":0,"write":0}}],"limit":{"context":200000,"output":32000},"capabilities":{"tools":true,"input":["text"],"output":["text"]}},
 {"id":"tiered-free","providerID":"opencode","name":"Tiered","status":"active","enabled":true,"cost":[{"input":0,"output":0,"cache":{"read":0,"write":0}},{"tier":{"type":"context","size":100000},"input":0.5,"output":2,"cache":{"read":0,"write":0}}],"limit":{"context":1000000,"output":1000}},
 {"id":"exo-free","providerID":"opencode","name":"Exo","status":"deprecated","enabled":true,"cost":[{"input":0,"output":0,"cache":{"read":0,"write":0}}],"limit":{"context":1048576,"output":1000}},
 {"id":"off-free","providerID":"opencode","name":"Off","status":"active","enabled":false,"cost":[{"input":0,"output":0,"cache":{"read":0,"write":0}}],"limit":{"context":1000,"output":1000}},
 {"id":"nocost","providerID":"opencode","name":"NoCost","status":"active","enabled":true,"cost":[],"limit":{"context":1000,"output":1000}},
 {"id":"space-bunny-free","providerID":"opencode-go","name":"Space Bunny","status":"active","enabled":true,"cost":[{"input":0,"output":0,"cache":{"read":0,"write":0}}],"limit":{"context":1000,"output":1000}},
 {"id":"glm-5.3","providerID":"opencode-go","name":"GLM","status":"active","enabled":true,"cost":[{"input":1.4,"output":4.4,"cache":{"read":0,"write":0}}],"limit":{"context":1000,"output":1000}}
]}
"""

@MainActor
@Suite("OpenCode CLI generations", .serialized)
struct OpenCodeGenerationTests {
    @Test func theClassicGenerationUsesModelsVerboseAndPure() {
        let c = OpenCodeCapabilities.parse(modelsHelp: classicModelsHelp, runHelp: classicRunHelp)
        #expect(c.isSupported && c.runFlavor == .classic && c.catalogSource == .modelsVerbose && c.unsupportedReason(version: "1.18.34") == nil)
        #expect(OpenCodeSpec(modelID: "opencode/x").arguments(sessionID: nil, newSessionID: "", workingDirectory: "/tmp") == ["run", "--pure", "--format", "json", "-m", "opencode/x"])
    }

    @Test func the119GenerationReadsPricesThroughTheDocumentedApiAndRunsStandalone() {
        let c = OpenCodeCapabilities.parse(modelsHelp: v2ModelsHelp, runHelp: v2RunHelp, apiHelp: v2ApiHelp)
        #expect(c.isSupported && c.runFlavor == .standalone && c.catalogSource == .apiModelList)
        #expect(OpenCodeService.modelListArguments == ["api", "model.list"])                         // the ONLY api operation JARVIS invokes
        let spec = OpenCodeSpec.make(for: RouteFixtures.freeModel("x"), flavor: c.runFlavor, now: RouteFixtures.now)
        #expect(spec?.arguments(sessionID: "ses_1", newSessionID: "", workingDirectory: "/tmp") == ["run", "--standalone", "--format", "json", "-m", "opencode/x", "-s", "ses_1"])
        #expect(OpenCodeSpec.make(for: RouteFixtures.freeModel("x"), flavor: .unsupported, now: RouteFixtures.now) == nil)
    }

    @Test func aCliThatCannotListPricesOrHasNoRunInterfaceIsRefused() {
        let noApi = OpenCodeCapabilities.parse(modelsHelp: v2ModelsHelp, runHelp: v2RunHelp, apiHelp: "")
        #expect(!noApi.isSupported && noApi.unsupportedReason(version: "1.19.0")?.contains("no readable model prices") == true)
        let weird = OpenCodeCapabilities.parse(modelsHelp: classicModelsHelp, runHelp: "opencode run\n  --something-else")
        #expect(!weird.isSupported && weird.unsupportedReason(version: "9.9")?.contains("unsupported `run` interface") == true)
    }

    @Test func v2ModelListIsParsedWithEveryCostTierConsidered() {
        let infos = OpenCodeCatalog.parseModelList(v2ModelListJSON)
        #expect(infos.count == 7)
        let r = Dictionary(uniqueKeysWithValues: infos.map { ($0.fullID, OpenCodeModelRegistry.record(from: $0, verifiedAt: RouteFixtures.now, source: "v2")) })
        #expect(r["opencode/big-pickle"]?.isFreePoolMember == true && r["opencode/big-pickle"]?.contextLimit == 200000)
        #expect(r["opencode/tiered-free"]?.pricingStatus == .paid && r["opencode/tiered-free"]?.isFreePoolMember == false)      // a priced context tier makes it paid
        #expect(r["opencode/exo-free"]?.isFreePoolMember == false && r["opencode/exo-free"]?.availability == .unavailable)       // status "deprecated"
        #expect(r["opencode/off-free"]?.isFreePoolMember == false)                                                              // enabled: false
        #expect(r["opencode/nocost"]?.pricingStatus == .unknown && r["opencode/nocost"]?.isFreePoolMember == false)             // no price ⇒ never free
        #expect(r["opencode-go/space-bunny-free"]?.isFreePoolMember == false && r["opencode-go/space-bunny-free"]?.blockedReason?.contains("credentialed") == true)
        #expect(r["opencode-go/glm-5.3"]?.pricingStatus == .paid)
        #expect(OpenCodeCatalog.parseModelList("not json").isEmpty && OpenCodeCatalog.parseModelList("{\"data\":[]}").isEmpty)
    }

    @Test func eachGenerationGetsItsOwnRestrictiveWorkspaceConfigAndNeverBoth() throws {
        let dir = NSTemporaryDirectory() + "oc-gen-\(UUID().uuidString)"
        let classic = try OpenCodeWorkspace.prepare(under: dir, flavor: .classic)
        let classicFiles = try FileManager.default.contentsOfDirectory(atPath: classic)
        #expect(classicFiles == ["opencode.json"])
        let v2 = try OpenCodeWorkspace.prepare(under: dir, flavor: .standalone)
        let v2Files = try FileManager.default.contentsOfDirectory(atPath: v2)
        #expect(v2 == classic && v2Files == ["opencode.jsonc"])                                         // the other generation's file is removed
        let text = try String(contentsOfFile: v2 + "/opencode.jsonc", encoding: .utf8)
        #expect(text == OpenCodeWorkspace.v2ConfigJSONC)
        let rules = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["permissions"] as? [[String: String]] ?? []
        func effect(_ a: String) -> String? { rules.last { $0["action"] == a }?["effect"] }
        #expect(rules.first?["action"] == "*" && rules.first?["effect"] == "ask")                    // everything else: ask ⇒ rejected headless
        for a in ["execute", "edit", "webfetch", "websearch"] { #expect(effect(a) == "deny", "\(a)") }       // Code Mode could make network requests
        #expect(effect("shell") == nil && effect("read") == nil)                                       // denying these makes the free tier answer 403
        #expect(!text.contains("allow"))
    }

    /// A fake `opencode` binary (real child process) that answers --version / --help / models / api like the given generation.
    private func fakeOpenCode(in dir: String, version: String, modelsHelp: String, runHelp: String, apiHelp: String = "", catalog: String, emptyApiAnswers: Int = 0) -> String {
        try! modelsHelp.write(toFile: dir + "/models.help", atomically: true, encoding: .utf8)
        try! runHelp.write(toFile: dir + "/run.help", atomically: true, encoding: .utf8)
        try! apiHelp.write(toFile: dir + "/api.help", atomically: true, encoding: .utf8)
        try! catalog.write(toFile: dir + "/catalog.txt", atomically: true, encoding: .utf8)
        try! "".write(toFile: dir + "/api.count", atomically: true, encoding: .utf8)
        return FakeCLI.script("""
        echo "$@" >> \(dir)/opencode.calls
        case "$1" in
          --version) echo "\(version)";;
          models) if [ "$2" = "--help" ]; then cat \(dir)/models.help; else cat \(dir)/catalog.txt; fi;;
          run) if [ "$2" = "--help" ]; then cat \(dir)/run.help; else cat >/dev/null; echo "RUN-WAS-LAUNCHED" >> \(dir)/opencode.calls; fi;;
          api) if [ "$2" = "--help" ]; then cat \(dir)/api.help; else
                 echo x >> \(dir)/api.count; n=$(wc -l < \(dir)/api.count)
                 if [ "$n" -le \(emptyApiAnswers) ]; then echo '{"location":{},"data":[]}'; else cat \(dir)/catalog.txt; fi
               fi;;
        esac
        """, in: dir, name: "opencode")
    }

    @Test func theRealProbeRejectsACliWithNoPriceSourceWithoutEverRunningIt() async throws {
        let h = IntelligenceHarness()
        h.openCode.catalogOverride = nil                                                           // use the real probing branch
        h.prefs.openCodePathOverride = fakeOpenCode(in: h.dir, version: "1.19.0", modelsHelp: v2ModelsHelp, runHelp: v2RunHelp, apiHelp: "", catalog: "")
        await h.openCode.refresh(remote: true)
        guard case .unavailable(let why) = h.openCode.state else { Issue.record("must be unavailable, got \(h.openCode.state)"); return }
        #expect(why.contains("no readable model prices") && h.openCode.version == "1.19.0" && h.openCode.freePool.isEmpty)
        let calls = (try? String(contentsOfFile: h.dir + "/opencode.calls", encoding: .utf8)) ?? ""
        #expect(!calls.contains("--verbose") && !calls.contains("model.list") && !calls.contains("RUN-WAS-LAUNCHED"))
        #expect(h.openCode.provider(for: RouteFixtures.freeModel("alpha-free")) == nil)
    }

    @Test func theRealProbeReadsV2PricesThroughApiModelListWithBoundedPollingAndBuildsAStandaloneLauncher() async throws {
        let h = IntelligenceHarness()
        h.openCode.catalogOverride = nil
        OpenCodeService.catalogPollInterval = 0.05
        defer { OpenCodeService.catalogPollInterval = 2.5 }
        h.prefs.openCodePathOverride = fakeOpenCode(in: h.dir, version: "1.19.0", modelsHelp: v2ModelsHelp, runHelp: v2RunHelp, apiHelp: v2ApiHelp, catalog: v2ModelListJSON, emptyApiAnswers: 2)
        await h.openCode.refresh(remote: true)
        #expect(h.openCode.state == .ready && h.openCode.capabilities?.runFlavor == .standalone)
        #expect(h.openCode.freePool.map(\.id) == ["opencode/big-pickle"])
        let calls = (try? String(contentsOfFile: h.dir + "/opencode.calls", encoding: .utf8)) ?? ""
        #expect(calls.components(separatedBy: "\n").filter { $0 == "api model.list" }.count == 3)           // 2 empty (unsettled snapshot) + 1 real answer
        #expect(!calls.contains("credential") && !calls.contains("integration") && !calls.contains("--verbose"))
        let model = try #require(h.openCode.model("opencode/big-pickle"))
        #expect(h.openCode.freePool.first?.freeVerificationSource?.contains("api model.list") == true)
        let provider = try #require(h.openCode.provider(for: model))
        let r = await OneShotRunner.run(provider: provider, prompt: "hello")
        _ = r
        let after = (try? String(contentsOfFile: h.dir + "/opencode.calls", encoding: .utf8)) ?? ""
        #expect(after.contains("run --standalone --format json -m opencode/big-pickle") && !after.contains("--pure"))
        let wsFiles = try FileManager.default.contentsOfDirectory(atPath: h.dir + "/work/opencode")
        #expect(wsFiles == ["opencode.jsonc"])
    }

    @Test func ifTheServiceNeverSettlesPollingStopsAndFreeRoutingStaysOff() async {
        let h = IntelligenceHarness()
        h.openCode.catalogOverride = nil
        OpenCodeService.catalogPollInterval = 0.02
        defer { OpenCodeService.catalogPollInterval = 2.5 }
        h.prefs.openCodePathOverride = fakeOpenCode(in: h.dir, version: "1.19.0", modelsHelp: v2ModelsHelp, runHelp: v2RunHelp, apiHelp: v2ApiHelp, catalog: v2ModelListJSON, emptyApiAnswers: 100)
        await h.openCode.refresh(remote: true)
        guard case .unavailable(let why) = h.openCode.state else { Issue.record("must be unavailable"); return }
        #expect(why.contains("model list not ready") && h.openCode.freePool.isEmpty)
        let n = ((try? String(contentsOfFile: h.dir + "/opencode.calls", encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0 == "api model.list" }.count
        #expect(n == OpenCodeService.catalogPollAttempts)                                            // bounded
    }

    @Test func theRealProbeAcceptsTheClassicGenerationAndReadsPricesFromModelsVerbose() async throws {
        let h = IntelligenceHarness()
        h.openCode.catalogOverride = nil
        h.setCatalog([("alpha-free", 0, 0), ("pricey", 2, 6)])
        h.prefs.openCodePathOverride = fakeOpenCode(in: h.dir, version: "1.18.34", modelsHelp: classicModelsHelp, runHelp: classicRunHelp, catalog: h.catalog)
        await h.openCode.refresh(remote: true)
        #expect(h.openCode.state == .ready && h.openCode.capabilities?.runFlavor == .classic && h.openCode.freePool.map(\.id) == ["opencode/alpha-free"])
        let calls = (try? String(contentsOfFile: h.dir + "/opencode.calls", encoding: .utf8)) ?? ""
        #expect(calls.contains("models --pure --verbose --refresh") && !calls.contains("model.list"))
    }

    @Test func unrecognizedFlagsAreATypedUnsupportedVersionError() {
        let p = OpenCodeEventParser()
        let err = p.finalFailure(exitCode: 1, stderrTail: "ERROR\n  Unrecognized flag: --pure in command opencode run")
        #expect(err == .unavailable(.openCode, "unsupported CLI version"))
    }
}
