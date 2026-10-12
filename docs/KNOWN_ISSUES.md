# Known Issues

Classes: BLOCKING · NON-BLOCKING · MANUAL VERIFICATION REQUIRED · FUTURE MILESTONE. Resolved issues are kept.
**No BLOCKING issues exist for V0.1.**

## Open

### JARVIS-001 — VoiceOver names of custom-styled buttons
Status: Open · Class: MANUAL VERIFICATION REQUIRED (not a confirmed bug) · Severity: Medium
Description: Accessibility *identifiers* resolve via the AX API (`compact.open`, `compact.pause`, `compact.stop`, `dev.state.*`, `command.field`, …), `.accessibilityLabel` is set on every Button, and Menu/TextField labels read correctly. For custom-`ButtonStyle` buttons the label is not visible through AppleScript `description`/`title` (macOS 26 SwiftUI exposes it as `AXAttributedDescription`, which the available bridge can't read).
Evidence: System Events attribute dump (2026-10-10); in-process audit returns an empty tree (SwiftUI builds AX lazily).
Next: Check with VoiceOver (README checklist item 12). If names are missing, move `.accessibilityLabel` onto the button content / use `.accessibilityElement(children: .ignore)`.

### JARVIS-002 — Retina rendering not verified
Status: Open · NON-BLOCKING / MANUAL TEST REQUIRED
Description: All captures were taken on a 1× external display. Core Graphics/vector drawing should be fine on 2×, unverified.

### JARVIS-011 — Physical global hotkeys not verified from another application
Status: Open · MANUAL TEST REQUIRED
Description: Chord logic (17 unit tests) and the service → WindowManager path (smoke, scripted modifier timeline) are automated. Real ⌥⌘ / ⌥⌘⌘ presses while Finder/another app is focused were NOT performed (synthesizing key events into other apps was not attempted). Real-hardware timing (is 0.30 s comfortable for a double ⌘?) needs the user.
Next: README checklist → Global shortcuts. If the window is too tight/loose, change `ModifierChordMachine.window`.

### JARVIS-012 — Hotkey polling cost and chord limits
Status: Open · NON-BLOCKING
Description: Permission-free detection requires sampling: ≈0.3 % of one core at rest (12 Hz), 60 Hz only while Option is held. Compact fires ~0.3 s after ⌥⌘ (disambiguation latency; immediate if Option is released first). ⌥⌘+key/click and ⌥⌘⇧/⌃ are ignored by design. A very fast tap (< ~80 ms of Option) while idle-polling at 12 Hz could be missed; chords hold Option long enough in practice. Disable via Settings → Enable global shortcuts.

### JARVIS-003 — Real-click OPEN JARVIS, real ESC on Full HUD, resize-drag, click-outside dismissal not externally automated
Status: Open · MANUAL TEST REQUIRED
Description: The user declined further System Events automation; per policy no permission was added. Covered instead by in-process checks (real ESC `NSEvent` through the responder chain; `showFullHUD`; `windowWillResize`). Real menu-bar click open/close and compact ESC *were* observed earlier via System Events.

### JARVIS-004 — Dev tooling is compiled into the release binary
Status: Open · NON-BLOCKING
Description: `--smoke-test`, `--capture` (looks up `CGWindowListCreateImage` via `dlsym`; only captures own windows), `DevStateStrip` ship in release. Inert without launch args; strip is hidden via Settings.
Next: gate behind `#if DEBUG`/a dev build config when a distribution build exists.

### JARVIS-005 — Memory is not released after closing the Full HUD
Status: Open · NON-BLOCKING
Description: RSS ≈ 40 MB idle → ≈ 95 MB after Full HUD is first opened (≈ 110 MB with Compact open); windows/hosting views are kept for fast reopen. Acceptable for V0.1.

### JARVIS-006 — Menu-bar icon animation costs ~1.5 % of a core in animated states
Status: Open · NON-BLOCKING
Description: (V0.1.1: Full HUD animating ≈ 10–12.5 % of a core — neural layer adds ~2–3 points.) 0.5 s timer redraws the status button in listening/thinking/working. 0 % otherwise. Reduce Motion stops it.

### JARVIS-007 — Minimum window (980×620) is dense; centre column scrolls
Status: Open · NON-BLOCKING (polish)
Description: At minimum size the centre column falls back to a scroll view without indicators; side panels may clip. Content remains reachable.

### JARVIS-008 — Keyboard/focus polish
Status: Open · NON-BLOCKING / FUTURE
Description: No @FocusState management, no shortcuts for Approve/Deny or section switching; section tabs aren't grouped as a labelled container; decorative-size nits.

### JARVIS-010 — Architecture items for later milestones (from review)
Status: Open · FUTURE MILESTONE
Description: Store mutations target "first active task" (need task-id addressing for V0.4); `AgentSlot/ToolSlot/ProjectSummary/ApprovalRequest` not Codable; no "interrupted" task status; `setState` has no arbitration among STT/LLM/task engine; `LocalCommandHandler` has no response channel (V0.2); `isFullHUDOpen` is `isVisible` (true even if occluded); `observeContinuously` has no cancel handle. See `ARCHITECTURE.md` → extension points.

### JARVIS-015 — Codex streams per message, not per token
Status: Open · NON-BLOCKING (documented provider limitation)
Description: `codex exec --json` emits each `agent_message` complete; token-level deltas exist only in `codex app-server`, which OpenAI labels experimental/unsupported for production. JARVIS shows Codex answers as they arrive at message granularity and does not fake streaming. Claude Code streams token by token (REAL TESTED).

### JARVIS-016 — Provider policy limits (Anthropic / OpenAI)
Status: Open · MANUAL VERIFICATION (policy) / FUTURE
Description: Anthropic permits an end user to sign in to the *unmodified* Claude Code binary with their own subscription but forbids third-party apps from offering Claude.ai login, routing requests through subscription credentials for users, or handling credentials. JARVIS only drives the user's own installed, signed-in binary and never touches credentials — fine for personal local use; **must be re-reviewed before any redistribution**. OpenAI documents ChatGPT-managed auth in automation as "advanced" (API keys are the recommended default for CI) and does not address other desktop apps. Also: subscription limits are shared with the user's other Claude Code / Codex use; requests carry overhead (~14k input tokens for Codex, ~5k for Claude on a trivial prompt).

### JARVIS-017 — Codex binary lives inside ChatGPT.app
Status: Open · NON-BLOCKING
Description: Not on PATH; found at `/Applications/ChatGPT.app/Contents/Resources/codex` (codex-cli 0.153.4). App updates may move it or change flags (`--disable <feature>` names are version-specific). A custom path can be set in Settings. Provider sessions/transcripts are stored by the CLIs under `~/.claude` and `~/.codex` (their normal behaviour).

### JARVIS-018 — Provider requests are sequential; no queue
Status: Open · NON-BLOCKING
Description: A second provider question while one is generating is refused with "still answering" (deterministic commands still work). Sessions are per provider; after STOP the half-finished session is kept (the next question resumes it).

### JARVIS-019 — Provider processes survive a hard kill of JARVIS
Status: Open · NON-BLOCKING
Description: Normal quit, SIGTERM/SIGINT/SIGHUP all kill any running provider tree. A `kill -9` or crash of JARVIS cannot run cleanup, so an in-flight `claude`/`codex` child may finish on its own (bounded by its own run).

### JARVIS-020 — Provider CPU/limits while streaming
Status: Open · NON-BLOCKING
Description: With the Full HUD open (neural animation) a streaming answer costs JARVIS ≈20 % of one core plus the provider's own ≈7–16 %. Subscription usage limits are shared with the user's other Claude/Codex use.

### JARVIS-021 — OpenCode integration depends on observed behaviour that changed between generations
Status: Open · MANUAL VERIFICATION after OpenCode upgrades
Description: OpenCode's CLI was redesigned between 1.18.x and 1.19.x (docs/OPENCODE_RESEARCH.md). JARVIS supports both and detects the generation from `--help` at every refresh; an unknown generation disables the free pool (price unknown ⇒ never routed). Tool restriction relies on: non-interactive `ask` = rejected (observed on both; explicit message on v2), explicit denies of `execute`/`edit`/web (v2) — and on NOT denying `shell`/`read`/`bash` (the free tier answers 403 otherwise). A v2 gap (Code Mode `execute` could make a network request) was found by the canaries and closed. Re-run `--intelligence-live-test` after every OpenCode upgrade. The v2 JSON stream sometimes lacks the final `step_finish` (clean exit + text is accepted; token counts then unavailable). Price lookup on v2 goes through OpenCode's shared background service (started by OpenCode, not by JARVIS; JARVIS's own requests run `--standalone`).

### JARVIS-022 — OpenCode requests are heavy and message-level
Status: Open · NON-BLOCKING
Description: ≈4.5–5k input tokens and ≈4–10 s even for a trivial prompt (OpenCode's own system prompt); output arrives as one message (no token streaming). Free-tier limits are undocumented; any 403/429/5xx puts the model into cooldown.

### JARVIS-023 — "Free" is a moving target; some free models train on prompts
Status: Open · POLICY
Description: Free status comes from OpenCode's current price data and expires after 24 h; Zen documents the free period as "limited time". Several free models may use prompts for training (stored per model as `DataPolicy`; unknown = treated as may-train). JARVIS never sends sensitive text to free cloud and sends project code only to zero-retention models, but ordinary questions to a "may train" model are allowed in Auto — disable "Use verified-free OpenCode models in Auto" if that is not acceptable. The user's `opencode-go` credential is never used (those models are priced).

### JARVIS-024 — Local model limits
Status: Open · NON-BLOCKING
Description: Qwen3.5 4B 4-bit is deliberately limited to lightweight tasks (quality of longer answers is modest; it sometimes prefixes replies with "JARVIS:"). First use starts the worker (≈2 s load; the Python runtime is a 605 MB isolated venv created by `scripts/setup_local_ai.sh`, 57 pinned PyPI packages). ≈1.9–2.2 GB resident, ≈3.4 GB peak unified memory while loaded; generation is GPU-bound, so JARVIS/worker CPU numbers do not show the load. A SIGKILL of JARVIS cannot run cleanup, but the worker exits by itself when its stdin closes.

### JARVIS-025 — Task classification is heuristic
Status: Open · NON-BLOCKING
Description: `TaskClassifier` is a deterministic EN/TR keyword/shape classifier. It is biased toward "technical ⇒ not lightweight" (a miss can only make routing more conservative, never hand development work to the local model — enforced again inside `LocalQwenProvider`), but unusual phrasings may be routed to a more expensive engine than necessary.

### JARVIS-026 — Coding WORK is still workerRequired; no UI spawns agents yet
Status: Open · FUTURE (V0.4)
Description: "Write/fix/refactor …" requests stay `workerRequired` in conversation (V0.3 rule) and never reach any engine. The free-model pool is exercised by coding/knowledge *questions* and by `AgentRunManager` (foundation; no UI entry point, no tools, no file writes). The audit schema for file changes/approvals/proposals exists but nothing writes real file changes yet.

### JARVIS-027 — Benchmarks are small evidence, not guarantees
Status: Open · NON-BLOCKING
Description: Suite v1 = 13 fixture cases (3 general, 3 research, 4 coding, 3 testing). Passing it makes a model *eligible* for Auto, not good at your project; results expire after 14 days. Swift answers are type-checked only (never executed). Claude/Codex are not benchmarked (subscription engines are always eligible when ready).

### JARVIS-028 — Persistence limits
Status: Open · NON-BLOCKING
Description: SQLite is not encrypted (mode 0600 in the user's account); no automatic pruning of artifacts/runs; runs left `running` by a crash are listed by `interruptedRuns()` but not resumed (V0.4). Claude/Codex do not report token counts through the current parsers (recorded as "–"); OpenCode and the local model do.

### JARVIS-013 — Deterministic router limits (V0.2)
Status: Open · NON-BLOCKING
Description: Matching is alias/phrase based, not NLP: unusual phrasings fall through to "needs a provider" (truthful, never a wrong action). A bare "stop"/"close"/"clear"/"open" is treated as a command. Turkish coverage is a small explicit alias set; replies are English except for Turkish input. Worker-vs-reasoning is a keyword heuristic (verb + technical noun).

### JARVIS-014 — Conversation is in-memory only
Status: Open · FUTURE MILESTONE (V0.10 project memory)
Description: Messages are Codable and bounded (500) but not persisted; cleared on quit. Provider-side sessions are kept by the CLIs.

## Resolved

### JARVIS-R16 — Local STOP could leave the runtime "busy" (V0.3.1, found by the real live test)
Resolved. `LocalQwenProvider.waitUntilStopped` returned before the worker acknowledged the cancel, so the next request saw the runtime still running and was refused. The provider task now waits for the job to end and never reports a cancelled stream as finished; regression tests added.

### JARVIS-R17 — Agent concurrency limits were checked against a list filled too late (V0.3.1)
Resolved. Slots are now claimed synchronously at decision time (found while designing the concurrent-spawn tests).

### JARVIS-R13 — Orphaned grandchildren after cancel (V0.3, found by the real-process tests)
Resolved. `proc_listchildpids` returns a PID *count* with a buffer (not bytes), so descendant discovery silently returned nothing and `cancel()` could leave helpers running. Fixed + `cancelLeavesNoOrphanedGrandchildren` / `processIgnoringSigintAndSigtermIsKilled` tests; REAL TESTED with Claude Code and Codex (no survivors).

### JARVIS-R14 — Race: lingering exit reported as a user cancel (V0.3)
Resolved. After stdout EOF the process may still be exiting; cleaning it up was misreported as `.cancelled`. User cancellation is now tracked separately from internal cleanup.

### JARVIS-R15 — Live test left the stored provider preference changed (V0.3)
Resolved. `defer` never ran because the tool ends with `exit()`; the preference is now restored explicitly (and the stored value was reset to Auto).

### JARVIS-R12 — Could not paste (⌘V) / ⌘C ⌘X ⌘A ⌘Z in the command input; Full HUD could not take keyboard focus from another app
Resolved 2026-10-10 (V0.2.1, user-reported). Root cause: no main menu in an accessory app (so no Edit-menu key equivalents) + Full HUD was a regular window that stays non-key when `NSApp.activate()` is denied. Fix and rationale: DEC-019. Proven first by a failing smoke reproduction (`mainMenu == nil`, ⌘V/⌘C/⌘Z ignored), then passing. Physical keyboard use still MANUAL TEST REQUIRED.

### JARVIS-R10 — "narrow" layout never applied to the Full HUD top bar
Resolved 2026-10-10 (V0.2). `FullHUDView` injected `hudIsNarrow` for its children but read it itself, so the top bar always used the wide layout; at 980 pt the long "AWAITING APPROVAL" chip widened the whole layout and clipped the right column. Fix: `FullHUDBody` child reads the injected value; narrow top bar uses text-only tabs, no version tag and the short state label. Visible in `captures/full_minsize_waiting.png`.

### JARVIS-R11 — V0.2 review findings fixed
Resolved 2026-10-10: replies were silent to VoiceOver (now announced by `ConversationService`); Compact feedback hard-clipped mid-word (now tail-ellipsis overlay, hover shows full text) and never expired (20 s); stale accessibility hint; a fixed-height conversation panel could push approval buttons out of view at minimum size (flexible panel, approval card moved directly under the core); routing: fillers hid `Jarvis`/lead-ins ("please can you…", "…, Jarvis please"), Turkish dative forms/status phrasings missing, bare words (`continue`, `clear`, `iptal`, `open`, `aç`, `tam`) hijacked chat (now only when JARVIS is addressed), `build` was both verb and noun, non-code "write an email about the project" went to a worker, diacritic-free Turkish got English replies. 17 regression tests.

### JARVIS-R09 — Compact and Full HUD could be visible at the same time
Resolved 2026-10-10 (V0.1.1, reported by the user's manual test). Invariant enforced centrally in `WindowManager` (DEC-015); 12 smoke checks, mutation-verified.

### JARVIS-R08 — Compact HUD resized when the state changed
Resolved 2026-10-10 (V0.1.1). Window followed SwiftUI intrinsic height. Fixed canonical size (DEC-014), fixed-height task card, smoke test measures the frame across all states. Awaits user's manual confirmation (README checklist).

### JARVIS-R01 — Demo state switching left tasks incoherent
Resolved 2026-10-10. Leaving Approval stranded the task as "Awaiting approval"; Working-from-Error was a no-op; Completed/Error/Idle showed a RUNNING task. Fix: `JarvisTask.complete/fail`, `JarvisStore.completeActiveTask/failActiveTask/clearPendingApproval`, `DemoScenario.apply` rules; 6 unit tests + smoke checks.

### JARVIS-R02 — Full HUD minimum size was (0, 0)
Resolved. NSHostingView overwrote `contentMinSize`. Fix: enforce in `WindowManager.windowWillResize`; smoke-tested.

### JARVIS-R03 — Animated core used ~30 % of a core
Resolved. Moved to AppKit `CoreNSView` (DEC-006): ≈9 % animating, 0 % hidden.

### JARVIS-R04 — Menu-bar icon re-rasterized every tick
Resolved. Frames cached; tick 0.5 s; image only reassigned when changed.

### JARVIS-R05 — Layout defects at minimum width
Resolved. Wrapped wordmark/tabs/state labels, crushed centre column, cut-off approval card, overflowing dev strip. Width-aware layout (`hudIsNarrow`), icon-only dev chips when narrow.

### JARVIS-R06 — Small text / truncated task titles
Resolved. Type floor 10.5 pt; short status labels in dense rows.

### JARVIS-R07 — Settings window had no ESC/⌘W; approval not announced to VoiceOver
Resolved. `SettingsWindow`; `announcementRequested` notification on the approval card (announcement itself MANUAL VERIFICATION REQUIRED).

### JARVIS-009 — Repository had no commits
Resolved 2026-10-10. Baseline commit `feat(v0.1): establish native macOS Jarvis foundation` on `main`, pushed to origin (see `git log`). Workflow: DEC-011 / AGENTS.md. No `v0.1` tag until the user approves V0.1.

### JARVIS-V032-1 — Agents UI is verified by captures and the smoke test, not by a human
Status: Open · MANUAL TEST REQUIRED
Description: VoiceOver reading order, real selection/⌘C in the console, STOP click, layout feel with long consoles and Retina rendering were not checked by a person. (README 40–66.)

### JARVIS-V032-2 — Sanitizer cost at extreme rates
Status: Open · NON-BLOCKING
Description: Pattern sanitization costs ≈0.35 ms per line. A synthetic 400 lines/s stream (≈25× a real CLI) costs ≈13 % of one core with HUDs closed and ≈20–29 % with the console hidden/visible in the Full HUD. Memory stays flat (RSS +1–2 MB over 90 s). Real streams are far slower (a few lines/s). A faster sanitizer (pre-filter on candidate characters) is possible if needed.

### JARVIS-V032-3 — Real CLI runs have no measurable progress
Status: Open · by design (DEC-030)
Description: Claude Code / Codex / OpenCode / local runs show an indeterminate bar with elapsed time; a percentage appears only for runs with declared steps (benchmarks/agents with a step list). Codex/OpenCode stream at message level, so their console fills at the end.

### JARVIS-V032-4 — Console is read-only and there is no Pause
Status: Open · by design (DEC-031)
Description: None of the integrations supports same-session input or pausing; the capability matrix is in `docs/AGENT_OBSERVABILITY.md`.

### JARVIS-V032-5 — Console cosmetics
Status: Open · NON-BLOCKING
Description: In the run detail, "Copy all" and STOP stretch across the full width of their rows.

### JARVIS-V04-1 — Task UI and real project use are verified by captures/smoke/live tests, not by a person
Status: Open · MANUAL TEST REQUIRED
Description: Folder picker (NSOpenPanel from a non-activating Full HUD), VoiceOver reading order of the Tasks screen, approve/deny/stop/resume clicks, Reduce Motion and Retina were not checked by a human. Choosing a folder under Desktop/Documents/Downloads can trigger macOS's own "Files and Folders" prompt (a system dialog, not a JARVIS permission request). README items 67–91.

### JARVIS-V04-2 — Real autonomy was demonstrated on a tiny fixture only
Status: Open · NON-BLOCKING
Description: The REAL end-to-end test (OpenCode FREE `space-bunny-free`, Python calculator, ≈16–18 s) passed; larger/multi-file projects, Unity/C# build profiles and weaker free models are unverified. Planner/coding quality is the routed model's; failures are reported honestly (planner/format failures, test failures after the bounded repair/escalation).

### JARVIS-V04-3 — Concurrency and repair limits are deliberately small
Status: Open · by design
Description: At most 2 active tasks; only read-only analysis steps run side by side; a repair re-runs the failing command only (an earlier passed build step is not re-run); ≤3 attempts per code step; plans ≤12 steps; one workspace per task; context is targeted (≤7 files / ≈50 k chars), so very large projects need specific goals.

### JARVIS-V04-4 — Resume after a restart is explicit and conservative
Status: Open · by design
Description: Interrupted tasks are never resumed automatically. If a code step's files no longer match what JARVIS wrote or the original content, the task fails with `workspaceChanged` instead of guessing. Waiting approvals for edits to user-dirty files are re-asked after a restart (the edits they described are gone). The cumulative diff after a restart comes from the last checkpoint.

### JARVIS-V04-5 — Build/test steps execute project code
Status: Open · by design
Description: "Run the tests" runs the project's own test code (workspace-only, scrubbed environment, timeout, allowlisted executable/arguments, no network client of JARVIS). There is no OS-level sandbox; do not point tasks at untrusted projects.

### JARVIS-V04-6 — No native notifications, no daemon
Status: Open · FUTURE MILESTONE
Description: Completion is reported in the conversation/activity/VoiceOver announcement; a macOS notification would need a permission. Tasks run only while the JARVIS process lives; quitting interrupts them (checkpointed).

### JARVIS-V04-7 — Claude Code / Codex task escalation not exercised for real
Status: Open · MOCK TESTED
Description: Bounded repair and escalation (including `exclude`/`pin`, explicit-mode refusal) are covered with scripted agents; the real live test finished on OpenCode FREE without escalation and Claude/Codex were not asked to code on a fixture (subscription quota).

### JARVIS-V05-1 — Proposals/Settings UI verified by captures, smoke and live tests, not by a person
Status: Open · MANUAL TEST REQUIRED
Description: The Proposals cards (including the critical variant), Settings → Autonomy radio group, the Compact "N SUGGESTIONS" tag, VoiceOver reading order, Reduce Motion and the visual weight of Approve/Deny/Dismiss were not checked by a human. README items 92–125.

### JARVIS-V05-2 — Few finding sources by design
Status: Open · by design
Description: V0.5 derives findings only from what V0.4 records (missing regression test after a code change, missing test command, failures after repair) plus optional reviewer suggestions. There is no project-wide scanning, no build-warning parser and no Unity-specific reasoning (V0.6). Real reviewers sometimes add suggestions that become proposals; they are claims (medium/weak evidence) and never automatic.

### JARVIS-V05-3 — Autonomy is deliberately narrow
Status: Open · by design
Description: Automatic actions are limited to small test/maintenance/bug changes with strong deterministic evidence (≤2 files, one per user task, never chained); approved critical actions (purchases, push, credentials, deployment, deleting) are `unsupported` — approval does not create those capabilities. The default mode is Ask Before Acting; Low-Risk Autonomous should be enabled only after the user has verified the behaviour.

### JARVIS-V05-4 — Cooldown semantics are heuristic
Status: Open · NON-BLOCKING
Description: Reworded asks about the same file are suppressed during a cooldown (deny 14 d, dismiss 3 d, expiry 7 d) unless materially new deterministic evidence appears; token similarity is deterministic but not semantic, so unusual wording may produce a second card. Scope-expansion stops require a manual "re-propose".

### JARVIS-V05-5 — No notifications
Status: Open · FUTURE MILESTONE
Description: Proposals are passive cards (a Compact tag and a Dashboard line). A macOS notification would need a permission and was deliberately not added.

### JARVIS-V06-1 — Unity UI and real-game use are not user-verified
Status: Open · MANUAL TEST REQUIRED
Description: Automated and REAL (headless editor, fixture) tests passed, but nobody has verified the Unity line/task section/Compact phrase, VoiceOver, Reduce Motion, a **windowed** editor with the bridge installed by approval, or any real game. README items 126–153. The real game must only be connected read-only first.

### JARVIS-V06-2 — No visual validation
Status: Open · by design (future)
Description: No Game/Scene View screenshot is captured or inspected; Unity reports state "Visual validation: NOT PERFORMED". Structural, compilation and test validation are real.

### JARVIS-V06-3 — Narrow Unity surface
Status: Open · by design
Description: Deletion supports GameObjects only (approval per action); components/prefabs/scenes/assets cannot be deleted; no prefab unpack/apply; no package installation, project upgrade tooling, Asset Store, downloads; rollback = Undo + verify/repair, no scene transaction; one mutating Unity step per project at a time.

### JARVIS-V06-4 — First import and a headless editor
Status: Open · NON-BLOCKING
Description: JARVIS' own editor is headless (no window): first open of a large project can take many minutes (connect timeout 10 min), and a person cannot watch it. A user's windowed editor works the same way once the bridge package is installed (needs approval and triggers a domain reload in that editor). Unity's own CPU/RAM (≈0.4 GB editor process, ≈2.1 GB including compiler/package helpers for the tiny fixture; plan for it on a 16 GB machine) is Unity's, not JARVIS'.

### JARVIS-V06-5 — A crash cannot clean up
Status: Open · NON-BLOCKING
Description: SIGKILL/crash of JARVIS cannot be intercepted: an owned editor dies with the process tree only on normal exit/SIGTERM; after a hard crash an owned editor may stay running (possibly in Play Mode). The next launch reconnects to it (state PLAY MODE is reported truthfully), an owned editor's leftover Play Mode is reset by the next Play step, and CLOSE EDITOR closes it. Tested with a simulated crash aftermath, not a real SIGKILL.

### JARVIS-V06-6 — Reviewer behaviour changed (generic)
Status: Open · behaviour note
Description: Since DEC-050 a failing AI review no longer fails a task whose hard validators passed unless it names verifiable evidence or the user asked for a review gate; the advice is only in the report. Tasks with no build/test (nothing hard to pass) keep the old behaviour.

### JARVIS-V06-7 — Test framework dependency of the bridge's test ops
Status: Open · NON-BLOCKING
Description: `runTests` needs `com.unity.test-framework` in the project (the fixture uses 1.7.0, resolved offline from the editor's built-in packages). Without it `getTestAvailability` says unavailable and a Unity test step fails honestly. PlayMode runs depend on the project's own PlayMode asmdefs.

### JARVIS-V07-1 — Voice UI and real human speech are not user-verified
Status: Open · MANUAL TEST REQUIRED
Description: Automated tests (unit, smoke, captures) and the REAL `--voice-live-test` (synthetic speech from the macOS voices through the real recognisers, the real conversation path, real TTS, real OS-level Right-Option key events, a real microphone open/close) passed — but nobody has spoken to JARVIS. Recognition quality for a real voice (accent, distance, noise, speed), TTS naturalness/pronunciation/fatigue, VoiceOver behaviour, Reduce Motion, the physical right-Option feel and background use from another app are unverified. Synthetic speech flatters accuracy (clean, consistent). README items 154–223.

### JARVIS-V07-2 — Mixed Turkish/English technical speech is the weakest case
Status: Open · NON-BLOCKING
Description: Whisper-small commits to one language per utterance: with Auto it may hear a Turkish sentence with English product words as English (and garble the Turkish part); with a fixed Turkish setting it garbles English terms. Apple's recogniser mishears technical words ("Play more", "added mode"). The domain prompt (Jarvis, Unity, Play Mode, EditMode, BoxCollider …) helps single-language sentences. A larger Whisper model (large-v3-turbo, ≈1.6 GB download, ≈1.8 GB resident) was measured separately and handled the code-switched fixture better; it is optional (point `Whisper model folder` at it) and not the default because of memory. Recommendation until you have tried it with your own voice: set the recognition language explicitly (Turkish for Turkish speech with English terms).

### JARVIS-V07-3 — Whisper previews are re-decodes, not native streaming
Status: Open · by design (documented)
Description: While the key is held the local recogniser re-decodes the audio so far (first preview after ≈1 s of speech, then about once per 1.2 s, never two at once) and decodes everything once more at release (≈0.2–0.4 s for a few seconds of speech). Apple's recogniser streams natively (first partial ≈1 s after speech starts, finalisation ≈0.06 s) but is less accurate. Previews are provisional and never become messages.

### JARVIS-V07-4 — Apple on-device speech needs macOS 26; no SFSpeechRecognizer fallback
Status: Open · NON-BLOCKING
Description: `SpeechTranscriber` (SpeechAnalyzer) has no Turkish on macOS 26.4, so the Apple provider uses `DictationTranscriber` (tr-TR and en-US verified). It requires macOS 26; on macOS 14/15 only the optional Whisper helper provides speech input (the classic `SFSpeechRecognizer` was not used because it needs a second privacy permission). JARVIS never downloads Apple's language models itself (Settings → Install asks the system to).

### JARVIS-V07-5 — Voices are the installed standard ones; quality unknown
Status: Open · MANUAL TEST REQUIRED
Description: The Mac used for development has only compact/standard voices (Yelda tr-TR, Samantha en-US …); premium/enhanced voices need to be added by the user (System Settings → Accessibility → Spoken Content). TTS is incremental sentence synthesis (no native streaming). Neural voices (Piper: measured RTF 0.02–0.07 and 200–290 MB; Kokoro/XTTS) are optional future providers — licences (Piper is GPL-3, voice licences vary, XTTS non-commercial) and Turkish support must be decided first.

### JARVIS-V07-6 — The shortcut is fixed to the right Option key
Status: Open · NON-BLOCKING
Description: Only on/off is configurable. Keyboards without a right Option key, or users who need AltGr, can turn the shortcut off (voice can still be driven by the Settings test buttons only — there is no other trigger until V0.8). A press while the previous transcript is still being finalised (≈0.1–0.4 s) is ignored, not queued.

### JARVIS-V07-7 — Spoken replies and VoiceOver can overlap
Status: Open · MANUAL TEST REQUIRED
Description: Replies are both announced to VoiceOver (V0.2) and spoken by the synthesiser when voice is used with VoiceOver on. Not verified by a person; the live region is not suppressed.

### JARVIS-V07-8 — Speech is not spontaneous (by design)
Status: Open · by design
Description: Typed turns are not spoken; task completion, proposals and approvals are never announced by voice (text/UI only); JARVIS never listens while speaking (no echo cancellation: use headphones or wait). Hands-free listening, barge-in and spoken confirmations are V0.8.

### JARVIS-V07-9 — Apple speech services cannot be attributed
Status: Open · NON-BLOCKING
Description: Apple's recogniser/synthesiser run in system processes (`localspeechrecognition`, `SpeechSynthesisServerXPC`, `corespeechd` …): their memory/CPU is observed (tens of MB) but not controllable or attributable to JARVIS, and their network behaviour cannot be inspected (JARVIS itself has no socket). Installing a dictation language model is a system-level side effect (the dev machine's en-US `SpeechTranscriber` assets were installed once during research, ≈16 s).


## V0.8 — Natural Voice & Presence

### JARVIS-V08-1 — Acoustic look-alikes can wake JARVIS
Status: Open · NON-BLOCKING · MANUAL TEST REQUIRED
Description: On the adversarial look-alike list (90 words: "Jervis", "Jarvik", "Cervix", "Carpet" …) 26 fire at the shipped settings (live loop: ≤ 1 of 6 common look-alikes). Ordinary continuous speech: 0 false wakes in 2.9 h of synthetic speech, but that is a small, synthetic sample. Real rooms, TV, other voices: unknown. Mitigations: threshold 0.9, patience 3, utterance-initial rule; a false wake only opens a bounded attentive window (no recogniser unless speech follows, nothing is submitted without a transcript).

### JARVIS-V08-2 — The wake word must start an utterance, and a very quiet voice may be missed
Status: Open · by design
Description: "… so, Jarvis, do X" in the middle of a long sentence does not wake JARVIS (utterance-initial rule). The energy gate needs the level to rise ≥ 10 dB above the room's floor (≥ −58 dBFS): a whisper in a silent room can be missed. Saying the word again works.

### JARVIS-V08-3 — The wake head was trained on synthetic speech only
Status: Open · MANUAL TEST REQUIRED
Description: Training and test voices are all synthesisers (Supertonic / Apple). Real accents, microphones, distance and room acoustics are untested (README 224–343). Retraining is a script (`train_wake_head.sh`).

### JARVIS-V08-4 — Barge-in has no echo canceller
Status: Open · documented limit
Description: It relies on the level difference between the user and JARVIS' own voice at the microphone (measured on this MacBook Air only: coupling −26…−30 dB). A quiet voice below the echo, a very loud speaker, headphones with leakage, or a different machine may interrupt late, never, or (rarely) on loud non-speech. Push-to-Talk and Stop Speaking always work. Voice Processing I/O is the measured alternative (≈ 15 % CPU, fragile re-initialisation).

### JARVIS-V08-5 — The neural voice has not been listened to by a person
Status: Open · MANUAL TEST REQUIRED
Description: Technical status only (licence, latency, memory, offline, cancellation, stability). Naturalness, personality fit, Turkish/English pronunciation, "BoxCollider"/"Play Mode" pronunciation, fatigue: unknown until README 249, 254 and 309–317 are done. The Apple fallback's only Turkish voice (Yelda) is female: the "same identity in both languages" holds only with the neural voice.

### JARVIS-V08-6 — Neural first audio is slower than Apple's
Status: Open · NON-BLOCKING
Description: ≈ 0.3–1.0 s for the first phrase (Apple ≈ 0.15 s); ≈ 0.3 CPU-s per second of audio on 2 threads; ≈ 0.5 GB resident while loaded (unloads after 180 s idle and under memory pressure). The model is not a streaming model (incremental chunk TTS).

### JARVIS-V08-7 — Mixed Turkish/English recognition is still the weakest case
Status: Open · NON-BLOCKING
Description: `TechnicalTerms` only restores canonical spelling of known terms; it cannot repair a mis-heard word. Whisper turbo (optional, 1.8 GB) recognises code-switching better.

### JARVIS-V08-8 — Endpoint latency is 0.5–1.0 s
Status: Open · NON-BLOCKING
Description: A finished sentence ends the turn ≈ 0.5–0.7 s after the last word (hint from a fresh preview), an ambiguous one after 1.0 s, an unfinished one after 1.5 s. The hint depends on the recogniser's punctuation (Whisper punctuates; Apple's streaming partials do not), so Apple turns tend to wait the full 1.0 s.

### JARVIS-V08-9 — Upstream status of the neural voice
Status: Open · NON-BLOCKING
Description: The Supertonic repository is archived/read-only upstream; the weights are OpenRAIL-M (use-based restrictions: no impersonation, disclose machine-generated content — JARVIS is openly an AI assistant). The revision is pinned; Piper (fast, NC/unclear licences) and Chatterbox (heavy) were measured as alternatives.

### JARVIS-V08-10 — Wake feature models are frozen at openWakeWord v0.5.1
Status: Open · NON-BLOCKING
Description: The mel/embedding models are from a 2024 release (Apache-2.0). They are small and stable; replacing them means retraining the head.

### JARVIS-V08-11 — Hung or crash-looping sentinel
Status: Open · NON-BLOCKING
Description: A hung helper is detected only while audio flows (ping every 20 s, 4 s to answer), then restarted; after 3 restarts in 10 minutes wake mode reports "unavailable" until toggled. Push-to-Talk is unaffected.

### JARVIS-V08-12 — Battery and VoiceOver
Status: Open · MANUAL TEST REQUIRED
Description: All measurements ran on AC power; CPU/runtime evidence (0.00 CPU-s in a quiet room, 0.1 % of a core with continuous speech) predicts a small battery cost, but nobody has measured it on battery. Announcements are polite and state-only; overlap with JARVIS' own speech is unverified (as JARVIS-V07-7).

### JARVIS-V08-13 — Installation weight and effort
Status: Open · by design
Description: `setup_voice_ai.sh --natural` needs `uv` and network once (≈ 190 MB runtime + 4 MB models + 381 MB voice); `train_wake_head.sh` takes 20–60 minutes. Without them wake mode and the neural voice are "unavailable" with an explanation; Push-to-Talk and the Apple voice keep working.

### JARVIS-V08-14 — Occasional timing flakes in two automated checks (open, not a product defect as far as known)
Seen once each: the V0.7 `--voice-live-test` check "no managed process left after shutdown" (registry count 1 right after `voice.shutdown()`, passed on every rerun; the failing check now prints the executable names) and the smoke test "Exclusivity: Full visible → Compact hotkey → only Compact" inside one `verify.sh` run (passed on rerun and in the next full verify). Both are timing-sensitive checks under load; neither reproduced after.

