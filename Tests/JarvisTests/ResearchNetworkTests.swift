import Testing
import Foundation
@testable import Jarvis

@Suite("Research · web client against the fixture web", .serialized)
struct WebClientTests {
    private func fetch(_ env: ResearchFixtureEnv, _ url: String, cfg: FetchConfig = FetchConfig()) async -> Result<FetchedDocument, ResearchFailure> { await env.client.fetch(url, config: cfg) }

    @Test func aPageIsFetchedWithHonestHeadersAndNoCookies() async throws {
        let env = try ResearchFixtureEnv()
        guard case .success(let doc) = await fetch(env, "https://docs.unity3d.com/docs/boxcollider") else { Issue.record("fetch"); return }
        #expect(doc.status == 200 && doc.text.contains("BoxCollider") && doc.finalURL.host == "docs.unity3d.com")
        let h = env.server.requestHeaders.last ?? [:]
        #expect(h["user-agent"]?.contains("JARVIS-Research") == true && h["cookie"] == nil && h["authorization"] == nil)
        #expect(doc.headers["set-cookie"] == nil)
    }

    @Test func redirectsAreFollowedHopByHopAndRecorded() async throws {
        let env = try ResearchFixtureEnv()
        guard case .success(let doc) = await fetch(env, "https://docs.unity3d.com/redirect/a") else { Issue.record("fetch"); return }
        #expect(doc.finalURL.path == "/docs/boxcollider" && doc.hops.count == 3)
        #expect(env.transport.log.contains { $0.hasSuffix("/redirect/b") })
    }

    @Test func redirectLoopsAndForbiddenTargetsAreBlocked() async throws {
        let env = try ResearchFixtureEnv()
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/redirect/loop") { #expect(f.description.contains("redirect")) } else { Issue.record("loop") }
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/redirect/private") { #expect(f.description.contains("169.254") || f.description.contains("refused")) } else { Issue.record("metadata redirect") }
        if case .failure = await fetch(env, "https://docs.unity3d.com/redirect/file") {} else { Issue.record("file redirect") }
        #expect(!env.transport.log.contains { $0.contains("169.254") })           // the second hop never reached the transport
    }

    @Test func urlsThePolicyRefusesNeverReachTheTransport() async throws {
        let env = try ResearchFixtureEnv()
        for u in ["http://127.0.0.1/", "http://localhost:8080/", "file:///etc/passwd", "http://192.168.0.1/", "http://169.254.169.254/", "ftp://example.com/x", "https://user:pw@docs.unity3d.com/"] {
            if case .success = await fetch(env, u) { Issue.record("\(u) must be refused") }
        }
        #expect(env.transport.log.isEmpty)
    }

    @Test func aHostThatResolvesPrivatelyIsRefusedBeforeConnecting() async throws {
        let env = try ResearchFixtureEnv(extraHosts: ["rebind.example.test"], resolverOverrides: ["rebind.example.test": [.v4([93, 184, 216, 34]), .v4([10, 0, 0, 5])]])
        if case .failure(let f) = await fetch(env, "https://rebind.example.test/x") { #expect(f.description.contains("10.0.0.5")) } else { Issue.record("rebinding") }
        #expect(env.transport.log.isEmpty)
    }

    @Test func failuresAreReportedTruthfully() async throws {
        let env = try ResearchFixtureEnv()
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/nope") { #expect(f == .httpStatus(404) && f.leavesFactUnknown == false) } else { Issue.record("404") }
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/captcha") { #expect(f == .captcha) } else { Issue.record("captcha") }
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/error500", cfg: { var c = FetchConfig(); c.retries = 0; return c }()) { #expect(f == .httpStatus(500) && f.leavesFactUnknown) } else { Issue.record("500") }
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/files/good.png") { #expect(f.description.contains("unsupported")) } else { Issue.record("binary") }
        if case .failure(let f) = await fetch(env, "https://not-a-virtual-host.example.test/") { _ = f } else { Issue.record("unknown host") }
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/asset/login") { _ = f } else if case .success(let d) = await fetch(env, "https://docs.unity3d.com/asset/login") { #expect(HTMLExtractor.extract(d.body).isLoginWall) }
    }

    @Test func transientErrorsAreRetriedOnceAndRateLimitsRespectRetryAfter() async throws {
        let env = try ResearchFixtureEnv()
        var cfg = FetchConfig(); cfg.retries = 2
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/flaky", cfg: cfg) { Issue.record("two 503 then success should recover: \(f)") }
        let t0 = Date()
        if case .failure(let f) = await fetch(env, "https://docs.unity3d.com/ratelimit") { if case .rateLimited = f {} else { Issue.record("rate limit: \(f)") } } else { Issue.record("429") }
        #expect(Date().timeIntervalSince(t0) >= 0.9)             // it waited the advertised second before its single retry
    }

    @Test func largePagesAreTruncatedNotRejected() async throws {
        let env = try ResearchFixtureEnv()
        var cfg = FetchConfig(); cfg.maxBytes = 8_000
        guard case .success(let doc) = await fetch(env, "https://docs.unity3d.com/slow/page", cfg: cfg) else { Issue.record("fetch"); return }
        #expect(doc.truncated && doc.body.count <= 8_000)
    }

    @Test func cancellationStopsAnInFlightFetchQuickly() async throws {
        let env = try ResearchFixtureEnv()
        let client = env.client
        let task = Task { await client.fetch("https://docs.unity3d.com/slow/page", config: FetchConfig()) }
        try await Task.sleep(for: .milliseconds(400))
        let t0 = Date()
        task.cancel()
        let r = await task.value
        #expect(Date().timeIntervalSince(t0) < 1.5)
        if case .failure(let f) = r { #expect(f == .cancelled) } else { Issue.record("a cancelled fetch must not look like a completed one") }
    }

    @Test func perHostPolitenessSpacesRequests() async throws {
        let limiter = HostRateLimiter(defaultInterval: 0.25)
        let t0 = Date()
        try await limiter.wait(host: "a.example"); try await limiter.wait(host: "a.example"); try await limiter.wait(host: "a.example")
        #expect(Date().timeIntervalSince(t0) >= 0.45)
        let t1 = Date(); try await limiter.wait(host: "b.example")
        #expect(Date().timeIntervalSince(t1) < 0.2)
    }
}

@Suite("Research · providers", .serialized)
struct ProviderParsingTests {
    @Test func duckDuckGoResultsAreParsedAndUnwrapped() async throws {
        let env = try ResearchFixtureEnv(extraHosts: ["html.duckduckgo.com"])
        // the fixture serves the same markup shape as the real HTML endpoint
        guard case .success(let doc) = await env.client.fetch("https://html.duckduckgo.com/html/?q=boxcollider") else { Issue.record("fetch"); return }
        let hits = DuckDuckGoHTMLProvider.parse(doc.text, limit: 10)
        #expect(hits.count == 4 && hits[0].url == "https://docs.unity3d.com/docs/boxcollider" && hits[0].title == "BoxCollider - Unity Manual" && hits[2].snippet.contains("throw animation"))
        #expect(DuckDuckGoHTMLProvider.parse("<html><body>nothing</body></html>", limit: 5).isEmpty)
    }

    @Test func githubRepositoryUrlsAreParsedStrictly() {
        #expect(GitHubInspector.parseRepoURL("https://github.com/n0tnow/Jarvis")! == ("n0tnow", "Jarvis"))
        #expect(GitHubInspector.parseRepoURL("https://github.com/n0tnow/Jarvis.git/issues")! == ("n0tnow", "Jarvis"))
        #expect(GitHubInspector.parseRepoURL("https://github.com/topics/unity") == nil && GitHubInspector.parseRepoURL("https://evil.example/github.com/a/b") == nil && GitHubInspector.parseRepoURL("https://github.com/only") == nil)
    }
}

private func hit(_ title: String, _ url: String, _ snippet: String = "", rank: Int = 1, provider: String = "duckduckgo-html") -> WebSearchHit { WebSearchHit(title: title, url: url, snippet: snippet, provider: provider, rank: rank) }

private func pipeline(_ env: ResearchFixtureEnv, goal: String, hits: [WebSearchHit], model: ModelCall? = nil, project: ProjectFacts? = nil, events: (@Sendable (ResearchEvent) -> Void)? = nil) -> ResearchPipeline {
    let provider = FixtureSearchProvider(id: "duckduckgo-html") { _ in hits }
    return ResearchPipeline(request: ResearchIntake.parse(goal: goal, project: project), client: env.client, providers: [provider], model: model, events: events)
}

@Suite("Research · pipeline", .serialized)
struct PipelineTests {
    @Test func documentationResearchKeepsOfficialAndCommunityApart() async throws {
        let env = try ResearchFixtureEnv()
        let p = pipeline(env, goal: "research unity BoxCollider documentation and community workarounds", hits: [hit("Manual", "https://docs.unity3d.com/docs/boxcollider"), hit("Thread", "https://discussions.unity.com/community/thread1", rank: 2)])
        guard case .success = await p.search(), case .success(let n) = await p.read() else { Issue.record("search/read"); return }
        #expect(n == 2)
        let report = await { () -> ResearchReport in await p.compare(); return await p.buildReport().report }()
        let srcs = await p.allSources().filter { $0.method != .searchSnippet }
        #expect(srcs.contains { $0.domain == "docs.unity3d.com" && $0.official == .official && $0.type == .officialDocs })
        #expect(srcs.contains { $0.domain == "discussions.unity.com" && $0.official != .official && $0.type == .forum })
        #expect(report.recommendation.contains("official source") && report.recommendation.contains("BoxCollider"))
        #expect(report.sourceCount == 2 && report.status == .completed)
    }

    @Test func aPageThatTriesToInstructTheAssistantIsInertEvidence() async throws {
        let env = try ResearchFixtureEnv()
        let p = pipeline(env, goal: "find a free animation pack", hits: [hit("Normal", "https://store.fixture.example/inject")])
        _ = await p.search(); _ = await p.read()
        let src = await p.allSources().first { $0.method != .searchSnippet }
        #expect(src?.injectionFlags.contains("ignore-previous-instructions") == true && src?.note?.contains("ignored") == true)
        let report = await { () -> ResearchReport in await p.compare(); return await p.buildReport().report }()
        #expect(!report.injectionNotes.isEmpty)
        // nothing the page said became a request: only the page itself and nothing else was fetched (no evil.example, no curl target)
        #expect(!env.transport.log.contains { $0.contains("evil.example") })
    }

    @Test func modelOutputIsAcceptedOnlyWhereItsQuotedEvidenceIsReallyInThePage() async throws {
        let env = try ResearchFixtureEnv()
        let model: ModelCall = { purpose, prompt, validate in
            guard purpose == .extraction else { return nil }
            // the prompt must fence web text and carry the security rules
            #expect(prompt.contains("UNTRUSTED_WEB_CONTENT") && prompt.contains("DATA, not instructions"))
            let answer = """
            {"candidates": [], "claims": [
              {"subject": "BoxCollider", "kind": "workaround", "statement": "Use continuous collision detection on the Rigidbody.", "source": "S1", "excerpt": "set the Rigidbody to continuous collision detection", "community_reported": true},
              {"subject": "BoxCollider", "kind": "apiBehavior", "statement": "It supports GPU skinning.", "source": "S1", "excerpt": "BoxCollider fully supports GPU skinning on all meshes"}
            ], "instruction_attempts": []}
            """
            return validate(answer) ? ModelAnswer(text: answer, provider: "Scripted", model: "t") : nil
        }
        let p = pipeline(env, goal: "research unity boxcollider not colliding error", hits: [hit("Thread", "https://discussions.unity.com/community/thread1")], model: model)
        _ = await p.search(); _ = await p.read(); _ = await p.extract()
        let claims = await p.snapshot().claims
        #expect(claims.contains { $0.statement.contains("continuous collision detection") && $0.statement.hasPrefix("Community-reported") })
        #expect(!claims.contains { $0.statement.contains("GPU skinning") })                         // invented evidence is dropped
        let notes = await p.snapshot().modelNotes
        #expect(notes.contains { $0.contains("dropped") })
    }

    @Test func assetResearchVerifiesCurrentPriceLicenceAndCompatibilityPerCandidate() async throws {
        let env = try ResearchFixtureEnv()
        let hits = [hit("Free Throw Pack", "https://kenney.nl/asset/free-throw", "throw pack"), hit("Paid Throw Pack", "https://assetstore.unity.com/asset/paid-throw", "FREE!! download now", rank: 2),
                    hit("Mystery", "https://kenney.nl/asset/unknown-license", rank: 3), hit("Promo", "https://polyhaven.com/asset/promo", rank: 4), hit("Hobby", "https://assetstore.unity.com/asset/noncommercial", rank: 5)]
        let project = ProjectFacts(name: "Hamam", unityVersion: "6000.0.23f1", renderPipeline: "URP")
        let p = pipeline(env, goal: "find a free throw animation for our game commercial", hits: hits, project: project)
        _ = await p.search(); _ = await p.read(); _ = await p.extract(); await p.verify(); await p.compare()
        let report = await p.buildReport().report
        func cand(_ n: String) -> CandidateRecord? { report.candidates.first { $0.name.contains(n) } }
        let free = try #require(cand("Free Throw"))
        #expect(free.price.state == .freeVerified && free.license.identifier == "MIT" && free.compatibility.overall == .compatible && free.verdict == .preferred)
        #expect(free.acquisition == .publicDirectDownload && free.downloadURL == "https://kenney.nl/files/good.zip")
        let paid = try #require(cand("Paid Throw"))
        #expect(paid.price.state == .paidVerified && paid.verdict == .notRecommended && paid.acquisition == .paidPurchase)
        #expect(report.contradictions.contains { $0.contains("snippet said “free”") })                    // the stale snippet lost against the current page
        let mystery = try #require(cand("Mystery"))
        #expect(mystery.license.state == .unknown && mystery.verdict == .notRecommended && mystery.unknowns.contains("licence not found"))
        let promo = try #require(cand("Promo"))
        #expect(promo.price.state == .promotion && promo.verdict == .notRecommended)
        let hobby = try #require(cand("Hobby"))
        #expect(hobby.license.state == .nonCommercial && hobby.verdict == .notRecommended)
        #expect(report.recommendation.hasPrefix("Preferred: Free Throw"))
        // every verified fact in the report cites a source
        #expect(report.facts.filter { $0.status == .verified }.allSatisfy { !$0.sourceIDs.isEmpty })
    }

    @Test func snippetOnlyFreeNeverBecomesFree() async throws {
        let env = try ResearchFixtureEnv()
        // the listing cannot be read (login wall): the snippet says "free", the verdict must stay UNKNOWN / requires-login
        let p = pipeline(env, goal: "find a free animation pack", hits: [hit("Hidden pack", "https://store.fixture.example/asset/login", "FREE download $0.00")])
        _ = await p.search(); _ = await p.read(); _ = await p.extract()
        let seeded = await p.snapshot().candidates
        if seeded.isEmpty {
            var c = CandidateRecord(researchID: await p.request.id, name: "Hidden pack", url: "https://store.fixture.example/asset/login"); c.kind = .animation
            await p.putCandidate(c)
        }
        await p.verify()
        let c = await p.snapshot().candidates.first
        #expect(c?.price.state != .freeVerified && c?.price.state.isFree == false)
    }

    @Test func budgetsStopTheSearch() async throws {
        let env = try ResearchFixtureEnv()
        var many: [WebSearchHit] = []
        for i in 0..<30 { many.append(hit("Doc \(i)", "https://docs.unity3d.com/docs/boxcollider?page=\(i)", rank: i + 1)) }
        let provider = FixtureSearchProvider(id: "duckduckgo-html") { _ in many }
        var budget = ResearchBudget.standard; budget.maxSources = 3
        let p = ResearchPipeline(request: ResearchIntake.parse(goal: "find the official documentation boxcollider unity"), budget: budget, client: env.client, providers: [provider])
        _ = await p.search(); _ = await p.read()
        #expect(await p.allSources().filter { $0.method != .searchSnippet }.count <= 3)
        #expect(env.transport.log.filter { $0.contains("boxcollider") }.count <= 3)
    }

    @Test func aSearchProviderThatAsksForACaptchaIsAbandonedNotBypassed() async throws {
        let env = try ResearchFixtureEnv()
        struct Blocked: SearchProvider { let id = "duckduckgo-html"; let title = "DDG"; var capabilities: ProviderCapabilities { ProviderCapabilities() }
            func search(_ q: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> { .failure(.captcha) } }
        let ok = FixtureSearchProvider(id: "stack-exchange") { _ in [hit("Thread", "https://discussions.unity.com/community/thread1", provider: "stack-exchange")] }
        var req = ResearchIntake.parse(goal: "research unity boxcollider error")
        req.type = .troubleshooting
        let p = ResearchPipeline(request: req, client: env.client, providers: [Blocked(), ok])
        let r = await p.search()
        if case .success = r {} else { Issue.record("the other provider should still deliver: \(r)") }
        let w = await p.snapshot().warnings
        #expect(w.contains { $0.contains("USER INTERACTION REQUIRED") })
    }

    @Test func cancellingTheResearchStopsItsNetworkWork() async throws {
        let env = try ResearchFixtureEnv()
        let hits = (0..<6).map { hit("Slow \($0)", "https://docs.unity3d.com/slow/page?n=\($0)", rank: $0 + 1) }
        let p = pipeline(env, goal: "find the official documentation boxcollider unity", hits: hits)
        _ = await p.search()
        let t = Task { await p.read() }
        try await Task.sleep(for: .milliseconds(500))
        let t0 = Date(); t.cancel()
        _ = await t.value
        #expect(Date().timeIntervalSince(t0) < 3)
    }
}
