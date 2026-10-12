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
forbid "no unapproved network clients (providers are subprocesses only)" "URLSession|URLRequest|NWConnection|NWPathMonitor|CFNetwork|CFStream|NSURLConnection|WKWebView|WebKit|WebSocket|import Network|Data\\(contentsOf|String\\(contentsOf|contentsOf: *URL\\(string"
forbid "no paid-API endpoints or web-subscription scraping" "api\\.openai\\.com|api\\.anthropic\\.com|chatgpt\\.com|claude\\.ai/(api|chat)|console\\.anthropic|platform\\.openai|backend-api|openai\\.com/v1|anthropic\\.com/v1"
forbid "no credential / token / cookie access" "auth\\.json|\\.credentials|SecItemCopyMatching|SecKeychain|binarycookies|HTTPCookieStorage|--with-api-key|--with-access-token|apiKeyHelper"
forbid "API-key / token variable names appear ONLY in the scrub list" "ANTHROPIC_API_KEY|OPENAI_API_KEY|CODEX_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_BASE_URL|OPENAI_BASE_URL|OPENAI_ORG|AWS_BEARER_TOKEN|ANTHROPIC_BEDROCK|ANTHROPIC_VERTEX|CLAUDE_CODE_USE_(BEDROCK|VERTEX)|OPENCODE_API_KEY|OPENCODE_SERVER_PASSWORD|OPENROUTER_API_KEY|GROQ_API_KEY|MISTRAL_API_KEY|GEMINI_API_KEY|XAI_API_KEY|DEEPSEEK_API_KEY|HF_TOKEN|HUGGING_FACE_HUB_TOKEN" "^Sources/Jarvis/Providers/ProviderEnvironment\\.swift"
forbid "no dangerous provider flags or API-key-only modes" "\"--bare\"|dangerously|danger-full-access|bypassPermissions|--full-auto|--approve-for-me|\"--enable\"|workspace-write|--yolo|--allowedTools|--allow-dangerously|--add-dir|--mcp-config|\"--api-key|--with-api-key|\"--auto\"|\"--attach\"|\"--share\"|\"--password\"|\"--mdns\"|\"serve\"|\"web\""
forbid "Process is created ONLY by ManagedProcess (one audited launch point)" "(^|[^[:alnum:]_.])Process\\(\\)|NSTask|posix_spawn|Foundation\\.Process" "^Sources/Jarvis/Providers/ManagedProcess\\.swift"
# (TaskPlan.swift holds the plan validator's DENY-list of prohibited phrases — words it rejects, not code that uses them.)
forbid "no generic launchers / downloaders / UI scripting" "/usr/bin/env|\"env\"|curl|wget|osascript|NSWorkspace\\.shared\\.(launchApplication|open\\(.*URL\\(string)" "^Sources/Jarvis/App/(SmokeTest|DevCapture)\\.swift|^Sources/Jarvis/Tasks/TaskPlan\\.swift|^Sources/Jarvis/Unity/UnityProtocol\\.swift"
forbid "no shell is ever used to run a provider" "/bin/(ba|z)?sh|launchPath|\"sh\", *\"-c\"|popen\\(|[^.[:alnum:]_]system\\("
forbid "OpenCode credential/integration API operations are never invoked (only the fixed model.list)" "credential\\.(list|get|remove|create|update)|integration\\.(list|get|connect)|connect/(key|external|oauth|command)"
forbid "no URL literals in product code (JARVIS contacts no host itself; providers do their own networking)" "\"https?://|URL\\(string:"
forbid "the product never reads the pasteboard (only native paste; the dev smoke test is excluded)" "NSPasteboard|generalPasteboard" "App/SmokeTest\\.swift"

# --- V0.3.1: persistence, models and secrets must never be committed; the local worker must stay offline ---
tracked_bad=$(git ls-files 2>/dev/null | grep -E '\.(sqlite|sqlite3|sqlite-wal|sqlite-shm|db|safetensors|gguf|mlx|npz|pt|pth|onnx|wav|caf|aiff|aif|m4a|mp3|flac|ogg|opus)$' || true)
[ -z "$tracked_bad" ] && pass "no runtime database or model file is tracked by git" || { fail "runtime database / model file tracked: $tracked_bad"; }
big=$(git ls-files 2>/dev/null | while read -r f; do [ -f "$f" ] && [ "$(stat -f%z "$f")" -gt 5242880 ] && echo "$f"; done)
[ -z "$big" ] && pass "no tracked file larger than 5 MB" || fail "large tracked files: $big"
secrets=$(git ls-files 2>/dev/null | grep -vE '^Tests/' | xargs grep -IEn "sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----" 2>/dev/null | head -3)
[ -z "$secrets" ] && pass "no secrets in tracked files (excluding test fixtures)" || { fail "possible secret in tracked files"; echo "$secrets" | cut -c1-120; }
if grep -nE "^[[:space:]]*(import|from)[[:space:]]+(requests|urllib|socket|http|httpx|aiohttp|huggingface_hub|websocket)" scripts/local-ai/*.py >/dev/null 2>&1; then fail "local worker imports a network library"; else pass "local worker imports no network library"; fi
grep -q 'HF_HUB_OFFLINE' scripts/local-ai/jarvis_local_worker.py && pass "local worker forces offline mode" || fail "local worker does not force offline mode"
swift_db=$(grep -rln "sqlite3_open" Sources | grep -v Persistence/SQLiteDatabase.swift || true)
[ -z "$swift_db" ] && pass "raw SQLite access is confined to Persistence/SQLiteDatabase.swift" || fail "raw sqlite3 use outside the persistence engine: $swift_db"

# --- V0.3.2 Agent Observatory: raw provider output may only enter observable/durable state through the sanitization boundary ---
forbid "no pseudo-terminal / embedded shell (Agent Console is read-only JARVIS-managed output)" "forkpty|openpty|posix_openpt|/dev/ptmx|NSTask|\\bsudo\\b" "^Sources/Jarvis/Tasks/TaskPlan\\.swift|^Sources/Jarvis/Proactive/OpportunityAssessor\\.swift"
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
voi_entry=$(grep -rln 'source: \.voice' Sources | grep -v 'Sources/Jarvis/App/AppContext.swift' | grep -v 'Sources/Jarvis/Services/Conversation/ConversationService.swift' | grep -v 'Sources/Jarvis/Core/ConversationStore.swift' | grep -v 'Sources/Jarvis/Tasks/GoalIntake.swift' | grep -v 'Sources/Jarvis/App/DevCapture.swift' | grep -v 'Sources/Jarvis/App/VoiceLiveTest.swift' || true)
[ -z "$voi_entry" ] && pass "a spoken transcript enters the conversation only through ConversationService.submit (the typed path) wired in AppContext" || { fail "voice input path outside AppContext/ConversationService: $voi_entry"; }
voi_mic=$(grep -rnE 'AVAudioEngine\(|installTap|AVAudioInputNode|inputNode' Sources | grep -v 'Sources/Jarvis/Voice/AudioInput.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_mic" ] && pass "microphone capture exists in exactly one file (Voice/AudioInput.swift)" || { fail "audio capture outside AudioInput.swift"; echo "$voi_mic" | head -3; }
voi_perm=$(grep -rnE 'AVCaptureDevice|requestAccess' Sources | grep -v 'Sources/Jarvis/Voice/MicrophoneAccess.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_perm" ] && pass "the microphone permission is read/requested in exactly one file (Voice/MicrophoneAccess.swift)" || { fail "permission API outside MicrophoneAccess.swift"; echo "$voi_perm" | head -3; }
voi_launch=$(grep -rnE 'MicrophoneInput\(|pushToTalkPressed\(\)|\.start\(onFrame' Sources | grep -vE 'Sources/Jarvis/Voice/(VoiceCoordinator|AudioInput)\.swift|Sources/Jarvis/App/(AppDelegate|SmokeTest|VoiceLiveTest)\.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
[ -z "$voi_launch" ] && pass "the microphone starts only from the Push-to-Talk handler (never at launch, from a timer, or from the UI)" || { fail "microphone start outside the PTT path"; echo "$voi_launch" | head -3; }
voi_audio=$(grep -rnE 'forWriting|AVAudioRecorder|AVAssetWriter|\.(wav|caf|aiff|m4a)\"|writeFrames|ExtAudioFileCreate' Sources | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
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
tracked_voice=$(git ls-files 2>/dev/null | grep -E '(^|/)(voice-venv|whisper[^/]*|piper[^/]*)/|\.(wav|caf|aiff|m4a|mp3|flac|ogg|npz)$' || true)
[ -z "$tracked_voice" ] && pass "no audio file, voice model or voice runtime is tracked by git" || fail "tracked voice artefact: $tracked_voice"

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
