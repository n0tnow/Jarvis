import Foundation

// MARK: - Overnight-safe execution (V1.0 reliability pass)
//
// "The user is away" changes how JARVIS waits, never what it is allowed to do. The rules, all enforced here as data so they can be tested:
//   · a step that needs an approval, a critical action, or an edit to a file the user changed is NEVER run or decided while the user is away — it is PAUSED (the task keeps its checkpoint) and reported;
//   · independent safe steps (no dependency on a paused or failed step) continue;
//   · a transient failure is retried within the bounded `RetrySchedule`, a stuck step follows `StuckTaskDetector`, a provider failure follows `FallbackPolicy` — nothing retries forever;
//   · nothing is guessed: an ambiguous step pauses instead of choosing;
//   · everything that happened is recorded for the morning report (what finished, what is waiting for the person and why, what failed and why) — no chain-of-thought, no secret, no raw audio.
// This is the same TaskEngine semantics (approvals, leases, capability checks) applied with patience; it adds no scheduler, no second orchestrator and no authority.

struct OvernightStep: Equatable, Sendable {
    enum State: String, Sendable { case pending, ready, running, passed, failed, paused, skipped }
    var key: String
    var title: String
    var dependsOn: [String] = []
    var state: State = .pending
    var risk: RiskClass = .low
    var needsApproval = false
    /// The step would change a file the user changed (the engine's "user-dirty" rule).
    var touchesUserDirtyFile = false
    var ambiguous = false
}

enum OvernightDecision: Equatable, Sendable {
    case run(String)
    /// Paused, with the reason a person will read in the morning.
    case pause(String, reason: PauseReason)
    case waitForRunning
    case finished
    case blocked(reason: String)
}

enum PauseReason: String, Equatable, Sendable {
    case needsApproval, criticalAction, userDirtyFile, ambiguous, dependencyFailed
}

enum OvernightPolicy {
    /// What to do next. `userAway` false means a person is present: the normal engine rules apply and an approval is simply asked for.
    static func next(_ steps: [OvernightStep], userAway: Bool, maxParallel: Int = 1) -> OvernightDecision {
        let byKey = Dictionary(uniqueKeysWithValues: steps.map { ($0.key, $0) })
        func depsDone(_ s: OvernightStep) -> Bool { s.dependsOn.allSatisfy { byKey[$0]?.state == .passed || byKey[$0]?.state == .skipped } }
        func depsDead(_ s: OvernightStep) -> Bool { s.dependsOn.contains { [.failed, .paused].contains(byKey[$0]?.state ?? .pending) } }
        let running = steps.filter { $0.state == .running }.count
        // every unfinished step in plan order: the first that may run, run; the ones that may not, are paused and the REST continue
        for s in steps where s.state == .pending || s.state == .ready {
            if depsDead(s) { continue }                                                        // waits behind a paused / failed step: not run, not skipped
            guard depsDone(s) else { continue }
            if let pause = pauseReason(s, userAway: userAway) { return .pause(s.key, reason: pause) }
            if running >= maxParallel { return .waitForRunning }
            return .run(s.key)
        }
        if running > 0 { return .waitForRunning }
        if steps.allSatisfy({ [.passed, .skipped].contains($0.state) }) { return .finished }
        if steps.contains(where: { $0.state == .paused }) { return .blocked(reason: "waiting for the person") }
        if steps.contains(where: { $0.state == .failed }) { return .blocked(reason: "a step failed and everything left depends on it") }
        return .blocked(reason: "no step can start")
    }

    /// Why a step may not run while the user is away (nil = it may). Critical actions and approvals never run unattended; with the user PRESENT the same steps ask for the approval instead.
    static func pauseReason(_ s: OvernightStep, userAway: Bool) -> PauseReason? {
        if s.risk >= .critical { return .criticalAction }                                       // no path exists for these at all, present or away
        guard userAway else { return nil }
        if s.needsApproval || s.risk >= .high { return .needsApproval }
        if s.touchesUserDirtyFile { return .userDirtyFile }
        if s.ambiguous { return .ambiguous }
        return nil
    }

    /// Steps that can still run although something earlier is paused or failed: independent of every paused / failed step, transitively.
    static func continuable(_ steps: [OvernightStep]) -> [String] {
        let byKey = Dictionary(uniqueKeysWithValues: steps.map { ($0.key, $0) })
        var dead = Set(steps.filter { $0.state == .failed || $0.state == .paused }.map(\.key))
        var changed = true
        while changed {
            changed = false
            for s in steps where !dead.contains(s.key) && s.dependsOn.contains(where: { dead.contains($0) }) { dead.insert(s.key); changed = true }
        }
        return steps.filter { ($0.state == .pending || $0.state == .ready) && !dead.contains($0.key) && byKey[$0.key] != nil }.map(\.key)
    }
}

/// What the morning report may contain: outcomes and reasons, never content that must not persist.
struct MorningReport: Equatable, Sendable {
    var finished: [String] = []
    var waitingForPerson: [(step: String, reason: PauseReason)] = []
    var failed: [(step: String, reason: String)] = []
    var retried = 0
    var fellBack = 0
    var stuckEvents = 0

    static func == (a: MorningReport, b: MorningReport) -> Bool {
        a.finished == b.finished && a.retried == b.retried && a.fellBack == b.fellBack && a.stuckEvents == b.stuckEvents
            && a.waitingForPerson.map { "\($0.step):\($0.reason.rawValue)" } == b.waitingForPerson.map { "\($0.step):\($0.reason.rawValue)" }
            && a.failed.map { "\($0.step):\($0.reason)" } == b.failed.map { "\($0.step):\($0.reason)" }
    }

    func lines(language l: ReplyLanguage) -> [String] {
        var out: [String] = []
        out.append(l == .tr ? "Bitenler: \(finished.isEmpty ? "yok" : finished.joined(separator: ", "))" : "Finished: \(finished.isEmpty ? "none" : finished.joined(separator: ", "))")
        for w in waitingForPerson {
            let why: String
            switch w.reason {
            case .needsApproval: why = l == .tr ? "onayınızı bekliyor" : "needs your approval"
            case .criticalAction: why = l == .tr ? "kritik bir işlem; ben yapmam" : "a critical action; I do not do those"
            case .userDirtyFile: why = l == .tr ? "sizin değiştirdiğiniz bir dosyaya dokunuyor" : "touches a file you changed"
            case .ambiguous: why = l == .tr ? "net değildi; tahmin etmedim" : "it was unclear; I did not guess"
            case .dependencyFailed: why = l == .tr ? "önceki bir adım başarısız oldu" : "an earlier step failed"
            }
            out.append("\(w.step): \(why)")
        }
        for f in failed { out.append((l == .tr ? "Başarısız: " : "Failed: ") + "\(f.step) — \(f.reason)") }
        if retried + fellBack + stuckEvents > 0 { out.append(l == .tr ? "Yeniden denemeler \(retried), başka sağlayıcıya geçiş \(fellBack), takılma \(stuckEvents)." : "Retries \(retried), provider fallbacks \(fellBack), stuck events \(stuckEvents).") }
        return out
    }
}
