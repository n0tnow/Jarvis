# V1.0 autonomous-engineering-pipeline guards (sourced by scripts/verify.sh after guards_background.sh). The engineering layer (`Sources/Jarvis/Engineering/`) is PURE decision logic around the existing
# TaskEngine: it describes assignments, observes repository state READ-ONLY, compares a worker's claims with that observation and decides what verification, review, repair or rollback is warranted.
# It starts no process, writes no file, holds no approval or capability, calls no provider and creates no second orchestrator. These guards pin that, plus the safety rules the pipeline relies on.
EN=Sources/Jarvis/Engineering

geng_authority() {
  grep -rnE 'decideApproval|ApprovalGuard|\.approve\(|\.deny\(|TaskCapability|CapabilitySet\(|grantCapabilit|engine\.submit|taskEngine|submitTask|StepAgentRunner|AgentRunManager|ManagedProcess|Process\(\)|NSTask|posix_spawn|/bin/(ba|z)?sh|osascript|AppleScript|URLSession|URLRequest|NWConnection|WebSocket|SecItem|Keychain|NSWorkspace|kill\(|terminate\(' $EN | nonc
}
v09_none "engineering pipeline: the layer holds no approval, capability, task-submission, provider, process, network, credential or kill API" "$(geng_authority)"

geng_readonly() {
  # the only file access is a read-only snapshot; nothing here writes, removes, moves, copies or creates, logs, persists, schedules, or loops without a bound
  grep -rnE '\.write\(|write\(to|createFile|removeItem|moveItem|copyItem|createDirectory|setAttributes|FileHandle|UserDefaults|sqlite|(^|[^A-Za-z])print\(|NSLog|os_log|Logger\(|debugPrint|Timer\.|scheduledTimer|DispatchSource|asyncAfter|Task\.sleep|while true|repeat *\{' $EN | nonc
}
v09_none "engineering pipeline: read-only (no write / remove / move / create), no logging, persistence, timer or unbounded loop" "$(geng_readonly)"

geng_one_orchestrator() {
  grep -rnE '\b(BackgroundOrchestrator|EngineeringOrchestrator|EngineeringEngine|PipelineOrchestrator|SuperAgent|MasterAgent|AutonomyEngine2|TaskEngine2|OvernightEngine)\b' Sources Tests | grep -v "ArchitectureDriftDetector.swift\|EngineeringVerificationTests.swift\|guards_" | nonc
  grep -rnE 'TaskEngine|AgentCoordinator|AgentOrchestrator' $EN | grep -v 'ArchitectureDriftDetector\|EngineeringChecks.swift' | nonc
}
v09_none "engineering pipeline: no second orchestrator exists and no engineering file references the TaskEngine (the engine consults the pipeline, never the reverse)" "$(geng_one_orchestrator)"

geng_claims() {
  # worker claims never become evidence: evidence is constructed only where it is defined, claims are compared in the verifier, and no engineering file turns a claim into a pass
  # V1.0 final integration: the ONE production runner (`EngineeringSeam.evidence`, in Tasks/) may construct it — and only from a `CommandResult` of an approved profile; a cancelled run yields none.
  grep -rn 'VerificationEvidence(' Sources | grep -v "^$EN/EngineeringVerification.swift" | grep -v "^Sources/Jarvis/Tasks/EngineeringSeam.swift" | nonc
  [ "$(grep -c 'VerificationEvidence(' Sources/Jarvis/Tasks/EngineeringSeam.swift)" = "1" ] || echo 'EngineeringSeam must construct VerificationEvidence in exactly one place'
  hasre Sources/Jarvis/Tasks/EngineeringSeam.swift 'static func evidence\(step: StepType, profile: CommandProfile, result: CommandResult, digest: String'
  hasre Sources/Jarvis/Tasks/EngineeringSeam.swift 'if result\.cancelled \{ return nil \}'
  hasre $EN/EngineeringVerification.swift 'struct VerificationEvidence'
  hasre $EN/EngineeringVerification.swift 'e\.snapshotDigest == currentDigest'
  hasre $EN/EngineeringVerification.swift 'stale evidence leaves the stage open|stale evidence'
  hasre $EN/EngineeringVerification.swift 'case verifiedAutomated'
  grep -rnE 'claims[A-Za-z]*\.(status|allGreen|filesChanged)[^=]*(return \.verified|status = \.verified)' $EN | nonc
}
v09_none "engineering pipeline: a worker's claim cannot construct or replace verification evidence; evidence belongs to one revision" "$(geng_claims)"

geng_cost() {
  # worker selection: the local conversational model never codes, paid only when explicitly chosen, unknown price never free, explicit choice never falls back
  hasre $EN/WorkerSelection.swift 'the local conversational model is not a coding / testing / review worker'
  hasre $EN/WorkerSelection.swift 'paid workers are used only when explicitly chosen'
  hasre $EN/WorkerSelection.swift 'unknown price is never free'
  hasre $EN/WorkerSelection.swift 'no fallback'
  hasre $EN/EngineeringAssignment.swift 'func routingProfile'
  # nothing outward-facing is automatic
  hasre $EN/RollbackAndHygiene.swift 'static func mayRunAutomatically\(_ a: ExternalAction, policy: CommitPolicy\) -> Bool \{ a == \.localCommit && policy\.allowLocalCommit \}'
  hasre $EN/RollbackAndHygiene.swift 'static func isCritical\(_ a: ExternalAction\) -> Bool \{ a != \.localCommit \}'
}
v09_none "engineering pipeline: no local chat model as a coding worker, no automatic paid worker, unknown price never free, no outward-facing action without its own gate" "$(geng_cost)"

geng_safety() {
  # rollback is a plan that names only task-produced files; user-dirty / unexplained / changed-again files are never reverted; a critical assignment needs its gate; no write after cancel
  hasre $EN/RollbackAndHygiene.swift 'the file changed again after the task wrote it'
  hasre $EN/RollbackAndHygiene.swift 'changed during the task but not by an edit JARVIS applied'
  hasre $EN/RollbackAndHygiene.swift 'a task that was not created by JARVIS|not created by JARVIS'
  hasre $EN/OwnershipAndLifecycle.swift 'static func mayIssueWrite'
  hasre $EN/OwnershipAndLifecycle.swift 'a\.risk < \.critical \|\| a\.gateApproved'
  hasre $EN/RepairLoop.swift 'if repeats >= 3 \{ return record\(\.stop\(\.sameFailureRepeated\)'
  hasre $EN/WorkspaceSnapshot.swift 'enum ChangeAttribution'
  # no destructive operation names exist in the layer (a plan names files; applying it is the engine's guarded job)
  grep -rnE 'removeItem|trashItem|git +(res[e]t|cle[a]n)' $EN | nonc
}
v09_none "engineering pipeline: rollback never touches user-dirty or unexplained files, repair loops are bounded, critical work needs its gate, no write after a cancel" "$(geng_safety)"

geng_project_agnostic() {
  # no project is special-cased: the layer and its tests never name the real user project, and fixtures are disposable
  grep -rniE 'hamam|hammam' $EN Tests/JarvisTests/Engineering*.swift | nonc
  grep -rnE '/Users/|Application Support/JARVIS|~/Library' Tests/JarvisTests/Engineering*.swift $EN | nonc
}
v09_none "engineering pipeline: project-agnostic (no real project named), tests use disposable fixtures only" "$(geng_project_agnostic)"

geng_honesty() {
  grep -q 'NOT the TaskEngine' Tests/JarvisTests/EngineeringSimulationTests.swift || echo 'simulation scope statement missing'
  [ -f docs/AUTONOMOUS_ENGINEERING_PIPELINE.md ] || echo 'docs/AUTONOMOUS_ENGINEERING_PIPELINE.md missing'
  grep -q 'NOT WIRED' docs/AUTONOMOUS_ENGINEERING_PIPELINE.md || echo 'integration gaps not listed'
  grep -q 'MANUAL TEST REQUIRED' docs/AUTONOMOUS_ENGINEERING_PIPELINE.md || echo 'manual validation list missing'
}
v09_none "engineering pipeline: the simulation states that it is not the engine, and the doc lists what is not wired and what still needs a manual test" "$(geng_honesty)"
