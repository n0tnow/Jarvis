# V1.0 background-reliability guards (sourced by scripts/verify.sh after guards_reliability.sh). The task-reliability policies are PURE value logic around the existing TaskEngine: they derive, classify and
# decide — they hold no approval, capability, task-submission, process, network, credential or persistence API, run no timers and log nothing. There is exactly ONE orchestrator (the TaskEngine) and the
# policies never become a second one. These guards pin that, plus the safety rules the pass relies on.
BG_RL=Sources/Jarvis/Reliability
BG_PURE="$BG_RL/TaskStatusDeriver.swift $BG_RL/StepReadiness.swift $BG_RL/RetryPolicy.swift $BG_RL/TaskBudget.swift $BG_RL/StepReplayPolicy.swift $BG_RL/ApprovalBinding.swift $BG_RL/ProjectDrift.swift $BG_RL/TaskEventLog.swift $BG_RL/UsageLedger.swift $BG_RL/ContextSelector.swift $BG_RL/WorkerAdmission.swift $BG_RL/TaskDigest.swift Sources/Jarvis/Decision/DecisionQuality.swift"

gbg_authority() {
  # no approval decision, capability grant, task submission, process, network, credential, launch or file-writing API in any background policy file (types such as ApprovalRecord may be READ, never decided)
  grep -nE 'decideApproval|ApprovalGuard|\.approve\(|\.deny\(|TaskCapability|CapabilitySet\(|grantCapabilit|engine\.submit|taskEngine|submitTask|StepAgentRunner|Process\(\)|NSTask|posix_spawn|/bin/(ba|z)?sh|osascript|AppleScript|URLSession|URLRequest|NWConnection|WebSocket|SecItem|Keychain|HTTPCookieStorage|Data\(contentsOf|String\(contentsOf|NSWorkspace|kill\(|terminate\(' $BG_PURE | nonc
}
v09_none "background pass: the task-reliability policies hold no approval, capability, task-submission, process, network, credential, launch or kill API" "$(gbg_authority)"

gbg_quiet() {
  grep -nE 'print\(|NSLog|os_log|Logger\(|debugPrint|dump\(|UserDefaults|sqlite|createFile|\.write\(|write\(to|forWriting|FileHandle|Timer\.|scheduledTimer|DispatchSource|asyncAfter|Task\.sleep|AVAudio|AudioFrame|\[Float\]|while true|repeat *\{' $BG_PURE | nonc
}
v09_none "background pass: the policies log nothing, persist nothing, schedule nothing, touch no audio and contain no unbounded loop" "$(gbg_quiet)"

gbg_one_orchestrator() {
  # there is no second orchestrator: the policies are consulted by the TaskEngine, never the other way round, and no such type exists
  grep -rnE '\b(BackgroundOrchestrator|BackgroundEngine|SuperAgent|MasterAgent|AutonomyEngine2|TaskEngine2|OvernightEngine|OvernightOrchestrator)\b' Sources Tests | nonc
  grep -nE 'TaskEngine|AgentOrchestrator|TaskRunner' $BG_PURE | nonc
}
v09_none "background pass: no second orchestrator exists and no policy file references the TaskEngine (the engine consults the policies)" "$(gbg_one_orchestrator)"

gbg_hooks() {
  # the engine hooks are exactly the two small delegations; neither widens authority
  hasre Sources/Jarvis/Tasks/TaskEngine.swift 'StepReadiness\.ready\(ctx\.steps\)'
  hasre Sources/Jarvis/Tasks/TaskEngine+Execution.swift 'existing\.state == \.approved, ApprovalFreshness\.mayReuse\(existing, forAction: existing\.action, now: Date\(\)\)'
  # approvals: critical never reusable, high short-lived, an expired or different action asks again
  hasre $BG_RL/ApprovalBinding.swift 'case \.critical: 0'
  hasre $BG_RL/ApprovalBinding.swift 'existing\.state == \.approved && existing\.action == action'
}
v09_none "background pass: the engine delegates step readiness to StepReadiness and reuses an approval only while ApprovalFreshness allows it (critical never)" "$(gbg_hooks)"

gbg_safety() {
  # unattended safety: benchmarks only on request, optional heavy work yields, non-idempotent steps are never replayed on a guess, git is never reset / cleaned / forced by a reaction to drift
  hasre $BG_RL/WorkerAdmission.swift 'benchmarks start only when explicitly requested'
  hasre $BG_RL/WorkerAdmission.swift 'if w\.isOptionalByDefault, !required'
  hasre $BG_RL/StepReplayPolicy.swift 'the action may already have happened and repeating it could do it twice'
  hasre $BG_RL/StepReplayPolicy.swift 'case \.nonIdempotentWrite, \.critical: return \.recordUnverifiedDoNotRepeat'
  hasre $BG_RL/ProjectDrift.swift 'case resetRepository, cleanWorkingTree, checkoutOverChanges, commitOnTheUsersBehalf, pushToRemote, forceAnything, discardUserChanges'
  hasre $BG_RL/ProjectDrift.swift 'static let forbiddenReactions: Set<ForbiddenReaction> = Set\(ForbiddenReaction\.allCases\)'
  hasre $BG_RL/RetryPolicy.swift 'var perTask = 12'
  hasre $BG_RL/RetryPolicy.swift 'guard cls\.isRetryableAutomatically else'
  hasre $BG_RL/TaskBudget.swift 'var consecutiveVerificationFailures = 6'
  hasre $BG_RL/TaskEventLog.swift 'if entries\.count > capacity \{ evict\(\) \}'
  # a benchmark or stress test is never driven by a timer
  grep -rniE 'benchmark' Sources | grep -E 'Timer\.|scheduledTimer|asyncAfter|DispatchSource' | nonc
}
v09_none "background pass: benchmarks never auto-start, non-idempotent steps are not replayed on a guess, drift never triggers a destructive git reaction, retries and budgets are bounded" "$(gbg_safety)"

gbg_honesty() {
  # the simulation says what it is, the report says what it measured, the docs say what is NOT done
  grep -q 'NOT the TaskEngine' Tests/JarvisTests/OvernightSimulationTests.swift || echo 'simulation scope statement missing'
  [ -f docs/V1_BACKGROUND_RELIABILITY.md ] || echo 'docs/V1_BACKGROUND_RELIABILITY.md missing'
  grep -q 'NOT WIRED' docs/V1_BACKGROUND_RELIABILITY.md || echo 'integration gaps not listed'
  grep -q 'MANUAL TEST REQUIRED' docs/V1_BACKGROUND_RELIABILITY.md || echo 'manual validation list missing'
}
v09_none "background pass: the simulation states that it is not the engine, and the doc lists what is not wired and what still needs a manual test" "$(gbg_honesty)"
