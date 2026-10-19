# V1.0 final-integration guards (sourced by scripts/verify.sh after guards_jev.sh). The engineering policy layer is connected to the ONE existing TaskEngine through narrow typed seams
# (`Tasks/EngineeringSeam.swift`, `Tasks/TaskEngine+Engineering.swift`). These guards pin that the seam stays a seam: no second engine, no process / approval / network / credential API of its own, and that the
# hooks that make "NO VERIFIED ACTION → NO COMPLETION CLAIM" true in the engine cannot be removed unnoticed.
TK=Sources/Jarvis/Tasks
SEAM="$TK/EngineeringSeam.swift $TK/TaskEngine+Engineering.swift"

gin_seam_authority() {
  # the seam decides and records; it starts no process, creates no approval or capability, submits no task, opens no network connection, touches no credential, writes no file
  grep -nE 'ManagedProcess|Process\(\)|NSTask|posix_spawn|/bin/(ba|z)?sh|osascript|AppleScript|URLSession|URLRequest|NWConnection|SecItem|Keychain|decideApproval|requestApproval\(|ApprovalRecord\(|\.approve\(|CapabilitySet\(|grantCapabilit|engine\.submit|\.submit\(goal|removeItem|\.write\(to|createFile|UserDefaults|kill\(|terminate\(' $SEAM | nonc
}
v09_none "final integration: the engineering seam starts no process, creates no approval / capability / task, opens no connection, touches no credential or file" "$(gin_seam_authority)"

gin_one_engine() {
  grep -rnE '\b(EngineeringTaskEngine|EngineeringEngine|EngineeringModelRouter|EngineeringProviderManager|EngineeringAgentEngine|EngineeringOrchestrator|WorkerRouter2|VerificationRunner2|GitTool2|EngineeringStore|EngineeringDatabase)\b' Sources Tests | grep -v 'guards_' | nonc
  # the seam is an extension of the existing engine, not a type with its own scheduler / queue / timer
  grep -nE 'Timer\.|scheduledTimer|DispatchQueue|Task\.sleep|while true|asyncAfter|AsyncStream|TaskGroup' $SEAM | nonc
  # no second database: the run record lives in the existing task checkpoint
  grep -rnE 'CREATE TABLE.*engineering|engineering_runs|engineeringRuns' Sources | nonc
}
v09_none "final integration: no second engine / router / provider manager / store — the seam is an extension of TaskEngine with no scheduler, timer or table of its own" "$(gin_one_engine)"

gin_hooks() {
  hasre $TK/TaskEngine.swift 'await engineeringBegin\(ctx\)'
  hasre $TK/TaskEngine.swift 'if let refusal = await engineeringCompletionGate\(ctx\) \{ ctx\.hardFailure = refusal; await finalizeFailure\(ctx\) \}'
  # finalizeSuccess has exactly one caller and it is behind the gate
  [ "$(grep -rn 'finalizeSuccess(ctx)' Sources | grep -v 'func finalizeSuccess' | wc -l | tr -d ' ')" = "1" ] || echo 'finalizeSuccess must have exactly one caller (behind the engineering completion gate)'
  hasre $TK/TaskEngine+Execution.swift 'if let refusal = engineeringGate\(ctx, prepared: prepared\) \{ out\.failure = refusal; return out \}'
  hasre $TK/TaskEngine+Execution.swift 'if let stale = await engineeringStaleness\(ctx\) \{ out\.failure = stale; return out \}'
  hasre $TK/TaskEngine+Execution.swift 'AssignmentGate\.mayApplyResult'
  hasre $TK/TaskEngine+Execution.swift 'engineeringRecordEvidence\(ctx, step: step, profile: profile, result: result, digest: digest\)'
  hasre $TK/TaskEngine+Execution.swift 'if !\(await engineeringRepairGate\(ctx, failure: last\.tail\)\) \{ return nil \}'
  # the gate runs BEFORE the write: prepare → engineering gate → dirty-file approval → lease → apply
  local a b c
  a=$(grep -n 'engineeringGate(ctx, prepared: prepared)' $TK/TaskEngine+Execution.swift | head -1 | cut -d: -f1)
  b=$(grep -n 'let changes = try tools.apply(prepared' $TK/TaskEngine+Execution.swift | head -1 | cut -d: -f1)
  c=$(grep -n 'engineeringAfterApply(ctx' $TK/TaskEngine+Execution.swift | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] || echo "engineering gate must precede the write and the after-apply observation must follow it (gate@$a apply@$b after@$c)"
  # persistence: the run is inside the existing checkpoint, trusted only when the artifact still matches its hash
  hasre $TK/TaskEngine+Lifecycle.swift 'var engineering: EngineeringRunRecord\?'
  hasre $TK/TaskEngine+Lifecycle.swift 'artifacts\?\.verify\(art\) == true'
  hasre $TK/TaskEngine+Engineering.swift 'EngineeringCheckpointer\.resume\(stored, checkpointSnapshot: restored\.observed'
  hasre $TK/TaskEngine+Engineering.swift 'case \.corrupt:'
}
v09_none "final integration: the engineering hooks are in the engine — completion gate before success, review before the write, evidence from the real run, repair gate, checkpoint + revalidated resume" "$(gin_hooks)"

gin_truth() {
  # the claim rule is in one function and the report says NOT VERIFIED when it must
  hasre $TK/EngineeringSeam.swift 'static func completion\(verdict v: VerificationVerdict, plan: VerificationPlan, profilesAvailable: Bool\) -> EngineeringCompletion'
  hasre $TK/EngineeringSeam.swift 'if v\.diffStats\.files == 0 \{ return \.failed'
  hasre $TK/EngineeringSeam.swift 'if v\.isVerified \{ return \.verified'
  hasre $TK/TaskReport.swift 'changes applied, NOT VERIFIED'
  # only the verifier's `.verified` / `.verifiedAutomated` produce a verified completion: worker text never does
  grep -nE 'claims[A-Za-z]*\.status *== *\.done[^\n]*(verified|completed)|return \.verified\([^\n]*claims' $SEAM | nonc
  # the writes are limited by the assignment the engine derives: forbidden paths protect the verification profile
  hasre $TK/EngineeringSeam.swift 'scope\.forbidden = \["\.git/\*\*", "\.jarvis/\*\*"\]'
  hasre $TK/EngineeringSeam.swift 'scope\.mayModifyGuards = false'
  # the gated Jev registry hook exists and is exact (never fuzzy)
  hasre Sources/Jarvis/Decision/JevTargetResolver.swift 'ProjectOpenResolver\.nameMatches'
  hasre Sources/Jarvis/App/AppContext+Daily.swift 'engine\.projectResolver = '
}
v09_none "final integration: the completion rule lives in one function, an unverifiable change is reported NOT VERIFIED, forbidden paths protect the verification profile, the Jev registry hook is exact" "$(gin_truth)"
