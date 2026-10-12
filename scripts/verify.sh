#!/bin/zsh
# Canonical V0.1 automated verification: unit tests → bundle → plist/permission audit → smoke test → idle resources.
# Prints PASS / FAIL / SKIP lines and exits non-zero on any FAIL. Does NOT replace the user's manual test.
cd "$(dirname "$0")/.."
fails=0
pass() { print "PASS  $1"; }
fail() { print "FAIL  $1"; fails=$((fails+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi }

print "== Unit tests"
out=$(scripts/test.sh 2>&1); echo "$out" | grep -E "Test run with" || true
echo "$out" | grep -q "passed after" && ! echo "$out" | grep -q "✘" && pass "unit tests" || fail "unit tests"

print "== Bundle"
scripts/build_app.sh release >/dev/null 2>&1 && pass "build_app.sh release" || { fail "build_app.sh release"; exit 1; }
APP=build/Jarvis.app
check "Info.plist lints" plutil -lint $APP/Contents/Info.plist
check "LSUIElement = true (menu bar agent)" test "$(plutil -extract LSUIElement raw $APP/Contents/Info.plist)" = "true"
check "CFBundleExecutable exists" test -x "$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw $APP/Contents/Info.plist)"
check "signature valid (strict, deep)" codesign --verify --strict --deep $APP
check "arm64 binary" sh -c "lipo -archs $APP/Contents/MacOS/Jarvis | grep -q arm64"

print "== Permission audit"
# V0.7 (DEC-057): the ONLY allowed privacy key is the microphone usage description (Push-to-Talk). Any other NS*UsageDescription still fails.
other_usage=$(plutil -p $APP/Contents/Info.plist | grep -i "UsageDescription" | grep -v "NSMicrophoneUsageDescription" || true)
[ -z "$other_usage" ] && pass "no NS*UsageDescription keys except the microphone (Push-to-Talk)" || fail "unexpected NS*UsageDescription key: $other_usage"
[ -z "$(codesign -d --entitlements - $APP 2>/dev/null | grep -v -E '^Executable=')" ] && pass "no entitlements" || fail "no entitlements"
# (Exemption, V0.7: AVCaptureDevice may appear in Voice/MicrophoneAccess.swift ONLY — the single place that reads/requests the microphone permission.)
! grep -rEl "AVCaptureDevice|CGRequestScreenCapture|CGPreflightScreenCapture|AXIsProcessTrusted|NSAppleScript|SFSpeechRecognizer|addGlobalMonitorForEvents|CGEventTapCreate|RegisterEventHotKey|IOHIDManager|CNContactStore|CLLocationManager|UNUserNotificationCenter" Sources | grep -v "^Sources/Jarvis/Voice/MicrophoneAccess.swift$" | grep -q . \
  && pass "no permission-gated API usage in sources" || fail "permission-gated API usage found in sources"

# --- V0.3 provider policy (replaces the V0.2 blanket "no provider code" rule; docs/DECISIONS.md DEC-020) ---
# ALLOWED: driving the user's own, unmodified Codex / Claude Code CLIs as child processes.
# STILL FORBIDDEN: any JARVIS network client, paid-API endpoints, API keys, credential/cookie/token access, scraping,
# shells, dangerous CLI flags, silent billing fallback, clipboard monitoring.
forbid() { # name, pattern, [exclude-file-regex]
  local name="$1" pattern="$2" excl="${3:-^$}"
  local hits; hits=$(grep -rIEn "$pattern" Sources | grep -vE "$excl" | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|///)" )
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; echo "$hits" | head -5; fi
}
# V0.9 narrow exemptions (DEC-088…): the audited research layer is the ONLY place that may speak HTTP / run WebKit; denylist/fixture files may CONTAIN the words they detect.
V09_NET='^Sources/Jarvis/App/MemoryLiveTest\.swift|^Sources/Jarvis/Research/(HTTPTransport|RenderedPageProvider|WebClient)\.swift|^Sources/Jarvis/Services/Demo/ResearchFixtures\.swift'
V09_DENY='^Sources/Jarvis/Research/UntrustedContent\.swift|^Sources/Jarvis/Services/Demo/ResearchFixtures\.swift'
V09_URL='^Sources/Jarvis/App/(SmokeTest|ResearchLiveTest)\.swift|^Sources/Jarvis/Research/|^Sources/Jarvis/Services/Demo/Research|^Sources/Jarvis/Tasks/TaskEngine\+Research\.swift|^Sources/Jarvis/Persistence/ResearchRepository\.swift'
V09_WRITE='^Sources/Jarvis/Research/Acquisition/(Downloader|ArchiveInspector)\.swift'

forbid "no unapproved network clients (providers are subprocesses only)" "URLSession|URLRequest|NWConnection|NWPathMonitor|CFNetwork|CFStream|NSURLConnection|WKWebView|WebKit|WebSocket|import Network|Data\\(contentsOf|String\\(contentsOf|contentsOf: *URL\\(string" "$V09_NET"
forbid "no paid-API endpoints or web-subscription scraping" "api\\.openai\\.com|api\\.anthropic\\.com|chatgpt\\.com|claude\\.ai/(api|chat)|console\\.anthropic|platform\\.openai|backend-api|openai\\.com/v1|anthropic\\.com/v1"
forbid "no credential / token / cookie access" "auth\\.json|\\.credentials|SecItemCopyMatching|SecKeychain|binarycookies|HTTPCookieStorage|--with-api-key|--with-access-token|apiKeyHelper"
forbid "API-key / token variable names appear ONLY in the scrub list" "ANTHROPIC_API_KEY|OPENAI_API_KEY|CODEX_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_BASE_URL|OPENAI_BASE_URL|OPENAI_ORG|AWS_BEARER_TOKEN|ANTHROPIC_BEDROCK|ANTHROPIC_VERTEX|CLAUDE_CODE_USE_(BEDROCK|VERTEX)|OPENCODE_API_KEY|OPENCODE_SERVER_PASSWORD|OPENROUTER_API_KEY|GROQ_API_KEY|MISTRAL_API_KEY|GEMINI_API_KEY|XAI_API_KEY|DEEPSEEK_API_KEY|HF_TOKEN|HUGGING_FACE_HUB_TOKEN" "^Sources/Jarvis/Providers/ProviderEnvironment\\.swift"
forbid "no dangerous provider flags or API-key-only modes" "\"--bare\"|dangerously|danger-full-access|bypassPermissions|--full-auto|--approve-for-me|\"--enable\"|workspace-write|--yolo|--allowedTools|--allow-dangerously|--add-dir|--mcp-config|\"--api-key|--with-api-key|\"--auto\"|\"--attach\"|\"--share\"|\"--password\"|\"--mdns\"|\"serve\"|\"web\""
forbid "Process is created ONLY by ManagedProcess (one audited launch point)" "(^|[^[:alnum:]_.])Process\\(\\)|NSTask|posix_spawn|Foundation\\.Process" "^Sources/Jarvis/Providers/ManagedProcess\\.swift"
# (TaskPlan.swift holds the plan validator's DENY-list of prohibited phrases — words it rejects, not code that uses them.)
forbid "no generic launchers / downloaders / UI scripting" "/usr/bin/env|\"env\"|curl|wget|osascript|NSWorkspace\\.shared\\.(launchApplication|open\\(.*URL\\(string)" "^Sources/Jarvis/App/(SmokeTest|DevCapture)\\.swift|^Sources/Jarvis/Tasks/TaskPlan\\.swift|^Sources/Jarvis/Unity/UnityProtocol\\.swift|$V09_DENY"
forbid "no shell is ever used to run a provider" "/bin/(ba|z)?sh|launchPath|\"sh\", *\"-c\"|popen\\(|[^.[:alnum:]_]system\\(" "$V09_DENY"
forbid "OpenCode credential/integration API operations are never invoked (only the fixed model.list)" "credential\\.(list|get|remove|create|update)|integration\\.(list|get|connect)|connect/(key|external|oauth|command)"
forbid "no URL literals in product code (JARVIS contacts no host itself; providers do their own networking)" "\"https?://|URL\\(string:" "$V09_URL"
forbid "the product never reads the pasteboard (only native paste; the dev smoke test is excluded)" "NSPasteboard|generalPasteboard" "App/SmokeTest\\.swift"

# --- V0.3.1: persistence, models and secrets must never be committed; the local worker must stay offline ---
tracked_bad=$(git ls-files 2>/dev/null | grep -E '\.(sqlite|sqlite3|sqlite-wal|sqlite-shm|db|safetensors|gguf|mlx|npz|pt|pth|onnx|wav|caf|aiff|aif|m4a|mp3|flac|ogg|opus)$' || true)
[ -z "$tracked_bad" ] && pass "no runtime database or model file is tracked by git" || { fail "runtime database / model file tracked: $tracked_bad"; }
big=$(git ls-files 2>/dev/null | while read -r f; do [ -f "$f" ] && [ "$(stat -f%z "$f")" -gt 5242880 ] && echo "$f"; done)
[ -z "$big" ] && pass "no tracked file larger than 5 MB" || fail "large tracked files: $big"
# Narrow exemption: the V0.7 voice live test logs two SYNTHETIC secret-shaped strings on purpose (to prove they are redacted); only those fixtures may appear there.
secrets=$(git ls-files 2>/dev/null | grep -vE '^Tests/' | xargs grep -IEn "sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----" 2>/dev/null | grep -vE '^Sources/Jarvis/App/VoiceLiveTest\.swift:[0-9]+:.*(LIVEVOICE0123456789abcdefghij|ghp_abcdefghijklmnopqr'""'stuvwxyz0123456789)' | head -3)
[ -z "$secrets" ] && pass "no secrets in tracked files (excluding test fixtures)" || { fail "possible secret in tracked files"; echo "$secrets" | cut -c1-120; }
if grep -nE "^[[:space:]]*(import|from)[[:space:]]+(requests|urllib|socket|http|httpx|aiohttp|huggingface_hub|websocket)" scripts/local-ai/*.py >/dev/null 2>&1; then fail "local worker imports a network library"; else pass "local worker imports no network library"; fi
grep -q 'HF_HUB_OFFLINE' scripts/local-ai/jarvis_local_worker.py && pass "local worker forces offline mode" || fail "local worker does not force offline mode"
swift_db=$(grep -rln "sqlite3_open" Sources | grep -v Persistence/SQLiteDatabase.swift || true)
[ -z "$swift_db" ] && pass "raw SQLite access is confined to Persistence/SQLiteDatabase.swift" || fail "raw sqlite3 use outside the persistence engine: $swift_db"

# --- V0.3.2 Agent Observatory: raw provider output may only enter observable/durable state through the sanitization boundary ---
forbid "no pseudo-terminal / embedded shell (Agent Console is read-only JARVIS-managed output)" "forkpty|openpty|posix_openpt|/dev/ptmx|NSTask|\\bsudo\\b" "^Sources/Jarvis/Tasks/TaskPlan\\.swift|^Sources/Jarvis/Proactive/OpportunityAssessor\\.swift|$V09_DENY"
forbid "console text enters the hub only via SafeProvider / SafeToolOutput (or the labelled developer simulation)" "\\.appendOutput\\(" "^Sources/Jarvis/Observability/(SafeProvider|SafeToolOutput|ObservatoryDemo|ExecutionHub)\\.swift"
forbid "console events are persisted only by the hub / audit recorder (events are sanitized by construction)" "\\.appendEvents\\(" "^Sources/Jarvis/(Observability/ExecutionHub|Intelligence/AuditRecorder|Persistence/JarvisRepository)\\.swift"
forbid "console output artifacts are written only by the hub" "folder: *\\.providerOutput" "^Sources/Jarvis/Observability/ExecutionHub\\.swift"
forbid "no raw INSERT into agent_events outside the repository" "INSERT[^;]*agent_events" "^Sources/Jarvis/Persistence/(JarvisRepository|Migrations)\\.swift"
grep -q "SafeProvider(base:" Sources/Jarvis/Intelligence/IntelligenceCoordinator.swift && pass "every engine built by the coordinator is wrapped in SafeProvider" || fail "coordinator does not wrap providers in SafeProvider"
tracked_logs=$(git ls-files 2>/dev/null | grep -E '\.(log|ndjson)$|(^|/)console[^/]*\.(txt|json)$' || true)
[ -z "$tracked_logs" ] && pass "no console/log dumps are tracked by git" || fail "tracked log/console dumps: $tracked_logs"


# --- V0.4 Autonomous task engine: bounded, user-initiated, no unrestricted write/shell/Git power ---
forbid "no destructive/remote Git operations anywhere in the product (reset --hard, clean, force push, push, checkout -f, rebase, filter-branch)" "reset +--hard|git +clean|clean +-f|push +--force|push +-f|checkout +-f|filter-branch|\"push\"|\"rebase\"|git +push|git +commit" "^Sources/Jarvis/Tasks/TaskPlan\\.swift|^Sources/Jarvis/Proactive/OpportunityAssessor\\.swift"
git_mut=$(grep -nE '"(commit|push|reset|clean|checkout|add|rm|stash|merge|rebase|pull|fetch|clone|config|tag|branch)"' Sources/Jarvis/Tasks/GitTool.swift | grep -v '^\s*//' || true)
[ -z "$git_mut" ] && pass "GitTool is read-only (status/branch/HEAD only)" || { fail "GitTool contains a mutating Git subcommand"; echo "$git_mut" | head -3; }
shells=$(grep -nE 'static let names: Set<String> = .*"(sh|bash|zsh|dash|ksh|env|curl|wget|git|rm|osascript|perl|ruby|ssh|sudo)"' Sources/Jarvis/Tasks/CommandProfiles.swift || true)
[ -z "$shells" ] && pass "build/test executables are an explicit allowlist with no shell, env, downloader or Git" || fail "unapproved executable on the build/test allowlist"
task_writes=$(grep -rnE '\.write\(to:|\.write\(contentsOf|createFile\(|removeItem\(|moveItem\(|copyItem\(|setAttributes\(|\.replaceItem' Sources/Jarvis/Tasks | grep -v 'Sources/Jarvis/Tasks/ProjectTools.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$task_writes" ] && pass "task engine writes project files only through ProjectTools (capability + workspace + lease checked)" || { fail "file write outside ProjectTools in Tasks/"; echo "$task_writes" | head -3; }
bad_caps=$(grep -rnE 'granted:.*\.(gitPush|gitCommit|purchase|useNetwork|useBrowser)|TaskCapability\.allCases\)' Sources | grep -v 'Sources/Jarvis/Tasks/TaskModel.swift' || true)
[ -z "$bad_caps" ] && pass "no code path grants gitPush / gitCommit / purchase / network / browser capabilities" || { fail "forbidden capability granted"; echo "$bad_caps" | head -3; }
[ "$(grep -c 'neverGranted' Sources/Jarvis/Tasks/TaskModel.swift)" -ge 2 ] && pass "CapabilitySet strips never-grantable capabilities" || fail "CapabilitySet no longer strips never-grantable capabilities"
ui_db=$(grep -rnE 'app\.repository|\.repository\??\.(update|insert|setTaskStatus|insertSteps|insertLease|releaseLeases)' Sources/Jarvis/UI | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$ui_db" ] && pass "the UI never writes the task database (task/step/approval state changes only through TaskEngine)" || { fail "UI touches the repository"; echo "$ui_db" | head -3; }
tracked_fix=$(git ls-files 2>/dev/null | grep -E 'jarvis-task-(demo|fixture)|(^|/)\.jarvis/|task-(checkpoint|report)' || true)
[ -z "$tracked_fix" ] && pass "no task fixture, checkpoint or report output is tracked by git" || fail "tracked task output: $tracked_fix"


# --- V0.5 Proactive reasoning: a DECISION layer above the task engine — it never executes, never approves itself, never polls ---
# (OpportunityAssessor.swift holds DETECTION keywords such as "git push"/"purchase": words that make the policy stricter, not actions.)
pro_writes=$(grep -rnE '\.write\(to:|\.write\(contentsOf|createFile\(|removeItem\(|moveItem\(|copyItem\(|setAttributes\(|Process\(\)|ManagedProcess|CommandRunner|\.apply\(|\.delete\(' Sources/Jarvis/Proactive | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$pro_writes" ] && pass "the proactive layer never edits files, deletes, applies edits or launches processes (only the V0.4 TaskEngine executes)" || { fail "proactive layer executes something"; echo "$pro_writes" | head -3; }
pro_tools=$(grep -rn 'ProjectTools(' Sources/Jarvis/Proactive | grep -v 'capabilities: .readOnly' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$pro_tools" ] && pass "the proactive layer only reads the project (ProjectTools with readOnly capabilities)" || { fail "proactive layer uses a writing ProjectTools"; echo "$pro_tools" | head -3; }
pro_poll=$(grep -rnE 'Task\.sleep|Timer\.|asyncAfter|scheduledTimer|DispatchSource' Sources/Jarvis/Proactive | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$pro_poll" ] && pass "proactive reasoning is event-driven (no timers, no polling, no sleeping)" || { fail "polling/timer in the proactive layer"; echo "$pro_poll" | head -3; }
pro_decide=$(grep -rnE 'status = \.approved|state = \.approved|\.approve\(' Sources/Jarvis/Proactive Sources/Jarvis/Persistence/OpportunityRepository.swift | grep -v 'Proactive/ProposalService.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$pro_decide" ] && pass "only ProposalService records proposal decisions (no model/provider text can approve)" || { fail "approval state written outside ProposalService"; echo "$pro_decide" | head -3; }
pro_callers=$(grep -rn 'proposalService\.approve(' Sources | grep -v 'Sources/Jarvis/UI/' || true)
[ -z "$pro_callers" ] && pass "proposals are approved only from the HUD buttons" || { fail "proposal approval called outside the UI"; echo "$pro_callers" | head -3; }
pro_submit=$(grep -rn 'tasks\.submit(\|taskEngine\.submit(\|engine\.submit(' Sources/Jarvis/Proactive | grep -v 'Proactive/OpportunityEngine.swift' || true)
[ -z "$pro_submit" ] && pass "automatic and approved actions become tasks only through OpportunityEngine → TaskEngine.submit" || { fail "task creation bypasses OpportunityEngine"; echo "$pro_submit" | head -3; }
[ "$(grep -c 'neverGranted' Sources/Jarvis/Proactive/OpportunityPolicy.swift)" -ge 1 ] && pass "the policy treats never-grantable capabilities as critical" || fail "policy no longer references neverGranted capabilities"
pro_ext=$(grep -rnE 'StoreKit|SecItem|paidAPI|URLSession|openai\.com|anthropic\.com' Sources/Jarvis/Proactive | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$pro_ext" ] && pass "no paid-API / purchase / credential execution code in the proactive layer" || { fail "external-effect code in the proactive layer"; echo "$pro_ext" | head -3; }

# --- V0.6 Unity Project Agent: typed operations only, no code/menu/shell execution, no second engine, no raw Unity output at rest ---
# (UnityProtocol.swift and TaskPlan.swift hold DENY-lists of words a provider may not use — detection keywords, not actions.)
unity_files() { find Sources/Jarvis/Unity -name '*.swift' ! -name '*.generated.swift'; }
uni_exec=$(unity_files | xargs grep -nE 'Process\(\)|NSTask|posix_spawn|/bin/(ba|z)?sh|osascript|-executeMethod|-runTests|ExecuteMenuItem' | grep -v 'Unity/UnityProtocol.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$uni_exec" ] && pass "the Unity layer has no process/shell/scripting/menu execution (editor launch = ManagedProcess with a fixed argument list)" || { fail "Unity layer executes something"; echo "$uni_exec" | head -3; }
uni_mp=$(grep -rln 'ManagedProcess(' Sources/Jarvis/Unity | grep -v 'Unity/UnityLauncher.swift' || true)
[ -z "$uni_mp" ] && pass "only UnityLauncher starts a process, with a fixed argument list (no model-supplied argument, no -executeMethod)" || { fail "process started outside UnityLauncher: $uni_mp"; }
grep -q '"-batchmode", "-nographics", "-projectPath", projectRoot' Sources/Jarvis/Unity/UnityLauncher.swift && ! grep -vE '^[[:space:]]*//' Sources/Jarvis/Unity/UnityLauncher.swift | grep -q 'executeMethod' && pass "the editor launch arguments are the fixed list" || fail "editor launch arguments changed"
uni_net=$(unity_files | xargs grep -nE 'URLSession|URLRequest|NWConnection|WebSocket|CFNetwork|Data\(contentsOf|SecItem|StoreKit|git (push|commit)' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$uni_net" ] && pass "the Unity layer has no network, credential, purchase or Git code" || { fail "network/credential/Git code in the Unity layer"; echo "$uni_net" | head -3; }
uni_w=$(unity_files | xargs grep -lE '\.write\(to:|\.write\(contentsOf|createFile\(|removeItem\(|moveItem\(|copyItem\(|createDirectory\(' | grep -vE 'Unity/(UnityTransport|UnityBridgeInstaller)\.swift' || true)
[ -z "$uni_w" ] && pass "file writes in the Unity layer are confined to the request spool and the bridge package installer" || { fail "Unity file write outside spool/installer: $uni_w"; }
! grep -q 'manifest.json' Sources/Jarvis/Unity/UnityBridgeInstaller.swift && pass "the bridge installer never edits the project's package manifest (no package installation capability)" || fail "installer touches manifest.json"
uni_ops=$(grep -rnE 'transport\.send\(|\.perform\(.*session' Sources | grep -vE 'Sources/Jarvis/Unity/|Sources/Jarvis/Tasks/TaskEngine\+Unity\.swift|Sources/Jarvis/App/UnityLiveTest\.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$uni_ops" ] && pass "editor operations are sent only by the Unity layer, the Unity task steps and the live test (providers and the UI never talk to the editor)" || { fail "editor operation sent from elsewhere"; echo "$uni_ops" | head -3; }
uni_ui=$(grep -rnE 'UnityOperation|UnityToolSession|\.perform\(' Sources/Jarvis/UI Sources/Jarvis/Proactive | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$uni_ui" ] && pass "neither the UI nor the proactive decision layer can operate the Unity editor" || { fail "UI/proactive layer references Unity operations"; echo "$uni_ui" | head -3; }
uni_enum=$(awk '/enum UnityOperation: Equatable, Sendable \{/,/var wireName/' Sources/Jarvis/Unity/UnityProtocol.swift | grep -iE 'case (code|script|menu|command|shell|eval|execute|csharp|invoke|method)' || true)
[ -z "$uni_enum" ] && pass "UnityOperation has no case that carries code, a menu item, a command or a script" || { fail "UnityOperation carries free-form execution"; echo "$uni_enum"; }
cs_bad=$(find UnityBridge/com.jarvis.bridge -name '*.cs' | xargs grep -nE 'ExecuteMenuItem|Process\.Start|ProcessStartInfo|UnityWebRequest|HttpClient|TcpListener|Socket\(|Assembly\.Load|CSharpCodeProvider|Roslyn|MethodInfo\.Invoke|System\.Net' || true)
[ -z "$cs_bad" ] && pass "the Editor bridge has no menu execution, process start, network, assembly loading or reflection invoke" || { fail "Editor bridge contains forbidden API"; echo "$cs_bad" | head -3; }
grep -q 'unknownOperation' UnityBridge/com.jarvis.bridge/Editor/JarvisBridge.cs && grep -q 'playModeMutationBlocked' UnityBridge/com.jarvis.bridge/Editor/JarvisBridge.cs && pass "the bridge rejects unknown operations and persistent mutations during Play Mode on its own" || fail "bridge safety checks missing"
grep -q 'editorStateDenial' Sources/Jarvis/Unity/UnityPolicy.swift && grep -q 'isPersistentMutation' Sources/Jarvis/Unity/UnityPolicy.swift && pass "policy blocks persistent mutation during Play Mode / compilation" || fail "Play Mode mutation policy missing"
grep -q 'needsUpgradeApproval' Sources/Jarvis/Unity/UnityService.swift && grep -q 'approvedUpgrade' Sources/Jarvis/Unity/UnityService.swift && pass "opening a project with a different Unity version requires an explicit approval (no silent upgrade)" || fail "project upgrade guard missing"
grep -q 'UnityResponseSanitizer.sanitize' Sources/Jarvis/Unity/UnityService.swift && pass "every editor answer passes the sanitizer before any other code sees it" || fail "editor answers are not sanitized"
uni_raw=$(grep -rnE 'result\["(message|stack)"\]' Sources | grep -vE 'Sources/Jarvis/Unity/UnityModels.swift' || true)
[ -z "$uni_raw" ] && pass "raw Console message/stack fields are read only by the sanitizing UnityConsoleEntry initializer" || { fail "raw Unity console text read elsewhere"; echo "$uni_raw" | head -3; }
tracked_unity=$(git ls-files 2>/dev/null | grep -E '(^|/)(Library|Temp|Logs|Obj|Build|Builds|UserSettings)/|\.(csproj|sln)$|\.unitypackage$' || true)
[ -z "$tracked_unity" ] && pass "no generated Unity directory, solution file or package archive is tracked" || fail "tracked Unity output: $(echo $tracked_unity | head -c 200)"

# --- V0.7 Voice I/O: an input/output layer around the SAME conversation pipeline — no authority, no always-on microphone, no stored audio ---
# (Exemptions: App/SmokeTest.swift calls pushToTalkPressed() ON PURPOSE to prove an automated run never opens the microphone; App/VoiceLiveTest.swift
#  opens the real microphone only with the explicit --voice-real-mic flag, to prove capture plumbing, and replays fixture audio through the coordinator.)
voice_src() { find Sources/Jarvis/Voice -name '*.swift'; }
voi_auth=$(voice_src | xargs grep -nE 'decideApproval|\.decide\(|approve|ProposalService|EngineTaskControlling|TaskEngine|ApprovedExecutables|ProjectTools|ConversationService|appendUser|appendJarvis|JarvisRepository' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_auth" ] && pass "the voice layer cannot approve, edit, run or route anything itself (no approval/task/file/repository/conversation access)" || { fail "voice layer reaches an authority"; echo "$voi_auth" | head -3; }
voi_entry=$(grep -rn 'source: \.voice' Sources | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | cut -d: -f1 | sort -u | grep -v 'Sources/Jarvis/App/AppContext.swift' | grep -v 'Sources/Jarvis/Services/Conversation/ConversationService.swift' | grep -v 'Sources/Jarvis/Core/ConversationStore.swift' | grep -v 'Sources/Jarvis/Tasks/GoalIntake.swift' | grep -v 'Sources/Jarvis/App/DevCapture.swift' | grep -v 'Sources/Jarvis/App/VoiceLiveTest.swift' | grep -v 'Sources/Jarvis/App/ResearchLiveTest.swift' | grep -v 'Sources/Jarvis/App/MemoryLiveTest.swift' || true)
[ -z "$voi_entry" ] && pass "a spoken transcript enters the conversation only through ConversationService.submit (the typed path) wired in AppContext" || { fail "voice input path outside AppContext/ConversationService: $voi_entry"; }
# (V0.8: JARVIS' own playback engine, Voice/SpeechPlayer.swift, is OUTPUT only: it may create an AVAudioEngine and meter its mixer, but never touch an input node.)
voi_mic=$(grep -rnE 'AVAudioInputNode|inputNode' Sources | grep -v 'Sources/Jarvis/Voice/AudioInput.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
voi_eng=$(grep -rnE 'AVAudioEngine\(|installTap' Sources | grep -vE 'Sources/Jarvis/Voice/(AudioInput|SpeechPlayer)\.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_mic" ] && [ -z "$voi_eng" ] && pass "microphone capture exists in exactly one file (Voice/AudioInput.swift); the only other audio engine is the output-only SpeechPlayer" || { fail "audio capture/engine outside AudioInput.swift/SpeechPlayer.swift"; echo "$voi_mic$voi_eng" | head -3; }
voi_perm=$(grep -rnE 'AVCaptureDevice|requestAccess' Sources | grep -v 'Sources/Jarvis/Voice/MicrophoneAccess.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_perm" ] && pass "the microphone permission is read/requested in exactly one file (Voice/MicrophoneAccess.swift)" || { fail "permission API outside MicrophoneAccess.swift"; echo "$voi_perm" | head -3; }
# (V0.8 exemptions: Voice/Natural/AudioHub.swift is the ONE microphone hub (engine only while a subscriber exists); App/AppContext.swift names MicrophoneInput as the hub's
#  source; App/NaturalVoiceLiveTest.swift presses PTT on purpose and, with --natural-acoustic, opens the real microphone for a level-only measurement.)
voi_launch=$(grep -rnE 'MicrophoneInput\(|pushToTalkPressed\(\)|\.start\(onFrame' Sources | grep -vE 'Sources/Jarvis/Voice/(VoiceCoordinator|AudioInput)\.swift|Sources/Jarvis/Voice/Natural/AudioHub\.swift|Sources/Jarvis/App/(AppDelegate|AppContext|SmokeTest|VoiceLiveTest|NaturalVoiceLiveTest)\.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_launch" ] && pass "the microphone starts only from the Push-to-Talk handler or the opt-in wake subscription (never at launch, from a timer, or from the UI)" || { fail "microphone start outside the PTT/wake path"; echo "$voi_launch" | head -3; }
# (Exemption: App/NaturalVoiceLiveTest.swift can write its OWN synthetic fixtures as WAVs, only when JARVIS_DUMP_FIXTURES is set, for the Python wake benchmark — never microphone audio.)
voi_audio=$(grep -rnE 'forWriting|AVAudioRecorder|AVAssetWriter|\.(wav|caf|aiff|m4a)\"|writeFrames|ExtAudioFileCreate' Sources | grep -v 'Sources/Jarvis/App/NaturalVoiceLiveTest.swift' | grep -vE "$V09_WRITE" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_audio" ] && pass "no code can write an audio file (raw microphone audio is never persisted)" || { fail "audio file writing code"; echo "$voi_audio" | head -3; }
voi_db=$(grep -nEi 'pcm|wav|audio_|waveform|partial_transcript|transcript_history|recording' Sources/Jarvis/Persistence/Migrations.swift | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_db" ] && pass "the database schema has no audio, waveform, recording or partial-transcript storage" || { fail "audio-like storage in the schema"; echo "$voi_db" | head -3; }
voi_paid=$(grep -rnEi 'speech\.googleapis\.com|texttospeech\.googleapis|deepgram|assemblyai|elevenlabs|polly\.[a-z0-9-]+\.amazonaws|cognitiveservices|openai.*(whisper-1|audio/(speech|transcriptions))|api\.speechmatics|rev\.ai|(ELEVENLABS|DEEPGRAM|ASSEMBLYAI|AZURE_SPEECH)[A-Z_]*' Sources scripts/voice-ai scripts/setup_voice_ai.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|#)' || true)
[ -z "$voi_paid" ] && pass "no paid or cloud speech API, endpoint or key variable exists (default voice path is local/system)" || { fail "paid/cloud speech reference"; echo "$voi_paid" | head -3; }
voi_py=$(grep -nE '^[[:space:]]*(import|from)[[:space:]]+(requests|urllib|socket|http|httpx|aiohttp|websocket|subprocess|tempfile|soundfile|wave|pyaudio|sounddevice)' scripts/voice-ai/*.py || true)
[ -z "$voi_py" ] && grep -q 'HF_HUB_OFFLINE' scripts/voice-ai/jarvis_stt_worker.py && pass "the speech helper imports no network/process/audio-file library and forces offline mode" || { fail "speech helper imports a forbidden library or is not offline"; echo "$voi_py" | head -3; }
grep -q 'TranscriptText.clean' Sources/Jarvis/Voice/WhisperRuntime.swift && grep -q 'TranscriptText.clean' Sources/Jarvis/Voice/AppleSpeechSTT.swift && pass "recogniser/helper text passes the sanitizer before any other code sees it" || fail "recogniser output is not sanitized"
grep -q 'maximumAudioSeconds' Sources/Jarvis/Voice/VoiceCoordinator.swift && grep -q 'bufferingNewest' Sources/Jarvis/Voice/VoiceCoordinator.swift && grep -q 'MAX_SECONDS' scripts/voice-ai/jarvis_stt_worker.py && pass "audio buffers are bounded (60 s hold limit, bounded frame queue, bounded helper buffer)" || fail "an audio buffer is no longer bounded"
voi_poll=$(voice_src | xargs grep -nE 'Timer\.|scheduledTimer|CADisplayLink|DispatchSource' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_poll" ] && pass "the voice layer has no timers or polling (event-driven; idle voice costs nothing)" || { fail "timer/polling in the voice layer"; echo "$voi_poll" | head -3; }
voi_net=$(voice_src | xargs grep -nE 'URLSession|URLRequest|Data\(contentsOf|NWConnection|WebSocket|Process\(\)|NSTask|/bin/(ba|z)?sh|osascript|curl|wget' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_net" ] && pass "the voice layer has no network, shell or scripting code" || { fail "network/shell code in the voice layer"; echo "$voi_net" | head -3; }
[ "$(grep -c 'NSMicrophoneUsageDescription' Resources/Info.plist)" = "1" ] && pass "Info.plist declares exactly the microphone usage description" || fail "Info.plist microphone description missing or duplicated"
tracked_voice=$(git ls-files 2>/dev/null | grep -E '(^|/)(voice-venv|natural-venv|whisper[^/]*|piper[^/]*|supertonic[^/]*|wake)/|\.(wav|caf|aiff|aif|m4a|mp3|flac|ogg|opus|pcm|npz|onnx|safetensors|gguf)$' || true)
[ -z "$tracked_voice" ] && pass "no audio file, voice model or voice runtime is tracked by git" || fail "tracked voice artefact: $tracked_voice"

# --- V0.8 Natural voice: opt-in wake word, local VAD, turn manager, barge-in, neural voice — still an I/O layer with no authority ---
# (Exemptions are the same narrow, documented ones as V0.7 plus: Voice/SpeechPlayer.swift = output-only AVAudioEngine; Voice/Natural/AudioHub.swift = the single microphone hub;
#  App/NaturalVoiceLiveTest.swift + Services/Demo/VoiceTestRig.swift = the opt-in closed-loop test with a scripted microphone and a simulated speaker.)
nat_src() { find Sources/Jarvis/Voice -name '*.swift'; }
nat_auth=$(nat_src | xargs grep -nE 'GoalIntake|TaskIntake|OpportunityEngine|taskSubmitter|submitTask|UserDefaults|SecItem|kSecClass|Keychain|NSPasteboard' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$nat_auth" ] && pass "wake word, VAD, turn manager and barge-in have no path to task creation, proposals, approvals, preferences, credentials or the clipboard" || { fail "natural-voice code reaches an authority"; echo "$nat_auth" | head -3; }
grep -q 'Key.wakeEnabled) as? Bool ?? false' Sources/Jarvis/Core/Preferences.swift && pass "wake mode is OPT-IN: its stored default is OFF" || fail "wake mode default is no longer OFF"
nat_enable=$(grep -rnE 'handsFree\.enable\(\)|hf\.enable\(\)' Sources | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$nat_enable" ] && grep -q 'handsFree.applySettings()' Sources/Jarvis/App/AppContext.swift && pass "wake listening starts only through applySettings() (saved preference + permission + installed helper), never unconditionally" || { fail "wake mode can be enabled directly"; echo "$nat_enable" | head -3; }
nat_hub=$(grep -rnE 'microphoneHub\.subscribe\(|hub\.subscribe\(' Sources | grep -vE 'Sources/Jarvis/Voice/Natural/(AudioHub|HandsFreeCoordinator)\.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$nat_hub" ] && pass "microphone frames reach consumers only through the ONE hub (wake subscription + Push-to-Talk adapter)" || { fail "hub subscription outside the allowed files"; echo "$nat_hub" | head -3; }
nat_py=$(grep -nE '^[[:space:]]*(import|from)[[:space:]]+(requests|urllib|socket|http|httpx|aiohttp|websocket|subprocess|tempfile|soundfile|wave|pyaudio|sounddevice|openwakeword)|os\.system|eval\(|exec\(|snapshot_download|hf_hub_download|urlretrieve|open\(|np\.save|savez' scripts/voice-ai/jarvis_sentinel_worker.py scripts/voice-ai/jarvis_tts_worker.py scripts/voice-ai/jarvis_wake_head.py scripts/voice-ai/jarvis_audio_features.py || true)
[ -z "$nat_py" ] && grep -q 'auto_download=False' scripts/voice-ai/jarvis_tts_worker.py && grep -q 'HF_HUB_OFFLINE' scripts/voice-ai/jarvis_tts_worker.py && grep -q 'HF_HUB_OFFLINE' scripts/voice-ai/jarvis_sentinel_worker.py && pass "the wake/VAD and neural-voice helpers have no network, process, download, file-writing or dynamic-code API and force offline mode (the neural helper cannot download)" || { fail "a natural-voice helper imports/uses a forbidden API"; echo "$nat_py" | head -3; }
nat_cloud=$(grep -rniE 'porcupine|picovoice|snowboy|elevenlabs|play\.ht|fish\.audio|fishaudio|resemble\.ai/api|polly\.|speech\.googleapis|texttospeech\.googleapis|deepgram|assemblyai|ACCESS_KEY|api_key|apiKey|ref_audio|speaker_wav|audio_prompt|reference_audio|voice_clone|cloneVoice' Sources/Jarvis/Voice scripts/voice-ai/*.py scripts/setup_voice_ai.sh scripts/train_wake_head.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|#)' || true)
[ -z "$nat_cloud" ] && pass "no cloud wake word, paid or cloud speech service, API-key requirement or reference-voice cloning input exists in the voice code or its setup" || { fail "cloud/paid/cloning reference in the voice code"; echo "$nat_cloud" | head -3; }
nat_dl=$(grep -rnE 'snapshot_download|hf_hub_download|huggingface\.co|github\.com/dscripka|curl ' Sources/Jarvis | grep -vE "Sources/Jarvis/Tasks/TaskPlan\.swift|$V09_DENY" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$nat_dl" ] && pass "JARVIS itself never downloads a model (only the explicit setup scripts do, with pinned revisions/checksums)" || { fail "model download code in the app"; echo "$nat_dl" | head -3; }
nat_buf=$(grep -c 'AudioRing(maxSeconds: 3.0)' Sources/Jarvis/Voice/Natural/HandsFreeCoordinator.swift)
[ "$nat_buf" = "1" ] && grep -q 'bufferingNewest(120)' Sources/Jarvis/Voice/Natural/HandsFreeCoordinator.swift && grep -q 'messageSamples = 1600' Sources/Jarvis/Voice/Natural/SentinelRuntime.swift && grep -q 'maxQueued = 12' Sources/Jarvis/Voice/VoiceResponseSpeaker.swift && grep -q 'MAX_LINE' scripts/voice-ai/jarvis_sentinel_worker.py && pass "the wake ring (≤ 3 s), the frame queue, the sentinel queue and the speech queue are bounded" || fail "a natural-voice buffer is no longer bounded"
nat_poll=$(find Sources/Jarvis/Voice/Natural -name '*.swift' | xargs grep -nE 'Timer\.|scheduledTimer|CADisplayLink|DispatchSource|while true|repeat \{' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$nat_poll" ] && pass "no busy polling or periodic timer in the natural-voice layer (single-shot waits only; the energy gate keeps an idle room at zero work)" || { fail "polling in the natural-voice layer"; echo "$nat_poll" | head -3; }
nat_san=$(grep -nE 'as\? String' Sources/Jarvis/Voice/Natural/SentinelRuntime.swift Sources/Jarvis/Voice/Natural/NeuralVoice.swift | grep -vE '"type"|"id"|"pcm"' | grep -vE '^[^:]+:[0-9]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$nat_san" ] && pass "helper output is read only as protocol keys, numbers, flags and audio (no helper text reaches the UI, storage or a prompt)" || { fail "free helper text is read"; echo "$nat_san" | head -3; }
nat_ws=$(grep -rnE 'ProcessRegistry|ManagedProcess\(' Sources/Jarvis/Voice/Natural | grep -v 'HelperHost.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$nat_ws" ] && grep -q 'ManagedProcess(executable: config.executable' Sources/Jarvis/Voice/Natural/HelperHost.swift && pass "every voice helper is supervised by HelperHost → ManagedProcess (the audited launch point; killed with its tree at quit)" || { fail "a helper process is started outside HelperHost"; echo "$nat_ws" | head -3; }
grep -q 'handsFree.shutdown(); voice.shutdown()' Sources/Jarvis/App/AppContext.swift && pass "application termination shuts the hands-free layer and every voice helper down" || fail "termination no longer shuts wake mode down"
grep -q 'original character' Sources/Jarvis/Voice/Natural/VoiceIdentity.swift && ! grep -rqiE 'bettany|paul[ _-]?bettany|tony stark|iron man' Sources scripts --exclude=verify.sh && pass "the JARVIS voice identity is declared original (no actor, performer or character voice is referenced or cloned)" || fail "voice identity wording or a forbidden reference changed"


# --- V0.9 Web research & asset acquisition: separate authority levels, untrusted web content, a quarantine, no account/payment power (DEC-088…) ---
# (Exemptions are narrow and named above: V09_NET = the only files that may speak HTTP / run WebKit; V09_DENY = denylist/fixture text; V09_URL = the audited research layer;
#  V09_WRITE = the two files that write a download / an extraction into the QUARANTINE.)
RS=Sources/Jarvis/Research
v09_none() { # name, grep-output (empty = pass)
  if [ -z "$2" ]; then pass "$1"; else fail "$1"; echo "$2" | head -4; fi
}
nonc() { grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; }
# 1. Network primitives live in exactly two audited files; nothing else in the product can open a connection or a web view.
v09_none "URLSession / WebKit / sockets exist ONLY in Research/HTTPTransport + Research/RenderedPageProvider (+ the test fixture server)" "$(grep -rnE 'URLSession\(|URLSessionConfiguration|WKWebView\(|import WebKit|WKWebsiteDataStore|socket\(AF_|NWConnection|NWListener|CFSocket' Sources | grep -vE "^Sources/Jarvis/Research/(HTTPTransport|RenderedPageProvider)\.swift|^Sources/Jarvis/Services/Demo/ResearchFixtures\.swift|Sources/Jarvis/Voice|Sources/Jarvis/Providers" | nonc)"
v09_none "the web view uses a NON-persistent profile and evaluates ONLY its fixed extraction script (no page/model-provided JavaScript)" "$( (grep -rnE 'evaluateJavaScript\(|callAsyncJavaScript\(|loadHTMLString|WKUserScript|addScriptMessageHandler' Sources | grep -v "^$RS/RenderedPageProvider.swift" | nonc; grep -n 'evaluateJavaScript(' $RS/RenderedPageProvider.swift | grep -v 'Self.extractionScript' | nonc; grep -L 'nonPersistent()' $RS/RenderedPageProvider.swift) 2>/dev/null)"
# 2. Research and acquisition are tasks: nothing in the research layer creates tasks, decides approvals or proposals (only the screen's view model may call the engine).
v09_none "the research layer never creates a task or an approval by itself (TaskEngine/approvals are touched only by the view model and the engine extension)" "$(grep -rnE 'TaskEngine|\.submit\(|submitResearch|submitAcquisition|submitImport|decide\(|ApprovalRecord|setEngineApproval|ProposalService|\.approve\(' $RS | grep -v "^$RS/ResearchViewModel.swift" | nonc)"
v09_none "voice / hands-free code has no research path of its own (spoken research is the SAME ConversationService.submit)" "$(grep -rnE 'ResearchIntake|submitResearch|ResearchPipeline|WebClient|ResearchServices' Sources/Jarvis/Voice | nonc)"
# 3. Web content is DATA: every model prompt that carries page text is fenced and preceded by the security rules; web text never reaches a system/plan prompt.
v09_none "prompts with web text are fenced (UntrustedContent.fence) and carry the security preamble" "$( [ "$(grep -c 'UntrustedContent.preamble' $RS/ResearchPipeline+Candidates.swift $RS/ResearchReportBuilder.swift | awk -F: '{s+=$2} END {print s}')" -ge 2 ] && [ "$(grep -c 'UntrustedContent.fence' $RS/ResearchPipeline+Candidates.swift $RS/ResearchReportBuilder.swift | awk -F: '{s+=$2} END {print s}')" -ge 2 ] || echo 'missing fence/preamble' )"
v09_none "model output is parsed into typed records and its evidence must be grounded in the page (no free-text authority)" "$( grep -q 'Grounding.isGrounded' $RS/ResearchPipeline+Candidates.swift && grep -q 'ExtractionParser.parse' $RS/ResearchPipeline+Candidates.swift || echo 'grounding check missing' )"
v09_none "no tool/shell/launcher can be reached from the research layer (nothing it fetches is ever executed)" "$(grep -rnE 'ManagedProcess|Process\(|launchApplication|NSWorkspace\.shared\.open\(|openApplication|NSAppleScript|/bin/(ba|z)?sh|dlopen|NSBundle|Bundle\(path' $RS | grep -v "^$RS/ResearchViewModel.swift" | nonc)"
# 4. Network policy: http(s) only, no loopback exemption, no private ranges, every hop revalidated.
v09_none "the URL policy allows only http/https, has no loopback exemption, and every redirect hop is revalidated" "$( (grep -q 'allowedSchemes: Set<String> = \["http", "https"\]' $RS/URLPolicy.swift || echo 'schemes'; grep -nEi 'testOnly|loopbackExempt|allowLocalhost|allowPrivate' $RS/*.swift | nonc; grep -q 'authorizeRedirect' $RS/WebClient.swift || echo 'redirect revalidation missing'; grep -q 'AddressClassifier.nonPublicReason' $RS/WebClient.swift || echo 'post-connection check missing') )"
v09_none "no raw Authorization / Cookie / Set-Cookie handling outside the header redactor (no cookie storage, no credentials)" "$(grep -rnEi 'set-cookie|"cookie"|authorization|HTTPCookieStorage|WKHTTPCookieStore|allCookies|URLCredential\(|urlCredentialStorage = [^n]' $RS Sources/Jarvis/Tasks/TaskEngine+Research.swift | grep -vE "^$RS/(HTTPTransport|URLPolicy).swift" | nonc)"
v09_none "the browser/credential stores of the user are never touched (no Safari/Chrome/Firefox profile, cookie DB, Login Data, Keychain web credentials)" "$(grep -rnEi 'Library/Safari|com\.apple\.Safari|Google/Chrome|Application Support/Firefox|Login Data|Cookies\.binarycookies|Local State|SecItemCopyMatching|kSecClassInternetPassword|ASWebAuthentication|loginKeychain' Sources | nonc)"
v09_none "no CAPTCHA solving, anti-bot evasion or fake human behaviour" "$(grep -rnEi 'solve.?captcha|2captcha|anticaptcha|capsolver|stealth|undetected|fingerprint.?spoof|navigator\.webdriver' Sources | nonc)"
v09_none "no paid search API, no API key, no hardcoded credential in the research layer" "$(grep -rnEi 'X-Subscription-Token|api\.search\.brave|serpapi|serper\.dev|googleapis\.com/customsearch|bing\.microsoft|api-key|apikey|api_key|bearer ' $RS | grep -vE "^$RS/(HTTPTransport|URLPolicy).swift" | nonc)"
# 5. Price / licence honesty.
v09_none "UNKNOWN price is never free and unknown/unverified licences are never automatic" "$( (grep -q 'var isFree: Bool { self == .freeVerified }' $RS/ResearchModel.swift || echo 'isFree'; grep -q '\[.permissive, .attributionRequired\].contains(state)' $RS/ResearchModel.swift || echo 'allowsAutomaticAcquisition'; grep -q 'snippetOnly' $RS/PriceAnalyzer.swift || echo 'snippet rule'; grep -q 'case .paidPurchase: return .rejected' $RS/Acquisition/AcquisitionService.swift || echo 'paid rule'; grep -q 'case .accountRequiredFree, .marketplaceClaim: return .rejected' $RS/Acquisition/AcquisitionService.swift || echo 'account rule') )"
# 6. Quarantine: downloads never go into a project; extraction only inside the quarantine; no execution; archive names are validated; the importer is the only project writer.
v09_none "Downloader/ArchiveInspector know nothing about projects or workspaces (they write ONLY where they are told: the quarantine)" "$(grep -nE 'WorkspaceGuard|projectRoot|ProjectTools|Assets/' $RS/Acquisition/Downloader.swift $RS/Acquisition/ArchiveInspector.swift $RS/Acquisition/AcquisitionService.swift | nonc)"
v09_none "only AssetImporter writes into a project (workspace-guarded, hash-verified, never overwrites, only from a READY artifact)" "$( (grep -rln 'WorkspaceGuard' $RS | grep -v '/AssetImporter.swift'; grep -q 'record.state == .readyForImport' $RS/Acquisition/AssetImporter.swift || echo 'ready check'; grep -q 'destinationExists' $RS/Acquisition/AssetImporter.swift || echo 'no-overwrite check') )"
v09_none "archive entry names are validated before ANY extraction (traversal, absolute paths, symlinks, special files, bombs)" "$( ( [ "$(grep -c 'unsafeReason' $RS/Acquisition/ArchiveInspector.swift)" -ge 3 ] || echo 'unsafeReason not applied'; grep -q 'isSymlink' $RS/Acquisition/ArchiveInspector.swift || echo 'symlink check'; grep -q 'maxRatio' $RS/Acquisition/ArchiveInspector.swift || echo 'ratio check'; grep -q '0o600' $RS/Acquisition/ArchiveInspector.swift || echo 'file mode') )"
v09_none "downloads are https-only, bounded (size, time, redirects), hashed incrementally and quarantine-flagged" "$( (grep -q 'requireHTTPS' $RS/Acquisition/Downloader.swift || echo https; grep -q 'maxBytes' $RS/Acquisition/Downloader.swift || echo size; grep -q 'SHA256()' $RS/Acquisition/Downloader.swift || echo hash; grep -q 'com.apple.quarantine' $RS/Acquisition/Downloader.swift || echo flag) )"
v09_none "no research code paints an account action or a purchase (sign-in, claim, checkout, payment fields are not implemented)" "$(grep -rnEi 'checkout|add.to.cart|addToCart|payment.?method|credit.?card|card.?number|\.signIn\(|login\(|claimAsset|add to my assets' $RS Sources/Jarvis/Tasks/TaskEngine+Research.swift | nonc | grep -vE 'UntrustedContent.swift|PriceAnalyzer.swift|ResearchModel.swift|ResearchReportBuilder.swift|SourceClassifier.swift|HTMLExtraction.swift|AcquisitionService.swift|ResearchPipeline\+Candidates.swift')"
# 7. Bounded: budgets exist and every loop in the research layer is bounded.
v09_none "research budgets (queries, sources, browser navigations, model calls, bytes, seconds) and per-host politeness exist and are used" "$( (for k in maxQueries maxSources maxRendered maxProviderCalls maxTotalBytes maxSeconds; do grep -q "$k" $RS/ResearchModel.swift || echo "missing $k"; done; for u in 'exhausted(budget)' 'canRead(budget)' 'canRender(budget)' 'canCallProvider(budget)'; do grep -q "$u" $RS/ResearchPipeline.swift $RS/ResearchPipeline+Candidates.swift $RS/ResearchReportBuilder.swift || echo "budget not enforced: $u"; done; grep -q 'HostRateLimiter' $RS/WebClient.swift || echo 'rate limiter') )"
v09_none "no unbounded polling or periodic timers in the research layer (single-shot waits only; nothing runs while idle)" "$(grep -rnE 'Timer\.scheduled|repeats: *true|DispatchSource.*Timer|while true' $RS Sources/Jarvis/Tasks/TaskEngine+Research.swift | grep -vE "^$RS/(WebClient|HTTPTransport)\.swift|^$RS/Acquisition/ArchiveInspector\.swift" | nonc)"
v09_none "the browser tier is torn down when idle and shut down at quit" "$( (grep -q 'scheduleTeardown' $RS/RenderedPageProvider.swift || echo teardown; grep -q 'research?.browser?.shutdown()' Sources/Jarvis/App/AppContext.swift || echo 'quit shutdown') )"
# 8. Persistence + repository hygiene: no page bodies, no binaries, nothing third-party tracked.
v09_none "the schema stores no page body, no HTML, no binary artifact (research tables hold URLs, hashes and bounded excerpts)" "$(awk '/static let v7/,/V8 — project memory/' Sources/Jarvis/Persistence/Migrations.swift | grep -nEi 'body|html|content_blob|raw_page|archive|BLOB' | nonc)"
v09_none "no downloaded artifact, archive, 3D/audio asset, page archive or browser runtime is tracked by git" "$(git ls-files 2>/dev/null | grep -Ei '\.(zip|unitypackage|fbx|glb|gltf|blend|7z|tar|tgz|gz|dmg|pkg|exe|mht|mhtml|warc|har|wav|mp3|ogg)$|(^|/)(chromium|chrome-linux|playwright|ms-playwright)' )"
v09_none "no tracked file looks like an HTML page archive (research never archives third-party pages)" "$(git ls-files 2>/dev/null | grep -Ei '\.html?$' )"

# --- V0.10 Project memory: derived knowledge with provenance; never authority; never a cloud service; never a hidden background process (DEC-104…) ---
MEM=Sources/Jarvis/Memory
v09_none "the memory layer cannot approve, decide, import, acquire, run a process, open a connection or touch credentials" "$(grep -rnE 'decideApproval|requestApproval|ApprovalGuard|\.decide\(|ProposalService|submitImport|submitAcquisition|submitResearch|ApprovedExecutables|ManagedProcess|Process\(\)|NSTask|URLSession|URLRequest|WKWebView|NSWorkspace|Keychain|SecItem' $MEM | nonc)"
v09_none "policy, approval and command-safety code never reads memory (memory is context, not authority)" "$(grep -nE 'MemoryItem|MemoryService|ProjectMemory|MemoryRetriever|ProjectContextBuilder|memoryContext' Sources/Jarvis/Proactive/OpportunityPolicy.swift Sources/Jarvis/Tasks/TaskPlan.swift Sources/Jarvis/Tasks/CommandProfiles.swift Sources/Jarvis/Tasks/Workspace.swift Sources/Jarvis/Tasks/ProjectTools.swift Sources/Jarvis/Services/Conversation/ApprovalGuard.swift 2>/dev/null | nonc)"
v09_none "no cloud vector database, no paid or hosted embedding API, no key variable for one" "$(grep -rnEi 'api\.openai\.com|api\.cohere|voyageai|pinecone|weaviate|qdrant\.cloud|embeddings\.create|text-embedding-(3|ada)|OPENAI_API_KEY|COHERE_API_KEY|VOYAGE_API_KEY|chromadb' Sources scripts/memory-ai scripts/setup_memory_ai.sh | grep -v 'Sources/Jarvis/Providers/ProviderEnvironment.swift' | nonc)"
v09_none "the embedding helper imports no network/process library, forces offline mode and never downloads" "$( (grep -nE '^[[:space:]]*(import|from)[[:space:]]+(requests|urllib|socket|http|httpx|aiohttp|websocket|subprocess)' scripts/memory-ai/jarvis_embed_worker.py; grep -q 'HF_HUB_OFFLINE' scripts/memory-ai/jarvis_embed_worker.py || echo 'not offline') )"
v09_none "every memory passes the secret gate before it is stored AND before it is embedded" "$( (grep -q 'MemoryGate.containsSecret(rawText)' $MEM/MemoryService.swift || echo 'curator'; [ "$(grep -c 'MemoryGate.containsSecret' $MEM/MemoryIndex.swift)" -ge 2 ] || echo 'index') )"
v09_none "memory records are written only by the curator (MemoryService) and the repository; vectors only by the index, the curator (delete) and the repository" "$(grep -rnE 'insertMemory\(|updateMemory\(' Sources | grep -vE 'Sources/Jarvis/Memory/MemoryService\.swift|Sources/Jarvis/Persistence/MemoryRepository\.swift' | nonc; grep -rnE 'upsertEmbedding\(|replaceEmbeddings\(' Sources | grep -vE 'Sources/Jarvis/Memory/MemoryIndex\.swift|Sources/Jarvis/Persistence/MemoryRepository\.swift' | nonc)"
v09_none "a model's statement is capped (inferred / unverified) unless its quoted evidence was found verbatim in the source; web text becomes research memory only through validated V0.9 records" "$( (grep -q 'c.grounded && sources.contains' $MEM/MemoryService.swift || echo 'model cap'; grep -q 'unverifiedResearch' $MEM/MemoryService.swift || echo 'research gate'; grep -q 'Grounding.isGrounded' $MEM/MemoryIngest.swift || echo 'grounding') )"
v09_none "current deterministic truth is consulted before a keyed memory is stored and before context is built" "$( (grep -q 'truth.truth(for: key, projectRoot: projectRoot)' $MEM/MemoryService.swift || echo 'admit'; grep -q 'reconcileWithTruth' $MEM/ProjectContextBuilder.swift || echo 'context') )"
v09_none "forgotten memory is excluded from retrieval, vectors and index rebuilds" "$( (grep -q 'subtracting(\[.forgotten\])' $MEM/MemoryRetrieval.swift || echo 'retrieval'; grep -q "status != 'forgotten'" Sources/Jarvis/Persistence/MemoryRepository.swift || echo 'vectors'; grep -q 'fresh.status.isLive' $MEM/MemoryIndex.swift || echo 'sync') )"
v09_none "agent context is bounded per agent kind and injected only through the engine's single job path, with the memory ids audited" "$( (grep -q 'maxChars' $MEM/ProjectContextBuilder.swift || echo 'budget'; grep -q 'memory?.recordUse' Sources/Jarvis/Tasks/TaskEngine+Planning.swift || echo 'audit'; grep -rn 'contextFor(agentType' Sources | grep -vE 'Sources/Jarvis/Memory/|TaskEngine\+Planning\.swift|OpportunityEngine|App/MemoryLiveTest\.swift' | nonc) )"
v09_none "memory has no timers, polling or periodic work (single-shot idle unload only)" "$(grep -rnE 'Timer\.scheduled|repeats: *true|DispatchSource.*Timer|while true' $MEM | nonc)"
v09_none "memory never deletes history: no file removal and no DELETE on task, run, approval, research or acquisition tables" "$(grep -rnE 'removeItem|trashItem|DELETE FROM (tasks|agent_runs|activity|approvals|research_|acquisitions|task_)' $MEM Sources/Jarvis/Persistence/MemoryRepository.swift | nonc)"
v09_none "the memory schema stores no conversation archive, transcript, page body or audio" "$(awk '/static let v8/,0' Sources/Jarvis/Persistence/Migrations.swift | grep -nEi 'transcript|messages|page_body|html|raw_|audio|pcm' | nonc)"
v09_none "no embedding model, runtime index or memory database is tracked by git" "$(git ls-files 2>/dev/null | grep -Ei 'memory-minilm|memory-bench|memory-venv|\.(onnx|npz|safetensors|gguf|sqlite|sqlite-wal|sqlite-shm)$')"

print "== Smoke test (real window manager, store, status item)"
log=$(mktemp)
$APP/Contents/MacOS/Jarvis --smoke-test >$log 2>&1; rc=$?
grep -E "^(FAIL|SKIP)" $log
print "   $(grep -c '^PASS' $log) PASS, $(grep -c '^FAIL' $log) FAIL, $(grep -c '^SKIP' $log) SKIP"
[ $rc -eq 0 ] && pass "smoke test exit code 0" || fail "smoke test exit code $rc"
! grep -v -E "^(PASS|FAIL|SKIP|SMOKE)" $log | grep -qi -E "error|fault|unable to|constraint|warning" \
  && pass "no error/warning output from app (stdout+stderr)" || { fail "unexpected error/warning output"; grep -i -E "error|fault|unable|constraint|warning" $log | head; }

print "== Idle resource check (HUDs closed, state idle, 8s window)"
pkill -x Jarvis 2>/dev/null; sleep 1
open -n $APP --args --state idle --no-providers
sleep 4
pid=$(pgrep -nx Jarvis)
cpu() { ps -o cputime= -p $pid | awk -F'[:.]' '{print $1*60+$2+$3/100}'; }
a=$(cpu); sleep 8; b=$(cpu)
used=$(echo "$b - $a" | bc)
print "   CPU seconds used in 8s: $used   RSS: $(ps -o rss= -p $pid | awk '{printf "%.0f MB", $1/1024}')"
[ "$(echo "$used < 0.4" | bc)" = "1" ] && pass "idle CPU < 5% of one core" || fail "idle CPU too high ($used s / 8 s)"
pkill -x Jarvis 2>/dev/null

print
(( fails == 0 )) && print "VERIFY PASSED" || print "VERIFY FAILED ($fails)"
exit $fails
