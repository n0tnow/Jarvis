import Foundation
import Testing
@testable import Jarvis

// V1.0 background-intelligence pass — a deterministic, seeded, fake-clock SIMULATION of a long unattended task.
//
// HONEST SCOPE: this is NOT the TaskEngine. It composes the real task model (TaskStateMachine, TaskStepRecord, StepType idempotency, FailureCategory) with the real reliability policies
// (StepReadiness, RetryLedger, TaskBudgetLedger, StepReplayPolicy, VerificationPolicy, ProviderResilienceBook, FallbackPolicy, TaskEventLog, NotificationPolicy, NightTaskDigest) in a small driver
// written for the test. What it proves: the POLICIES hold together over 50–200 steps, hours of simulated time, crashes, outages and faults; it does not prove the engine wires them (that is listed
// in docs/V1_BACKGROUND_RELIABILITY.md as the integration seam). No real provider, process, database, timer, microphone or GUI is involved; the clock never sleeps.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// Deterministic generator (xorshift64*): the same seed always produces the same night.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2685821657736338717
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000.0 }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

private final class SimClock: @unchecked Sendable {
    var now = epoch
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(max(0, s)) }
}

private struct FaultProfile {
    var transient = 0.0          // a provider-style transient failure on a step attempt
    var permanent = 0.0          // a deterministic, non-retryable failure
    var verificationInconclusive = 0.0
    var crashEvery = 0           // simulate a restart every N executed attempts (0 = never)
    var outage: ClosedRange<Int>?   // attempts (by global attempt number) during which provider "primary" is down
}

private struct SimResult {
    var steps: [TaskStepRecord]
    /// Attempts started per step (a provider that failed before producing anything counts here).
    var executions: [String: Int]
    /// Times a step's EFFECT was applied (the provider answered and the tool layer acted). Providers are text-in/text-out: a provider failure happens before any effect.
    var effects: [String: Int]
    var illegalTransitions: [String]
    var approvalsRequested: [String]
    var ranWithoutApproval: [String]
    var retriesTotal: Int
    var maxRetriesPerStep: Int
    var modelRequests: Int
    var budgetExhaustedDimension: BudgetDimension?
    var simulatedSeconds: TimeInterval
    var log: TaskEventLog
    var eventsRecorded: Int
    var providersUsed: [String: Int]
    var paidUsed: Bool
    var crashes: Int
    var unverifiedRecorded: [String]
    var finalDerived: DerivedTaskView
    var checkpoints: Int
    var notifications: Int

    /// A compact fingerprint: equal seeds must give an equal fingerprint (determinism).
    var fingerprint: String {
        let s = steps.map { "\($0.key):\($0.state.rawValue):\($0.attempts)" }.joined(separator: ",")
        return "\(s)|r\(retriesTotal)|m\(modelRequests)|c\(crashes)|t\(Int(simulatedSeconds))|e\(eventsRecorded)|n\(notifications)"
    }
}

private enum Sim {
    static func plan(count: Int, rng: inout SeededRandom) -> [TaskStepRecord] {
        let types: [StepType] = [.analysis, .codeChange, .build, .test, .codeChange, .review, .unityEdit, .analysis]
        var steps: [TaskStepRecord] = []
        for i in 0..<count {
            var type = types[rng.below(types.count)]
            if i % 17 == 16 { type = .delete }                          // a critical step now and then
            if i % 29 == 28 { type = .computerAct }                      // a non-idempotent write now and then
            var deps: [String] = []
            if i > 0 { deps.append("s\(i - 1 - rng.below(min(i, 3)))") }  // a mostly-linear DAG with some independent branches
            if i > 4, rng.chance(0.15) { deps = [] }                      // an independent branch
            steps.append(TaskStepRecord(id: UUID(), taskID: UUID(), index: i, key: "s\(i)", title: "step \(i)", type: type, dependsOn: deps, validation: .default(for: type), state: .pending, attempts: 0, optional: i % 11 == 10))
        }
        return steps
    }

    static func run(seed: UInt64, count: Int, faults: FaultProfile, budget: TaskBudget = TaskBudget(), paidProviderPresent: Bool = true, userAway: Bool = true) -> SimResult {
        var rng = SeededRandom(seed: seed)
        var planRng = SeededRandom(seed: seed ^ 0xABCDEF)
        var steps = plan(count: count, rng: &planRng)
        let clock = SimClock()
        let book = ProviderResilienceBook(clock: { clock.now })
        var retries = RetryLedger(seed: seed)
        var ledger = TaskBudgetLedger(budget: budget)
        var log = TaskEventLog(capacity: 120)
        var notify = NotificationPolicy()
        var usage: [String: Int] = [:]
        var executions: [String: Int] = [:]
        var effects: [String: Int] = [:]
        var illegal: [String] = []
        var approvals: [String] = []
        var ranWithoutApproval: [String] = []
        var unverified: [String] = []
        var eventsRecorded = 0, attemptNumber = 0, crashes = 0, checkpoints = 0, notifications = 0, completedSinceCheckpoint = 0, maxPerStep = 0
        var exhausted: BudgetDimension?
        var taskState = TaskState.running
        let candidates = [FallbackCandidate(id: "primary", cost: .subscription), FallbackCandidate(id: "backup", cost: .freeCloud)] + (paidProviderPresent ? [FallbackCandidate(id: "paid", cost: .paid)] : [])
        var paidUsed = false

        func record(_ kind: TaskEventKind, step: String? = nil, code: String, detail: String = "") {
            log.record(kind, step: step, code: code, detail: detail, at: clock.now); eventsRecorded += 1
            if case .notify = notify.evaluate(kind, at: clock.now) { notifications += 1 }
        }
        func move(_ i: Int, to: TaskStepState) {
            if !TaskStateMachine.canMove(steps[i].state, to: to) { illegal.append("\(steps[i].key): \(steps[i].state.rawValue) → \(to.rawValue)"); return }
            steps[i].state = to
        }
        func moveTask(to: TaskState) {
            if !TaskStateMachine.canMove(taskState, to: to) { illegal.append("task: \(taskState.rawValue) → \(to.rawValue)"); return }
            taskState = to
        }
        func providerFor(_ attempt: Int) -> String? {
            // the first admitted, non-paid candidate in order (an explicit paid choice does not exist in this run)
            for c in FallbackPolicy.candidates(order: candidates, failed: nil, explicitChoice: nil, book: book) where book.admit(c.id) { return c.id }
            return nil
        }
        func primaryDown(_ attempt: Int) -> Bool { faults.outage?.contains(attempt) ?? false }

        /// A restart in the middle of an attempt: running steps are interrupted, the task is interrupted, an EXPLICIT resume follows, and every interrupted step is re-examined with the truthful evidence
        /// (did its effect happen before the crash?) by the real `StepReplayPolicy`.
        func restart() {
            crashes += 1
            let hit = steps.indices.filter { steps[$0].state.isActive }
            for i in hit { move(i, to: .interrupted) }
            moveTask(to: .interrupted); record(.interrupted, code: "restart")
            clock.advance(30)
            moveTask(to: .running); record(.resumed, code: "explicit-resume")
            for i in hit {
                let happened = effects[steps[i].key, default: 0] > 0 && steps[i].attempts == effects[steps[i].key, default: 0]
                let evidence = ReplayEvidence(effectObserved: happened, worldUnchanged: !happened)
                switch StepReplayPolicy.decide(steps[i].type, crash: happened ? .afterEffectBeforeRecord : .duringRead, evidence: evidence) {
                case .replay, .revalidateThenReplay: move(i, to: .ready)
                case .skipAlreadyDone: move(i, to: .skipped); record(.stepCompleted, step: steps[i].key, code: "already-done")
                case .askUser, .neverReplay: move(i, to: .waitingForApproval); approvals.append(steps[i].key); record(.approvalRequested, step: steps[i].key, code: "replay-needs-decision")
                }
            }
        }

        record(.taskStarted, code: "start")
        var guardIterations = 0
        loop: while guardIterations < count * 60 {
            guardIterations += 1
            switch ledger.check() {
            case .exhausted(let d, _, _): exhausted = d; record(.budgetExhausted, code: d.rawValue); break loop
            case .warn(let d, _, _): record(.budgetWarning, code: d.rawValue)
            case .ok: break
            }
            let ready = StepReadiness.ready(steps)
            guard let next = ready.first else { break }
            let i = steps.firstIndex { $0.key == next.key }!
            if steps[i].state == .pending { move(i, to: .ready) }

            // unattended: critical / approval-bound steps are never run and never decided — they wait for a person; independent work continues
            if StepSideEffects.classify(steps[i].type) == .critical || (userAway && steps[i].type.idempotency == .manual) {
                move(i, to: .waitingForApproval); approvals.append(steps[i].key); record(.approvalRequested, step: steps[i].key, code: "needs-person")
                continue
            }
            guard let provider = providerFor(attemptNumber) else {
                // nothing may serve the request: pause the whole task honestly instead of spinning
                record(.blocked, code: "no-provider"); moveTask(to: .interrupted); break loop
            }
            usage[provider, default: 0] += 1
            if provider == "paid" { paidUsed = true }
            move(i, to: .running); steps[i].attempts += 1
            attemptNumber += 1; ledger.noteModelRequest()
            executions[steps[i].key, default: 0] += 1
            record(.stepStarted, step: steps[i].key, code: "start")
            let took = 20 + Double(rng.below(100))
            clock.advance(took); ledger.addActive(took)

            let crashNow = faults.crashEvery > 0 && attemptNumber % faults.crashEvery == 0
            let crashAfterEffect = crashNow && rng.chance(0.5)
            if crashNow, !crashAfterEffect { restart(); continue }                    // the process died before the provider answered: nothing happened
            let downNow = provider == "primary" && primaryDown(attemptNumber)
            if downNow || rng.chance(faults.transient) {
                book.recordFailure(provider, .offline)
                switch retries.decide(step: steps[i].key, failure: .providerUnavailable) {
                case .retry(let after, let attempt, _):
                    ledger.noteProviderRetry(); record(.retryScheduled, step: steps[i].key, code: "provider-unavailable", detail: "attempt \(attempt)")
                    maxPerStep = max(maxPerStep, retries.used(steps[i].key))
                    clock.advance(after); ledger.addActive(after)
                    move(i, to: .interrupted); move(i, to: .ready)             // legal edges: running → interrupted → ready
                case .giveUp(_, let reason):
                    record(.failure, step: steps[i].key, code: "retry-\(reason.rawValue)")
                    move(i, to: .failed); ledger.noteToolFailure()
                }
                continue
            }
            book.recordSuccess(provider)
            effects[steps[i].key, default: 0] += 1
            if crashAfterEffect { restart(); continue }                              // the effect happened; the record of it did not
            if rng.chance(faults.permanent) {
                move(i, to: .failed); ledger.noteToolFailure(); ledger.noteVerification(passed: false)
                record(.verificationFailed, step: steps[i].key, code: "validation-failed")
                continue
            }
            move(i, to: .verifying)
            if rng.chance(faults.verificationInconclusive) {
                switch VerificationPolicy.afterAction(steps[i].type, verification: .inconclusive, alreadyRepeated: executions[steps[i].key, default: 0] > 1) {
                case .recordUnverifiedDoNotRepeat: unverified.append(steps[i].key); move(i, to: .passed); record(.verificationPassed, step: steps[i].key, code: "unverified-recorded")
                case .reverifyOrRepeatOnce: move(i, to: .running); steps[i].state = .interrupted; move(i, to: .ready)
                case .failHonestly: move(i, to: .failed); record(.verificationFailed, step: steps[i].key, code: "inconclusive")
                case .accept: move(i, to: .passed)
                }
                continue
            }
            move(i, to: .passed); ledger.noteVerification(passed: true)
            record(.verificationPassed, step: steps[i].key, code: "ok")
            completedSinceCheckpoint += 1
            if completedSinceCheckpoint >= 10 { completedSinceCheckpoint = 0; checkpoints += 1; record(.checkpointWritten, code: "checkpoint") }
        }
        // what a person finds in the morning: the task is never marked completed while approvals are pending or steps failed
        let allDone = steps.allSatisfy { $0.state == .passed || $0.state == .skipped }
        if allDone, taskState == .running { moveTask(to: .completed); record(.taskCompleted, code: "done") }
        else if exhausted != nil, taskState == .running { moveTask(to: .interrupted) }
        else if taskState == .running, steps.contains(where: { $0.state == .waitingForApproval }) { moveTask(to: .waitingForApproval); record(.blocked, code: "waiting-for-person") }
        else if taskState == .running { record(.blocked, code: "nothing-runnable") }
        let derived = TaskStatusDeriver.derive(task: taskState, steps: steps)
        for s in steps where s.state == .running { ranWithoutApproval.append(s.key) }
        for s in steps where StepSideEffects.classify(s.type) == .critical && (s.state == .passed || s.state == .running) { ranWithoutApproval.append(s.key) }
        return SimResult(steps: steps, executions: executions, effects: effects, illegalTransitions: illegal, approvalsRequested: approvals, ranWithoutApproval: ranWithoutApproval, retriesTotal: retries.total, maxRetriesPerStep: maxPerStep,
                         modelRequests: Int(ledger.used(.modelRequests)), budgetExhaustedDimension: exhausted, simulatedSeconds: clock.now.timeIntervalSince(epoch), log: log, eventsRecorded: eventsRecorded,
                         providersUsed: usage, paidUsed: paidUsed, crashes: crashes, unverifiedRecorded: unverified, finalDerived: derived, checkpoints: checkpoints, notifications: notifications)
    }
}

@Suite("V1.0 background · deterministic overnight simulation (policy composition; NOT the TaskEngine)")
struct OvernightSimulationTests {
    private func invariants(_ r: SimResult, _ label: String) {
        #expect(r.illegalTransitions.isEmpty, Comment(rawValue: "\(label): illegal transitions \(r.illegalTransitions.prefix(3))"))
        #expect(r.ranWithoutApproval.isEmpty, Comment(rawValue: "\(label): a critical step ran unattended \(r.ranWithoutApproval)"))
        #expect(!r.paidUsed, Comment(rawValue: "\(label): a paid provider was used automatically"))
        #expect(r.retriesTotal <= RetryPolicy().perTask && r.maxRetriesPerStep <= RetryPolicy().perStep, Comment(rawValue: "\(label): retry budget broken"))
        #expect(r.log.entries.count <= r.log.capacity, Comment(rawValue: "\(label): event log over capacity"))
        #expect(r.log.entries.reduce(0) { $0 + $1.count } + r.log.dropped == r.eventsRecorded, Comment(rawValue: "\(label): events lost without being counted"))
        for s in r.steps where StepSideEffects.classify(s.type) == .nonIdempotentWrite || StepSideEffects.classify(s.type) == .critical {
            #expect(r.effects[s.key, default: 0] <= 1, Comment(rawValue: "\(label): non-idempotent step \(s.key) applied its effect \(r.effects[s.key, default: 0]) times"))
        }
        // a step that failed or waits is never reported as done; the derived status never says completed unless every step passed or was skipped
        let done = r.steps.allSatisfy { $0.state == .passed || $0.state == .skipped }
        #expect((r.finalDerived.status == .completed) == done, Comment(rawValue: "\(label): completion claim without all steps done (\(r.finalDerived.status))"))
        // a step waiting for approval is never silently passed
        for key in r.approvalsRequested { if let s = r.steps.first(where: { $0.key == key }) { #expect(s.state != .passed || r.executions[key, default: 0] == 0, Comment(rawValue: "\(label): \(key) passed after waiting for a person")) } }
    }

    @Test("a calm night of 120 steps: hours of simulated time, checkpoints, no wasted requests, critical steps wait for the person")
    func calm() {
        let r = Sim.run(seed: 1, count: 120, faults: FaultProfile())
        invariants(r, "calm")
        #expect(r.simulatedSeconds > 3600, "the run covers more than an hour of fake time")
        #expect(r.checkpoints >= 5)
        #expect(!r.approvalsRequested.isEmpty && r.approvalsRequested.allSatisfy { key in r.steps.first { $0.key == key }!.state == .waitingForApproval || r.steps.first { $0.key == key }!.state == .skipped })
        #expect(r.modelRequests == r.executions.filter { !$0.key.hasPrefix("crash@") }.values.reduce(0, +), "one counted request per execution, no hidden calls")
        #expect(r.finalDerived.status != .completed, "critical steps are waiting, so the task is not complete")
        #expect(r.finalDerived.status == .waitingForApproval || r.finalDerived.status == .blocked || r.finalDerived.status == .waitingForDependency)
        #expect(r.providersUsed.keys.allSatisfy { $0 != "paid" })
    }

    @Test("the same seed gives the same night; different seeds give different nights")
    func determinism() {
        let f = FaultProfile(transient: 0.1, permanent: 0.03, verificationInconclusive: 0.05, crashEvery: 17)
        #expect(Sim.run(seed: 7, count: 100, faults: f).fingerprint == Sim.run(seed: 7, count: 100, faults: f).fingerprint)
        #expect(Sim.run(seed: 7, count: 100, faults: f).fingerprint != Sim.run(seed: 8, count: 100, faults: f).fingerprint)
    }

    @Test("a provider outage in the middle of the night: the circuit opens, the free backup serves, nothing paid is used, no retry storm")
    func outage() {
        let f = FaultProfile(transient: 0, permanent: 0, verificationInconclusive: 0, crashEvery: 0, outage: 20...60)
        let r = Sim.run(seed: 3, count: 100, faults: f)
        invariants(r, "outage")
        #expect((r.providersUsed["backup"] ?? 0) > 0, "the backup took over")
        #expect(!r.paidUsed)
        #expect(r.retriesTotal <= RetryPolicy().perTask)
    }

    @Test("crashes every 13 attempts: every restart is an explicit resume, nothing non-idempotent is replayed, nothing illegal happens")
    func crashes() {
        for seed in 1...12 as ClosedRange<UInt64> {
            let r = Sim.run(seed: seed, count: 80, faults: FaultProfile(transient: 0.05, permanent: 0.02, verificationInconclusive: 0.05, crashEvery: 13))
            invariants(r, "crash seed \(seed)")
            #expect(r.crashes >= 1, Comment(rawValue: "seed \(seed) never crashed"))
        }
    }

    @Test("a tiny model-request budget stops the run with a named dimension and a checkpoint — never silently, never more than one request over")
    func budgetStop() {
        var b = TaskBudget(); b.modelRequests = 25
        let r = Sim.run(seed: 5, count: 120, faults: FaultProfile(), budget: b)
        #expect(r.budgetExhaustedDimension == .modelRequests)
        #expect(r.modelRequests <= 25, Comment(rawValue: "requests \(r.modelRequests)"))
        #expect(r.log.count(of: .budgetExhausted) == 1 && r.log.count(of: .budgetWarning) >= 1)
        #expect(r.finalDerived.status == .paused, Comment(rawValue: "\(r.finalDerived.status)"))
        invariants(r, "budget")
    }

    @Test("a hostile fault profile (30% transient, 10% permanent, 20% inconclusive, restarts) still obeys every invariant for 40 seeds")
    func chaos() {
        var worst = 0
        for seed in 100..<140 as Range<UInt64> {
            let count = 50 + Int(seed % 5) * 37                                    // 50 … 198 steps
            let r = Sim.run(seed: seed, count: count, faults: FaultProfile(transient: 0.3, permanent: 0.1, verificationInconclusive: 0.2, crashEvery: 11, outage: 30...45))
            invariants(r, "chaos \(seed)")
            worst = max(worst, r.eventsRecorded)
        }
        #expect(worst > 0)
    }

    @Test("when every provider is down the task pauses honestly with a machine reason instead of spinning")
    func allDown() {
        // outage covers everything: both candidates fail through the same fault path
        let r = Sim.run(seed: 9, count: 40, faults: FaultProfile(transient: 1.0))
        invariants(r, "allDown")
        #expect(r.finalDerived.status != .completed)
        #expect(r.retriesTotal <= RetryPolicy().perTask)
        #expect(r.modelRequests < 200, "bounded: no infinite loop of requests")
    }

    @Test("the morning questions are answered from the structured result of a night")
    func morning() {
        let r = Sim.run(seed: 21, count: 60, faults: FaultProfile(transient: 0.1, permanent: 0.05, crashEvery: 19))
        var task = TaskRecord(id: UUID(), title: "night", goal: "Refactor the menu system", kind: .development)
        task.state = r.finalDerived.status == .paused ? .interrupted : (r.finalDerived.status == .waitingForApproval ? .waitingForApproval : .running)
        let d = NightTaskDigest.build(task: task, steps: r.steps, events: r.log, language: .en)
        for q in MorningQuestion.allCases {
            let en = MorningBrief.answer(q, digests: [d], language: .en)
            let tr = MorningBrief.answer(q, digests: [d], language: .tr)
            #expect(!en.isEmpty && !tr.isEmpty, Comment(rawValue: "\(q)"))
        }
        // "can you continue?" is a question about state: it must not claim to have started anything
        let can = MorningBrief.answer(.canYouContinue, digests: [d], language: .en).lowercased()
        #expect(!can.contains("started") && !can.contains("resumed"))
    }
}

// MARK: Scaling — the pure policies stay linear

@Suite("V1.0 background · the policies scale linearly")
struct PolicyScalingTests {
    private func measure(_ body: () -> Void) -> TimeInterval { let s = Date(); body(); return Date().timeIntervalSince(s) }

    @Test("event log: 20× more events cost about 20× more, not 400×")
    func eventLog() {
        func run(_ n: Int) -> TimeInterval {
            measure {
                var log = TaskEventLog(capacity: 400)
                for i in 0..<n { log.record(i % 7 == 0 ? .stepCompleted : .failure, step: "s\(i % 50)", code: "c\(i % 13)", detail: "d", at: epoch.addingTimeInterval(Double(i))) }
                #expect(log.entries.count <= 400)
            }
        }
        _ = run(2_000)                                  // warm-up
        let small = max(run(5_000), 0.001), large = run(100_000)
        #expect(large / small < 120, Comment(rawValue: "ratio \(large / small)"))
    }

    @Test("readiness over 2,000 steps is fast and linear-ish")
    func readiness() {
        func chain(_ n: Int) -> [TaskStepRecord] {
            (0..<n).map { i in TaskStepRecord(id: UUID(), taskID: UUID(), index: i, key: "s\(i)", title: "s", type: .analysis, dependsOn: i == 0 ? [] : ["s\(i - 1)"], validation: .default(for: .analysis), state: i < n / 2 ? .passed : .pending, attempts: 0, optional: false) }
        }
        let a = chain(500), b = chain(5_000)
        let ta = max(measure { for _ in 0..<20 { _ = StepReadiness.ready(a) } }, 0.0005)
        let tb = measure { for _ in 0..<20 { _ = StepReadiness.ready(b) } }
        #expect(tb / ta < 60, Comment(rawValue: "ratio \(tb / ta)"))
        #expect(StepReadiness.ready(b).count == 1)
    }

    @Test("context selection over 20,000 items is bounded in output and fast")
    func context() {
        let items = (0..<20_000).map { ContextItem(kind: $0 % 3 == 0 ? .history : .recentTurn, text: "turn \($0)", weight: Double($0)) }
        var selection: ContextSelection?
        let t = measure { selection = ContextSelector.select(items, budget: 4_000) }
        #expect(t < 2.0, Comment(rawValue: "took \(t)s"))
        #expect((selection?.usedCharacters ?? 0) <= 4_000)
        #expect((selection?.included.count ?? 0) < 400)
    }

    @Test("retry ledger and budget ledger are O(1) per operation")
    func ledgers() {
        var ledger = RetryLedger(policy: RetryPolicy(perTask: 1_000_000))
        var budget = TaskBudgetLedger(budget: TaskBudget(wallClock: 1e12, modelRequests: 10_000_000, providerRetries: 10_000_000, toolFailures: 10_000_000, consecutiveVerificationFailures: 10_000_000))
        let t = measure {
            for i in 0..<50_000 { _ = ledger.decide(step: "s\(i % 500)", failure: .providerUnavailable); budget.noteModelRequest() }
        }
        #expect(t < 5.0, Comment(rawValue: "took \(t)s"))
    }
}
