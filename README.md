# JARVIS

A native macOS menu-bar AI operating layer (long-term). V0.1 native foundation + HUD · V0.2 text conversation and deterministic command router · V0.3 real intelligence through **your own signed-in Claude Code / Codex** · **V0.8 natural voice** (opt-in local wake word “Jarvis”, natural endpointing, barge-in, a local neural JARVIS voice — still the same pipeline) · **V0.7 voice I/O** (hold right ⌥ to talk — Turkish or English; the final transcript enters the SAME pipeline as typed text; local/system speech only) · **V0.4 autonomous task engine** (you give a bounded goal; JARVIS plans, executes with agents/tools, validates with real builds/tests, repairs within bounds, reports — user-initiated only) · **V0.3.2 agent observatory** (live sanitized consoles, truthful progress, history, Stop) · **V0.3.1 intelligence infrastructure**: durable SQLite persistence + audit trail, a **verified-free OpenCode model pool**, an **on-device Qwen model for lightweight tasks**, a **provider supervisor**, **policy-driven automatic model routing** and a bounded **background-agent foundation**. JARVIS itself has **no API keys, no network client, no macOS permission request, and never touches your credentials**; there is **no paid API anywhere**. JARVIS contacts no network host itself.

- **Version:** V0.8 — **READY FOR MANUAL TEST** (Natural Voice & Presence: opt-in local wake word + VAD, hands-free turn taking with a bounded follow-up window, barge-in with self-speech suppression, local neural JARVIS voice with Apple fallback, original voice identity: `docs/NATURAL_VOICE.md`; not user-verified — human speech, voice naturalness and the real room are manual). V0.7 — READY FOR MANUAL TEST (Voice I/O Foundation: Push-to-Talk, streaming/incremental STT, incremental TTS, voice session state, Turkish + English: `docs/VOICE_IO.md`). V0.6 — READY FOR MANUAL TEST (Unity Project Agent & Editor Bridge inside the V0.4 engine: `docs/UNITY_PROJECT_AGENT.md`). V0.5 — READY FOR MANUAL TEST (decision layer above the V0.4 task engine: `docs/PROACTIVE_REASONING.md`). V0.4 — READY FOR MANUAL TEST (app version string `0.1.1`; V0.1–V0.2.1 were manually tested by the user; V0.3, V0.3.1, V0.3.2 and V0.4 are not yet). Details: `docs/AUTONOMOUS_TASK_ENGINE.md`, `docs/AGENT_OBSERVABILITY.md`, `docs/PROVIDER_RESEARCH.md`, `docs/OPENCODE_RESEARCH.md`, `docs/MODEL_ROUTING.md`, `docs/PERSISTENCE.md`.
- Handoff for agents: `PROJECT_STATE.md`, `AGENTS.md` (includes the Git workflow: `main` only, linear history)

## Requirements

- macOS 14+ on Apple Silicon (built/tested on macOS 26.4, M5)
- Swift 6.x toolchain / Command Line Tools. **Xcode is not required** (and wasn't installed on the dev machine).

## Build, run, test

```bash
scripts/build_app.sh          # builds build/Jarvis.app (release, ad-hoc signed)
open build/Jarvis.app         # menu bar icon appears (no Dock icon)
scripts/verify.sh             # full automated verification
scripts/test.sh               # unit tests only
scripts/setup_local_ai.sh     # optional, once: isolated MLX runtime (605 MB, 57 pinned packages) for the on-device model — downloads NO model
scripts/setup_voice_ai.sh --natural  # optional, once (V0.8): isolated ONNX runtime (≈190 MB), 3 pinned wake/VAD feature models (4 MB, SHA-256 verified) and ONE pinned neural voice (Supertonic 3, ≈381 MB, OpenRAIL-M); then scripts/train_wake_head.sh trains the local “Jarvis” head (≈ 0.6 MB, synthetic speech, 20–60 min). Never downloaded by JARVIS itself
scripts/setup_voice_ai.sh     # optional, once: isolated speech runtime (≈480 MB) + ONE pinned Whisper model (≈460 MB, MIT upstream) for the more accurate local recogniser; JARVIS never downloads it itself. Without it, voice uses Apple's on-device recogniser
```

**Opt-in REAL tests** (V0.8: `Jarvis --natural-voice-live-test [--natural-audible] [--natural-acoustic] [--natural-combined] [--natural-idle <min>]` — SYNTHETIC speech through the real wake sentinel, turn manager, Whisper, the same ConversationService and the neural/Apple voice in a closed acoustic loop (scripted microphone + simulated speaker with this Mac's measured echo coupling); `--natural-acoustic` additionally measures the REAL speaker→microphone loop (audible, levels only); silent by default) (V0.7: `Jarvis --voice-live-test [--voice-audible] [--voice-no-whisper] [--voice-real-mic] [--voice-combined]` — SYNTHETIC speech from the macOS voices through the real recognisers, the real conversation path and real TTS, real OS-level Right-Option key events, resource figures; silent by default) (spend only free/local engines plus two tiny Claude Code requests; never part of `verify.sh`):
`build/Jarvis.app/Contents/MacOS/Jarvis --intelligence-live-test [--benchmark-models]` (V0.3.1/V0.3.2 stack, own data directory), `--unity-live-test [--unity-no-provider]` (V0.6: a REAL headless Unity editor started by JARVIS on a disposable fixture copied to a temp folder — typed scene/component/property edits, compile/domain reload, EditMode+PlayMode tests, Play Mode, Console delta, dirty-scene and Play-Mode protection, cancellation, relaunch, and real OpenCode-FREE-routed fixes of a compile error and a failing test; own data directory, never your game), `--proactive-live-test` (V0.5: real proposal → approval → V0.4 task, low-risk auto action, denial, relaunch — OpenCode FREE, isolated fixtures, own data directory), `--demo-proposals` (labelled simulated suggestions for the UI), `--task-live-test` (V0.4: the real task engine on isolated temporary fixture projects — OpenCode FREE preferred, own data directory, never the JARVIS repository) and `--provider-live-test` (V0.3 Claude Code / Codex).

**Global shortcuts** (work while any app is focused; no permission): hold **Option** and press **Command** → toggle Compact HUD (fires ~0.3 s later unless it turns out to be a double press). Hold **Option** and press **Command twice quickly** (within 0.3 s) → toggle Full HUD. Either Command key. Ignored if you add another key, a click, Shift or Control (so ⌥⌘D, ⌥⌘-click etc. are untouched). Turn off in Settings → Enable global shortcuts.

**Wake word (V0.8, Settings → Voice → Wake word “Jarvis”, OFF by default):** a small local detector listens for “Jarvis”; before it hears it nothing is transcribed, stored or sent (bounded in-memory audio; recognition starts only when you speak after the word). Say “Jarvis” (a soft sound, ATTENTIVE), speak, JARVIS answers in the JARVIS voice and listens for a follow-up for ≈ 8 s; speak over it to interrupt. Wake is an activation, not authentication — approvals stay HUD buttons. Needs `scripts/setup_voice_ai.sh --natural` + `scripts/train_wake_head.sh`; without them wake mode says why it is unavailable and Push-to-Talk keeps working.

**Push-to-Talk (V0.7, Settings → Voice, off by default):** HOLD the **right Option (⌥) key by itself** for a moment, speak Turkish or English, release. The microphone is open only while it is held; the transcript shows while you speak and becomes ONE normal message when you let go; JARVIS answers in text and aloud (stop: the Stop button, the menu bar item, "stop talking", a new Push-to-Talk or typing). Needs the macOS microphone permission (asked on first use) and nothing else. Spoken "yes/approve" never approves anything — approvals are HUD buttons.

**Commands you can type** (Full HUD or Compact command field; optional “Jarvis,” prefix, case/punctuation ignored):

| Say | Does |
|---|---|
| open / show / go to the report · tasks · system · memory · dashboard · settings | opens the Full HUD on that section (Compact closes) |
| what are you doing? · status · what state are you in? | answers from the real state/task |
| pause / resume / stop (the task) | controls the demo task, confirms, logs activity |
| open compact · open full hud · open Jarvis · close Jarvis | HUD control |
| clear conversation | clears the conversation |
| hello · thanks | tiny local replies |
| raporu aç · görevleri göster · ayarları aç · sistemi aç · belleği göster · görevi duraklat · devam et · görevi durdur · durum nedir · sohbeti temizle · Jarvis'i kapat | Turkish equivalents |
| anything else (“Explain how neural networks work.”, “Explain this Swift function: …”) | answered by the selected provider (Claude Code / Codex), streamed into the Conversation panel; **stop generating** (or the STOP GENERATION button, ⌘.) cancels it |
| autonomous work (“Fix my Unity multiplayer, run it and keep working until it passes.”) | classified `workerRequired`: **no provider is started**; JARVIS says execution isn't enabled yet (task engine = V0.4) |

Quit: right-click the menu bar icon → Quit JARVIS (or ⋯ menu in the Compact HUD).

## Current features

| Feature | Status |
|---|---|
| Menu bar item with state-specific glyphs | IMPLEMENTED · AUTOMATED TESTED (partial) · MANUAL TEST REQUIRED |
| Compact HUD (fixed 392×448 in every state; task, step, elapsed, progress, Open/Pause/Stop, command) | IMPLEMENTED · AUTOMATED TESTED (frame measured across states) · MANUAL TEST REQUIRED |
| Ambient neural-network background (Full HUD, state-reactive, pauses when hidden / Reduce Motion) | IMPLEMENTED · AUTOMATED TESTED (lifecycle) · VISUALLY VERIFIED · MANUAL TEST REQUIRED |
| **Text commands** (EN + TR) → router → executor → real UI/task actions; Conversation panel; honest "provider not connected" replies | IMPLEMENTED · AUTOMATED TESTED (unit + 7 acceptance scenarios on the real WindowManager) · MANUAL TEST REQUIRED |
| **Real intelligence:** Claude Code (token streaming) and Codex (message-level) via their official CLIs; Auto / Codex / Claude Code selection; follow-up context; STOP GENERATION that really kills the process; provider status in Settings | IMPLEMENTED · **REAL TESTED** through the JARVIS stack (`--provider-live-test`) · MOCK TESTED (fake CLIs, 327 unit tests) · MANUAL TEST REQUIRED |
| **V0.3.1 persistence:** SQLite (WAL, migrations, corrupt-file recovery) in `~/Library/Application Support/JARVIS`, file-backed artifacts, redacted **audit trail** (who/what/why/when/tools/validation/escalation per run) | IMPLEMENTED · AUTOMATED TESTED · **REAL TESTED** (written by the app, closed, reopened) |
| **OpenCode free pool:** models are "free" only when OpenCode's current price data is all-zero on the keyless tier (never by name), re-verified daily; per-model data-handling labels; benchmark suite; tools rejected | IMPLEMENTED · **REAL TESTED** (real free models, tool canaries) · MOCK TESTED |
| **Local Qwen3.5-4B (MLX)** for lightweight tasks only (never coding/tests/repo/review/debug/architecture/Unity/security): starts on demand, unloads when idle or under memory pressure | IMPLEMENTED · **REAL TESTED** · MOCK TESTED (fake worker, real processes) |
| **Model router + supervisor:** Auto = Local → OpenCode free → Claude/Codex by policy; explicit modes never fall back; persisted reasons; cooldown/backoff; bounded restart; bounded escalation | IMPLEMENTED · AUTOMATED TESTED (≈90 routing/policy/supervisor tests) · **REAL TESTED** |
| Background agent foundation (limits for 16 GB, parent/child, no recursion, cancel, bounded repair/escalation, audit) — no UI entry point yet | IMPLEMENTED · AUTOMATED TESTED |
| Native text editing (⌘V/⌘C/⌘X/⌘A/⌘Z), multiline composer | IMPLEMENTED · AUTOMATED TESTED (real key events) · physical keyboard MANUAL TEST REQUIRED |
| Global shortcuts ⌥⌘ (Compact) and ⌥⌘⌘ (Full), no permission needed | IMPLEMENTED · AUTOMATED TESTED (logic + scripted integration) · **MANUAL TEST REQUIRED** (physical keys from another app) |
| **V0.4 autonomous task engine:** goal intake → durable task → validated structured plan → event-driven scheduler → analysis/coding/review agents + build/test tools → deterministic validation → bounded repair (1) + escalation (1) → checkpoints, report; workspace sandbox, write leases, Git baseline + user-change protection, approvals for destructive actions, cancellation, restart recovery (explicit resume) | IMPLEMENTED · AUTOMATED TESTED (≈105 task tests on isolated Git fixtures) · **REAL TESTED** (`--task-live-test`: OpenCode FREE fixed a failing test end to end; cancel, interrupt/resume) · MANUAL TEST REQUIRED |
| **V0.5 proactive reasoning & approval policy:** after a task, JARVIS derives findings from recorded facts, deduplicates them and a deterministic policy decides ignore / record / propose / require approval / (opt-in) auto low-risk action; approved or automatic work becomes a normal V0.4 task with a bound scope; JARVIS never approves its own proposal; event-driven, no polling | IMPLEMENTED · AUTOMATED TESTED (≈54 tests, isolated Git fixtures) · **REAL TESTED** (`--proactive-live-test` 26/26, OpenCode FREE) · MANUAL TEST REQUIRED |
| **V0.6 Unity Project Agent:** JARVIS-owned typed Editor bridge (embedded package, local file spool — no MCP, no socket, no network, no arbitrary C#/menu/shell), Unity step types inside the V0.4 engine, truthful connection state, identity-safe scene/component/property edits, saved only for what JARVIS changed, unsaved user work + Play Mode protected, Unity's own compiler/test/Console state as validation, review cannot overrule hard facts | IMPLEMENTED · AUTOMATED TESTED (≈105 new tests; simulated editor = MOCK) · **REAL TESTED** (`--unity-live-test` 59/59 on Unity 6000.5.1f1, incl. OpenCode FREE fixing a real compile error and a real failing test) · MANUAL TEST REQUIRED |
| **V0.8 Natural voice & presence:** opt-in local wake word (custom head on frozen features, ONNX, no key/cloud) + Silero VAD in one helper, natural hint-based endpointing (0.5–1.5 s), turn manager with a bounded follow-up window, barge-in with self-speech suppression from JARVIS' own known output (no echo-canceller claim), local neural JARVIS voice (Supertonic 3; Apple voices as fallback; incremental chunk synthesis), original voice identity v1, speakable answers for voice turns, one microphone hub + one output engine | IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (synthetic speech, closed loop) · human speech / voice naturalness / real room MANUAL TEST REQUIRED |
| **V0.7 Voice I/O:** hold-to-talk (right ⌥), partial then FINAL transcript → the typed pipeline (`ConversationService.submit`), Apple on-device + local Whisper recognisers (Turkish/English, real language detection for Whisper), incremental sentence TTS with the macOS voices, speech rendering/chunking/long-answer policy, stop at once, voice-created V0.4 tasks (`input_channel`), approvals HUD-only, no stored audio, no network/paid API | IMPLEMENTED · AUTOMATED TESTED · **REAL TESTED with SYNTHETIC speech** · **HUMAN SPEECH / TTS QUALITY / VOICEOVER: MANUAL TEST REQUIRED** |
| Full HUD (Dashboard, Tasks, Agents, System; Report/Memory placeholders) | IMPLEMENTED · MANUAL TEST REQUIRED |
| JARVIS Core visualization for all 7 states | IMPLEMENTED · VISUALLY VERIFIED (screenshots) |
| Window-management layer for future UI self-control | IMPLEMENTED · AUTOMATED TESTED |
| Demo task, activity feed, agents/tools panels (DEMO) | IMPLEMENTED |
| Developer state simulator | IMPLEMENTED |
| Settings (Reduce Motion, Developer Controls) | IMPLEMENTED |
| Launch at Login | PLANNED (disabled placeholder) |
| Report view, Memory view | PLANNED (V0.10) |
| Wake word / hands-free / barge-in (V0.8), web research & asset acquisition (V0.9), project memory (V0.10), computer use (V0.11), advanced multi-agent (V0.12), visual validation of Unity | PLANNED — see `docs/ROADMAP.md` |

## Architecture overview

`JarvisStore` (what JARVIS is doing: state, tasks, activity) is separate from `HUDState` (which windows/sections are showing). Windows are controlled only through `JarvisWindowControlling`/`WindowManager`. Details: `docs/ARCHITECTURE.md`.

## Directory structure

```
Package.swift                 SwiftPM manifest (no dependencies)
Resources/Info.plist          LSUIElement agent; the ONLY usage string is the microphone (V0.7)
Sources/Jarvis/
  App/        entry point, AppContext (composition root), launch options, dev smoke test / capture
  Core/       JarvisState, JarvisStore, HUDState, Preferences, observation bridge
  Models/     JarvisTask, ActivityEvent, display slots
  Services/   window management, local command handler, Demo/ (demo data only)
  UI/         Theme, MenuBar, CompactHUD, FullHUD, Components, VisualEffects, Settings
  Providers/  V0.3 CLI providers (ManagedProcess, parsers, ProviderManager) + OpenCode spec/parser
  Intelligence/ V0.3.1: router, classifier, local runtime, OpenCode service, supervisor, resources, agents, benchmark, coordinator
  Persistence/ V0.3.1: SQLite engine, migrations, repository, artifacts, redaction (+ V0.4 TaskRepository)
  Observability/ V0.3.2: sanitizer, execution hub, SafeProvider/SafeToolOutput, Agent Observatory
  Unity/      V0.6: Unity discovery/detection, typed protocol, file-spool transport, policy, service/connection, mutation lock, launcher, bridge installer (+ UnityBridge/ = the C# Editor package and the fixture)
  Voice/      V0.8 Natural/: turn machine, endpoint policy, barge-in detector, hands-free coordinator, microphone hub, helper host, wake/VAD sentinel runtime, neural voice, voice identity, transcript guards; SpeechPlayer + PlayerBackedTTS. V0.7: voice coordinator, push-to-talk machine, speech chunker/renderer, response speaker, microphone input/permission, STT/TTS providers (Apple, Whisper helper)
  Proactive/  V0.5: opportunity model, deterministic policy, normaliser/dedup, assessor, finding extractor, revalidator, OpportunityEngine, ProposalService
  Tasks/      V0.4: task model/state machines, plans, workspace guard, project tools, command profiles, leases, engine, reports, intake
Tests/JarvisTests/            unit tests (Swift Testing)
scripts/                      build_app.sh, test.sh, verify.sh, setup_local_ai.sh, local-ai/ (worker + pinned requirements), setup_voice_ai.sh [--natural], train_wake_head.sh, voice-ai/ (speech, wake/VAD and neural-voice workers + pinned requirements, bench/)
docs/                         architecture, decisions, roadmap, issues, log, current task
captures/                     dev screenshots (git-ignored)
```

## Known limitations

See `docs/KNOWN_ISSUES.md`. Notably: conversation history is in-memory (the audit trail is persistent), demo data in the HUD panels, custom-button VoiceOver labels need a manual check, Retina rendering unverified, dev tooling is compiled into the release binary.

## Next milestone

V0.9 — Web Research & Asset Acquisition — **not started; do not start it until the user approves V0.8** (`docs/ROADMAP.md`, DEC-068/086).

## Manual test checklist (V0.1)

1. `scripts/build_app.sh && open build/Jarvis.app` — an icon appears in the menu bar; no Dock icon; **no permission dialog**.
2. Click the icon → Compact HUD opens under it. Click the icon again → closes. Open it, press **ESC** → closes. Open it, click elsewhere → closes.
3. In Compact HUD click **OPEN JARVIS** → Full HUD opens, centered, in front. Compact HUD is gone.
4. Press **ESC** (and try the **CLOSE** button, and ⌘W) → Full HUD closes; menu bar icon is still there.
5. Reopen Compact → OPEN JARVIS again → the demo task is where you left it (Multiplayer Synchronization, step 4/6).
6. Click each state chip in the DEV · STATE SIMULATOR strip (Idle, Listening, Thinking, Working, Approval, Complete, Error). Check: core visual, state chip, task chip and menu bar icon all change coherently; Complete returns to Idle after ~6 s; Approval shows Approve/Deny.
7. Compact HUD: **PAUSE** → status PAUSED and clock stops; **RESUME**; **STOP** → "No active task". Dev strip → **RESET DEMO TASK** (Full HUD) restores it.
8. Type `test` + Return in either command field → appears in Activity feed, brief Thinking → Complete.
9. Full HUD: switch tabs (Dashboard / Tasks / Report / System / Memory). Drag the window edges to resize; it must not go below ~980×620 and nothing should overlap or clip badly. Move/drag it by its background.
10. Right-click the menu bar icon → menu works (Open JARVIS, Settings…, Quit). Open Settings: toggle Reduce Motion (animation stops/slows) and Show Developer Controls (strip disappears).
11. Look at quality: contrast, text size, glass/blur, the "JARVIS is present" feel. Test on a Retina display and, if available, a second display and light/dark menu bar.
12. **VoiceOver check (MANUAL VERIFICATION REQUIRED):** with VoiceOver on, focus the Compact HUD buttons (OPEN JARVIS / PAUSE / STOP / state chips) and confirm each announces a sensible name; in the Approval state confirm "Approval required: Run multiplayer tests" is announced.
13. Activity Monitor: JARVIS should be ≈0–0.5% CPU when idle/HUDs closed (hotkey polling is tiny).

### V0.2 additions (text conversation + command router)
17. Full HUD → type `open the report` + Return: the Report section opens, the **Conversation panel** (Dashboard) records `YOU open the report` / `JARVIS Opening the report.`; the command field clears, keeps focus, and shows the last reply as one grey line.
18. Try `what are you doing?`, `pause the current task`, `resume`, `status`, `Jarvis, show me the tasks`, `raporu aç`, `görevleri göster`, `hello`, `thanks`, `clear conversation`. Replies must reflect the real demo task (title, step, paused/running). `pause` twice → “already paused” notice; with no task (after `stop`) → “no active task” notice.
19. `Explain quantum mechanics.` and `Fix my Unity multiplayer system.` → an amber notice saying no provider/worker is connected. **No fake answer, no state change.**
20. Compact HUD: type `what are you doing?` → one truncated reply line in the command field; the window stays exactly 392×448. Type `show tasks` → Compact disappears, Full HUD opens on Tasks (never both visible). Paste a very long text → still no resize.
21. Blank/space-only Return does nothing. 50 quick submissions keep order and never duplicate windows. The conversation should read like a command history, not a messenger — tell me if it is too dense, too small, or too chatty.
22. Offline check: disconnect from the network; everything above still works (nothing uses the network).

### V0.3 additions (real providers)
**Prerequisite:** be signed in with the vendor's own flow: `claude auth login` (Claude Code) and/or `codex login` (Codex ships inside the ChatGPT app). Settings → Intelligence provider shows each provider's real state (READY / SIGN-IN REQUIRED / NOT INSTALLED) and has a Refresh button. JARVIS never asks for keys or passwords.
26. Settings → Intelligence provider: both providers should read READY (with versions). Try Auto, Claude Code, Codex.
27. Full HUD: type `Explain what a neural network is.` → the Conversation badge shows **THINKING · <provider>** with **STOP GENERATION**, text appears (Claude Code token by token; Codex as a whole message), then the badge returns to `<PROVIDER> · READY`. The JARVIS state chip returns to Idle.
28. Copy a multi-line Swift function from another app, paste it into JARVIS (⌘V), type a new line (Shift+Return) `Explain this function.`, Return → the answer refers to your code. Then `Explain that more simply.` → context-aware follow-up.
29. Start a long answer (`Write a long essay about the history of computing.`) and press **STOP GENERATION** (or type `stop generating`): output stops within a second. In Terminal `pgrep -lx claude codex` must show no process started by JARVIS afterwards (the Claude desktop app has its own `claude` processes).
30. Settings: choose a provider that isn't READY (e.g. rename the path or sign out of one) and ask something → a clear message with the official sign-in command, **no silent fallback** to the other provider. Deterministic commands (`raporu aç`, `show tasks`, `pause the task`) must never start a provider (no THINKING badge).
31. From the Compact HUD ask a normal question → Compact closes, Full HUD opens, answer streams there. Compact stays 392×448.
32. Quit JARVIS while an answer is streaming → no `claude`/`codex` child process is left behind.
Note: each request uses a little of your subscription (Codex ≈14k input tokens per trivial request, Claude ≈5k); Claude Code's and Codex's usage limits are shared with your other use of them.

### V0.3.1 additions (infrastructure) — MANUAL TEST REQUIRED
Optional set-up for the local model: `scripts/setup_local_ai.sh` (needs `uv`; the model folder `~/AI/models/Qwen3.5-4B-MLX-4bit` must already exist — JARVIS never downloads models).
33. Settings → **Intelligence provider**: the picker now has Auto / Local / OpenCode Free / Claude Code / Codex. **Routing** shows the last decision and why. **OpenCode (verified-free models)** lists models that are free *by current price data*, with data-handling labels (ZERO-RETENTION / MAY TRAIN) and a Benchmark button; "Not eligible" shows every other model with the reason. **Local model** shows READY · UNLOADED, a Test button, measured speed/memory.
34. Click **Test local model** → `“JARVIS_LOCAL_OK” in ~2 s` (first use starts the worker by itself; nothing to start by hand). After the idle time (default 5 min) the status returns to READY · UNLOADED and the process disappears (`pgrep -fl jarvis_local_worker`).
35. Choose **Local** and type `Summarize in one sentence: …` → answered locally. Type `Explain this Swift function: …` → JARVIS explains that the local model is for lightweight tasks and sends nothing (no fallback).
36. Click **Benchmark** on one or two free models (13 small fixture prompts each, ~1 min) → results appear as `gen 3/3 · res 3/3 · cod 3/4 · tst 3/3`. In **Auto**, a coding/knowledge question now goes to a benchmarked free model (provider badge `OpenCode · <model>`), architecture/security questions go to Claude Code/Codex, small summaries go Local. The activity feed shows only meaningful events (escalation, cooldown, model loaded/unloaded).
37. **STOP GENERATION** while an OpenCode or local answer is running: it stops within a second; no `opencode` / worker process remains.
38. Quit JARVIS while the local model is loaded → no `jarvis_local_worker.py` process remains. After a force-quit (`kill -9`) the worker also exits by itself.
39. Data check: `sqlite3 ~/Library/Application\ Support/JARVIS/jarvis.sqlite "select agent_type, engine, model, status from agent_runs order by started_at desc limit 5"` shows your requests (engine/model/status/reason; no prompt text, no secrets).

### V0.8 additions (natural voice & presence) — MANUAL TEST REQUIRED
V0.8 is AUTOMATED TESTED and REAL TESTED with SYNTHETIC speech in a closed acoustic loop (`Jarvis --natural-voice-live-test`; wake word, VAD, endpointing, turn taking, barge-in, self-speech, neural voice, Push-to-Talk, approvals, resources, quit cleanup). Nothing below has been done by a person yet: **every item is MANUAL TEST REQUIRED**, subjective ones (voice naturalness, personality, latency feel, fatigue, battery) especially. Wake mode is OFF by default. Details: `docs/NATURAL_VOICE.md`.

224. Launch JARVIS (`build/Jarvis.app`, or `open build/Jarvis.app`). Install the optional natural-voice components first if you want them: `scripts/setup_voice_ai.sh --natural` then `scripts/train_wake_head.sh` (the wake head is trained locally on synthetic speech; neural voice + wake helper stay "not installed" without them and Push-to-Talk/Apple voice keep working).
225. Settings → Voice: Enable voice on, then turn **Wake word “Jarvis”** on. Confirm the status row says **LISTENING FOR "JARVIS"** (or an honest reason if not: microphone not allowed yet, helper not installed). The first time macOS may ask for the microphone — allow it.
226. Confirm full speech recognition is NOT running before the wake word: Activity Monitor shows no `Jarvis`-owned Whisper helper (`python … jarvis_stt_worker.py`) and the System panel says WAKE · LOCAL DETECTOR; only `jarvis_sentinel_worker.py` (≈ 125 MB) runs. Settings → developer controls → Voice diagnostics shows the same.
227. Confirm no raw recording is created: nothing new appears in `~/Library/Application Support/JARVIS` apart from `jarvis.sqlite*`, artefacts and logs (no `.wav/.caf/.m4a/.pcm`); `find ~/Library/Application\ Support/JARVIS -newer build/Jarvis.app -type f`.
228. Say “Jarvis” naturally (one short word, then a pause). Expect a short soft sound and the ATTENTIVE chip.
229. Confirm JARVIS woke (Compact/Full show ATTENTIVE; the status line “Go ahead — I’m listening.”).
230. Say it quietly (just above a whisper, a metre away). Note whether it wakes (JARVIS-V08-2: a very quiet voice may need repeating).
231. Say it quickly (“Jarvis!” as one syllable-ish).
232. Say it with a Turkish pronunciation (“Carvis”, “Jarvis” as a Turkish reader would).
233. Say similar non-wake words (“Service”, “Marvin”, “Harvest”, “Hey Travis”, “Çarşı”).
234. Confirm no false wake (a rare one is a documented limit, JARVIS-V08-1 — count them).
235. Play ordinary speech (a video, a podcast, people talking) for several minutes at normal volume.
236. Confirm no false wake during it; if one happens, note what was playing.
237. Make JARVIS say its own name (Settings → “Test English” says “Hello, I am Jarvis …”; or ask “who are you?”).
238. Confirm JARVIS does not wake itself (no ATTENTIVE chip, no sound afterwards).
239. Wake JARVIS (“Jarvis”).
240. Pause before speaking (2–3 s).
241. Confirm the ATTENTIVE state is shown and the Wake status stays honest.
242. Say nothing.
243. Confirm that after ≈ 7 s JARVIS returns to WAKE (no hidden listening; Voice diagnostics shows the transition) and that the recogniser helper never started.
244. Wake again.
245. Speak a Turkish command (“Jarvis, görevler ekranını aç”, “Jarvis, sistem durumunu söyle”).
246. Confirm the endpoint feels natural (JARVIS answers about 0.5–1 s after you finish; not while you are still speaking).
247. Confirm Turkish speech recognition (the message shows your sentence with the voice mark).
248. Confirm the Turkish response (spoken and shown are the same answer).
249. Evaluate the JARVIS Turkish voice naturalness (MANUAL TEST REQUIRED: pronunciation, rhythm, pauses, warmth).
250. Evaluate the voice personality (calm, composed, precise — not theatrical, not robotic).
251. Speak English (“Jarvis, open the Tasks screen.”).
252. Confirm English speech recognition.
253. Confirm the English response.
254. Evaluate the JARVIS English voice (MANUAL TEST REQUIRED).
255. Speak a mixed technical sentence (“Jarvis, BoxCollider değişikliğini kontrol et”, “Play Mode testlerini çalıştır”).
256. Confirm the technical terms (JARVIS-V08-7: mixed language is still the weakest case; note what was heard).
257. Ask with a mid-sentence hesitation (“Jarvis, Unity’deki … şey … son testlere bak”).
258. Confirm there is no premature endpoint (ONE message, not two).
259. Ask with a longer intentional pause (3 s of silence in the middle).
260. Observe the endpoint behaviour (a deliberate pause > 1.7 s is a new turn — by design).
261. Ask something that produces a long answer (“Jarvis, projeyi uzun uzun anlat”, with a provider connected, or Settings → “Test …”).
262. Interrupt immediately (start speaking within the first second).
263. Confirm JARVIS stops (≈ 0.3 s after you start; your sentence becomes the new turn).
264. Interrupt mid-answer.
265. Confirm it stops and the old answer does not resume.
266. Continue speaking your new request.
267. Confirm the new turn is captured, transcribed and answered.
268. Interrupt near the end of the answer.
269. Confirm no stale speech resumes afterwards.
270. Make keyboard noise while JARVIS speaks (type for 10 s).
271. Confirm no false barge-in.
272. Make small room noise (a chair, a cough, a glass).
273. Confirm no false barge-in (a cough or a clear word may; note it).
274. Test speaker echo (turn the Mac speakers up, then down; try headphones).
275. Confirm JARVIS does not transcribe itself (no message that quotes JARVIS’ own sentence). Note the volume at which your voice stops interrupting (JARVIS-V08-4).
276. Ask a follow-up WITHOUT “Jarvis” right after an answer.
277. Confirm the follow-up is accepted (ATTENTIVE window ≈ 8 s).
278. Wait past the attentive window (≈ 10 s).
279. Speak without the wake word.
280. Confirm it is ignored (no message, no recogniser, no answer).
281. Wake again.
282. Confirm the session returns normally.
283. Start a safe long-running task (a read-only analysis of a throw-away project, “Jarvis, analyze the multiplayer issue”).
284. Confirm the acknowledgement is spoken (“On it. I created the task …”).
285. Confirm the task continues after the voice turn closes (Tasks screen; JARVIS is back to WAKE; no spontaneous speech later).
286. Ask for the task status while the task runs (“Jarvis, what are you doing?”).
287. Confirm the answer (deterministic, short, spoken and shown).
288. Ask about the Unity state (“Jarvis, Unity durumu?”) with a Unity project selected.
289. Confirm the deterministic state path where possible (no provider call for state questions).
290. Create a safe pending approval (a throw-away project, a task whose plan deletes a file).
291. Say “approve”.
292. Confirm it is still pending (JARVIS says approvals are decided only with the HUD buttons).
293. Say “evet onayla”.
294. Confirm it is still pending.
295. Approve or deny ONLY with the HUD buttons.
296. Turn wake mode off (Settings, or the menu-bar item “Turn Wake Mode Off”).
297. Confirm the microphone is not listening: no orange microphone indicator, no `jarvis_sentinel_worker.py` process.
298. Confirm Push-to-Talk still works (hold right ⌥, speak, release).
299. Turn wake mode on again.
300. Test with the Compact HUD open.
301. Confirm it stays exactly 392 × 448 in WAKE, ATTENTIVE, LISTENING, SPEAKING and INTERRUPTED.
302. Test with the Full HUD open (the voice strip shows the state and the last latencies).
303. Test with no HUD open (menu bar only).
304. Test with JARVIS in the background (another app in front).
305. Test the menu-bar controls (right-click: Turn Wake Mode On/Off, Stop Speaking while speaking).
306. Test Reduce Motion (System Settings → Accessibility → Display): voice works identically; nothing animates.
307. Test VoiceOver: states are announced (Wake mode on, Listening, Interrupted); VAD transitions and partial transcripts are not.
308. Check that VoiceOver does not fight excessively with JARVIS’ own speech (JARVIS-V07-7 / V08-12; note how bad it is).
309. Preview the JARVIS voice (Settings → JARVIS voice → Hear it → Turkish / English).
310. Compare the Apple fallback (System Fallback → Hear it).
311. Compare the neural voice (JARVIS Default and JARVIS Calm).
312. Rate Turkish naturalness (1–5).
313. Rate English naturalness (1–5).
314. Rate mixed technical pronunciation (“BoxCollider”, “Play Mode”, “GameObject”).
315. Rate latency perception (wake → answer; interruption → reply).
316. Rate voice fatigue after 10 minutes of conversation.
317. Rate personality consistency across Turkish and English (one identity, or two different people?).
318. Trigger memory pressure if safely possible (open large apps) and watch Settings → Voice: “Using: …” falls back to the Apple voice.
319. Confirm graceful fallback (speech continues with the Apple voice, wake mode keeps listening).
320. Restore normal state (close the large apps).
321. Quit JARVIS while wake mode is on.
322. Confirm every helper exits (`pgrep -fl jarvis_` shows nothing).
323. Relaunch.
324. Confirm the wake preference is restored (only if you left it on) and the microphone permission is not asked again.
325. Confirm full STT is not active after relaunch (no recogniser helper until you speak).
326. Quit while JARVIS is speaking.
327. Confirm the audio stops at once.
328. Relaunch.
329. Confirm no stale speech (nothing is spoken at launch).
330. Inspect Application Support (`~/Library/Application Support/JARVIS`).
331. Confirm no microphone recording exists there.
332. Inspect SQLite (`sqlite3 …/jarvis.sqlite .schema`).
333. Confirm no audio blob / waveform / partial-transcript column exists.
334. Run wake mode for an extended idle period (≥ 1 hour in a quiet room).
335. Confirm no phantom wake or turn (Activity feed shows no “Wake word heard”).
336. Observe CPU (Activity Monitor: JARVIS ≈ 0 %; the sentinel ≈ 0 % in a quiet room).
337. Observe memory (sentinel ≈ 125 MB; no growth over the hour).
338. Test on battery if practical.
339. Record the subjective battery impact (Activity Monitor → Energy).
340. Test physical distance (0.5 m, 1 m, 2 m, across the room).
341. Test faster speech.
342. Test softer speech.
343. Test normal room noise (fan, music at low volume, a second person talking).

### V0.7 additions (voice I/O) — MANUAL TEST REQUIRED
Developer-only: `build/Jarvis.app/Contents/MacOS/Jarvis --voice-live-test` (silent REAL test with synthetic speech; add `--voice-audible` to hear it, `--voice-real-mic` to open the real microphone for 1.5 s). Optional better recogniser: `scripts/setup_voice_ai.sh`. Automated runs never open the microphone.
154. Settings → **Voice** → turn **Enable voice (Push-to-Talk)** on (it is off by default). Relaunch JARVIS with Voice enabled.
155. Confirm the microphone is NOT active: the macOS menu bar shows no orange microphone dot, `Activity Monitor` shows no `Jarvis` audio use, the System panel says Voice READY · PUSH-TO-TALK, JARVIS state is Idle.
156. Open Settings → Voice. Confirm the **Shortcut** row (hold right ⌥), the microphone row (NOT ASKED YET / ALLOWED / DENIED) and the explanation text.
157. Confirm the **Speech recogniser** list: Whisper (local, MLX) and Apple Speech (on-device) each with READY / SETUP NEEDED and cost class LOCAL / SYSTEM; the line “Using: …” says which one Auto picks and why. (Whisper needs `scripts/setup_voice_ai.sh` once.)
158. Confirm the **TTS** side: Turkish voice and English voice pickers list only voices that really are installed (Yelda, Samantha, …); “Test Turkish” / “Test English” speak a short phrase; “Stop” silences it.
159. Confirm the **Recognition language** setting (Auto / Turkish / English) and its explanation (Whisper detects Turkish/English; Apple cannot, so Auto then uses your system language).
160. Choose voices and the speech rate; the choice persists after relaunch.
161. With another app (or JARVIS) in front, **hold the right ⌥ key alone** for about a second. macOS asks for **microphone** access — the first time only.
162. Allow it. Confirm nothing else is requested (no Accessibility, no Speech Recognition prompt).
163. Hold the right ⌥ again: after ≈0.25 s the microphone opens and JARVIS shows **LISTENING** (menu-bar glyph, Compact/Full state chip, the red mic chip).
164. The LISTENING indication is unmistakable without colour (icon + word); with Compact open the command field shows “Listening…”; with Full open the Conversation panel shows a voice strip with a small level bar.
165. Say a Turkish sentence while holding, e.g. “Jarvis, Unity'deki son task'ın durumunu göster.”
166. While speaking: a provisional transcript appears (Apple: updates continuously; Whisper: a preview about every 1.2 s after the first second). It may change; it is never added as a message.
167. Release the key. The **LISTENING indication stops immediately** and the macOS microphone dot disappears (before the transcript is even ready).
168. Exactly ONE user message appears (with a small mic mark) — the final transcript; no partial messages are left behind.
169. Judge the Turkish transcript: diacritics (ç ğ ı ö ş ü İ) preserved, “Unity”, “task”, “Play Mode”, “Console”, “BoxCollider” recognised?
170. Settings → Speech recogniser: choose **Apple Speech**, then **Whisper**, and repeat a Turkish sentence with each. An explicit choice never falls back — if one is not ready JARVIS says why. Tell me which is more accurate/faster for your voice.
171. JARVIS answers in the Conversation panel AND aloud (Turkish answer, Turkish voice).
172. The spoken answer says the same thing as the text (no extra or contradictory content; markdown/code is not read literally).
173. Turn **Speak responses to voice requests** off: voice requests get text-only answers; turn it on again: spoken again.
174. Hold the key and say an English sentence, e.g. “Jarvis, run the EditMode tests.” Confirm recognition and an English reply spoken with the English voice.
175. Say a mixed sentence, e.g. “Jarvis, BoxCollider değişikliğini kontrol et and run the relevant test.” Note what was heard (mixed speech is the hardest case — try Recognition language = Turkish / English / Auto and tell me which works best).
176. Check the semantics: even if words are wrong, is the command still recognisable? (The approval policy protects you either way.)
177. Test **Push-to-Talk with JARVIS in the background** (another app in front): works the same.
178. Test with the **Compact HUD** open: the transcript replaces the placeholder in the command field; Compact stays exactly 392×448.
179. Test with the **Full HUD** open: voice strip in the Conversation panel; the answer appears there.
180. Test with **no HUD open**: LISTENING shows in the menu-bar glyph; the answer is spoken (and visible when you open a HUD).
181. Say a deterministic command: “Jarvis, görevler ekranını aç” / “Jarvis, open the Tasks screen”. The Tasks screen opens (Compact closes), a short reply is spoken.
182. Confirm no heavy provider was started for it (Agents section: no new run; no `claude`/`codex`/`opencode` process) — deterministic commands use the same fast path as typing.
183. Say a safe task goal with a project folder chosen in Settings: “Jarvis, analyze the test project.”
184. Confirm a normal V0.4 task appears (Tasks screen; `sqlite3 ~/Library/Application\ Support/JARVIS/jarvis.sqlite "select title, origin, input_channel from tasks order by created_at desc limit 3"` shows origin userTask, input_channel voice) and JARVIS speaks only a short acknowledgement while the task keeps running.
185. Confirm voice did not bypass anything: capabilities, workspace guard, approvals and validation are exactly as for a typed goal.
186. Ask for something that needs approval (e.g. a task whose goal asks to delete a file) — the approval card appears in the HUD.
187. Confirm JARVIS only says that the approval is needed in the HUD (or nothing) — it does not approve.
188. While the approval is pending say “approve” / “evet, onayla” / “yes, do it”.
189. Confirm **nothing is approved**: JARVIS replies that approvals are decided only with the HUD buttons; the card is still waiting (typing “approve” behaves the same).
190. Deny it with the **HUD button**; confirm the task ends as denied.
191. Ask something with a long answer by voice (e.g. “explain how the task engine validates a plan in detail”).
192. Confirm **bounded speech**: only the first few sentences (about half a minute at most) are read, then “The full answer is on screen.”; code blocks/tables are never read out; the full text is in the panel.
193. While JARVIS is speaking press **Stop Speaking** (Compact stop button, Full HUD “STOP SPEAKING”, or the menu-bar item). Confirm it stops at once.
194. Confirm no later phrase of that answer plays afterwards.
195. While JARVIS is speaking, hold the right ⌥ again: speech stops first, then LISTENING starts (an explicit stop — NOT barge-in; JARVIS never listens while it speaks).
196. Press and release the key rapidly twice (and tap it very briefly): nothing weird happens — no stuck LISTENING, no duplicate message, no old transcript.
197. Confirm a recording shorter than about a third of a second is discarded with a short notice, and that a second press while the previous transcript is still being finalised is simply ignored.
198. Deny microphone access (System Settings → Privacy & Security → Microphone → JARVIS off), hold the key.
199. Confirm a clear explanation (no endless prompts, System Settings does not open by itself, the “Open System Settings” button is explicit) and that typing/commands still work.
200. Re-enable the permission. While listening, **unplug/disconnect the microphone** (or switch the input device) if practical.
201. Confirm graceful recovery: the session ends with a message, no stuck LISTENING/SPEAKING, and the next press works.
202. Judge Turkish TTS quality (naturalness, speed, pronunciation of Unity/Play Mode/BoxCollider). Compact voices are what is installed by default — try Spoken Content premium voices if you want better.
203. Judge English TTS quality the same way.
204. Judge mixed-language pronunciation (Turkish voice reading English words and vice-versa).
205. Judge volume and speech rate (Settings → Speech rate); tell me whether the default is comfortable over a longer session (fatigue).
206. With **VoiceOver** on: states are announced as words (Listening / Transcribing / Speaking / microphone denied), the Stop Speaking button has a label. Tell me if spoken replies and VoiceOver overlap badly.
207. Confirm VoiceOver does not announce every partial transcript update.
208. With **Reduce Motion** on (or Settings → Reduce Motion): the voice strip level bar is static; nothing animates; voice is fully usable.
209. Confirm the Compact HUD is **exactly 392×448** in every voice state (Listening, Transcribing, Thinking, Speaking, error).
210. Confirm Compact/Full HUD **exclusivity** still holds while voice is active.
211. Quit JARVIS (⌘Q) **while it is speaking** and again while the Whisper helper is loaded.
212. Confirm playback stops at once and `pgrep -fl jarvis_stt_worker` shows nothing (the helper dies with JARVIS).
213. Relaunch JARVIS.
214. Confirm the voice state is **IDLE** (never LISTENING/SPEAKING restored) and the microphone is not active.
215. Confirm no raw recording exists: `find ~/Library/Application\ Support/JARVIS ~/AI \( -iname '*.wav' -o -iname '*.caf' -o -iname '*.m4a' \)` finds nothing, and the SQLite files contain no audio.
216. Optional: in a Unity project fixture (or a safe read-only project) ask by voice: “Unity bağlı mı?”
217. Confirm a state answer without a heavy coder: the reply comes from JARVIS' real Unity state (connected / not connected) and no provider run is started for it.
218. Ask by voice for the task status: “Son task çalışıyor mu?” / “what are you doing?” Confirm a truthful, state-based answer.
219. Open the Agents section and Activity: confirm only short voice lines (Voice: listening · transcript submitted (N characters) · first audio N ms · helper loaded/unloaded) and no transcript text or audio anywhere.
220. Settings → Show Developer Controls → Voice diagnostics: last-turn latencies (STT start / first partial / finalisation, text→TTS, TTS→audio, release→audio) look plausible; helper memory is shown separately from JARVIS' own.
221. Memory: Activity Monitor — JARVIS stays small (≈100–160 MB); the Whisper helper ≈0.9 GB only while loaded and disappears after ≈2 minutes idle (or when memory is tight); Apple's speech services are separate system processes.
222. Idle: with Voice enabled and nothing happening, JARVIS shows ≈0 % CPU and no audio use (no polling, no always-on microphone).
223. Tell me whether the right-Option shortcut feels right (too easy to trigger by accident? hard to reach?), whether the 0.25 s hold is good, and report anything odd (I add it to `docs/KNOWN_ISSUES.md`).

### V0.6 additions (Unity Project Agent) — MANUAL TEST REQUIRED
**Prepare:** `docs/UNITY_PROJECT_AGENT.md`. Unity 6000.5.1f1 (or the version your fixture declares) must be installed via Unity Hub and signed in. **Use the disposable fixture, never your real game first:** `cp -R UnityBridge/Fixture ~/Desktop/JarvisFixture` (+ optionally `git init` and commit there). JARVIS starts its own headless editor for it (first open imports the project: allow a minute or two); you may also open the folder in Unity yourself first — JARVIS then connects to YOUR editor after you approve the bridge install.
126. Full HUD → TASKS → **CHOOSE FOLDER…** → the fixture folder. A **UNITY** line appears with `Unity 6000.5.1f1 · Built-in`, "JARVIS bridge not installed (asked first)" and the state **AVAILABLE** (not CONNECTED: only discovery happened).
127. Confirm the declared version matches the editor Unity Hub shows for the project; set the folder's `ProjectSettings/ProjectVersion.txt` to an uninstalled version (on a copy!) and run any Unity task → JARVIS asks *"Open this project with Unity X (it declares Y)…"* and does nothing until you approve (deny ⇒ task fails, nothing launched).
128. Type `Inspect why TestCube has no collider` → JARVIS asks to **install the JARVIS Unity Editor bridge** (approve). The task plans (unityInspect → …), the UNITY line turns **CONNECTING** then **CONNECTED**, the task completes. In Finder: `Packages/com.jarvis.bridge/` exists and `Packages/manifest.json` is unchanged.
129. In the finished task card (expand it) read the Unity steps' evidence: scenes, TestCube found once, components, CounterObject `startValue=1`, compile OK, Play Mode edit. Nothing changed in the project (`git status` clean apart from Unity's own `.meta`/lock files).
130. Run `Add a BoxCollider to TestCube if it does not have one` → completes; open the scene in Unity (or `grep BoxCollider Assets/Scenes/FixtureScene.unity`): exactly **one** BoxCollider; the scene was saved; nothing else changed.
131. Run the same request again → completes, still **one** BoxCollider (idempotent). In Unity: Edit → Undo history shows JARVIS' operation if the editor has a window (headless editors have none).
132. Run `Set CounterObject startValue from 1 to 5` → `Counter.startValue` is 5 in the scene file; running it again is a no-op; asking for a change "from 1 to 7" now fails (the old value is not 1) and changes nothing.
133. Break a script (add a syntax error to `Assets/Scripts/Calculator.cs` and commit) → `Fix the Unity compile error` → JARVIS reads Unity's compiler error, a **real provider** (Agents → engine/model named, never Local Qwen) edits the script through the normal file path, **Unity compiles** and the step says `Unity compile: PASS`.
134. Make `Calculator.Add` return `a - b` (commit) → `Fix the failing Unity test` → provider fix, Unity recompiles, **the exact EditMode tests run again** and pass (`EditMode 2/2 passed · scope: …`); a review that merely dislikes the code does not fail the task (report shows "Reviewer advice").
135. `Run the Unity tests and tell me what failed` on a project with a failing test → failure text names the failing test and its message (sanitized); no invented counts.
136. `Enter Play Mode and verify CounterObject starts correctly` → the UNITY line shows **PLAY MODE** only while the editor is really playing, then back to **CONNECTED**; the step evidence says entered (confirmed) … left (confirmed).
137. While Play Mode is active (start it yourself in a windowed editor, or during a long task) ask JARVIS to change the scene or a script → refused ("not allowed while Play Mode is active"), nothing changed; after leaving Play Mode the same request works.
138. Add `ErrorEmitter` to an object and play (task: `Create an ErrorHost object that logs an error in Play Mode and play the scene`) → the task FAILS naming **1 new Console error**; the synthetic `api_key`/`password` text in it is shown as `[REDACTED]` everywhere (task card, Agents console, `sqlite3 …jarvis.sqlite "select validation_evidence from task_steps"`).
139. Log an old error in the editor before the task → the report counts only errors **new** to the task ("repeat of an error that existed before" is shown separately).
140. In a windowed editor change something in the open scene and do NOT save. Ask JARVIS to modify that scene → **approval card** "Modify Unity scene with your unsaved changes". DENY ⇒ nothing modified/saved, your change still unsaved. Repeat and APPROVE ⇒ JARVIS applies its change and saves the scene (your approved edit included).
141. Duplicate-name test: ask `Create two GameObjects named Twin`, then `Add a Rigidbody to Twin` → JARVIS does **not** pick one: the task fails as ambiguous and lists `Twin#0`, `Twin#1`; `Add a Rigidbody to Twin#1` changes only the second.
142. Change a script in the project (add a comment) and run `Compile the Unity project` → compile PASS with "domain reloaded"; the UNITY line goes BUSY and back; the next task still works (objects are re-resolved).
143. Start a long task (`Play the scene for a long time`) and press **STOP** → STOPPED within seconds, Play Mode left, `Packages`/spool untouched, report written; Activity Monitor: no leftover Unity process of JARVIS' own after **CLOSE EDITOR** (UNITY line button).
144. Quit JARVIS (⌘Q) while a Unity task runs and relaunch → the task is **INTERRUPTED** (not running); the UNITY line reconnects to a still-running editor you opened yourself; RESUME works; a Play Mode left over in an editor JARVIS started is reset, one in your own editor is not touched.
145. `Delete TestCube` (goal asks for it) → **approval card** "Delete Unity object TestCube…". DENY ⇒ the object remains. Repeat and APPROVE ⇒ exactly that object is removed and the scene saved. Ask `Tidy the scene` (no deletion requested) with a plan that deletes → refused.
146. Ask a design question in a finished task's review (e.g. suggestions about lighting) → shows as a **SUGGESTION** (proposal) in Tasks, never started automatically in any autonomy mode; "Purchase this asset" is a CRITICAL card that cannot be executed.
147. Open Settings/Tasks and confirm nothing offers: running C#, menu items, shell, package install, Asset Store, uploads, git push.
148. Tasks → expand a finished Unity task: UNITY section says **Visual validation: not performed**; the report (Report artifact / `…/artifacts/reports/*.md`) lists Unity facts and never says "looks correct".
149. Agents screen: each Unity step is a **tool run** `UnityTool` (task-grouped, console events like "Applied: add BoxCollider to TestCube"), provider runs (planner, analysis, coding, UnityAgent) show their real engine/model; no fake provider cards for tools.
150. **Compact HUD stays 392×448** during a Unity task and shows only a short phrase (`… · Unity · Compiling` / `Testing` / `Play Mode`); no hierarchy or Console in Compact; Compact ⇄ Full exclusivity unchanged.
151. **VoiceOver**: the UNITY line reads "Unity editor: connected"; CLOSE EDITOR announces its target; approvals read their action. **Reduce Motion**: nothing new animates.
152. Resources: Activity Monitor — JARVIS ≈0 % CPU with Unity connected and idle (JARVIS has no polling loop); Unity's own CPU/RAM (≈0.4 GB for the editor process, ≈2 GB including its compiler/package helper processes, headless fixture) is Unity's, not JARVIS'; provider processes appear only while a provider step runs.
153. Report anything odd (I add it to `docs/KNOWN_ISSUES.md`). **Only after the fixture behaves** connect your real game **read-only** first (choose its folder, run `Inspect …`); do **not** let JARVIS mutate it until you submit a scoped task intentionally.

### V0.5 additions (proactive reasoning & approval policy) — MANUAL TEST REQUIRED
**Prepare:** `docs/PROACTIVE_REASONING.md`. Use a **throw-away Git project** (small, with a `calc.py`). Default mode is **Ask Before Acting**. Developer helper: `build/Jarvis.app/Contents/MacOS/Jarvis --no-providers --open-full --section tasks --demo-proposals` (scripted demo task that leaves one normal and one critical suggestion; uses a temporary data directory).
92. Settings → **Autonomy**: three modes (Observe Only / Ask Before Acting / Low-Risk Autonomous) with explanations; **Ask Before Acting** is selected on a fresh install; toggles for proactive reasoning and showing proposals.
93. Tasks → run a normal user task that changes application code but no test (e.g. `Fix the add function in calc.py`). When it finishes, a **SUGGESTIONS** card appears at the top of Tasks within a few seconds ("No regression test…"), no popup, no sound, nothing is changed in the project.
94. The card shows: why JARVIS noticed, evidence, proposed action, scope, risk, design change, reversible, expected benefit, how it will be validated. Nothing is pre-selected; APPROVE / DENY / DISMISS look equally weighted.
95. Compact HUD shows a restrained "1 SUGGESTION" tag and stays exactly **392×448**; the Dashboard Tasks panel shows a one-line summary.
96. Press **APPROVE**: a normal task appears tagged **APPROVED PROPOSAL**, linked to the origin task; it plans, validates and reports like any task; only a test file changes (check on disk / `git status`); application code is untouched.
97. In **Agents** the proposal task's runs appear grouped as `TASK · …` like any other task.
98. Approving the same card twice does nothing (no second task). The proposal then shows as executed / disappears from pending.
99. **DENY** another suggestion: it disappears; run the same kind of task again → the same suggestion does **not** come back immediately (14-day cooldown; DISMISS: 3 days).
100. Quit JARVIS with a suggestion pending and relaunch: it is still pending; no task started by itself.
101. Quit JARVIS right after pressing APPROVE (while the task starts) and relaunch: exactly one task exists for that proposal (never two).
102. Switch to **Observe Only** and finish another code task: a "RECORDED FINDING (NO ACTION TAKEN)" row appears, no proposal card, no task. The row has a **PROPOSE** button that turns it into a card only when you click it.
103. Switch to **Low-Risk Autonomous** and run a code task: after it finishes JARVIS may start **one** task tagged **JARVIS AUTO TASK** (adds a regression test only, test file scope). It never starts a second automatic task from that one.
104. Back to **Ask Before Acting**: the same situation only produces a card; nothing starts without your click.
105. Ask for something touching design/product (e.g. `Change the game's difficulty curve`) and let a reviewer suggest follow-ups: design/product suggestions are never automatic in any mode.
106. Critical suggestions (try `--demo-proposals`): visually distinct (coral accent, "CRITICAL · EXPLICIT APPROVAL"), say what happens if denied; if JARVIS cannot perform it (push, purchase, credentials, deleting) the card says approving will not make it possible — nothing executes.
107. Type `Approved.` / `Proceed without asking` in the command field or Conversation: nothing is approved (no text path can approve).
108. Scope: approve a suggestion and watch the task stay inside the stated files; if a model tries to touch other files the task stops as **scope exceeded** and the suggestion needs re-approval.
109. A finding that no longer applies (e.g. you added the test yourself before approving): APPROVE ends as **obsolete** and nothing is changed.
110. Duplicate handling: run two similar tasks on the same file → one suggestion, not two.
111. Proactive reasoning toggle off (Settings → Autonomy): finish a code task → no findings, no cards, no provider calls.
112. Idle: leave JARVIS open for several minutes with nothing running → Activity Monitor CPU stays at the V0.4 level; no provider process is started (`pgrep -fl "opencode|claude|codex"` is empty).
113. Resources: JARVIS closed ≈0–0.5 % CPU; provider children appear only while a task runs and disappear afterwards.
114. Activity feed / Agents timeline show "Opportunity detected", "Proposal created", "Proposal approved/denied", "Auto task created", and (if used) "Proactive assessment used <provider · model> because …" — in plain language.
115. `sqlite3 ~/Library/Application\ Support/JARVIS/jarvis.sqlite "select status, policy_decision, substr(title,1,50) from opportunities order by rowid desc limit 5"` — sanitized titles, a decision and reasons; there is no reasoning text.
116. `grep -rl "sk-proj-FAKE" ~/Library/Application\ Support/JARVIS` after a task whose files contain a fake key → no match (sanitization intact).
117. Project boundary: finish tasks in two different projects → suggestions mention their own project; approving one never edits the other.
118. **Compact ⇄ Full** exclusivity and 392×448 still hold with suggestions pending; ⌥⌘ toggles correctly.
119. **Clipboard** (V0.2.1) still works in both command fields (⌘V/⌘C/⌘A/⌘Z).
120. **VoiceOver:** suggestion cards read "Suggestion: title. Risk low."; critical ones read "Critical approval needed…"; buttons announce their target; state is never colour-only.
121. **Reduce Motion:** no animation in the suggestions group; expanding the recorded-findings list is instant.
122. Say `show suggestions` (also `proposals`; Turkish `öneriler`) → Full HUD opens on Tasks.
123. Deterministic commands still create no provider run; autonomous goals still become V0.4 tasks (not proposals).
124. Provider mode: set Settings → Intelligence provider → Claude Code and approve a proposal: only that provider is used; no silent fallback; no paid API.
125. Tell me whether the suggestion wording is clear, whether Ask Before Acting is too chatty/quiet, whether Low-Risk Autonomous feels safe, and report anything odd (I add it to `docs/KNOWN_ISSUES.md`).

### V0.4 additions (autonomous task engine) — MANUAL TEST REQUIRED
**Prepare:** `docs/AUTONOMOUS_TASK_ENGINE.md` explains the rules. Use a **throw-away project** (a copy of a small repo, or a folder with a failing test) — never your only copy. JARVIS edits files in the chosen folder (never commits/pushes), runs the project's own build/test commands, and waits for your approval before deleting anything or touching files that already have your uncommitted changes. Provider usage: Auto prefers a verified-free OpenCode model, then Claude Code/Codex.
67. Full HUD → **TASKS**. The **Project** card: click **CHOOSE FOLDER…**, pick your throw-away project. It shows the discovered build/test commands (or "none found"). *(macOS may show its own "Files and Folders" prompt for Desktop/Documents/Downloads — that is the system, not JARVIS.)*
68. In the command field type a bounded goal, e.g. `Fix the failing test in calc.py` (or Turkish: `calc.py içindeki başarısız testi düzelt`). JARVIS replies "On it. I created the task …" **within a second** — the task is created before work starts. Try also `Analyze the multiplayer issue` (read-only task) and `Explain NetworkPlayer` (a normal answer, **no** task).
69. **TASKS** shows the task under ACTIVE with the activity ("Planning…"), then its **plan**: click the card to expand — numbered steps with type, "validates: …", dependencies, state. Steps turn PASSED one by one; analysis/coding/review steps show evidence lines; test steps show real commands, exit codes and counts.
70. **AGENTS**: the task's runs appear grouped as `TASK · <title>` — PlannerAgent, AnalysisAgent, CodingAgent, TestTool, ReviewAgent — with provider/model, state, elapsed, console and timeline. Click a run → live console (sanitized, read-only); TestTool consoles show the real test output.
71. **Progress:** the bar/percentage equals *validated steps / steps* (e.g. `2 of 5 steps validated · 40 %`). Before the plan exists there is no percentage. Nothing a model writes ("90 % done") ever changes it.
72. Close the Full HUD (ESC) while the task runs → the task **keeps running** (menu bar icon keeps its working state). Reopen it (⌥⌘ or menu bar) → the same task, same state. The Compact card shows title, `STEP n/m`, `k of m validated · NN %`, `· 1 agent`; **PAUSE is disabled** (autonomous tasks can't be paused), STOP works.
73. When it finishes: the Conversation panel gets a concise summary with only facts (`5/5 steps validated`, files changed, `Tests: … exit 0 · N tests, N passed`, which provider did what). Check the file on disk and run the project's tests yourself.
74. **STOP:** start another task, press **STOP** on its card (or Compact STOP, or type `stop`). It ends as STOPPED within seconds. In Terminal: `pgrep -fl "opencode|claude|codex|python3"` shows nothing started by JARVIS; the Tasks card says what was stopped; no file lease remains.
75. **Restart recovery:** start a task, quit JARVIS (⌘Q or `kill`) while it runs, relaunch → the task appears under NEEDS YOUR ATTENTION as **INTERRUPTED** (not RUNNING, not lost). Completed steps keep PASSED. Press **RESUME** → it continues from the saved state; finished steps are not redone.
76. **Approval:** with a file `old/legacy.py` in the project type `Delete the file old/legacy.py from the project`. The task stops at **AWAITING APPROVAL** with the exact action; the Full HUD shows the approval card and the Tasks card has APPROVE/DENY. Nothing is deleted until you approve. Quit & relaunch while waiting → it is still waiting.
77. **Denied approval:** repeat and press **DENY** → the task ends FAILED ("approval denied"), the file is intact.
78. **Dirty workspace:** in a Git project edit `calc.py` (leave it uncommitted), then ask JARVIS to fix something in `calc.py`. It must **ask before touching that file**; if you deny, your edit is unchanged; if you approve, your change survives next to the fix. `git status`/`git log` afterwards: JARVIS made **no commit** and no reset/clean.
79. **Failure honesty:** ask for something impossible (e.g. fix a test that cannot be fixed by editing `calc.py`). The task fails with the real failure output, after at most one repair and one escalation; the report says what failed and suggests the next step. Nothing claims success.
80. **History/report:** the finished card shows the summary; expand for the plan, per-step evidence, workspace, Git baseline. The report/checkpoint files are under `~/Library/Application Support/JARVIS/artifacts/{reports,checkpoints}`.
81. **Compact stays 392×448** with a task running/waiting/interrupted (no jump, no clipping).
82. **Exclusivity:** with a task running, `show tasks` from Compact opens the Full HUD on Tasks and closes Compact; ⌥⌘ toggles back; never both visible.
83. **Clipboard** (V0.2.1) still works in both command fields (⌘V/⌘C/⌘A/⌘Z).
84. **VoiceOver:** task cards read "title, state, N of M steps validated"; steps read "Step n: title, state"; APPROVE/DENY/STOP/RESUME announce their target; state is never colour-only.
85. **Reduce Motion:** no animation in the Tasks screen; progress still updates.
86. **Resources:** Activity Monitor — JARVIS ≈0–0.5 % closed; ≈2 % with a parked task (menu-bar icon animation, as in V0.1.1); the provider child processes (opencode/claude) are separate and disappear when the task ends.
87. **Sleep/wake:** start a long task, close the lid / sleep for a minute, wake → elapsed time did not count the sleep; the task state is re-evaluated (it may fail with a provider timeout rather than pretend).
88. **Security spot-check:** `grep -r "sk-" ~/Library/Application\ Support/JARVIS/artifacts` after asking a task to touch a file containing a fake key → nothing; a file named `.env` is never read or edited by a task.
89. **Limits:** try a goal with no project chosen → "need a project folder"; try two goals at once (a third is refused while two are active).
90. **Switch provider mode** (Settings → Intelligence provider → Claude Code) and run a task: only that provider is used; if it fails there is no fallback and no escalation.
91. Tell me whether the Tasks screen/plan view is too dense, whether 3 repair attempts per code step feels right, and report anything odd (I add it to `docs/KNOWN_ISSUES.md`).

### V0.3.2 additions (agent observatory) — MANUAL TEST REQUIRED
Developer-only helpers: `build/Jarvis.app/Contents/MacOS/Jarvis --open-full --section agents --demo-agents` (labelled SIMULATED, never saved). The console is **read-only sanitized output** — it is not a terminal.
40. Full HUD → top bar **AGENTS** (or type `show agents` / `ajanları aç`): four provider cards (Claude Code, Codex, OpenCode, Local Qwen), each with a truthful state (READY, NOT INSTALLED, SIGN-IN REQUIRED, UNLOADED …) and, if it ran before, its last run.
41. Ask a question (Full HUD, Local or Auto): while it answers, the provider card shows **RUNNING** (Local Qwen: first STARTING while it loads, then RUNNING, afterwards LOADED · IDLE — never RUNNING when idle). An active-run card appears with its elapsed time and STOP.
42. Select the run → **Overview / Console / Timeline**. The console shows the same answer being produced (Claude token by token; Codex/OpenCode when the message arrives), plus start/finish events. Nothing is typed there; there is no input field by design.
43. Select console text with the mouse and press **⌘C**, paste it in another app; click **Copy all** likewise. Confirm no secret/key text ever appears (try asking the model to repeat `sk-proj-FAKE0123456789abcdefghijklmnopqrstuvwx` — it must show a redaction marker).
44. Progress: real runs show an indeterminate bar + elapsed time and "no measurable steps" — **never a percentage**. (`--demo-agents` shows a 0/5-step planner as an example of a real step bar.)
45. Press **STOP** on a run (card or detail) while a long answer streams: it ends within about a second, the run reads CANCELLED, `pgrep -fl "claude|codex|opencode|jarvis_local_worker"` shows nothing started by JARVIS.
46. **History** tab: previous runs, newest first, with status/engine/model/duration; filter by engine/status/text; "Load more" paginates. **Timeline** tab: provider start/finish, cancels, escalations, cooldowns — only meaningful events.
47. Quit JARVIS (⌘Q or `kill`) while a run is active, relaunch → that run appears as **INTERRUPTED** with the reason "JARVIS was closed while this run was active"; not RUNNING, not lost.
48. Compact HUD stays exactly **392×448**. While something runs it shows one extra line "AGENTS · n ACTIVE · provider · agent · activity"; with nothing running the line is absent. Clicking Open Jarvis still switches to the Full HUD (never both visible).
49. Native clipboard still works: ⌘V/⌘C/⌘A in both command fields (V0.2.1 items 23–25).
50. Accessibility: with VoiceOver, cards/runs/STOP/tabs announce their names and states in words (state is never colour-only); with **Reduce Motion** no animation runs in the Agents section.
51. Activity Monitor: JARVIS closed ≈0–0.5 % CPU; Compact ≈0.3–1 %; Full HUD on Agents without runs ≈1–2 %; the console never grows memory without bound during a long answer.
52. Settings → Show Developer Controls: **SIMULATE** menu in Agents offers demo runs/stress, every item labelled SIMULATED; simulated runs never appear in History after restart.
53. Local Qwen: after the idle time the card returns to **UNLOADED** and the worker process disappears.
54. OpenCode: a run shows the real model name (e.g. `opencode/…-free`); the card's state returns to READY afterwards.
55. A failed/rate-limited provider shows FAILED/RATE LIMITED with a reason and the History row keeps the failure reason (no raw provider text).
56. Open the Agents section with 20+ historical runs and scroll: no jank, no clipped text at the minimum window size (980×620).
57. Check `sqlite3 ~/Library/Application\ Support/JARVIS/jarvis.sqlite "select kind, substr(summary,1,60) from agent_events order by id desc limit 5"` — sanitized summaries only.
58. Check `grep -rl "sk-proj-FAKE" ~/Library/Application\ Support/JARVIS` after step 43 → no match in the database or artifacts (the prompt itself is stored only as hash/length/redacted excerpt).
59. Ask a coding question in Auto: the run card shows the engine/model the router chose and the History row carries its reason.
60. Deterministic commands (`show tasks`, `raporu aç`) create no run and no provider process.
61. A worker request (`Fix my Unity multiplayer system`) still says autonomous work is not enabled — nothing starts.
62. Switch Compact ⇄ Full repeatedly while a run streams: no duplicate windows, console keeps its text.
63. Keep the Agents section open for several minutes during a long answer: UI stays responsive, console tail follows, scroll position does not jump when you scroll up to read.
64. Offline: everything local (Qwen) still observable; JARVIS contacts no host itself.
65. Tell me whether the Agents layout is too dense/too sparse and whether Overview/Console/Timeline is the right split.
66. Report anything odd; I'll add it to `docs/KNOWN_ISSUES.md`.

### V0.2.1 additions (native text editing)
23. In another app copy some text (try multiline code or a log with Turkish characters) → open JARVIS → ⌘V pastes it in **both** the Compact and Full command inputs. ⌘A/⌘C/⌘X/⌘Z/⇧⌘Z and right-click → Paste/Copy also work. Test after opening JARVIS with the **⌥⌘ / ⌥⌘⌘ shortcut while another app is frontmost** — you must be able to type/paste immediately without clicking first.
24. Pasting several lines must NOT submit; **Return** submits, **Shift+Return** (or Option+Return) adds a line. A pasted trailing newline does not submit. In the Full HUD the input grows up to 6 lines then scrolls; in Compact it stays one line (scrolls) and the window stays exactly 392×448 even for a 100-line paste.
25. Compact → Full and Full → Compact: typing always goes to the visible one.

### V0.1.1 additions
- **HUD exclusivity:** only one HUD is ever visible. Full open → click the menu-bar icon or press ⌥⌘ → Full closes, Compact opens. Compact open → OPEN JARVIS or ⌥⌘⌘ → Compact closes, Full opens. Never both.
14. **Compact HUD fixed size:** open the Compact HUD and click through all seven state chips (Idle, Listening, Thinking, Working, Approval, Complete, Error), also after STOP (no active task) and with Settings → Show Developer Controls off. The outer window's **width and height and position must never change** (no jump, no clipping); only the inside crossfades quickly. Turn on Settings → Reduce Motion: the crossfade disappears.
15. **Global shortcuts (from Finder or another app, not JARVIS):** press **⌥⌘** (Option held, tap Command) → Compact HUD opens; again → it closes. Press **⌥⌘⌘** (Option held, tap Command twice quickly) → the **Full HUD opens directly — the Compact HUD must not flash first**; again → it closes (or comes forward if it was behind another window). Holding the keys down must not open duplicate windows or flicker. Try ⌥⌘D (Dock hide) / ⌥⌘-click: JARVIS must not react. Is 0.3 s comfortable for the double Command? Tell me if not. Settings shows both shortcuts and an on/off switch.
16. **Neural background:** Full HUD → Listening (gentle inward pulses), Thinking (busiest), Working (steady flow), Approval (slow, few), Complete (one settling ripple then calm), Error (brief disruption then calm), Idle (nearly static). It should be **subtle** and text must stay perfectly readable. Settings → Reduce Motion: the network becomes a static drawing. Close the Full HUD: Activity Monitor CPU returns to ≈0–2%. (Expected while animating: ≈10–13% of one core, ≈3% when Idle/Approval.)

Report anything odd and I'll add it to `docs/KNOWN_ISSUES.md`.
