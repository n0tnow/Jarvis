# V1.0 decision-milestone guards (sourced by scripts/verify.sh after guards_v15.sh): the Decision layer is ADVISORY — it classifies, plans and records; it never executes, approves, grants or reaches the network.
# The optional remote classifier (Jev) is an adapter boundary only: disabled by default, no transport, no credential store, no hard-coded model or host in this repository.
DC=Sources/Jarvis/Decision
DCV=Sources/Jarvis/Voice/Natural/PathologicalTranscriptGuard.swift

gdc_authority() {
  # no approval, capability, task submission, process, network or credential API anywhere in the decision layer or the transcript guard
  grep -rnE 'decideApproval|ApprovalGuard|pendingApproval|\.approve\(|\.deny\(|TaskCapability|CapabilitySet|grantCapabilit|engine\.submit|taskEngine|submitTask|submitResearch|StepAgentRunner|Process\(\)|NSTask|posix_spawn|/bin/(ba|z)?sh|osascript|AppleScript|URLSession|URLRequest|NWConnection|WebSocket|SecItem|Keychain|HTTPCookieStorage|Data\(contentsOf|String\(contentsOf' $DC $DCV | nonc
}
v09_none "decision layer: no approval, capability, task submission, process, AppleScript, network or credential API (it classifies and plans; it cannot act)" "$(gdc_authority)"

gdc_secrets() {
  # no endpoint, no key-shaped literal, no hard-coded hosted model in the decision layer (the real transport and credential are Phase B, on the user's Mac)
  grep -rnEi 'https?://|api[_-]?key|bearer|authorization|x-api|sk-[a-z0-9]{6}|claude-(opus|sonnet|haiku|fable)|gpt-[0-9]|typesafe\.|jev-[0-9]|\.env' $DC $DCV | nonc
}
v09_none "decision layer: no URL, API-key shape, credential header or hard-coded hosted model name" "$(gdc_secrets)"

gdc_defaults() {
  hasre $DC/JevDecisionProvider.swift 'var mode: JevMode = \.disabled'
  hasre $DC/JevDecisionProvider.swift 'struct UnconfiguredJevTransport'
  hasre $DC/JevDecisionProvider.swift 'func complete\(_ request: JevClassifyRequest, modelAlias: String'
  hasre Sources/Jarvis/Core/Preferences.swift 'JevMode\.disabled\.rawValue'
  # the only real transport is TypeSafeJevTransport (Providers/Jev); no other type conforms to JevTransport in Sources
  grep -rnE ': *JevTransport|JevTransport *\{' Sources | grep -vE 'Decision/JevDecisionProvider\.swift|Providers/Jev/TypeSafeJevTransport\.swift' | nonc
  # the closed set a remote decision may be accepted for in GATED mode is read-only / own-UI only
  grep -nE 'static let acceptableIntents' $DC/DecisionTypes.swift | grep -vE '\[\.conversation, \.voiceStatus, \.systemStatus, \.jarvisNavigation, \.projectQuery, \.providerCapability\]' | nonc
}
v09_none "Jev: disabled by default, the decision layer holds no transport and no credential, gated acceptance limited to the closed read-only set" "$(gdc_defaults)"

gdc_jev_secret() {
  # DEC-275: the Keychain is touched in ONE file, the key is read in ONE file, the Authorization header exists in ONE file, and nothing there logs or prints
  grep -rnE 'SecItem(Add|Update|CopyMatching|Delete)|kSecClassGenericPassword' Sources | grep -vE 'Sources/Jarvis/Providers/Jev/JevCredentialStore\.swift' | grep -vE '^Sources/Jarvis/(Capabilities/MCPInspectionRules|Readiness/)' | nonc
  grep -rnE 'JevCredentialStore\.(read|store|delete)\(' Sources | grep -vE 'Sources/Jarvis/Providers/Jev/(TypeSafeJevTransport|JevCredentialStore)\.swift|Sources/Jarvis/App/DecisionTools\.swift' | nonc
  grep -rnE 'forHTTPHeaderField: "Authorization"|"Bearer \\\(' Sources | grep -vE 'Sources/Jarvis/Providers/Jev/TypeSafeJevTransport\.swift' | nonc
  grep -nHE 'print\(|NSLog|os_log|Logger|debugPrint|dump\(' Sources/Jarvis/Providers/Jev/TypeSafeJevTransport.swift Sources/Jarvis/Providers/Jev/JevCredentialStore.swift | nonc
  # the secret never enters UserDefaults / SQLite / the preferences
  grep -nHE 'UserDefaults|sqlite|Preferences|FileManager|write\(to' Sources/Jarvis/Providers/Jev/JevCredentialStore.swift | nonc
}
v09_none "Jev credential: one Keychain file, one reader, one Authorization header, no log or print, never in preferences or files" "$(gdc_jev_secret)"

gdc_policy() {
  # risk and gate are re-derived from the policy table for every non-grammar decision; the answer's own risk/gate fields are never read
  hasre $DC/JevDecisionProvider.swift 'DecisionPolicy\.finalize\(intent: intent'
  grep -nE 'object\["(risk|gate)"\]' $DC/JevDecisionProvider.swift | nonc
  # git push / commit / purchase / credential are blocked by the table
  hasre $DC/JevDecisionProvider.swift '"git_push", "git_commit"'
  hasre $DC/DecisionPlanner.swift 'if d\.gate == \.blocked'
}
v09_none "policy outranks confidence: risk and gate come from DecisionPolicy; blocked decisions are refused by the planner" "$(gdc_policy)"

gdc_order() {
  # the decision step runs BEFORE the typed action step and before any model route in ConversationService
  local a b
  a=$(grep -n 'engine.decide(text' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1)
  b=$(grep -n 'if let actions = actionService, let intent = actions.recognizes(text)' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || echo "the decision step must precede the action step (decide@$a action@$b)"
  # a rejected transcript never reaches deliver(): the guard runs before it, and before the hands-free filters
  local g d
  g=$(grep -n 'PathologicalTranscriptGuard.evaluate(' Sources/Jarvis/Voice/VoiceCoordinator.swift | head -1 | cut -d: -f1)
  d=$(grep -n '            deliver(text, language: event?.language)' Sources/Jarvis/Voice/VoiceCoordinator.swift | head -1 | cut -d: -f1)
  [ -n "$g" ] && [ -n "$d" ] && [ "$g" -lt "$d" ] || echo "the pathological-transcript guard must run before deliver (guard@$g deliver@$d)"
  hasre Sources/Jarvis/Voice/VoiceCoordinator.swift 'case transcriptRejected'
}
v09_none "ordering: decisions precede typed actions and models; pathological transcripts are dropped before deliver()" "$(gdc_order)"

gdc_nav() {
  # a JARVIS-page action is claimed only after the canonical selection AND the window's own acknowledgement agree, with a settled second read-back
  hasre Sources/Jarvis/Actions/ActionService.swift 'requiresRenderAck'
  hasre Sources/Jarvis/Actions/ActionService.swift 'HUD render acknowledgement'
  hasre Sources/Jarvis/Actions/ActionService.swift 'navigationSettle'
  hasre Sources/Jarvis/UI/FullHUD/FullHUDView.swift 'hud.renderedSection = '
  # observations are the only evidence of visibility, and they carry a timestamp
  hasre Sources/Jarvis/Computer/ComputerRuntime.swift 'ObservedApp\(name: app, at: Date\(\)\)'
  hasre $DC/DecisionGrounding.swift 'static let freshSeconds'
}
v09_none "NO VERIFIED ACTION → NO COMPLETION CLAIM: navigation needs state + render acknowledgement + settle; visibility needs a fresh observation" "$(gdc_nav)"

gdc_corpus() {
  [ -f Benchmarks/decision_corpus.json ] || echo "Benchmarks/decision_corpus.json is missing"
  [ -f Benchmarks/local_model_probes.json ] || echo "Benchmarks/local_model_probes.json is missing"
  local n; n=$(grep -c '"id": "' Benchmarks/decision_corpus.json 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 250 ] || echo "decision corpus has only $n cases"
  grep -q 'jarvis.decision-corpus/1' Benchmarks/decision_corpus.json || echo "corpus schema id missing"
  # nothing in the local-model benchmark selects or hard-codes a production model
  grep -nHE 'LocalQwen|qwen3|Qwen3|mlx-community|huggingface' Sources/Jarvis/Decision/LocalModelBenchmark.swift | nonc
}
v09_none "decision benchmark corpus + local-model probes exist (≥ 250 cases, schema id), the harness hard-codes no model" "$(gdc_corpus)"

gdc_transcript() {
  # the guard keeps counts only: no transcript text in its metrics, no audio type, no file writes
  grep -nE 'AudioFrame|\[Float\]|forWriting|FileHandle|write\(|var (text|transcript)' $DCV | grep -vE '^[0-9]+:[[:space:]]*///' | nonc
  hasre $DCV 'enum TranscriptRejection'
  hasre $DCV 'excessiveTokenRepetition'
  hasre $DCV 'repeatedNGramLoop'
  hasre $DCV 'decoderLoopSuspected'
}
v09_none "pathological transcript guard: reason codes, counts only, no audio, no text, no writes" "$(gdc_transcript)"
