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
  has Sources/Jarvis/Services/Conversation/ConversationService.swift '(store.pendingApproval != nil || hasPendingDecision()), ApprovalGuard.isApprovalUtterance(text)'
  grep -n 'ReferenceResolver.resolve' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1 > /tmp/.g15_resolve
  grep -n 'ApprovalGuard.isApprovalUtterance(text)' Sources/Jarvis/Services/Conversation/ConversationService.swift | head -1 | cut -d: -f1 > /tmp/.g15_approval
  [ "$(cat /tmp/.g15_approval)" -lt "$(cat /tmp/.g15_resolve)" ] || echo "the approval guard must run BEFORE follow-up resolution"
  has $DY/WorkingContext.swift 'ApprovalGuard.isApprovalUtterance(text)'
}
v09_none "a spoken or typed yes/evet cannot decide anything: the approval guard covers every kind of pending decision and runs before follow-up resolution; a bare yes never answers a clarification" "$(g15_guardline)"

g15_ephemeral() {
  # the working context is memory-only: not Codable, not persisted, not written to Project Memory or the learning layer
  grep -nE 'UserDefaults|JSONEncoder|JSONDecoder|NSKeyedArchiver|PropertyListEncoder|\.write\(to:|createFile\(|repository|JarvisRepository|SQLite|ProjectMemory|MemoryService|memory\.|LearningService|learning\.|Codable' $DY/WorkingContext.swift | nonc
  grep -rnE 'workingContext' Sources --include=*.swift | grep -vE "^Sources/Jarvis/(Daily/|Services/Conversation/ConversationService\.swift|App/AppContext\+Daily\.swift|App/DailyLiveTest\.swift|UI/Settings/DailySettingsSection\.swift)" | nonc
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
  grep -rnE 'Bundle\.main|bundleURL|bundlePath|resourceURL' Sources | grep -vE '^Sources/Jarvis/(Core/Log\.swift|Readiness/(SetupRunner|SystemIntegration)\.swift|App/([A-Za-z]*LiveTest|LiveUIDriver|SmokeTest|DevCapture)\.swift|Computer/|Voice/)' | nonc
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
  grep -rnE 'requestAuthorization\(\)|LaunchAtLogin\.set\(' Sources | grep -vE '^Sources/Jarvis/(Readiness/|UI/Settings/DailySettingsSection\.swift|App/PackagingLiveTest\.swift)' | nonc
}
v09_none "no hidden persistence and no self-update: Launch at Login is SMAppService only (one file), no LaunchAgent/Daemon/launchctl, nothing in the app builds, installs or replaces the app, and notification / login-item requests come only from Readiness actions and Settings" "$(g15_persistence)"

g15_idle() {
  grep -rnE 'Timer\.|scheduledTimer|asyncAfter|Task\.sleep|makeTimerSource|NSTimer|CADisplayLink' $DY $RD | nonc
  grep -rnE 'readiness\.refresh\(\)|\.refresh\(\)' Sources/Jarvis/Core Sources/Jarvis/UI/CompactHUD | grep -i readiness | nonc
}
v09_none "nothing in Daily/ or Readiness/ runs on a timer or polls: readiness is read on appear, on Recheck and after a user action — never while idle" "$(g15_idle)"

g15_instance() {
  has $RD/SystemIntegration.swift '!arguments.dropFirst().contains { $0.hasPrefix("--") }'
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
