import Foundation

// MARK: - Replaying a step after a crash, and verification that is not a verdict (V1.0 background pass)
//
// After a restart or a worker death, "run the interrupted step again" is only safe for steps that cannot do harm twice. `StepType.idempotency` already says retryable / inspectFirst / manual; this adds the
// SIDE-EFFECT class (read-only · idempotent write · non-idempotent write · critical) so a regression test can pin the table, and the two decisions the engine needs:
//   1. what to do with an INTERRUPTED step (replay, revalidate first, skip because it already happened, ask a person, never replay);
//   2. what to do when an action RAN but its verification is INCONCLUSIVE — never repeat a non-idempotent action just because verification timed out ("the form was submitted; the check timed out").

enum SideEffectClass: String, Equatable, Sendable, CaseIterable {
    case readOnly, idempotentWrite, nonIdempotentWrite, critical
}

enum StepSideEffects {
    static func classify(_ t: StepType) -> SideEffectClass {
        switch t {
        case .analysis, .review, .build, .test, .unityInspect, .unityCompile, .unityTest, .unityValidate, .researchSearch, .researchRead, .researchExtract, .researchVerify, .researchReport, .experiment: return .readOnly
        case .codeChange, .unityEdit, .acquire, .unityPlayMode: return .idempotentWrite       // inspect first: the same edit blocks are re-checked against the file hashes
        case .computerAct, .delegateComputer, .delegateResearch: return .nonIdempotentWrite
        case .importAsset: return .nonIdempotentWrite
        case .delete, .approvalGate: return .critical
        }
    }
}

enum CrashPoint: String, Equatable, Sendable, CaseIterable { case beforeStart, duringRead, duringWrite, duringTest, duringVerification, afterEffectBeforeRecord }

/// What the world looked like when the engine re-examined an interrupted step. Facts, never guesses.
struct ReplayEvidence: Equatable, Sendable {
    /// The step's effect is visible and matches what it recorded (file hashes equal `afterHash`, the build artifact exists, …).
    var effectObserved = false
    /// The world is exactly as before the step (hashes equal `beforeHash`).
    var worldUnchanged = false
    /// The world differs from both (someone else changed it).
    var diverged = false
    /// A fresh approval exists for this exact action (critical steps).
    var freshApproval = false
}

enum ReplayDecision: Equatable, Sendable {
    case replay
    case revalidateThenReplay
    case skipAlreadyDone
    case askUser(String)
    case neverReplay(String)
}

enum StepReplayPolicy {
    static func decide(_ type: StepType, crash: CrashPoint, evidence: ReplayEvidence) -> ReplayDecision {
        if evidence.diverged { return .askUser("the files no longer match what the step wrote or the original content") }
        switch type.idempotency {
        case .retryable:
            return .replay                                                           // read / search / build / test: safe to repeat
        case .inspectFirst:
            if evidence.effectObserved { return .skipAlreadyDone }
            if evidence.worldUnchanged || crash == .beforeStart { return .replay }
            // a non-idempotent action (a GUI action, a delegated computer task) that MAY have happened is never repeated on a guess: re-observation is a person's call
            if StepSideEffects.classify(type) == .nonIdempotentWrite { return .askUser("the action may already have happened and repeating it could do it twice") }
            return .revalidateThenReplay
        case .manual:
            // delete, import, approval gates: never replayed on their own authority
            if StepSideEffects.classify(type) == .critical, evidence.freshApproval, !evidence.effectObserved { return .replay }
            if evidence.effectObserved { return .skipAlreadyDone }
            return .neverReplay("a \(type.label.lowercased()) step is never replayed without a fresh decision")
        }
    }
}

enum StepVerification: String, Equatable, Sendable { case verifiedSuccess, verifiedFailure, inconclusive }

enum PostActionDecision: Equatable, Sendable {
    case accept
    case failHonestly
    /// The action may have succeeded: record it UNVERIFIED, do NOT repeat it.
    case recordUnverifiedDoNotRepeat
    /// Safe to repeat the (idempotent / read-only) action and verify again — once, bounded.
    case reverifyOrRepeatOnce
}

enum VerificationPolicy {
    static func afterAction(_ type: StepType, verification: StepVerification, alreadyRepeated: Bool) -> PostActionDecision {
        switch verification {
        case .verifiedSuccess: return .accept
        case .verifiedFailure: return .failHonestly
        case .inconclusive:
            switch StepSideEffects.classify(type) {
            case .readOnly: return alreadyRepeated ? .failHonestly : .reverifyOrRepeatOnce
            case .idempotentWrite: return alreadyRepeated ? .recordUnverifiedDoNotRepeat : .reverifyOrRepeatOnce       // re-inspect and compare hashes, then at most one more try
            case .nonIdempotentWrite, .critical: return .recordUnverifiedDoNotRepeat
            }
        }
    }
}
