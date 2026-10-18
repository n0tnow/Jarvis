import Foundation
import Testing
@testable import Jarvis

// V1.0 reliability pass — stuck-task detection, provider resilience, resource budgeting, overnight-safe execution, progress truth, checkpoint hygiene and resume revalidation, content-free telemetry.
// Pure logic with injected clocks: no process, no provider, no timer, no model.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func live(_ phase: TaskLiveness.Phase, now: TimeInterval = 0, transition: TimeInterval = 0, output: TimeInterval? = nil, change: TimeInterval? = nil, identical: Int = 0, retries: Int = 0,
                  provider: Bool = true, fallback: Bool = false, present: Bool = true) -> TaskLiveness {
    TaskLiveness(phase: phase, now: t0.addingTimeInterval(now), lastTransitionAt: t0.addingTimeInterval(transition), lastOutputAt: output.map { t0.addingTimeInterval($0) }, lastObservedChangeAt: change.map { t0.addingTimeInterval($0) },
                 identicalFailures: identical, retriesUsed: retries, providerAvailable: provider, fallbackAvailable: fallback, userPresent: present)
}

// MARK: Stuck detection

@Suite("V1.0 reliability · deterministic stuck-task detection")
struct StuckDetectorTests {
    @Test("waiting for a person or for capacity is never stuck")
    func waiting() {
        #expect(StuckTaskDetector.evaluate(live(.waitingForApproval, now: 99_999)) == .waiting)
        #expect(StuckTaskDetector.evaluate(live(.waitingForCapacity, now: 99_999)) == .waiting)
    }

    @Test("a healthy step, a quiet-but-recent provider and an active tool are healthy")
    func healthy() {
        #expect(StuckTaskDetector.evaluate(live(.runningProvider, now: 100, transition: 0, output: 90)) == .healthy)
        #expect(StuckTaskDetector.evaluate(live(.runningTool, now: 500, transition: 0, change: 480)) == .healthy)
        #expect(StuckTaskDetector.evaluate(live(.planning, now: 60, transition: 0)) == .healthy)
    }

    @Test("measurable silence is detected: no provider output, no tool activity, no state change")
    func silence() {
        guard case .stuck(let r1, _) = StuckTaskDetector.evaluate(live(.runningProvider, now: 300, transition: 0, output: 10)) else { Issue.record("expected stuck"); return }
        #expect(r1.contains(.noProviderOutput))
        guard case .stuck(let r2, _) = StuckTaskDetector.evaluate(live(.runningTool, now: 1_200, transition: 0, change: 100)) else { Issue.record("expected stuck"); return }
        #expect(r2.contains(.noToolActivity))
        guard case .stuck(let r3, _) = StuckTaskDetector.evaluate(live(.planning, now: 2_000, transition: 0)) else { Issue.record("expected stuck"); return }
        #expect(r3.contains(.noStateChange))
    }

    @Test("the outcome order is fixed and bounded: retry once, then fall back, then ask (present) or fail honestly (away)")
    func outcomes() {
        func action(_ l: TaskLiveness) -> StuckAction? { if case .stuck(_, let a) = StuckTaskDetector.evaluate(l) { return a }; return nil }
        #expect(action(live(.runningProvider, now: 400, transition: 0, retries: 0)) == .retry)
        #expect(action(live(.runningProvider, now: 400, transition: 0, retries: 1, fallback: true)) == .fallbackProvider)
        #expect(action(live(.runningProvider, now: 400, transition: 0, retries: 1, fallback: false, present: true)) == .askUser)
        #expect(action(live(.runningProvider, now: 400, transition: 0, retries: 1, fallback: false, present: false)) == .failHonestly)
        // the same failure twice: another identical try is pointless
        #expect(action(live(.runningTool, now: 5, transition: 0, identical: 2, fallback: true)) == .fallbackProvider)
        #expect(action(live(.runningTool, now: 5, transition: 0, identical: 2, present: false)) == .failHonestly)
        // an unavailable provider: fall back, else ask (present) or PAUSE (away) — never retry into a dead provider
        #expect(action(live(.runningProvider, now: 5, transition: 0, output: 4, provider: false, fallback: true)) == .fallbackProvider)
        #expect(action(live(.runningProvider, now: 5, transition: 0, output: 4, provider: false, present: false)) == .pause)
        #expect(action(live(.runningProvider, now: 5, transition: 0, output: 4, provider: false, present: true)) == .askUser)
    }
}

// MARK: Provider resilience

@Suite("V1.0 reliability · provider resilience")
struct ProviderResilienceTests {
    private final class Clock: @unchecked Sendable { var now = t0 }

    @Test("retry schedule: bounded, exponential, capped, transient failures only")
    func retry() {
        let r = RetrySchedule()
        #expect(r.delay(afterAttempt: 0) == 2 && r.delay(afterAttempt: 1) == 4 && r.delay(afterAttempt: 9) == 30)
        #expect(r.shouldRetry(.offline, retriesSoFar: 0) && r.shouldRetry(.crashed, retriesSoFar: 1) && !r.shouldRetry(.offline, retriesSoFar: 2))
        for k in [ProviderFailureKind.timeout, .rateLimited, .outOfBalance, .authentication, .apiChanged, .malformed, .cancelled] { #expect(!r.shouldRetry(k, retriesSoFar: 0), Comment(rawValue: k.rawValue)) }
    }

    @Test("the circuit opens after consecutive failures, stays open for the cooldown, lets ONE probe through, and closes on success")
    func circuit() {
        let clock = Clock()
        let book = ProviderResilienceBook(failuresToOpen: 2, clock: { clock.now })
        #expect(book.admit("a") && book.state("a") == .closed)
        book.recordFailure("a", .offline)
        #expect(book.state("a") == .closed)
        book.recordFailure("a", .offline)
        guard case .open(let until) = book.state("a") else { Issue.record("expected open"); return }
        #expect(!book.admit("a") && until > clock.now)
        clock.now = until.addingTimeInterval(1)
        #expect(book.state("a") == .halfOpen)
        #expect(book.admit("a"), "first probe")
        #expect(!book.admit("a"), "only one probe at a time")
        book.recordFailure("a", .offline)
        if case .open(let again) = book.state("a") { #expect(again > until, "the cooldown grows") } else { Issue.record("a failed probe reopens the circuit") }
        clock.now = clock.now.addingTimeInterval(10_000)
        #expect(book.admit("a"))
        book.recordSuccess("a")
        #expect(book.state("a") == .closed && book.circuit("a").consecutiveFailures == 0)
    }

    @Test("balance, authentication and API changes open the circuit at once; a user cancel is nobody's fault")
    func immediate() {
        let book = ProviderResilienceBook(clock: { t0 })
        for k in [ProviderFailureKind.outOfBalance, .authentication, .apiChanged] { let b = ProviderResilienceBook(clock: { t0 }); b.recordFailure("p", k); if case .open = b.state("p") {} else { Issue.record(k.rawValue) } }
        book.recordFailure("p", .cancelled); book.recordFailure("p", .cancelled); book.recordFailure("p", .cancelled)
        #expect(book.state("p") == .closed && book.circuit("p").totalFailures == 0)
    }

    @Test("fallback: never paid, never the failed one, never an open circuit, and an explicit choice never falls back")
    func fallback() {
        let book = ProviderResilienceBook(failuresToOpen: 1, clock: { t0 })
        book.recordFailure("codex", .offline)
        let order = [FallbackCandidate(id: "claude", cost: .subscription), FallbackCandidate(id: "codex", cost: .subscription), FallbackCandidate(id: "opencode", cost: .freeCloud), FallbackCandidate(id: "gpt-paid", cost: .paid), FallbackCandidate(id: "local", cost: .local)]
        #expect(FallbackPolicy.candidates(order: order, failed: "claude", explicitChoice: nil, book: book).map(\.id) == ["opencode", "local"])
        #expect(FallbackPolicy.candidates(order: order, failed: "claude", explicitChoice: "claude", book: book).isEmpty)
        #expect(!FallbackPolicy.mayUse(FallbackCandidate(id: "gpt-paid", cost: .paid), explicitChoice: nil))
        #expect(FallbackPolicy.mayUse(FallbackCandidate(id: "gpt-paid", cost: .paid), explicitChoice: "gpt-paid"))
    }
}

// MARK: Resource budget

@Suite("V1.0 reliability · resource budgeting for 16 GB")
struct ResourceBudgetTests {
    private let b = ResourceBudget()

    @Test("only one local model is ever resident; a second is refused with what to unload")
    func oneModel() {
        let v = b.mayStart(.localModelLarge, running: [.localModelSmall])
        #expect(!v.allowed && v.unloadFirst == [.localModelSmall])
        #expect(b.mayStart(.localModelSmall, running: []).allowed)
    }

    @Test("the declared resident set stays under the budget; the user's own applications are never on the unload list")
    func budget() {
        #expect(b.limitMB == 12_288)
        let heavy: [ResidentComponent] = [.unityEditor, .browser, .xcode]
        let v = b.mayStart(.localModelLarge, running: heavy)
        #expect(!v.allowed, Comment(rawValue: v.reason))
        #expect(v.unloadFirst.allSatisfy { ![.unityEditor, .browser, .xcode].contains($0) })
        #expect(b.mayStart(.localModelSmall, running: [.unityEditor, .browser]).allowed)
    }

    @Test("memory pressure forbids starting anything large, but never blocks small helpers")
    func pressure() {
        #expect(!b.mayStart(.localModelSmall, running: [], pressure: .warning).allowed)
        #expect(!b.mayStart(.visionHelper, running: [], pressure: .critical).allowed)
        #expect(b.mayStart(.computerUseCapture, running: [], pressure: .critical).allowed)
    }

    @Test("two large models never coexist, and the preferred conversational model steps down next to Unity or Xcode")
    func preferred() {
        #expect(!b.mayStart(.visionHelper, running: [.localModelLarge]).allowed)
        #expect(b.preferredLocalModel(running: []) == .localModelLarge)
        #expect(b.preferredLocalModel(running: [.unityEditor]) == .localModelSmall)
        #expect(b.preferredLocalModel(running: [.xcode, .browser]) == .localModelSmall)
    }
}

// MARK: Overnight

@Suite("V1.0 reliability · overnight-safe execution")
struct OvernightPolicyTests {
    private func step(_ k: String, _ deps: [String] = [], state: OvernightStep.State = .pending, risk: RiskClass = .low, approval: Bool = false, dirty: Bool = false, ambiguous: Bool = false) -> OvernightStep {
        OvernightStep(key: k, title: k, dependsOn: deps, state: state, risk: risk, needsApproval: approval, touchesUserDirtyFile: dirty, ambiguous: ambiguous)
    }

    @Test("approvals, high-risk edits, user-dirty files and ambiguity pause while the user is away; the same steps just ask when they are present")
    func pauses() {
        #expect(OvernightPolicy.next([step("a", approval: true)], userAway: true) == .pause("a", reason: .needsApproval))
        #expect(OvernightPolicy.next([step("a", risk: .high)], userAway: true) == .pause("a", reason: .needsApproval))
        #expect(OvernightPolicy.next([step("a", dirty: true)], userAway: true) == .pause("a", reason: .userDirtyFile))
        #expect(OvernightPolicy.next([step("a", ambiguous: true)], userAway: true) == .pause("a", reason: .ambiguous))
        #expect(OvernightPolicy.next([step("a", approval: true)], userAway: false) == .run("a"))
        #expect(OvernightPolicy.next([step("a", risk: .critical)], userAway: false) == .pause("a", reason: .criticalAction), "critical actions never run, present or away")
    }

    @Test("independent safe steps continue past a paused one; dependents wait behind it")
    func independent() {
        let steps = [step("a", state: .paused, approval: true), step("b"), step("c", ["a"]), step("d", ["b"])]
        #expect(OvernightPolicy.continuable(steps) == ["b", "d"])
        #expect(OvernightPolicy.next(steps, userAway: true) == .run("b"))
        let done = [step("a", state: .paused), step("b", state: .passed), step("c", ["a"]), step("d", ["b"], state: .passed)]
        #expect(OvernightPolicy.next(done, userAway: true) == .blocked(reason: "waiting for the person"))
        #expect(OvernightPolicy.next([step("a", state: .passed)], userAway: true) == .finished)
    }

    @Test("a failed step blocks only its dependents; running steps are waited for within the parallel bound")
    func failures() {
        let steps = [step("a", state: .failed), step("b", ["a"]), step("c")]
        #expect(OvernightPolicy.next(steps, userAway: true) == .run("c"))
        #expect(OvernightPolicy.next([step("a", state: .running), step("b")], userAway: true, maxParallel: 1) == .waitForRunning)
        #expect(OvernightPolicy.next([step("a", state: .failed), step("b", ["a"])], userAway: true) == .blocked(reason: "a step failed and everything left depends on it"))
    }

    @Test("the morning report says what finished, what waits for the person and why, what failed — in both languages")
    func report() {
        let r = MorningReport(finished: ["scene"], waitingForPerson: [("delete", .needsApproval), ("push", .criticalAction)], failed: [("build", "compile error")], retried: 1, fellBack: 1, stuckEvents: 0)
        let tr = r.lines(language: .tr).joined(separator: "\n"), en = r.lines(language: .en).joined(separator: "\n")
        #expect(tr.contains("onayınızı bekliyor") && tr.contains("ben yapmam") && en.contains("needs your approval") && en.contains("Failed: build"))
    }
}

// MARK: Progress

@Suite("V1.0 reliability · progress is structure")
struct ReliabilityProgressTests {
    private func steps(_ states: [ProgressStep.State]) -> [ProgressStep] { states.enumerated().map { ProgressStep(title: "s\($0.offset + 1)", state: $0.element) } }

    @Test("the line is built from step states; the percentage is derived from verified steps only")
    func line() {
        let r = ProgressReport.build(steps([.passed, .passed, .running, .pending, .pending, .skipped]))
        #expect(r.total == 6 && r.measurable == 5 && r.passed == 2 && r.currentIndex == 2 && r.derivedPercent == 40)
        #expect(r.line(language: .en) == "Step 3/6 · running — s3 · verified 2/5")
        #expect(r.line(language: .tr).contains("Adım 3/6") && r.line(language: .tr).contains("çalışıyor"))
        #expect(ProgressReport.build(steps([.passed, .passed])).line(language: .en) == "All 2 steps are verified.")
        #expect(ProgressReport.build([]).derivedPercent == nil)
    }

    @Test("waiting, verifying, failure and interruption are said plainly")
    func states() {
        #expect(ProgressReport.build(steps([.passed, .waitingForApproval])).line(language: .en).contains("waiting for your approval"))
        #expect(ProgressReport.build(steps([.verifying])).line(language: .en).contains("verifying"))
        #expect(ProgressReport.build(steps([.passed, .failed, .pending])).line(language: .en).contains("blocked: step failed"))
        #expect(ProgressReport.build(steps([.interrupted, .pending])).blockedReason?.contains("resume") == true)
    }

    @Test("a model's percentage about a task is an unbacked claim")
    func percentages() {
        for text in ["Görev %80 tamamlandı.", "The task is 80% complete.", "İlerleme yüzde 60.", "Build is 95 percent done."] {
            #expect(ResponseClaimFirewall.findings(in: text).contains { $0.kind == .task }, Comment(rawValue: text))
        }
        #expect(ResponseClaimFirewall.findings(in: "Batarya yüzde 40 kaldı.").isEmpty, "a percentage that is not about a task is not a task claim")
    }
}

// MARK: Checkpoints and resume

@Suite("V1.0 reliability · checkpoint hygiene and resume revalidation")
struct ResumeTests {
    private let snap = ResumeSnapshot(taskID: "t1", planVersion: 2, workspaceRoot: "/tmp/p", gitHead: "abc", fileHashes: ["/tmp/p/a.swift": "h1", "/tmp/p/b.swift": "h2"], stepStates: ["s1": "passed"], openApprovalIDs: ["ap1"])

    private func truth(plan: Int = 2, exists: Bool = true, head: String? = "abc", files: [String: String?] = ["/tmp/p/a.swift": "h1", "/tmp/p/b.swift": "h2"], open: Set<String> = ["ap1"]) -> ResumeTruth {
        ResumeTruth(planVersion: plan, workspaceExists: exists, gitHead: head, currentFileHashes: files, approvalsStillOpen: open)
    }

    @Test("an unchanged world may resume — and re-observes first")
    func clean() {
        let issues = ResumeValidator.validate(snap, against: truth())
        #expect(issues.isEmpty && ResumeValidator.mayResume(issues))
        #expect(ResumeValidator.explain(issues, language: .en).contains("re-observe"))
    }

    @Test("a missing workspace, a new plan, another Git head, a changed or missing file each block the resume and are explained")
    func blockers() {
        #expect(ResumeValidator.validate(snap, against: truth(exists: false)) == [.workspaceMissing])
        #expect(ResumeValidator.validate(snap, against: truth(plan: 3)).contains(.planChanged(recorded: 2, current: 3)))
        #expect(ResumeValidator.validate(snap, against: truth(head: "def")).contains(.gitHeadChanged))
        #expect(ResumeValidator.validate(snap, against: truth(files: ["/tmp/p/a.swift": "CHANGED", "/tmp/p/b.swift": "h2"])).contains(.fileChanged("/tmp/p/a.swift")))
        #expect(ResumeValidator.validate(snap, against: truth(files: ["/tmp/p/a.swift": "h1", "/tmp/p/b.swift": nil])).contains(.fileMissing("/tmp/p/b.swift")))
        let issues = ResumeValidator.validate(snap, against: truth(head: "def", files: ["/tmp/p/a.swift": "X", "/tmp/p/b.swift": "h2"]))
        #expect(!ResumeValidator.mayResume(issues))
        let text = ResumeValidator.explain(issues, language: .tr)
        #expect(text.contains("a.swift") && text.contains("Git") && !text.contains("/tmp/p"), Comment(rawValue: text))           // names, never full paths
    }

    @Test("an approval that is no longer pending is informational, not a blocker")
    func approvals() {
        let issues = ResumeValidator.validate(snap, against: truth(open: []))
        #expect(issues == [.approvalNoLongerOpen("ap1")] && ResumeValidator.mayResume(issues))
    }

    @Test("checkpoints refuse secrets, chain-of-thought markers and raw audio references, and clip what they keep")
    func hygiene() {
        #expect(CheckpointHygiene.violations(in: "step passed: 3 files changed").isEmpty)
        #expect(CheckpointHygiene.violations(in: "<thinking>maybe the bug is</thinking>") == ["chain-of-thought marker"])
        #expect(CheckpointHygiene.violations(in: "saved /tmp/utterance.wav for later").contains("raw audio reference"))
        #expect(CheckpointHygiene.safeEvidence("<think>x</think>") == nil)
        #expect(CheckpointHygiene.safeEvidence(String(repeating: "a", count: 900))?.count == 400)
        #expect(CheckpointHygiene.safeEvidence("ok\u{7}done") == "ok done")
    }
}

// MARK: Telemetry

@MainActor
@Suite("V1.0 reliability · content-free telemetry")
struct TelemetryTests {
    @Test("an event is built from an audit entry without any text, bounded by capacity and retention, and cleared on request")
    func telemetry() {
        let log = DecisionAuditLog()
        let id = log.begin(source: .voice, utterance: "Safari'yi aç lütfen, şifrem hunter2")
        log.update(id) { $0.production = Decision(intent: .macosApplicationAction, confidence: 0.93, normalized: "Open Safari", target: "Safari", action: "launch", execution: true, provenance: .semanticLexicon); $0.route = "action"; $0.outcome = "verified success" }
        let event = DecisionTelemetry.event(from: log.entry(id)!)!
        let rendered = "\(event)"
        #expect(!rendered.contains("şifrem") && !rendered.contains("hunter2") && !rendered.contains("Safari") && event.confidenceBucket == 9 && event.provenance == .semanticLexicon)

        var tel = DecisionTelemetry(capacity: 3, retention: 100)
        let now = Date(timeIntervalSince1970: 1_000)
        for i in 0..<5 { var e = event; e.at = now.addingTimeInterval(Double(i)); tel.ingest(e, now: now.addingTimeInterval(Double(i))) }
        #expect(tel.events.count == 3)
        var old = event; old.at = now.addingTimeInterval(-500)
        tel.ingest(old, now: now)
        #expect(!tel.events.contains { $0.at == old.at }, "expired by retention")
        #expect(tel.summary().contains("macos_application_action=3") && tel.deterministicShare == 1)
        tel.clear()
        #expect(tel.events.isEmpty)
        #expect(DecisionTelemetry.latencyBucket(0.03) == 0 && DecisionTelemetry.latencyBucket(0.3) == 500 && DecisionTelemetry.latencyBucket(9) == 5000)
    }
}
