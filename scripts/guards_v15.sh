# V0.15 guards (sourced by scripts/verify.sh after guards_v14.sh): the daily experience is presentation, references, readiness and app lifecycle — never authority, never a second orchestrator.
hasre() { grep -qE -- "$2" "$1" || echo "missing in $1: $2"; }
DY=Sources/Jarvis/Daily; RD=Sources/Jarvis/Readiness
LIVE15='^Sources/Jarvis/App/(Daily|Packaging|Setup)LiveTest\.swift'

g15_orchestrator() {
  grep -rnE '(class|struct|enum|actor|protocol) +[A-Za-z]*(Voice|Conversation|Personality|Setup|App|Dependency|Readiness|Presentation)[A-Za-z]*Orchestrat' Sources | nonc
  # the new layers plan nothing, schedule nothing and run no agent
  grep -rnE 'OrchestratedPlan|GraphValidator|OrchestrationPlanner|saveGraph|AgentJob\(|\.agents\.run|StepAgentRunner|engine\.submit\(|taskEngine\.submit\(|\.submitTask\(|submitResearch\(' $DY $RD | nonc
}
v09_none "V0.15 adds no second orchestrator: no Voice/Conversation/Personality/Setup/App/Dependency orchestrator type exists, and the daily and readiness layers plan no graph, run no agent and submit no task" "$(g15_orchestrator)"

g15_noauthority() {
  # presentation, follow-ups and readiness can neither decide a request nor touch an approval
  grep -rnE '\.approve\(|\.deny\(|approveByStandingPolicy|AdaptiveDecisionSource|decisions\.|adaptiveDecisions|pendingApproval|requestApproval|grantCapabilit|TaskCapability|CapabilitySet|ApprovalPolicy' $DY | nonc
  grep -rnE '\.approve\(|\.deny\(|approveByStandingPolicy|AdaptiveDecisionSource|pendingApproval|requestApproval|grantCapabilit|CapabilitySet' $RD | nonc
}
v09_none "personality, working context and readiness never touch an approval, a decision or a capability: no approve / deny / pendingApproval / capability reference in Daily/ or Readiness/" "$(g15_noauthority)"

g15_guardline() {
  has Sources/Jarvis/Services/Conversation/ConversationService.swift '(store.pendingApproval != nil || hasPendingDecision()), ApprovalGuard.isApprovalUtterance(text0)'
  grep -n 'ReferenceResolver.resolve' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1 > /tmp/.g15_resolve
  grep -n 'ApprovalGuard.isApprovalUtterance(text0)' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1 > /tmp/.g15_approval
  [ "$(cat /tmp/.g15_approval)" -lt "$(cat /tmp/.g15_resolve)" ] || echo "the approval guard must run BEFORE follow-up resolution"
  has $DY/WorkingContext.swift 'ApprovalGuard.isApprovalUtterance(text)'
}
v09_none "a spoken or typed yes/evet cannot decide anything: the approval guard covers every kind of pending decision and runs before follow-up resolution; a bare yes never answers a clarification" "$(g15_guardline)"

g15_ephemeral() {
  # the working context is memory-only: not Codable, not persisted, not written to Project Memory or the learning layer
  grep -nE 'UserDefaults|JSONEncoder|JSONDecoder|NSKeyedArchiver|PropertyListEncoder|\.write\(to:|createFile\(|repository|JarvisRepository|SQLite|ProjectMemory|MemoryService|memory\.|LearningService|learning\.|Codable' $DY/WorkingContext.swift | nonc
  grep -rnE 'workingContext' Sources --include='*.swift' | grep -vE "^Sources/Jarvis/(Daily/|Services/Conversation/ConversationService\.swift|App/AppContext\+Daily\.swift|App/DailyLiveTest\.swift|UI/Settings/DailySettingsSection\.swift)" | nonc
}
v09_none "conversational working context is bounded and EPHEMERAL: no persistence, no Codable, no Project Memory or learning write; only ConversationService, the daily wiring, Settings and the live test touch it" "$(g15_ephemeral)"

g15_destructive() {
  has $DY/WorkingContext.swift 'Never from recency: only something the user explicitly chose or named, and only when it is the single candidate.'
  has $DY/WorkingContext.swift 'if f.verb.destructive { return ask([pick], verb: f.verb, conditional: f.conditional, context: context, language: l, confirmSingle: true) }'
  hasre $DY/WorkingContext.swift 'static let capacity = 16$'
  hasre $DY/WorkingContext.swift 'static let maxAge: TimeInterval = 30 \* 60$'
  hasre $DY/WorkingContext.swift 'static let maxTurns = 30$'
  has $DY/WorkingContext.swift 'guard UntrustedContent.scan(label).isEmpty, !OutputSanitizer.containsSecret(label) else { return nil }' 
}
v09_none "a destructive follow-up never guesses its target (only an explicit single choice, otherwise it asks, and approval still applies); the context is bounded (16 items, 30 minutes) and refuses instruction- or secret-shaped labels" "$(g15_destructive)"

g15_setup() {
  # no sudo, no downloader, no shell string, no package manager, no URL anywhere in the readiness layer
  grep -rnE 'sudo|curl|wget|osascript|NSAppleScript|brew |pip3? install|npm install|npx |apt |/bin/(ba|z)?sh|"sh", *"-c"|Process\(\)|https?://' $RD | nonc
  # the closed action list has no case that takes text, a URL or a command, and none for an external CLI or an MCP
  awk '/^enum SetupAction/,/^    var id/' $RD/ReadinessModel.swift | grep -E '^ *case ' | grep -iE 'url|command|shell|script|path|text|claude|codex|opencode|mcp|brew|npm|pip|download' | nonc
  # exactly one process launch point in the readiness layer (the setup script run), through ManagedProcess
  local n; n=$(grep -rn 'ManagedProcess(' $RD | nonc | wc -l | tr -d ' ')
  [ "$n" = "1" ] || echo "expected exactly one ManagedProcess launch in Readiness/, found $n"
}
v09_none "setup is typed and allowlisted: no sudo / downloader / package manager / shell string / URL in Readiness/, no setup action carries text, a URL or a command (or names an external CLI or MCP), and exactly one process launch (the packaged script, via ManagedProcess)" "$(g15_setup)"

g15_nocreds() {
  grep -rnE 'SecItem|kSec|Keychain|HTTPCookie|binarycookies|credential\.|auth\.json|\.credentials|find-generic-password|security find' $DY $RD | nonc
  # provider status comes from the safe probe the app already has; readiness reads no provider credential store
  grep -rnE 'CLAUDE_CONFIG_DIR|CODEX_HOME|[~/"]\.claude|[~/"]\.codex|opencode/auth|oauth' $RD | nonc
}
v09_none "readiness never enumerates or reads credentials: no Keychain, cookie, credential-store or provider-config access in Daily/ or Readiness/" "$(g15_nocreds)"

g15_paid() {
  grep -n 'provider.paid' $RD/ReadinessService.swift | grep -E 'action: *\.' | nonc
  awk '/^enum SetupAction/,/^    var id/' $RD/ReadinessModel.swift | grep -E '^ *case ' | grep -iE 'paid|api|key|subscription|purchase|buy' | nonc
}
v09_none "no paid API can be enabled by readiness or setup: the Paid API item has no action and no setup action mentions an API, key, subscription or purchase" "$(g15_paid)"

g15_bundle() {
  # mutable data never lives in the app; Bundle.main is read only for identity and the packaged setup scripts
  grep -rnE 'Bundle\.main|bundleURL|bundlePath|resourceURL' Sources | grep -vE '^Sources/Jarvis/(Core/Log\.swift|Readiness/(SetupRunner|SystemIntegration|CodeIdentity)\.swift|Persistence/StorageIsolation\.swift|App/([A-Za-z]*LiveTest|LiveUIDriver|SmokeTest|DevCapture|PermissionReport|UICapture)\.swift|Computer/|Voice/)' | nonc
  grep -rnE 'JarvisPaths\(root:.*(Bundle|bundle)' Sources | nonc
  # the installed app has no dependency on a repository, the working directory or a development server
  grep -rnE '#filePath|#file[^A-Za-z]|currentDirectoryPath|swift run|swift build|xcodebuild|localhost:|127\.0\.0\.1' Sources | grep -vE '^Sources/Jarvis/App/([A-Za-z]*LiveTest|StabilitySoak|VisualBenchmark|SmokeTest|DevCapture)\.swift|^Sources/Jarvis/Services/Demo/|^Sources/Jarvis/Research/URLPolicy\.swift|^Sources/Jarvis/Research/MCPDiscovery\.swift|^Sources/Jarvis/Tasks/CommandProfiles\.swift' | nonc
  # the packaging script refuses a bundle that contains a database or a model, and pins the entitlement list
  has scripts/package-app.sh 'no database and no model inside the bundle'
  has scripts/package-app.sh 'entitlements: only the microphone'
  [ "$(grep -c '<key>' Resources/Jarvis.entitlements)" = "1" ] || echo "Jarvis.entitlements must contain exactly one key"
  [ -z "$(find Resources -type f -size +5M 2>/dev/null)" ] || echo "a file larger than 5 MB is in Resources/"
}
v09_none "the app is a self-contained bundle: mutable state is never inside it, Bundle.main is read only for identity and the packaged setup scripts, nothing depends on the repository, the working directory or a development server, and the package script pins the entitlement list and refuses models or databases" "$(g15_bundle)"

g15_persistence() {
  has $RD/SystemIntegration.swift 'SMAppService.mainApp.register()'
  grep -rnE 'LaunchAgents|LaunchDaemons|launchctl' Sources scripts/package-app.sh scripts/install-app.sh | grep -vE '^Sources/Jarvis/(Capabilities/MCPInspectionRules|Computer/ComputerPolicy)\.swift' | nonc
  # no automatic update or replacement of the app by the app
  grep -rnE 'Sparkle|SUUpdater|package-app|install-app|replaceItemAt|\.dmg' Sources | grep -vE '^Sources/Jarvis/App/SetupLiveTest\.swift' | nonc
  # notifications and Launch at Login are asked for only from a user action
  grep -rnE 'requestAuthorization\(\)|LaunchAtLogin\.set\(' Sources | grep -vE '^Sources/Jarvis/(Readiness/|Daily/SettingsAssistant\.swift|UI/Settings/DailySettingsSection\.swift|App/PackagingLiveTest\.swift)' | nonc
}
v09_none "no hidden persistence and no self-update: Launch at Login is SMAppService only (one file), no LaunchAgent/Daemon/launchctl, nothing in the app builds, installs or replaces the app, and notification / login-item requests come only from Readiness actions and Settings" "$(g15_persistence)"

g15_idle() {
  grep -rnE 'Timer\.|scheduledTimer|asyncAfter|Task\.sleep|makeTimerSource|NSTimer|CADisplayLink' $DY $RD | nonc
  grep -rnE 'readiness\.refresh\(\)|\.refresh\(\)' Sources/Jarvis/Core Sources/Jarvis/UI/CompactHUD | grep -i readiness | nonc
}
v09_none "nothing in Daily/ or Readiness/ runs on a timer or polls: readiness is read on appear, on Recheck and after a user action — never while idle" "$(g15_idle)"

g15_instance() {
  has $RD/SystemIntegration.swift '!arguments.dropFirst().contains { $0.hasPrefix("--") && $0 != AppRelauncher.flag }'
  has Sources/Jarvis/App/AppDelegate.swift 'if SingleInstance.handOverToRunningInstance() { NSApp.terminate(nil); return }'
  has Sources/Jarvis/App/AppDelegate.swift 'func applicationShouldHandleReopen'
}
v09_none "a plain launch hands over to the running copy (single instance) while developer and live-test launches are exempt; reopening shows the running app" "$(g15_instance)"

g15_pure() {
  # the presentation layer cannot reach task state, the engine or the store
  grep -nE 'TaskEngine|taskEngine|JarvisStore|store\.|TaskView|\.cancel\(|stopActiveTask' $DY/ResponsePolicy.swift | nonc
  has $DY/ResponsePolicy.swift 'PRESENTATION ONLY'
  has $DY/ResponsePolicy.swift 'a sentence that carries a failure, a refusal, an unknown or a pending decision is never dropped by shortening'
}
v09_none "personality is presentation only: ResponsePolicy.swift cannot reach the task engine or the store, and shortening never drops a failure, refusal, unknown or pending decision" "$(g15_pure)"

g15_livetests() {
  # the V0.15 live tests use disposable fixtures only; the real Hamam project is never named or opened by them
  grep -niE 'hamam' Sources/Jarvis/App/DailyLiveTest.swift Sources/Jarvis/App/PackagingLiveTest.swift Sources/Jarvis/App/SetupLiveTest.swift | nonc
  grep -nE 'TaskDemo\.makeProject|fm\.temporaryDirectory' Sources/Jarvis/App/DailyLiveTest.swift Sources/Jarvis/App/SetupLiveTest.swift | head -1 | grep -q . || echo "the V0.15 live tests must use temporary fixtures"
  grep -nE '\.claudeCode|openCode\.(refresh|start|run|stop)|ProviderID|providers\.resolve|coordinator\.|supervisor\.|\.agents\.run' Sources/Jarvis/App/DailyLiveTest.swift Sources/Jarvis/App/SetupLiveTest.swift | nonc
}
v09_none "the V0.15 live tests touch no real project (Hamam is never named) and ask no provider (scripted answers only)" "$(g15_livetests)"

# ───────────────────────── V1.0 stabilisation fix 2 (real capability grounding · hands-free lifecycle · production UI truth · conversation/state truth) ─────────────────────────
g1f2_demo() {
  # production never seeds demo data: the default is false and only a developer launch option turns it on
  has Sources/Jarvis/App/AppContext.swift 'init(seedDemoData: Bool = false'
  has Sources/Jarvis/App/AppDelegate.swift 'seedDemoData: options.isDemoEnvironment'
  has Sources/Jarvis/App/AppContext.swift 'var simulatorControlsVisible: Bool { demoMode && preferences.showDeveloperControls }'
  # every simulator control in the UI is gated on simulatorControlsVisible (same or previous line)
  for f in $(grep -rlE 'DevStateStrip\(|\{ demoTasks \}|\{ simulateMenu \}' Sources/Jarvis/UI | grep -v DevStateStrip.swift); do
    awk -v F="$f" '{ if ($0 ~ /DevStateStrip\(|\{ demoTasks \}|\{ simulateMenu \}/ && $0 !~ /simulatorControlsVisible/ && prev !~ /simulatorControlsVisible/) print F":"NR": ungated simulator control"; prev=$0 }' "$f"
  done
  # no placeholder statuses in the UI
  grep -rnE 'DEMO · NOT CONNECTED|PLANNED · V0\.8|Lorem ipsum' Sources/Jarvis/UI | nonc
  # demo / fixture types are referenced only from developer, capture, live-test and wiring files
  grep -rlE 'DemoScenario|TaskDemo|ResearchDemo|AdaptiveDemo|OrchestrationDemo|DemoAgentRunner' Sources | grep -vE '^Sources/Jarvis/(Services/Demo/|App/(SmokeTest|DevCapture|AppDelegate|AppContext|[A-Za-z]*LiveTest)\.swift|UI/Components/DevStateStrip\.swift)' | nonc
  # the voice-state simulation hooks are called only by smoke / capture
  grep -rnE '(voice|hf|handsFree)\.simulate\(' Sources | grep -vE '^Sources/Jarvis/App/(SmokeTest|DevCapture)\.swift' | nonc
}
v09_none "production UI truth: demo seeding is opt-in (developer launch options only), every simulator control is gated on simulatorControlsVisible, no placeholder statuses ship, and demo / fixture types and voice-state simulation are reachable only from developer, capture and live-test files" "$(g1f2_demo)"

g1f2_firewall() {
  # the engine is told it is an engine; a finished reply that states JARVIS' abilities is replaced; ability questions never reach a model
  has Sources/Jarvis/Providers/CLIProviderSpecs.swift 'language engine inside JARVIS'
  has Sources/Jarvis/Services/Conversation/ConversationService.swift 'applyCapabilityFirewall(to: messageID'
  has Sources/Jarvis/Readiness/CapabilityClaimGuard.swift 'enum CapabilityClaimGuard'
  # the old wording that made the engine say “I can't read files” must not come back
  grep -nH 'cannot run commands, read or modify files' Sources/Jarvis/Providers/CLIProviderSpecs.swift | nonc
  # the guard and the ability answers touch no approval, capability or network
  grep -nHE '\.approve\(|pendingApproval|CapabilitySet|URLSession|Process\(' Sources/Jarvis/Readiness/CapabilityClaimGuard.swift | nonc
}
v09_none "provider identity firewall: the engine instruction says the engine is not the product and forbids stating JARVIS' abilities, the old 'cannot read files' wording is gone, and a finished reply that claims or denies abilities is replaced from readiness state" "$(g1f2_firewall)"

g1f2_settings() {
  # the closed settings registry: presentation and voice conveniences only — never an approval, a permission, a capability, an autonomy or provider/security choice
  grep -nHE '\.approve\(|ApprovalPolic|pendingApproval|autonomyMode|providerPreference|computerUseEnabled|webResearchEnabled|allowFreeCloud|allowLocalInAuto|visualGroundingMode|projectContinuationEnabled|experimentsEnabled|adaptiveLearningEnabled|memoryAutoLearn|AXIsProcessTrusted|CGPreflight|requestAuthorization' Sources/Jarvis/Daily/SettingsAssistant.swift | nonc
  # settings requests and storage questions are handled BEFORE Project Memory, so a preference can never become a memory command
  s=$(grep -n 'settings.recognizes(text)' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1)
  m=$(grep -n 'memory.recognizes(text)' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1)
  [ -n "$s" ] && [ -n "$m" ] && [ "$s" -lt "$m" ] || echo "settings requests must be handled before Project Memory"
  # a side effect is reported only after the typed value was read back
  grep -c 'guard p\.' Sources/Jarvis/Daily/SettingsAssistant.swift | awk '$1 < 5 { print "settings actions must verify the value that was set" }'
}
v09_none "settings requests change only the closed registry (voice / address / answer-length / wake / notifications / login item), are read back before they are reported, never touch approvals, permissions, capabilities or security, and run before Project Memory" "$(g1f2_settings)"

g1f2_correction() {
  # a correction is routed again from scratch, carries no authority, and is bounded memory-only context
  grep -nHE '\.approve\(|pendingApproval|CapabilitySet|\.decide\(' Sources/Jarvis/Daily/CorrectionIntent.swift | nonc
  grep -nHE 'Codable|UserDefaults|repository|sqlite' Sources/Jarvis/Daily/CorrectionIntent.swift Sources/Jarvis/Daily/StorageLedger.swift | nonc
  # the transcript repair table never contains an approval or destructive word
  grep -nHiE '\("(approve|onay|evet|yes|delete|sil|remove|kaldır)' Sources/Jarvis/Daily/CorrectionIntent.swift | nonc
}
v09_none "corrections and transcript repair carry no authority (no approval/decision reference), are memory-only (no persistence), and the repair table holds no approval or destructive word" "$(g1f2_correction)"

g1f2_wake() {
  # sleep mode / system sleep / device change are bounded and only the hands-free coordinator owns them; wake stays OFF by default
  has Sources/Jarvis/Voice/Natural/HandsFreeCoordinator.swift 'func enterSleepMode'
  has Sources/Jarvis/Voice/Natural/HandsFreeCoordinator.swift 'func suspendForSystemSleep'
  has Sources/Jarvis/Voice/Natural/HandsFreeCoordinator.swift 'var recoveryDelays: [Double] = [2, 6]'
  has Sources/Jarvis/Core/Preferences.swift 'voiceWakeEnabled = defaults.object(forKey: Key.wakeEnabled) as? Bool ?? false'
  # no global event monitors / taps were added for hands-free
  grep -rnE 'addGlobalMonitorForEvents|CGEventTapCreate|RegisterEventHotKey' Sources | grep -vE '^Sources/Jarvis/(Computer/AXBackend|App/[A-Za-z]*LiveTest)\.swift' | nonc
  # the Voice settings overview exists and the voice strip has a fixed reserved height
  has Sources/Jarvis/UI/Settings/VoiceStatusRows.swift 'enum VoiceStatusRows'
  has Sources/Jarvis/UI/Components/VoiceViews.swift 'static let reservedHeight: CGFloat = 26'
}
v09_none "hands-free lifecycle: sleep mode, Mac sleep/wake and audio-device changes are handled by the hands-free coordinator with bounded recovery, wake stays opt-in, no global event monitor exists, the Voice overview rows exist and the voice strip has a fixed reserved height" "$(g1f2_wake)"

# ───────────────────────── V1.0 stabilisation fix 3 (macOS productization · permissions · storage isolation · Full HUD design system) ─────────────────────────
g1f3_storage() {
  # test / developer launches never touch production storage: isolated defaults, data under JARVIS-LiveTests, hard guards
  has Sources/Jarvis/Persistence/StorageIsolation.swift 'enum StorageIsolation'
  has Sources/Jarvis/Persistence/StorageIsolation.swift 'STORAGE ISOLATION VIOLATION'
  has Sources/Jarvis/Core/Preferences.swift 'StorageIsolation.assertNotProduction(defaults)'
  has Sources/Jarvis/App/AppContext.swift 'StorageIsolation.assertNotProduction(dataRoot: p.root)'
  has Sources/Jarvis/App/AppContext.swift 'StorageIsolation.defaultsForRun'
  # no source touches the production defaults domain except the files that own it; no live test keeps its data under the production folder
  grep -rn 'UserDefaults\.standard' Sources --include='*.swift' | grep -vE '^Sources/Jarvis/(Persistence/StorageIsolation|Core/Preferences|Core/Log)\.swift' | nonc
  grep -rnE 'JarvisPaths\.standard\(\)\.root\.appendingPathComponent\("live-test' Sources | nonc
  # a fixture project selection is never a production project
  has Sources/Jarvis/Persistence/StorageIsolation.swift 'static func isTestFixturePath'
}
v09_none "storage isolation: tests and developer launches use an isolated defaults suite and a data directory under JARVIS-LiveTests, a violation is fatal, nothing else names UserDefaults.standard, and a fixture project selection is cleared from production" "$(g1f3_storage)"

g1f3_window() {
  # the whole window is never draggable; only the header drag region moves it
  grep -rn 'isMovableByWindowBackground = true' Sources | nonc
  has Sources/Jarvis/Services/Windows/FullHUDFramePolicy.swift 'struct WindowDragRegion'
  has Sources/Jarvis/Services/Windows/FullHUDFramePolicy.swift 'window?.performDrag(with: event)'
  # no exclusive full screen and no presentation-option tricks
  grep -rnE 'toggleFullScreen|NSApplication\.PresentationOptions|presentationOptions|\.fullScreenPrimary' Sources | nonc
  has Sources/Jarvis/Services/Windows/WindowManager.swift 'FullHUDFramePolicy.resolve('
}
v09_none "window policy: the Full HUD fills the usable screen as a normal resizable window (never exclusive full screen), only the header drag region moves it, and the saved frame is recovered onto an existing screen" "$(g1f3_window)"

g1f3_identity() {
  # developer bundle identity differs from the installed app's; staging copy is removed after install
  has scripts/build_app.sh 'dev.jarvis.Jarvis.dev'
  has scripts/install-app.sh 'Removed the staging copy'
  has scripts/package-app.sh 'dev.jarvis.Jarvis'
}
v09_none "app identity: the developer bundle has its own bundle id, the installed app is the only JARVIS after an install (staging removed), " "$(g1f3_identity)"

g1f3_ui() {
  # Settings is a Full HUD destination and the design system exists
  has Sources/Jarvis/Core/HUDState.swift 'case dashboard, tasks, agents, research, report, system, memory, computer, learning, capabilities, settings'
  has Sources/Jarvis/UI/Components/DesignSystem.swift 'struct PageScaffold'
  has Sources/Jarvis/UI/Theme/Theme.swift 'enum Grid'
  # voice never approves: the voice/wake settings page has no approval path
  grep -nE 'resolveApproval|decideApproval|\.approve\(' Sources/Jarvis/UI/Settings/VoiceControlCards.swift Sources/Jarvis/UI/FullHUD/Settings/SettingsPageView.swift | nonc
}
v09_none "Full HUD: Settings is a destination, pages are built on the shared design system (PageScaffold, Card, Theme.Grid), and the settings pages contain no approval path" "$(g1f3_ui)"

# ───────────────────────── V1.0 stabilisation fix 4 (action execution · system truth · self-echo safety) ─────────────────────────
g1f4_actions() {
  # NO VERIFIED ACTION → NO COMPLETION CLAIM: success wording is only rendered for a claimable receipt, and the model's first-person action claims are stripped
  has Sources/Jarvis/Actions/ActionReceipt.swift 'var successIsClaimable: Bool { status == .succeeded && verification?.passed == true }'
  has Sources/Jarvis/Actions/ActionService.swift 'case .succeeded where r.successIsClaimable:'
  has Sources/Jarvis/Services/Conversation/ConversationService.swift 'ActionClaimGuard'
  # a model has no execution path: the action service is reached only from ConversationService.handleAction, never from provider/model code
  grep -rln 'actionService' Sources/Jarvis/Providers Sources/Jarvis/Intelligence 2>/dev/null | nonc
  # actions never carry authority: no approval API in the action layer
  grep -rnE 'resolveApproval|decideApproval|\.approve\(|grantCapability' Sources/Jarvis/Actions | nonc
  # system status comes from the structured state, not a model
  has Sources/Jarvis/Readiness/ReadinessAssistant.swift 'case systemStatus(StatusScope)'
}
v09_none "actions: a completion sentence exists only for a verified receipt, the model's action claims are stripped, the action layer has no approval path and no model reaches it, system status is a structured intent" "$(g1f4_actions)"

g1f4_voice() {
  # barge-in needs an envelope confirmation (JARVIS' own delayed voice is recognised) and the phantom guard decides by provenance, not by text
  has Sources/Jarvis/Voice/Natural/BargeInDetector.swift 'var confirmEnvelope = true'
  has Sources/Jarvis/Voice/Natural/EchoProvenance.swift 'enum PhantomGuard'
  has Sources/Jarvis/Voice/VoiceCoordinator.swift 'PhantomGuard.verdict('
  # provenance, diagnostics and the guard hold no audio, no transcript and write nothing
  grep -nE 'AudioFrame|\[Float\]|forWriting|FileHandle|write\(|var (text|transcript)' Sources/Jarvis/Voice/Natural/EchoProvenance.swift | grep -vE '^[0-9]+:[[:space:]]*(///|//)' | nonc
  # voice has no authority: no approval path in the echo/provenance code and the vocabulary is plain structured names
  grep -nE 'approve|Approval|grant' Sources/Jarvis/Voice/Natural/EchoProvenance.swift Sources/Jarvis/Actions/PhoneticAppResolver.swift | grep -vE '^[0-9]+:[[:space:]]*(///|//)' | nonc
  has Sources/Jarvis/Voice/SpeechToText.swift 'static let maximumContextual = 40'
  # no platform echo canceller / voice-processing audio unit was introduced (not verified stable; layered rejection is used instead)
  grep -rnE 'kAudioUnitSubType_VoiceProcessingIO|setVoiceProcessingEnabled|isVoiceProcessingEnabled' Sources | nonc
}
v09_none "voice: barge-in is envelope-confirmed, short transcripts over JARVIS' own speech are rejected by provenance, diagnostics hold no audio or text, the vocabulary is bounded, voice has no approval path, no voice-processing unit" "$(g1f4_voice)"
