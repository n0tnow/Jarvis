# V1.0 Jev gating-pass guards (sourced by scripts/verify.sh after guards_engineering.sh). The remote classifier (Jev) answers ONE question — "what does the user intend?" — and stays OPTIONAL and ADVISORY:
# deterministic policy always wins, JARVIS' own gate decides what an answer may reach, and nothing the classifier says can execute, approve, grant or claim. These guards pin the structure that makes that true.
JV=Sources/Jarvis/Decision

gjv_authority() {
  # the gate, the evaluation and the provider hold no approval, capability, task-submission, action, Computer Use, process, network, credential-write or kill API
  grep -nE 'ActionService|ActionReceipt|TaskEngine|engine\.submit|submitTask|decideApproval|ApprovalGuard|ProposalService|\.approve\(|\.deny\(|TaskCapability|CapabilitySet|grantCapabilit|ComputerSession|ComputerController|AXBackend|ScreenCapture|ManagedProcess|Process\(\)|NSTask|posix_spawn|osascript|AppleScript|URLSession|URLRequest|NWConnection|SecItem|Keychain|NSWorkspace|kill\(|terminate\(' $JV/JevGatePolicy.swift $JV/JevEvaluation.swift $JV/JevDecisionProvider.swift | nonc
}
v09_none "Jev: the gate, the evaluation and the provider have no approval, capability, task, action, Computer Use, process, network, credential or kill API" "$(gjv_authority)"

gjv_one_door() {
  # a remote answer reaches the routing only through JevGatePolicy.evaluate; the execution-level simulation is measurement code and is called from nowhere else
  grep -rnE 'JevGatePolicy\.simulate' Sources | grep -v "$JV/JevEvaluation.swift" | nonc
  grep -rnE 'JevGatePolicy\.evaluate' Sources | grep -vE "$JV/DecisionEngine.swift|$JV/JevEvaluation.swift" | nonc
  # nothing outside the gate marks a decision as gated-accepted
  grep -rnE 'provenance *= *\.jevGated|provenance: *\.jevGated' Sources | grep -v "$JV/JevGatePolicy.swift" | nonc
  # no second gate / router / orchestrator for the classifier exists
  grep -rnE '\b(JevOrchestrator|JevRouter|JevExecutor|JevAgent|JevEngine|JevTaskRunner|JevApproval[A-Za-z]*|RemoteIntentExecutor)\b' Sources Tests | grep -v 'guards_' | nonc
}
v09_none "Jev: one door — a remote answer is accepted only by JevGatePolicy.evaluate (called by the engine), the simulation is measurement-only, no second router / executor / approval exists" "$(gjv_one_door)"

gjv_execution() {
  hasre $JV/JevGatePolicy.swift 'static let executionIsEnabledInProduction = false'
  hasre $JV/JevGatePolicy.swift 'guard simulating else \{ return \.reject\(\.executionNotEnabled\) \}'
  hasre $JV/JevGatePolicy.swift 'd\.intent == \.computerUse \|\| d\.intent == \.stopSpeech \|\| d\.intent == \.cancelTask'
  hasre $JV/JevGatePolicy.swift 'case \.macosApplicationAction, \.computerUse, \.projectOpen, \.projectTask, \.settingsChange, \.research, \.stopSpeech, \.cancelTask: \.executionCapable'
  # a constant, not a setting: nothing reads a preference to turn it on
  grep -rnE 'executionIsEnabledInProduction' Sources | grep -vE "$JV/JevGatePolicy.swift" | nonc
  # no Jev mode other than disabled is ever chosen by code (only a user preference or a test / benchmark tool)
  grep -rnE 'JevConfig\(mode: *\.(gated|shadow)' Sources | grep -vE 'Sources/Jarvis/App/DecisionTools.swift' | nonc
}
v09_none "Jev: execution-capable intents are never accepted in production (a constant, not a setting); computer / stop / cancel not even in the simulation; no code enables gated or shadow mode by itself" "$(gjv_execution)"

gjv_local_truth() {
  # risk, gate and target come from local code, never from the classifier
  hasre $JV/JevGatePolicy.swift 'LocalRiskDerivation\.derive\(raw: i\.raw, candidate: d\)'
  hasre $JV/JevGatePolicy.swift 'if local\.risk != \.low \|\| local\.gate != \.none \{ return \.reject\(\.localRiskHigher\) \}'
  hasre $JV/JevGatePolicy.swift 'criticalWords\(i\.raw\)\.isEmpty \{ return \.reject\(\.criticalContent\)'
  hasre $JV/JevGatePolicy.swift 'JevCorroboration\.anchored'
  hasre $JV/JevGatePolicy.swift 'case \(\.jarvisNavigation, _\):'
  hasre $JV/JevGatePolicy.swift 'guard d\.confidence\.isFinite else \{ return \.reject\(\.malformedConfidence\) \}'
  hasre $JV/JevGatePolicy.swift 'if production\.gate != \.none \{ return \.policyBlock \}'
  hasre $JV/JevGatePolicy.swift 'if production\.intent != \.unknown \{ return \.deterministicDecided \}'
  hasre $JV/DecisionEngine.swift 'JevPreflight\.skipReason\(raw: raw, production: outcome\.decision, gated: true\)'
  # the classifier's mapped decision takes risk / gate from the policy table (finalize), not from the answer
  hasre $JV/JevDecisionProvider.swift 'DecisionPolicy\.finalize\(intent: intent, confidence: c\.confidence'
  # a probability outside [0, 1] is malformed, never clamped
  hasre Sources/Jarvis/Providers/Jev/TypeSafeJevTransport.swift 'conf\.isFinite, conf >= 0, conf <= 1\.000_001'
  hasre $JV/JevDecisionProvider.swift 'c\.confidence >= 0, c\.confidence <= 1\.000_001'
}
v09_none "Jev: risk / gate / target are derived locally (critical words, policy table, JARVIS' own resolvers), the grammar's decisions, ambiguities and blocks are never sent, a malformed probability is rejected" "$(gjv_local_truth)"

gjv_privacy() {
  # what is sent: refused for secret shapes, paths / addresses masked, typed referents only for a pronoun; telemetry carries no utterance
  hasre $JV/JevDecisionProvider.swift 'JevPrivacyFilter\.looksSecret\(trimmed\)'
  hasre $JV/JevDecisionProvider.swift 'JevPrivacyFilter\.looksLikeFileName\(t\)'
  hasre $JV/JevDecisionProvider.swift 'guard elliptical else \{ return \[:\] \}'
  hasre $JV/JevDecisionProvider.swift 'projectNames: mentionsProject\(trimmed\)'
  grep -nE 'var (utterance|text|raw|target|path|transcript)\b' $JV/DecisionTelemetry.swift | nonc
  grep -rnE 'Memory(Service|Store)|ProjectContextBuilder|ConversationStore|screenshot|ScreenCapture|AVAudio|MicrophoneHub|SpeechPlayer' $JV/JevDecisionProvider.swift $JV/JevGatePolicy.swift $JV/JevEvaluation.swift | nonc
}
v09_none "Jev: minimal request — no memory, history, screen, audio, path or credential in the context; secret-shaped text is never sent; telemetry holds no utterance" "$(gjv_privacy)"

gjv_cost() {
  # budgets and timeouts: hourly + per-session caps, a shorter gated timeout, a breaker, bounded retry; no price is invented
  hasre $JV/JevDecisionProvider.swift 'var maxRequestsPerSession = 1000'
  hasre $JV/JevDecisionProvider.swift 'var gatedTimeoutSeconds: TimeInterval = 1\.5'
  hasre $JV/JevDecisionProvider.swift 'config\.maxRequestsPerSession > 0, _usage\.requests >= config\.maxRequestsPerSession'
  hasre $JV/DecisionEngine.swift 'min\(cfg\.timeoutSeconds, cfg\.gatedTimeoutSeconds\)'
  hasre $JV/JevDecisionProvider.swift 'if immediate\.contains\(f\) \|\| consecutiveFailures >= config\.breakerFailures'
  hasre $JV/JevEvaluation.swift 'guard let m = measuredCallLatency'
  grep -nE 'USD|dollar|per million|per 1k|pricePer|\$[0-9]+\.[0-9]{2}' $JV/JevEvaluation.swift $JV/JevGatePolicy.swift | nonc
}
v09_none "Jev: hourly and session budgets, a gated timeout shorter than the shared one, a circuit breaker, no auto-refill and no invented price or latency" "$(gjv_cost)"

gjv_evaluation() {
  # the evaluation is pure (no network, file, clock, state) and says what each number is: simulated vs recorded
  grep -nE 'URLSession|FileManager|Date\(\)|UserDefaults|DispatchQueue|Task\.sleep|\.write\(|print\(' $JV/JevEvaluation.swift $JV/JevGatePolicy.swift | nonc
  hasre $JV/JevEvaluation.swift 'SIMULATED classifier: this exercises the GATE, it says nothing about Jev'
  hasre $JV/JevEvaluation.swift 'RECORDED from a real run'
  # the new corpora exist, are hand-written ground truth, and the held-out set shares no sentence with an older corpus (tests/JevGateTests pins it)
  for f in jev_heldout jev_hard_negative jev_ambiguity; do [ -s Benchmarks/$f.json ] || echo "missing Benchmarks/$f.json"; done
  grep -nE 'jev_heldout|jev_hard_negative|jev_ambiguity' Benchmarks/README.md | head -1 | grep -q . || echo 'Benchmarks/README.md does not describe the Jev corpora'
  [ -s docs/JEV_DECISION_POLICY.md ] || echo 'docs/JEV_DECISION_POLICY.md missing'
}
v09_none "Jev: the evaluation is pure and labels simulated vs recorded numbers; the three gating corpora and the policy document exist" "$(gjv_evaluation)"
