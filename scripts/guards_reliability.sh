# V1.0 reliability-pass guards (sourced by scripts/verify.sh after guards_decision.sh). The new policy layers are PURE: they classify, plan and record — they hold no approval, capability, task-submission,
# process, network, credential or persistence API, run no timers, log nothing, and cannot widen what JARVIS may do. These guards pin that, plus the invariants the pass relies on (a fuzzy match never executes,
# a paid provider is never an automatic fallback, every retry loop is bounded, no credential-shaped literal exists anywhere).
RL=Sources/Jarvis/Reliability
PURE_NEW="$RL/StuckTaskDetector.swift $RL/ProviderResilience.swift $RL/ResourceBudget.swift $RL/OvernightPolicy.swift $RL/ProgressTruth.swift $RL/ResumeValidator.swift Sources/Jarvis/Decision/ConfidencePolicy.swift Sources/Jarvis/Decision/ResponseContract.swift Sources/Jarvis/Decision/ObservationFreshness.swift Sources/Jarvis/Decision/DecisionTelemetry.swift Sources/Jarvis/Decision/CommandLexicon.swift Sources/Jarvis/Decision/DecisionReferents.swift Sources/Jarvis/Continuity/ProjectDiscovery.swift"

grel_authority() {
  # no approval, capability, task submission, process, network, credential or AppleScript API in any of the new policy files
  grep -nE 'decideApproval|ApprovalGuard|pendingApproval|\.approve\(|\.deny\(|TaskCapability|CapabilitySet|grantCapabilit|engine\.submit|taskEngine|submitTask|StepAgentRunner|Process\(\)|NSTask|posix_spawn|/bin/(ba|z)?sh|osascript|AppleScript|URLSession|URLRequest|NWConnection|WebSocket|SecItem|Keychain|HTTPCookieStorage|Data\(contentsOf|String\(contentsOf|NSWorkspace' $PURE_NEW | nonc
}
v09_none "reliability pass: the new policy files hold no approval, capability, task-submission, process, network, credential or launch API" "$(grel_authority)"

grel_quiet() {
  # nothing is logged, persisted or scheduled by the pure layers: no print/log, no UserDefaults/SQLite/files written, no timers, no audio types
  grep -nE 'print\(|NSLog|os_log|Logger\(|debugPrint|dump\(|UserDefaults|sqlite|createFile|\.write\(|write\(to|forWriting|FileHandle|Timer\.|scheduledTimer|DispatchSource|asyncAfter|Task\.sleep|AVAudio|AudioFrame|\[Float\]' $PURE_NEW | nonc
}
v09_none "reliability pass: the pure policy layers log nothing, persist nothing, schedule nothing and touch no audio" "$(grel_quiet)"

grel_fuzzy() {
  # a fuzzy / near-miss name only ever yields a QUESTION: suggestions are used in exactly one place (the planner's answer) and never construct an action
  grep -rn 'ProjectAliasResolver\.suggestions\|\.suggestions(for' Sources | grep -vE 'Sources/Jarvis/Continuity/ProjectDiscovery\.swift' | grep -vE 'Sources/Jarvis/Decision/DecisionPlanner\.swift' | nonc
  grep -nE 'near.*(\.openProject|ProjectOpenResolver\.resolve|\.reroute|\.action)' Sources/Jarvis/Decision/DecisionPlanner.swift | nonc
  hasre Sources/Jarvis/Decision/DecisionPlanner.swift 'let hint = near\.isEmpty'
  # exact stems only: the morphology never accepts a prefix as a name
  hasre Sources/Jarvis/Decision/CommandLexicon.swift 'isClosedChain\(String\(token\.dropFirst'
}
v09_none "reliability pass: fuzzy project / alias matches only suggest (a question), exact stems with a closed suffix chain are the only way a name resolves" "$(grel_fuzzy)"

grel_cost() {
  # a paid provider is never an automatic fallback; an explicit choice never falls back; the remote classifier stays off and abstention-only by default
  hasre $RL/ProviderResilience.swift 'c\.cost != \.paid'
  hasre $RL/ProviderResilience.swift 'guard explicitChoice == nil else \{ return \[\] \}'
  hasre Sources/Jarvis/Decision/JevDecisionProvider.swift 'var mode: JevMode = \.disabled'
  hasre Sources/Jarvis/Decision/JevDecisionProvider.swift 'var shadowScope: JevShadowScope = \.abstentionsOnly'
  hasre Sources/Jarvis/Decision/ConfidencePolicy.swift 'var remote: \[DecisionCategory: Double\] = \[\.readOnly: 0\.88, \.ownUI: 0\.92\]'
  # the remote classifier is only asked for an abstention of the grammar
  hasre Sources/Jarvis/Decision/ConfidencePolicy.swift 'guard production\.intent == \.unknown, production\.gate == \.none, production\.ambiguity == \.none'
}
v09_none "reliability pass: no paid provider as an automatic fallback, an explicit choice never falls back, Jev disabled + abstention-only + read-only/own-UI acceptance only" "$(grel_cost)"

grel_bounded() {
  # every retry / loop in the new layers is bounded: no `while true` in the pure reliability code; the Jev retry loop asks the bounded policy on every failure; retries have hard maximums
  grep -nE 'while true|repeat *\{' $PURE_NEW | nonc
  hasre Sources/Jarvis/Decision/JevDecisionProvider.swift 'JevRetryPolicy\.shouldRetry\(failure, attempt: attempt, maxRetries: config\.maxRetries\)'
  hasre Sources/Jarvis/Decision/JevDecisionProvider.swift 'var maxRetries = 1'
  hasre $RL/ProviderResilience.swift 'var maxAttempts = 2'
  hasre $RL/StuckTaskDetector.swift 'var maxRetries = 1'
  # the conversation layer re-routes a correction at most once
  hasre Sources/Jarvis/Services/Conversation/ConversationService.swift 'case \.rewrite\(let corrected\) where rewrites < 1:'
}
v09_none "reliability pass: retries and loops are bounded (Jev retry policy, retry schedule, stuck retry budget, one correction re-route)" "$(grel_bounded)"

grel_secrets() {
  # no credential-shaped literal anywhere in code, tests, corpora or docs (a key that was ever pasted into a chat is revoked, not committed); lines that PLANT an obviously fake secret to prove redaction (FAKE / not-real / hunter2 / alphabet runs) are the only exceptions
  grep -rnIE 'sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|AIza[0-9A-Za-z_-]{30,}' Sources Benchmarks docs scripts --exclude-dir=__pycache__ --exclude-dir=.venv | grep -vE 'scripts/guards_reliability.sh|scripts/verify.sh' | grep -vE 'not-real|notreal|FAKE|hunter2|ABCDEFGHIJKLMNOPQRSTUV|abcdefghijklmnopqrstuvwxyz|LIVEVOICE' | nonc
}
v09_none "reliability pass: no API-key, token or private-key shaped literal in sources, benchmarks, docs or scripts (tests plant fakes on purpose)" "$(grel_secrets)"

grel_corpus() {
  # the new corpora are checked-in ground truth with their schema, a must-not-execute class and ambiguity expectations; the blind set was measured once (its first measurement is recorded)
  grep -q '"schema": "jarvis.decision-corpus/1"' Benchmarks/decision_adversarial.json || echo 'adversarial schema'
  grep -q '"schema": "jarvis.decision-corpus/1"' Benchmarks/decision_blind.json || echo 'blind schema'
  grep -q 'mustNotExecute' Benchmarks/decision_adversarial.json || echo 'adversarial mustNotExecute'
  grep -q 'mustNotExecute' Benchmarks/decision_blind.json || echo 'blind mustNotExecute'
  grep -q 'first measurement' docs/V1_RELIABILITY_PASS.md || echo 'blind set first measurement not recorded'
}
v09_none "reliability pass: adversarial + blind corpora exist with their schema, must-not-execute and ambiguity labels, and the blind set's first measurement is recorded" "$(grel_corpus)"
