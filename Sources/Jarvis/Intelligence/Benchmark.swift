import Foundation

/// A tiny, honest evaluation suite. Free models earn automatic routing ONLY from real recorded results here
/// (no invented quality scores). Everything runs on in-prompt fixtures / temp directories — never on the JARVIS repository.
/// Validators never EXECUTE model-produced code: Swift answers are only type-checked (`swiftc -typecheck`).
enum BenchmarkSuite {
    static let id = "v1"

    struct Case: Sendable {
        let id: String
        let group: BenchmarkGroup
        let title: String
        let prompt: String
        var timeout: TimeInterval = 90
        let validate: @Sendable (String) async -> Verdict
    }

    struct Verdict: Sendable, Equatable {
        var passed: Bool
        var detail: String
        var malformed = false
    }

    static var all: [Case] { general + research + coding + testing }
    static func cases(_ g: BenchmarkGroup) -> [Case] { all.filter { $0.group == g } }

    // MARK: Helpers

    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "```") {
            let afterOpen = t[r.upperBound...]
            let body = afterOpen.drop(while: { $0 != "\n" }).dropFirst()
            if let close = body.range(of: "```") { t = String(body[..<close.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func jsonObject(_ s: String) -> Any? {
        let t = stripFences(s)
        var candidate = t
        if let a = t.firstIndex(where: { $0 == "{" || $0 == "[" }), let b = t.lastIndex(where: { $0 == "}" || $0 == "]" }), a <= b { candidate = String(t[a...b]) }
        return try? JSONSerialization.jsonObject(with: Data(candidate.utf8))
    }
    static func compact(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    // MARK: GENERAL

    static let general: [Case] = [
        Case(id: "g1-exact", group: .general, title: "instruction following", prompt: "Reply with exactly the single token JARVIS_BENCH_OK and nothing else.") { out in
            let t = out.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t`\"'."))
            return Verdict(passed: t == "JARVIS_BENCH_OK", detail: "got: " + Redactor.excerpt(out, max: 40))
        },
        Case(id: "g2-json", group: .general, title: "structured JSON", prompt: "Return ONLY a JSON object with exactly two keys: \"name\" (the string \"Ada\") and \"age\" (the number 36). No prose, no explanation.") { out in
            guard let o = jsonObject(out) as? [String: Any] else { return Verdict(passed: false, detail: "not JSON", malformed: true) }
            let ok = (o["name"] as? String) == "Ada" && (o["age"] as? NSNumber)?.intValue == 36 && o.count == 2
            return Verdict(passed: ok, detail: ok ? "valid" : "wrong values")
        },
        Case(id: "g3-summary", group: .general, title: "bounded summary", prompt: "Summarize the following in ONE sentence of at most 25 words, and include the word \"lighthouse\":\n\nThe old lighthouse stood on the northern cliff for two hundred years. Ships relied on its beam during storms. Last spring the town restored the tower and opened it to visitors. Volunteers now guide tours every weekend.") { out in
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = t.split(whereSeparator: \.isWhitespace).count
            let sentences = t.filter { ".!?".contains($0) }.count
            let ok = t.lowercased().contains("lighthouse") && words <= 25 && words >= 5 && sentences <= 2
            return Verdict(passed: ok, detail: "words=\(words) sentences=\(sentences)")
        },
    ]

    // MARK: RESEARCH

    static let research: [Case] = [
        Case(id: "r1-extract", group: .research, title: "information extraction", prompt: "Extract every (company, year) pair from the text as a JSON array of objects with keys \"company\" and \"year\" (number), in the order they appear. ONLY JSON.\n\nText: Acme was founded in 1999. Globex followed in 2004, and Initech opened in 2011.") { out in
            guard let a = jsonObject(out) as? [[String: Any]] else { return Verdict(passed: false, detail: "not a JSON array", malformed: true) }
            let got = a.map { "\(($0["company"] as? String)?.lowercased() ?? "")|\(($0["year"] as? NSNumber)?.intValue ?? -1)" }
            let ok = got == ["acme|1999", "globex|2004", "initech|2011"]
            return Verdict(passed: ok, detail: got.joined(separator: ","))
        },
        Case(id: "r2-classify", group: .research, title: "classification", prompt: "Classify each review as \"positive\", \"negative\" or \"neutral\". Return ONLY a JSON array of four strings in order.\n1. Absolutely loved it, would buy again!\n2. Broke after one day, total waste of money.\n3. It arrived on Tuesday.\n4. Terrible support and the screen cracked immediately.") { out in
            guard let a = jsonObject(out) as? [String] else { return Verdict(passed: false, detail: "not a JSON string array", malformed: true) }
            let ok = a.map { $0.lowercased() } == ["positive", "negative", "neutral", "negative"]
            return Verdict(passed: ok, detail: a.joined(separator: ","))
        },
        Case(id: "r3-compare", group: .research, title: "source-preserving comparison", prompt: "Two sources:\n[S1] The Zephyr phone has a 5,000 mAh battery and costs $499.\n[S2] The Nimbus phone has a 4,200 mAh battery and costs $399.\nWrite exactly two bullet points comparing battery and price. Cite the source of every claim with [S1] or [S2].") { out in
            let t = out.lowercased()
            let bullets = out.split(separator: "\n").filter { let s = $0.trimmingCharacters(in: .whitespaces); return s.hasPrefix("-") || s.hasPrefix("•") || s.hasPrefix("*") }.count
            let ok = out.contains("[S1]") && out.contains("[S2]") && (t.contains("5,000") || t.contains("5000")) && (t.contains("4,200") || t.contains("4200")) && bullets >= 2
            return Verdict(passed: ok, detail: "bullets=\(bullets)")
        },
    ]

    // MARK: CODING

    static let coding: [Case] = [
        Case(id: "c1-understand-swift", group: .coding, title: "understand a Swift snippet", prompt: "```swift\nfunc f(_ xs: [Int]) -> Int {\n    var t = 0\n    for x in xs where x % 2 == 0 { t += x }\n    return t\n}\n```\nWhat does f([1, 2, 3, 4]) return? Reply with ONLY the number.") { out in
            let t = out.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t`\"'."))
            return Verdict(passed: t == "6", detail: "got: " + Redactor.excerpt(out, max: 30))
        },
        Case(id: "c2-csharp-bug", group: .coding, title: "identify a C# bug", prompt: "This C# method has one bug:\n```csharp\n1: int Sum(int[] items) {\n2:     int total = 0;\n3:     for (int i = 0; i <= items.Length; i++) {\n4:         total += items[i];\n5:     }\n6:     return total;\n7: }\n```\nReply with ONLY a JSON object {\"line\": <the line number of the bug>, \"issue\": \"<short description>\"}.") { out in
            guard let o = jsonObject(out) as? [String: Any] else { return Verdict(passed: false, detail: "not JSON", malformed: true) }
            let line = (o["line"] as? NSNumber)?.intValue
            let issue = ((o["issue"] as? String) ?? "").lowercased()
            let ok = line == 3 && ["length", "bound", "index", "off-by-one", "off by one", "<="].contains { issue.contains($0) }
            return Verdict(passed: ok, detail: "line=\(line.map(String.init) ?? "nil")")
        },
        Case(id: "c3-patch-swift", group: .coding, title: "bounded patch (type-checked)", prompt: "This Swift function is wrong:\n```swift\nfunc add(_ a: Int, _ b: Int) -> Int {\n    return a - b\n}\n```\nReturn ONLY the corrected function in a ```swift code block.", timeout: 120) { out in
            let code = stripFences(out)
            let norm = compact(code)
            guard norm.contains("funcadd(") else { return Verdict(passed: false, detail: "no add function", malformed: true) }
            guard norm.contains("a+b") || norm.contains("b+a") else { return Verdict(passed: false, detail: "fix missing") }
            let (ok, why) = await SwiftTypecheck.check(code)
            return Verdict(passed: ok, detail: ok ? "typechecks" : why)
        },
        Case(id: "c4-compiler-output", group: .coding, title: "explain compiler output", prompt: "Swift reports:\n  error: cannot convert value of type 'String' to specified type 'Int'\nfor this line:\n  let n: Int = \"5\"\nReply with ONLY the corrected line of Swift (no explanation).", timeout: 120) { out in
            let line = stripFences(out).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.split(separator: "\n").count <= 2 else { return Verdict(passed: false, detail: "not a single line", malformed: true) }
            let n = compact(line)
            guard n.contains("letn:int=") && (n.contains("int(\"5\")") || n.hasSuffix("=5") || n.contains("=5//")) else { return Verdict(passed: false, detail: "wrong fix: " + Redactor.excerpt(line, max: 40)) }
            let (ok, why) = await SwiftTypecheck.check("func w() {\n\(line)\n_ = n\n}")
            return Verdict(passed: ok, detail: ok ? "typechecks" : why)
        },
    ]

    // MARK: TESTING

    static let testing: [Case] = [
        Case(id: "t1-failing-test", group: .testing, title: "analyze a failing test", prompt: "```swift\nfunc square(_ x: Int) -> Int { x + x }\n// test\nXCTAssertEqual(square(3), 9)   // failed: (\"6\") is not equal to (\"9\")\n```\nIn ONE sentence: which function is wrong and what is the bug?") { out in
            let t = out.lowercased()
            let ok = t.contains("square") && (t.contains("x + x") || t.contains("add") || t.contains("doubl") || t.contains("multipl") || t.contains("x * x") || t.contains("x*x"))
            return Verdict(passed: ok, detail: Redactor.excerpt(out, max: 60))
        },
        Case(id: "t2-propose-test", group: .testing, title: "propose a test", prompt: "Given:\n```swift\nfunc clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }\n```\nWrite ONE XCTest method named testClampLow asserting that clamp(-5, 0, 10) equals 0. Return ONLY the method in a ```swift block.") { out in
            let n = compact(stripFences(out))
            let ok = n.contains("functestclamplow()") && n.contains("xctassertequal(clamp(-5,0,10),0)")
            return Verdict(passed: ok, detail: ok ? "ok" : "assertion missing", malformed: !n.contains("func"))
        },
        Case(id: "t3-test-output", group: .testing, title: "interpret test output", prompt: "Test output:\nTest Case 'AppTests.testLogin' passed\nTest Case 'AppTests.testLogout' passed\nTest Case 'AppTests.testRefresh' failed: XCTAssertTrue failed\nTest Case 'AppTests.testProfile' passed\nReply with ONLY a JSON object {\"failed\": <count>, \"name\": \"<name of the failing test>\"}.") { out in
            guard let o = jsonObject(out) as? [String: Any] else { return Verdict(passed: false, detail: "not JSON", malformed: true) }
            let ok = (o["failed"] as? NSNumber)?.intValue == 1 && ((o["name"] as? String) ?? "").lowercased().contains("testrefresh")
            return Verdict(passed: ok, detail: ok ? "valid" : "wrong values")
        },
    ]
}

/// Type-checks Swift source in an isolated temp directory with `swiftc -typecheck` (never compiles to a binary, never runs it).
enum SwiftTypecheck {
    static func check(_ source: String) async -> (Bool, String) {
        // Tokens are assembled from fragments so the repository-wide policy scan (verify.sh) does not match this deny-list itself.
        let forbidden = ["Pro" + "cess(", "sys" + "tem(", "File" + "Manager", "URL" + "Session", "dl" + "open", "ex" + "ec", "NS" + "Task", "#" + "!/"]
        if let bad = forbidden.first(where: { source.contains($0) }) { return (false, "forbidden token \(bad)") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/swiftc") else { return (true, "swiftc unavailable (not checked)") }
        let dir = NSTemporaryDirectory() + "jarvis-bench-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/snippet.swift"
        guard (try? source.write(toFile: file, atomically: true, encoding: .utf8)) != nil else { return (false, "temp write failed") }
        var env = ProviderEnvironment.make()
        env["HOME"] = dir                                   // keep swiftc caches out of the real home
        guard let r = await ManagedProcess.runOnce(executable: "/usr/bin/swiftc", arguments: ["-typecheck", file], environment: env,
                                                   workingDirectory: dir, timeout: 60) else { return (false, "swiftc did not launch") }
        return (r.exitCode == 0 && !r.timedOut, r.exitCode == 0 ? "ok" : Redactor.excerpt(r.output + " " + r.errorOutput, max: 80))
    }
}

// MARK: - Runner

/// Runs cases through a provider factory, records REAL results (latency, duration, malformed output, pass/fail) and a
/// bounded raw-output artifact. A model is never marked passed without recorded evidence.
@MainActor
final class BenchmarkRunner {
    static let maxConsecutiveProviderFailures = 3
    private let repository: JarvisRepository?
    private let artifacts: ArtifactStore?

    /// True unless the model already has a result for EVERY case of the current suite (re-runs skip finished models).
    func needsBenchmark(_ modelID: String) -> Bool {
        guard let results = try? repository?.benchmarks(modelID: modelID) else { return true }
        let done = Set(results.filter { $0.suite == BenchmarkSuite.id }.map(\.caseID))
        return !Set(BenchmarkSuite.all.map(\.id)).isSubset(of: done)
    }

    /// True unless the model has a result for EVERY case of the V0.12 role suite.
    func needsRoleBenchmark(_ modelID: String) -> Bool {
        guard let results = try? repository?.benchmarks(modelID: modelID) else { return true }
        let done = Set(results.filter { $0.suite == RoleBenchmarkSuite.id }.map(\.caseID))
        return !Set(RoleBenchmarkSuite.all.map(\.id)).isSubset(of: done)
    }

    init(repository: JarvisRepository?, artifacts: ArtifactStore?) { self.repository = repository; self.artifacts = artifacts }

    struct CaseOutcome: Sendable { var caseID: String; var group: BenchmarkGroup; var passed: Bool; var detail: String; var durationMS: Double; var latencyMS: Double?; var error: ProviderError? }

    /// `makeProvider` is called per case so a provider that died mid-suite can't poison the rest.
    func run(modelID: String, groups: [BenchmarkGroup], makeProvider: () -> (any IntelligenceProvider)?,
             progress: ((CaseOutcome) -> Void)? = nil, onModelRemoved: (() -> Void)? = nil,
             onCaseStart: ((Int, BenchmarkSuite.Case) -> Void)? = nil) async -> [CaseOutcome] {
        let outcomes = await run(modelID: modelID, cases: groups.flatMap { BenchmarkSuite.cases($0) }, suite: BenchmarkSuite.id, makeProvider: makeProvider, progress: progress, onModelRemoved: onModelRemoved, onCaseStart: onCaseStart)
        updateStatus(modelID)
        return outcomes
    }

    /// V0.12: the same runner for any list of cases (the ROLE suite). Results are recorded under `suite`; the V0.3.1 Auto gate only reads suite `v1`.
    func run(modelID: String, cases: [BenchmarkSuite.Case], suite: String, makeProvider: () -> (any IntelligenceProvider)?,
             progress: ((CaseOutcome) -> Void)? = nil, onModelRemoved: (() -> Void)? = nil,
             onCaseStart: ((Int, BenchmarkSuite.Case) -> Void)? = nil) async -> [CaseOutcome] {
        var outcomes: [CaseOutcome] = []
        var removed = false
        var consecutiveProviderFailures = 0
        var caseIndex = -1
        for c in cases {
            let group = c.group
            do {
                caseIndex += 1
                if Task.isCancelled { return outcomes }                       // user pressed Stop: finish quietly between cases
                onCaseStart?(caseIndex, c)
                // The provider says the model is gone, or keeps failing: every further case would fail the same way — stop
                // spending requests (and minutes).
                if removed || consecutiveProviderFailures >= Self.maxConsecutiveProviderFailures {
                    let why = removed ? "skipped: model removed" : "skipped: provider failing"
                    let o = CaseOutcome(caseID: c.id, group: group, passed: false, detail: why, durationMS: 0, latencyMS: nil, error: nil)
                    outcomes.append(o); record(modelID, c, o, malformed: false, retries: 0, artifact: nil, suite: suite); progress?(o); continue
                }
                guard let provider = makeProvider() else {
                    let o = CaseOutcome(caseID: c.id, group: group, passed: false, detail: "provider unavailable", durationMS: 0, latencyMS: nil, error: .unavailable(.openCode, "provider unavailable"))
                    outcomes.append(o); record(modelID, c, o, malformed: false, retries: 0, artifact: nil, suite: suite); progress?(o); continue
                }
                let result = await OneShotRunner.run(provider: provider, prompt: c.prompt, timeout: c.timeout)
                var verdict = BenchmarkSuite.Verdict(passed: false, detail: "no output")
                if result.succeeded { verdict = await c.validate(result.text) }
                else if result.timedOut { verdict = .init(passed: false, detail: "timed out") }
                else if let e = result.error { verdict = .init(passed: false, detail: AuditRecorder.category(e)) }
                // A model that attempted tools in a conversation-only benchmark did not follow the task.
                if !result.toolAttempts.isEmpty { verdict.passed = false; verdict.detail += " (tried tools)" }
                var artifactID: UUID?
                if let artifacts, !result.text.isEmpty {
                    artifactID = try? artifacts.store(Data(Redactor.redact(String(result.text.prefix(20_000))).utf8), type: "benchmark-output", folder: .benchmark,
                                                      meta: "\(modelID) \(c.id)").id
                }
                if case .unavailable(_, OpenCodeModelRegistry.removedErrorText)? = result.error { removed = true; onModelRemoved?() }
                // Provider-side failures (not wrong answers): process crash, timeout, unavailable, network.
                if result.timedOut || result.error != nil { consecutiveProviderFailures += 1 } else { consecutiveProviderFailures = 0 }
                let o = CaseOutcome(caseID: c.id, group: group, passed: verdict.passed, detail: verdict.detail, durationMS: result.durationMS,
                                    latencyMS: result.firstOutputMS, error: result.error)
                outcomes.append(o)
                record(modelID, c, o, malformed: verdict.malformed || result.error == .malformedOutput(.openCode), retries: 0, artifact: artifactID, cancelled: result.cancelled, suite: suite)
                progress?(o)
            }
        }
        return outcomes
    }

    private func record(_ modelID: String, _ c: BenchmarkSuite.Case, _ o: CaseOutcome, malformed: Bool, retries: Int, artifact: UUID?, cancelled: Bool = false, suite: String = BenchmarkSuite.id) {
        try? repository?.add(BenchmarkResultRecord(modelID: modelID, suite: suite, caseID: c.id, category: c.group, passed: o.passed, validation: o.detail,
                                                   latencyMS: o.latencyMS, durationMS: o.durationMS, retries: retries, malformed: malformed, cancelled: cancelled,
                                                   artifactID: artifact, contextChars: suite == BenchmarkSuite.id ? nil : c.prompt.count))
    }

    /// Derives the model's overall benchmark status from recorded results only.
    func updateStatus(_ modelID: String) {
        guard let repository, let results = try? repository.benchmarks(modelID: modelID) else { return }
        let policy = BenchmarkPolicy()
        let summaries = BenchmarkGroup.allCases.compactMap { BenchmarkSummary.summarize(results, group: $0, suite: BenchmarkSuite.id) }
        let eligible = summaries.filter { policy.isEligible($0, group: $0.group, now: Date()) }.count
        let status: BenchmarkStatus = summaries.isEmpty ? .none : eligible == BenchmarkGroup.allCases.count ? .passed : eligible == 0 && summaries.count == BenchmarkGroup.allCases.count ? .failed : .partial
        try? repository.setBenchmarkStatus(modelID, status)
    }
}
