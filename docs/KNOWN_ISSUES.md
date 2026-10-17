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



## V0.9 — Web Research & Asset Acquisition

### JARVIS-V09-1 — Not validated by a human
Status: Open · MANUAL TEST REQUIRED
Description: Everything was verified by unit tests (1044), fixtures under the production URL policy, `verify.sh` and `--research-live-test` on this Mac (real public web, real Poly Haven download). Nobody has used the Research screen, judged report quality, or tried real tasks of their own (README 344–463).

### JARVIS-V09-2 — Unity Asset Store is not automated
Status: Open · by design
Description: the store has no public API and "free" assets need a signed-in account (account authority, not implemented). Research can read public listing pages when reachable and classify them `ACCOUNT ACTION REQUIRED`; JARVIS never signs in, accepts terms or claims an asset.

### JARVIS-V09-3 — Discovery depends on a keyless HTML endpoint
Status: Open · NON-BLOCKING
Description: general web discovery uses DuckDuckGo's HTML endpoint (robots allow it). It can change or answer with a challenge; JARVIS then stops that provider (no evasion) and uses the structured providers (docs resolver, GitHub, Stack Exchange, Hacker News, Poly Haven, Kenney). Open-web questions are weaker in that case.

### JARVIS-V09-4 — Relevance is word-based
Status: Open · NON-BLOCKING
Description: topical relevance compares stemmed subject words (glossary for common Turkish terms, model-translated English queries). Synonyms and unglossed Turkish words can miss a good candidate; the live run found no Poly Haven sink at all. A candidate that matches none of the request words is "not recommended", which is conservative. Image content is never judged (style fit is a text-only model assessment, labelled).

### JARVIS-V09-5 — Stack Overflow pages are read through the API
Status: Open · by design
Description: the HTML pages answer 403 to automated requests; JARVIS uses the documented public API (≈ 300 requests/day without a key) for the question and top answers instead of trying to get around the block. Heavy use in one day can exhaust it.

### JARVIS-V09-6 — Archive formats
Status: Open · NON-BLOCKING
Description: ZIP (extractable) and tar.gz/`.unitypackage` (listed, not extracted or imported) only; rar/7z/dmg/pkg are rejected as uninspectable; executables and installers are refused outright.

### JARVIS-V09-7 — JavaScript-heavy and login-walled pages
Status: Open · by design
Description: the rendered tier is read-only (no clicks/typing, no sign-in, no CAPTCHA). A page that needs interaction is reported as "interaction required" and the user opens it in their own browser. Interactive browsing is V0.11.

### JARVIS-V09-8 — Freshness is a moment, not a subscription
Status: Open · by design
Description: price and licence are verified when the research runs and again just before a download; there is no background re-verification. Evidence older than 24 h is flagged and requires approval for an automatic download.

### JARVIS-V09-9 — Extraction quality depends on the routed model
Status: Open · NON-BLOCKING
Description: candidates from structured providers (Poly Haven, Kenney, GitHub) need no model; candidates and claims from arbitrary pages are extracted by the routed model (≤3 calls) and kept only when their quoted evidence is in the page. With no model available the report is thinner but never invented. The live runs used Claude Code and the local Qwen model (subscription/local, no paid API).

### JARVIS-V09-10 — Browser-tier helper processes are not independently measured
Status: Open · NON-BLOCKING
Description: WebKit's content/network helpers are system-launched (XPC), not children of JARVIS (there is no Chromium and nothing of ours to track). The live test verifies that the web view is released after use and shutdown and that no browser descendant process of JARVIS remains; it does not count WebKit helper processes system-wide.

### JARVIS-V09-11 — Import is exercised on fixtures only
Status: Open · MANUAL TEST REQUIRED
Description: the importer and its approval ran for real on a disposable Git folder fixture (the real Poly Haven file) and, with the simulated editor, on Unity-style fixtures; no real Unity-editor import was performed (the real artifact was glTF JSON). Importing a researched asset into your real game is for you to try (README 344–463), ideally on a copy.

### JARVIS-V09-12 — Pre-existing Swift 6 warnings
Status: Open · NON-BLOCKING
Description: a few `lock()` in async contexts remain in the V0.8 natural-voice live test (warnings only, not errors in Swift 5 mode).

### JARVIS-V08-15 — `train_wake_head.sh` did not notice failed generator jobs (found while V0.9 was in progress)
Status: Mitigated (V0.9 session) · MANUAL TEST REQUIRED
Description: on the user's Mac the script failed with `FileNotFoundError: …/pos.json`: the background speech-generation jobs were joined with a bare `wait` (which ignores failures) and their logs were deleted by the exit trap, so the real cause was invisible. The installed head is intact. Fix: every job's exit status is checked, the failing logs are printed (tail) and kept (`$WORK/gen_*.log`). The root cause of the generator failure on that Mac is still unknown (not reproduced: running it was interrupted) — rerun `scripts/train_wake_head.sh --quick` and send the printed log tail.


## V0.10 — Project Memory

### JARVIS-V10-1 — Not validated by a human
Status: Open · MANUAL TEST REQUIRED
Description: verified by unit tests, `scripts/verify.sh` and `--memory-live-test` (real helper, the actual JARVIS repository as corpus). Nobody has used the Memory screen, judged answer quality on their own questions, or corrected/forgot real memories (README 464–583).

### JARVIS-V10-2 — The retrieval benchmark is small and synthetic
Status: Open · NON-BLOCKING
Description: the model and fusion weights were chosen on 62 memories / 48 queries (2 English→Turkish queries only). Differences of a few points are noise. The real-repository checks (12 queries) are more representative but also few. One compound Turkish question ("İndirilen dosyaları neden doğrudan Unity projesine atmıyoruz?") ranks its decision 5th–7th (it moved as the repository's own docs grew), never in the 3 records the answer shows.

### JARVIS-V10-3 — Forks that share a Git root commit share memory
Status: Open · by design
Description: project identity is the root commit (clones and moves keep memory); a fork or copy of a repository that still shares it also shares memory until its history diverges at the root. A folder that is not a Git repository and has no Unity `productGUID` is identified by its real path (a move creates a new project).

### JARVIS-V10-4 — Loosely phrased questions are answered by the model, not by records
Status: Open · by design
Description: only questions that explicitly ask about this project's history/state ("what did we decide…") are answered deterministically; others reach the normal conversation with the relevant packet in context. If no provider is available, they get no answer. The packet is marked "use only if relevant" and can attach loosely related records to general questions.

### JARVIS-V10-5 — Answers are composed, not written
Status: Open · NON-BLOCKING
Description: memory answers are accurate, cited and a little stiff (record sentences, short intros, Turkish intros around English records). A model-polished answer would read better but would need the packet plus a request per question.

### JARVIS-V10-6 — Model-proposed lessons are off by default and lightly exercised
Status: Open · NON-BLOCKING
Description: the grounded extraction path (prompt, schema, verbatim-evidence check, curator) is unit-tested with fake answers; it has not been run against a real model on real task reports.

### JARVIS-V10-7 — Keyword matching for Turkish is approximate
Status: Open · NON-BLOCKING
Description: 6-character prefix stemming plus a hand-written TR↔EN bridge; unusual inflections and unlisted vocabulary rely on the semantic signal (which needs the optional helper).

### JARVIS-V10-8 — The embedding helper is optional and heavy-ish
Status: Open · by design
Description: `scripts/setup_memory_ai.sh` needs `uv` and network once (≈ 128 MB runtime + 118 MB model); the helper then holds ≈ 565 MB RSS while loaded (unloaded after 2 minutes idle / under pressure). Without it Project Memory works with structured + keyword retrieval, and the Memory screen says semantic search is unavailable.

### JARVIS-V10-9 — Bootstrap reads only the documents it knows
Status: Open · NON-BLOCKING
Description: DECISIONS, KNOWN_ISSUES, AGENTS, DEVELOPMENT_LOG (+ Unity inspection, V0.9 database). Other docs (architecture, README, per-feature docs) and source code are not ingested; Git history is used as an identity/truth source, not mined. Task and conversation history from before V0.10 are not back-filled.

### JARVIS-V10-10 — Pre-existing Swift 6 warnings
Status: Open · NON-BLOCKING
Description: a few `lock()`-in-async warnings remain in older live-test code (warnings only in Swift 5 mode).

## V0.11 — General Computer Use

### JARVIS-V11-1 — Not used by a human yet
Status: Open · MANUAL TEST REQUIRED
Description: everything is automated-tested (120 unit tests on a virtual macOS) and REAL TESTED by `--computer-live-test` (real Accessibility against a JARVIS-owned fixture, real Finder/System Settings/Blender) — no person has used the Computer screen, the approval flow with real applications, the emergency chord or the voice path. See README 584–703.

### JARVIS-V11-2 — Xcode was not installed on the development Mac
Status: Open · NOT LIVE-VALIDATED
Description: only the Command Line Tools are installed, so "open the JARVIS project in Xcode", Xcode Settings and the ⌘1…⌘9 navigators are plan-tested (parser + policy + virtual macOS), not run against Xcode. The same typed actions were exercised live against the fixture, Finder and System Settings.

### JARVIS-V11-3 — Custom-drawn applications expose little to Accessibility
Status: Open · by design
Description: Blender's Accessibility tree is 7 nodes (window, menu bar); its editors and 3D viewport are not exposed. The window-scoped vision fallback can locate *text* in them (79 regions recognised in the Blender window) but V0.11 makes no attempt at modelling, and does not press inside the viewport.

### JARVIS-V11-4 — The vision fallback is on-device text recognition only
Status: Open · by design
Description: it finds controls that carry visible text (en/tr). Icon-only controls, text rendered as images, low-contrast labels and languages the recogniser lacks cannot be located; a model-based vision provider is deliberately not wired (no verified-free, privacy-safe route; `UnavailableModelVision`). VISION FALLBACK: local OCR live-validated · model vision NOT available.

### JARVIS-V11-5 — A coordinate click moves the real pointer
Status: Open · by design
Description: macOS ignores synthetic mouse events aimed at one process (measured), so the final-rung click goes through the system event stream as one down/up pair; the pointer is put back afterwards and the click is refused while the user is using the mouse or keyboard. Accessibility actions never move the pointer.

### JARVIS-V11-6 — Large containers are read partially
Status: Open · by design
Description: the tree is bounded (≤ 250 nodes, depth 9, ≤ 40 children of one container unless the app offers `AXVisibleChildren`). A row of a 10 000-row table that is not among the first children or the visible children is not seen until the content is scrolled; a truncated tree is reported as such and scroll distances are then stepped, not computed.

### JARVIS-V11-7 — Spaces, full-screen apps and Stage Manager
Status: Open · NON-BLOCKING
Description: Accessibility lists the windows of the current Space; a window on another Space or a full-screen app that macOS did not bring forward is "not found", honestly. No private API is used to switch Spaces.

### JARVIS-V11-8 — Some UI is not automated
Status: Open · by design
Description: open/save panels (a modal panel is detected and never clicked through; `openFile` is the typed way), drag and drop, notifications, Dock and menu-bar extras are not operated. "Export this file to a specific safe location" through a save panel is therefore not supported in V0.11.

### JARVIS-V11-9 — Consequence recognition is English and Turkish
Status: Open · NON-BLOCKING
Description: the label classifier knows EN/TR words and price patterns. A destructive or purchasing control labelled in another language is not recognised by its label; the mitigations are the blocked kinds (secure fields, terminals, Finder file menu items, System Settings switches), the dialog-context rule for generic confirm buttons and that every medium/high action from a *model* asks. Add vocabulary before using JARVIS with other languages.

### JARVIS-V11-10 — The emergency chord and the interference probe are not physically tested
Status: Open · MANUAL TEST REQUIRED
Description: the ⌃⌥⌘ sampler is measured with scripted modifiers (75 ms to trigger); a real hold, and the real idle-time probe (`CGEventSource.secondsSinceLastEventType`), were exercised with an injected "user is typing" probe only.

### JARVIS-V11-11 — Model-assisted planning has not run on a real model
Status: Open · NON-BLOCKING
Description: the bounded planner (prompt, JSON schema, forbidden keys, allowed apps, verified "done") is unit-tested with a scripted runner; automated runs must never spend quota and the live test makes no model request. The deterministic EN/TR parser covers the acceptance scenarios.

### JARVIS-V11-12 — Window titles are the disambiguator
Status: Open · by design
Description: two windows with the same (or empty) title cannot be told apart by name; a dialog's empty title is handled by "the dialog comes first". Such cases stop as AMBIGUOUS rather than guess.

### JARVIS-V11-13 — Hung applications are unit-tested only
Status: Open · NON-BLOCKING
Description: a really non-responsive application could not be produced safely; the 1.5 s messaging timeout, "application not responding" result and the no-force-quit rule are covered by the virtual macOS tests.

### JARVIS-V11-14 — macOS may refuse to bring an app forward
Status: Open · by design
Description: focus rules (cooperative activation) can refuse an activation; JARVIS verifies the frontmost application and reports "did not become frontmost" instead of assuming. Key-based actions then stop as STALE.

### JARVIS-V11-15 — The adapter set is small
Status: Open · NON-BLOCKING
Description: Finder, Xcode (navigators/Settings), Blender (notes), System Settings (navigation) and Unity (activate). Other applications use the generic Accessibility layer.

### JARVIS-V11-16 — The fixture adds a second executable to the package
Status: Open · NON-BLOCKING
Description: `JarvisFixture` is built by `swift build`/`scripts/build_app.sh` (a ~300-line AppKit file); it is never inside `Jarvis.app`.

### JARVIS-V11-17 — Per-key typing is slow
Status: Open · NON-BLOCKING
Description: when a field does not accept a direct value, `typeText` posts 8 characters per ~6 ms plus the target's own processing (≈ 20–60 ms per character in the fixture) — fine for a name, slow for a paragraph. Text longer than 2000 characters is refused.

### JARVIS-V11-18 — Pre-existing Swift 6 warnings
Status: Open · NON-BLOCKING
Description: unchanged from V0.10 (older live-test code); none in the Computer layer.

## V0.12 — Advanced multi-agent orchestration (JARVIS-V12-*)

### JARVIS-V12-1 — Templates cover the common shapes only
Status: Open · NON-BLOCKING
Description: `fix-flow`, `investigation`, `investigation-research`, `asset-suitability` and the single QA/Computer/Research routes need no planner model. Everything else (and every Unity scene goal) costs one planner-model call, and the quality of a model-proposed graph depends on that model even though JARVIS validates it structurally (roles, ordering, gates, limits). Workaround: rephrase the goal more specifically; V1.0 may add templates after real use.

### JARVIS-V12-2 — Role benchmarks are tiny and not deterministic across runs
Status: Open · NON-BLOCKING
Description: 11 cases, one sample per case. The same free model scored security 0/2 in one live run and 2/2 in another; routing evidence is therefore a snapshot, not a rating. Security-relevant routing uses COMPLETE evidence only (DEC-181), so a flaky model is excluded until it passes both cases again. Do not generalise from these tables.

### JARVIS-V12-3 — Review independence needs a second eligible provider
Status: Open · NON-BLOCKING
Description: when the free model is the only eligible engine (Claude/Codex not ready, or an explicit single-provider choice), the writer also reviews; the routing record says `sameProvider`. By design: the review is never skipped and diversity is never forced.

### JARVIS-V12-4 — Final synthesis is deterministic
Status: Open · NON-BLOCKING
Description: reports and conversation summaries are assembled from graph state and validated artifacts; no model rewrites them (DEC-184), so the wording is correct but plain. Model-rendered summaries (restating validated facts only) are a V1.0 polish candidate.

### JARVIS-V12-5 — The research question for a compound goal is a heuristic clause
Status: Open · NON-BLOCKING
Description: `researchQuestion(from:)` takes the clause(s) with a research cue, plus the goal's first clause when short. The V0.9 pipeline filters sources by subject relevance, so a vague clause can yield “nothing readable” (the optional branch then fails and the task ends PARTIAL, honestly). Mention the subject in the research clause (“…and check the latest official Unity BoxCollider documentation”).

### JARVIS-V12-6 — Computer / Unity nodes inside graphs are exercised mostly with fixtures
Status: Open · NON-BLOCKING · MANUAL TEST REQUIRED
Description: a Computer child inside a graph is tested against the virtual macOS (unit tests) and its ladder/plan-time checks are live-tested; a real Finder/Xcode/Blender run INSIDE a graph, and any real Unity editor run inside a V0.12 graph, were not part of the V0.12 live test (V0.6/V0.11 have their own live tests). Xcode was not installed; no Unity editor ran.

### JARVIS-V12-7 — Memory authority gate is pattern-based
Status: Open · NON-BLOCKING
Description: the V0.10 gate refuses authority-shaped statements with regular expressions (now including agent-targeted grants). A cleverly phrased grant may still be STORED; it still cannot act (contracts, policy, validators and the scheduler never read memory), and the Context Builder presents memory as context, not instruction. Over-refusal of a legitimate fact containing “without asking” is possible; rephrase.

### JARVIS-V12-8 — Fixed freshness and limits
Status: Open · NON-BLOCKING
Description: research reuse window 24 h, 2 structural revisions, 3 delegates, 12 nodes, 2 parallel readers, 1 review cycle, provider invocations ≤ 4 per node are constants chosen conservatively for a 16 GB MacBook Air; none is user-tunable (DEC-182).

### JARVIS-V12-9 — The V0.10 embedding helper stays resident up to 120 s after a task
Status: Open · NON-BLOCKING
Description: finished tasks ingest memory, which loads the embedding helper; it unloads itself after its 120 s idle timer (V0.10). The orchestration layer owns no process; the live test waits for this unload before measuring idle.

### JARVIS-V12-10 — Graph UI is a list; Compact line truncates
Status: Open · NON-BLOCKING
Description: nodes are listed with dependencies named, not drawn; parallel groups are implicit. Long role+model names truncate in the one-line Compact summary (the Full HUD shows everything).

### JARVIS-V12-11 — Soak and long-run evidence is bounded
Status: Open · NON-BLOCKING · MANUAL TEST REQUIRED
Description: the automated soak is a few minutes of scripted tasks on the real engine/DB; multi-hour real-provider runs, battery impact and real-quota behaviour belong to V1.0 / manual testing. Measured: 371 scripted tasks in 2 minutes → RSS 104→114 MB, no provider process left, but the database grew ≈ 24 KB per task (tasks, steps, attempts, agent runs, events are history and are never pruned; only artifacts/routing/graph rows are). A real day of use is far smaller; a pruning/archival policy for task history is a V1.0 question.

### JARVIS-V12-12 — Pre-existing race fixed: a dependent of two parallel readers could start twice
Status: Resolved (V0.12)
Description: found by the V0.12 live test. `scheduleLoop` did not exclude nodes already in flight, so a node whose last two dependencies finished at nearly the same time could be started twice (two attempts, two provider runs). Now a started node is never started again; regression-tested (`every node ran exactly once`).

### JARVIS-V12-13 — Pause does not exist
Status: By design
Description: a provider/tool state cannot be suspended truthfully (DEC-032 unchanged). Stop, Resume after interruption and approvals are the controls.


## V0.13 (Project operator, Unity development operator, visual grounding, experiments)

### JARVIS-V13-1 — Real Hamam project readiness is a manual test
Status: Open · MANUAL TEST REQUIRED
Description: every automated and live test used disposable fixtures (a disposable Git project, the Unity fixture, a real public asset in the quarantine). Whether "continue" does what the user means on THEIR game, and how good its choices are, can only be judged by them. README 824–986.

### JARVIS-V13-2 — Experiments and the correction loop run in the built-in render pipeline
Status: Open · NON-BLOCKING
Description: URP mirroring would need Unity's package registry (Unity's own traffic) and a matching pipeline asset. An experiment says what it tested; it never claims URP behaviour it did not test (`Probably compatible with URP` stays INFERRED).

### JARVIS-V13-3 — Audio is not heard
Status: By design
Description: JARVIS reports the configured clip and `isPlaying`; it cannot hear a headless editor. "Sounds right" is the user's call.

### JARVIS-V13-4 — A glTF-only free asset is refused as delivered
Status: Open · NON-BLOCKING
Description: the real run on a Poly Haven bucket acquired a 5.6 KB `.gltf` JSON; Unity has no built-in glTF importer, so the experiment was REFUTED ("nothing could be instantiated") and the evaluation says "Do not use as delivered". Converting formats or installing a glTF package is outside V0.13 (no package installation).

### JARVIS-V13-5 — The vision helper is cold for ≈ 3–8 s
Status: Open · NON-BLOCKING
Description: the first vision query after the helper has been unloaded loads the model (Qwen3-VL-4B ≈ 4 s, plus 1–4 s for the answer and the count check). Not kept resident on purpose (idle unload 45 s, no load under memory pressure). Choose the 2B model in Settings for a smaller footprint.

### JARVIS-V13-6 — Screen Recording / Accessibility are the user's to grant
Status: By design
Description: live visual tests need the permissions the V0.11 test already needs; JARVIS never grants them to itself and says so when missing.

### JARVIS-V13-7 — The V0.11 live test had an intermittent Accessibility check
Status: MITIGATED (V0.13.1) — production flaw fixed and unit-tested; the ENVIRONMENTAL trigger was never identified, so this is not called "resolved"; reopen if it recurs
Description: `CONTEXT: with “in the Inspector” … is pressed` failed in 5 of 9 V0.13 runs. V0.13.1 captured the failing state: the fixture HAD counted the click (the handler ran) while `AXUIElementPerformAction(AXPress)` returned an "unsupported" class error, so the executor reported a failure on the return code (attempts = 1, no duplicate press). That is a real defect in the executor, not a test race: an AX return code is not the outcome of the action.
Fix (DEC-206): on `unsupported` the executor makes one read-only cross-check (≤ 1.5 s) of the expected state — seen ⇒ VERIFIED ("took effect, not repeated"), not seen ⇒ FAILED; never a second press. Stale-screen, restart and target-fingerprint rules are unchanged; no sleep, retry or weakened assertion was added. Unit tests: `unsupportedAnswerButEffect` / `unsupportedAnswerNoEffect`.
What was NOT found: why the application answered "unsupported" in the failing window (≈ 22:37–22:55 on the dev Mac) and not afterwards — the error class stopped reproducing even before further changes. Evidence after the fix on the final code: 40/40 focused CONTEXT runs, 10/10 full `--computer-live-test` runs (95/0/2 each), 10/10 safe-task restart cycles; earlier on the same fix: 150/150 and 40/40 focused, 8/8 full, 30/30 repro. Before: 5 failures in 9 V0.13 runs. V0.12's binary failing `RESTART (part 1)` instead was a child-data-directory contamination of that check, fixed in the test (V0.13.1 restart cycle).
Two further test-side flaws found by the same repetition and fixed at the cause (not masked): the full-test "RESTART SAFE CYCLE" used a `.stateChanged` check on a label that already read the target value; and an icon-only press with a COLD vision model aged its own screenshot past the 6 s rule (model load ≈ 5 s) — the model is now loaded BEFORE the picture is taken (`VisionProposing.prepare`), the 6 s rule is unchanged.

### JARVIS-V13-8 — A real model-planned Unity graph needs enough evidence for its reviewer
Status: Resolved (V0.13)
Description: the first real runs failed at the independent Review node because the evidence lines lacked positions / values and a later step guessed a child's path. Edit prompts now carry what earlier steps changed (with the editor's real paths) and evidence lines carry the read-back values. One real run completes (35 s); other models / goals may still fail honestly.

### JARVIS-V13-9 — Experiments could never import an asset while inside the data folder
Status: Resolved (V0.13)
Description: found by the real asset run — the workspace guard refuses `…/Library/Application Support/JARVIS` as a project. The experiments root moved to `~/Library/Caches/JARVIS/experiments-<data dir>`.

### JARVIS-V13-10 — A refuted experiment was first evaluated as "technically fine"
Status: Resolved (V0.13)
Description: found by the same run. `AssetEvaluator` now follows the verdict (REFUTED ⇒ INCOMPATIBLE fact + "Do not use as delivered"; compatibility is TESTED only when the experiment CONFIRMED).

### JARVIS-V13-11 — A single box from the local model was not proof of a single match
Status: Resolved (V0.13)
Description: found by the icon-only live test (two identical star icons were clicked once). The helper now asks a counting question before accepting a single box; two or more ⇒ AMBIGUOUS.

### JARVIS-V13-12 — Live tests that finish early used to leave a started editor behind
Status: Resolved (V0.13)
Description: `exit()` skips the app's quit hook; the operator and continuity live tests now kill registered child processes before exiting.

### JARVIS-V13-13 — A model-planned continuation of a one-line fix still plans a research node
Status: Open · NON-BLOCKING
Description: the real continuation of "fix add()" ran `delegateResearch → analysis → test → codeChange → test → review` (80 s). The V0.12 planner chose it; a deterministic template for a documented one-file fix would be cheaper. Not changed in V0.13 (no speculative orchestration changes).

### JARVIS-V13-14 — Cloud vision is not integrated
Status: By design
Description: a Claude Code image probe works over the user's subscription but would send screen content out. Documented as an option; not implemented (docs/VISUAL_GROUNDING.md).

### JARVIS-V13-15 — Experiments judge "plays", never "sounds right"
Status: By design
Description: the audio experiment proves `isPlaying` in Play Mode and that the configured clip is the generated tone; JARVIS cannot hear. "Sounds right" is UNKNOWN in every report.

### JARVIS-V13-16 — Input System operations need the package in the project
Status: By design
Description: the bridge never installs or upgrades a package. Without `com.unity.inputsystem` the operations answer "package missing". Unity 6000.5.1f1 was the only version tested.

### JARVIS-V13-17 — A cold local vision model is ~5 s on first use
Status: Mitigated (V0.13.1)
Description: the model loads before the picture is taken, so the stale-screen rule is not hit; the first icon-only press after idle still costs the load time.

### JARVIS-V14-1 — The MCP sandbox is not a VM
Status: By design (documented)
Description: Seatbelt (`sandbox-exec`, deprecated by Apple) plus a sanitised environment. It runs as the SAME macOS user; CPU/memory are sampled and killed, not capped; world-readable system files remain readable; the Mach-service deny-list is best effort. Every benchmark report prints the boundary. If Apple removes `sandbox-exec`, the report says "sanitised environment only" and no server should be approved.

### JARVIS-V14-2 — Only one real MCP candidate was benchmarked
Status: Open
Description: real research covered 3D/Blender, design, audio, animation and Unity; the cochlea-mcp candidate was built inside the sandbox and benchmarked. The Blender MCP exposes arbitrary-code execution and needs a running Blender add-on, so it was researched and statically inspected but NOT benchmarked or recommended. Design/animation candidates were researched only.

### JARVIS-V14-3 — GitHub discovery is rate-limited and noisy
Status: Open
Description: unauthenticated GitHub API (60 core requests/h, 10 searches/min; JARVIS never adds a key). The registry-name filter still matches substrings such as "mcprep"; relevance is double-checked on the README but results can include non-MCP repositories. Discovery may need a retry after a registry timeout.

### JARVIS-V14-4 — Learned behaviour needs real history
Status: Open (manual)
Description: thresholds (3 independent episodes) mean a fresh install learns nothing for several tasks. Real learning quality on the user's own projects is unknown until used; live tests use generated, disposable histories (labelled ENGINE/POLICY).

### JARVIS-V14-5 — Self-improvement is verified only on disposable fixtures
Status: By design
Description: `selfRepositoryPath` is assigned only by live tests; the app default is none. Changing JARVIS' own source from the app needs a deliberate configuration that does not exist in the UI yet.

### JARVIS-V14-6 — Voice can only create a request
Status: By design
Description: "install / delete this MCP" by voice creates an HUD request; approval happens only by clicking. Spoken "yes/evet" approves nothing.

### JARVIS-V14-7 — Smoke composer/paste keyboard checks are timing-sensitive
Status: Mitigated (V0.14)
Description: `--smoke-test` checks "Composer grows for multiline content" and the ⌘V paste checks failed intermittently (also on the V0.13.1 baseline c44f942) when synthetic key events raced focus or layout. Mitigated: `press` waits for the key window and settles longer, the composer check waits for the layout; 7/7 consecutive passes plus a full `verify.sh` afterwards. Root cause is the synthetic-event delivery, not product code.

### JARVIS-V14-8 — MCP wrappers for real servers are generic
Status: Open
Description: typed wrappers validate arguments against the server's own schema and classify risk by name/description/parameters; a domain-specific wrapper (e.g. Blender object creation) still has to be written per accepted server.

### JARVIS-V15-1 — The final custom JARVIS voice is not selected
Status: Open (intentional)
Description: the output architecture is pluggable (`TextToSpeechProvider`), Apple system voices and the local neural voice work; the "real" JARVIS voice is chosen later (V1.0). Nothing is cloned or downloaded.

### JARVIS-V15-2 — Human acoustic validation is pending
Status: Open (manual)
Description: push-to-talk, wake word, barge-in, Turkish / English recognition and voice naturalness were tested with synthetic speech and fixtures only. README 1153+ asks for human tests.

### JARVIS-V15-3 — Ad-hoc signed, not notarized
Status: By design (documented)
Description: this Mac has no code-signing identity; the app is ad-hoc signed with the hardened runtime and not notarized. A local copy opens from Applications; a downloaded copy would show Gatekeeper warnings. Not sandboxed (see `docs/APP_PACKAGING.md`). macOS ties privacy permissions to the signature: a different signature (e.g. a future Developer ID build) will ask for them again.

### JARVIS-V15-4 — Setup needs `uv` and the network, and the app does not install `uv`
Status: By design
Description: the five Set Up buttons run the pinned scripts, which use `uv`, PyPI and Hugging Face. Without `uv` the button refuses and says so. The Set Up flow's disk-space numbers are estimates; hash-pinned downloads (wake models, memory model) are verified by the scripts; the Hugging Face model downloads are pinned by revision (no hash is available from the source).

### JARVIS-V15-5 — Launch at Login and notifications need a real login / real delivery to be trusted
Status: Open (manual)
Description: the registration state is read and set through `SMAppService`, which may answer "requires approval" for an ad-hoc signed app; actual start-at-login after a reboot and notification delivery (focus modes) were not exercised automatically.

### JARVIS-V15-6 — Follow-up resolution edge cases
Status: Open
Description: the resolver is deliberately narrow (short imperatives with an opening or closing verb, ≤ 7 words) and prefers asking to guessing. Unusual phrasings fall through to the normal pipeline (a model answers). Unity-object references exist only after a typed Unity result names them; "biraz sola al" works on a single known object. Turkish suffix handling is prefix-based.

### JARVIS-V15-7 — The first-run walk-through opens the Full HUD on the real data
Status: By design
Description: the installed app uses your real Application Support data from its first launch (no separate profile). The walk-through is skippable and requests nothing by itself.

### JARVIS-V15-8 — Spoken completion is skipped while JARVIS is already speaking
Status: By design
Description: a completion never interrupts speech in progress and never opens the microphone; it can therefore be silent when the user is mid-conversation (the message is still in the conversation).

### JARVIS-V15-9 — Local model folder change applies after restart
Status: Open
Description: "Select Existing Model Folder" stores the path; the local runtime configuration is read at launch.

### JARVIS-V15-10 — Provider authentication is only what the safe probe can tell
Status: By design
Description: READY for Claude Code / Codex means the existing status probe succeeded; it does not prove a subscription limit has not been reached or that the account can run a particular model. JARVIS never reads credentials.

### JARVIS-V15-11 — An ad-hoc signed app loses its macOS privacy grants on every reinstall
Status: Open (by design of ad-hoc signing)
Description: macOS ties Microphone / Accessibility / Screen Recording to the exact code signature. An ad-hoc signature is the hash of the build, so each new `JARVIS.app` is a new app to macOS and asks again (verified: after reinstalling, the same bundle id read PERMISSION NEEDED / NOT SET UP). Re-grant on first use (the first Push-to-Talk hold shows the microphone prompt; Accessibility via “Allow Accessibility”). A stable signature (a Developer ID, or a self-signed code-signing certificate you create in Keychain Access) would keep the grants across updates; JARVIS does not create one on its own.

### JARVIS-V15-12 — Voice is OFF by default
Status: By design (made visible in V1.0 stabilisation fix 1)
Description: the installed app starts with Voice off, so holding the right ⌥ key does nothing audible. JARVIS now says so (hint after the hold; Readiness “Voice input · Push-to-Talk (hold right ⌥): OFF” with a Turn On Voice button; “Her şey hazır mı?” mentions it). Switching Voice on is always your click.

### JARVIS-V15-13 — A capability question phrased outside the recognised grammar still reaches the conversation model
Status: Open
Description: the introspection grammar is deliberately strict (it must not swallow real requests such as “Can you use Claude Code to fix the bug?”). An unusual phrasing of a capability question falls through to the model, which knows nothing about this installation. Report such phrasings and they are added as tests.

### JARVIS-V15-13 (update, V1.0 fix 2)
Status: Mitigated
Description: the provider identity firewall (DEC-248) now also replaces an engine reply that denies or overclaims an ability, and the engine instruction no longer says “you cannot read files”. A capability question still has to match the strict grammar to be answered without a model; the firewall is the second line of defence.

### JARVIS-V1F2-1 — A false engine claim is visible for the length of one streamed reply before the firewall replaces it
Status: Open (by design)
Description: `CapabilityClaimGuard` runs on the finished reply; the text streams first. In a spoken turn the claim is replaced before the reply is spoken (speech starts after the answer completes). Report any phrasing it misses so the sentence list can be extended.

### JARVIS-V1F2-2 — Real acoustic wake-word behaviour is not automated
Status: MANUAL TEST REQUIRED
Description: the V0.8 benchmark and the closed-loop live test measure the detector, latency and resources with synthetic audio; whether “Jarvis” wakes the installed app from your voice, in your room, with your Mac's microphone, and how often ordinary talk wakes it, can only be judged by you. Microphone permission for the ad-hoc signed installed app must be granted again after every rebuild (JARVIS-V15-11).

### JARVIS-V1F2-3 — Wake recovery after sleep or a device change is bounded
Status: By design
Description: after the Mac wakes or the audio device changes, wake listening is retried twice (2 s, 6 s). If the device is still unavailable it stays UNAVAILABLE with an instruction; turn the Wake Word off and on again (Settings, menu bar or “wake word'ü kapat / aç”) to retry. Nothing retries forever.

### JARVIS-V1F2-4 — “Show Developer Controls” no longer shows the state simulator in the installed app
Status: Resolved by design (DEC-247)
Description: the simulator, demo tasks and agent simulation exist only in developer launches (`--dev-demo`, `--capture`, `--smoke-test`).

### JARVIS-V1F3-1 — Ad-hoc signing: macOS permissions do not carry over between builds
Status: Open (limitation; explained in the UI)
Description: Accessibility, Screen Recording and Microphone are bound to the exact code identity. Every install of an ad-hoc build is a new identity, so after installing build N you must switch the permission on again for THAT build (remove the old JARVIS entry with − and add /Applications/JARVIS.app, or toggle it). System → "This JARVIS" shows the signature and says when the build is new. Screen Recording additionally applies only after a restart (Restart JARVIS). A stable signing identity would remove this; none exists on this Mac.

### JARVIS-V1F3-2 — The Unity live tests leave `unity.DefaultCompany.jarvis-*-live-*.plist` files in ~/Library/Preferences
Status: Open (cosmetic)
Description: Unity's own player preferences for the disposable fixture projects of `--unity-live-test`, `--operator-live-test` and the soak. They belong to Unity, not to JARVIS, and are not removed automatically.

### JARVIS-V1F3-3 — The visual design is judged by a person
Status: HUMAN UI APPROVAL REQUIRED
Description: layout, alignment and rendering were checked with rendered captures of the installed binary and geometry tests; whether it feels like a finished macOS product is Bilal's call (README 1259–1267).

### JARVIS-V1F4-1 — Real acoustic self-echo behaviour is not automated
The envelope confirmation and the provenance guard are proven on synthetic level series and on the hands-free coordinator with a fake microphone (observed chain reproduced by the legacy detector, fixed by the new one). Whether they hold in Bilal's room, with his speakers/headset and the neural voice's buffering, is a human test (README 1268–1277). A delay above 0.7 s (some Bluetooth chains) is outside the searched range. The gain-ducking probe and a platform echo canceller are NOT implemented.

### JARVIS-V1F4-2 — Media control is not yet proven against a real player
The Play/Pause press is unit-tested on a virtual UI and needs Accessibility; `Tests/Fixtures/media-player.page` (rename to .html to open) is a local page for a manual check. Sites whose player controls are not exposed as buttons named Play/Pause are not handled.

### JARVIS-V1F4-3 — Apple dictation contextual strings have an unmeasured effect
The vocabulary is passed through `AnalysisContext.contextualStrings`; whether it changes recognition of "Safari" was not measured. The sound-shape fallback in action context covers the observed mis-hearings without it.

### JARVIS-V1F4-4 — Typed actions reply after their read-back
A rapid sequence of page commands can show a reply after a later question (replies land once verified). `ConversationService.waitUntilIdle` waits for them.

### JARVIS-V1F4-5 — Permissions are lost again with the new ad-hoc build
Build 110 reports Accessibility false, Screen Recording false, Microphone not determined (cdhash 3a9064ac); macOS ties permissions to the exact ad-hoc build (see JARVIS-V1F3-1).
