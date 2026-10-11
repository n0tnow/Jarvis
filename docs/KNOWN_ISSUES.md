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

### JARVIS-013 — Deterministic router limits (V0.2)
Status: Open · NON-BLOCKING
Description: Matching is alias/phrase based, not NLP: unusual phrasings fall through to "needs a provider" (truthful, never a wrong action). A bare "stop"/"close"/"clear"/"open" is treated as a command. Turkish coverage is a small explicit alias set; replies are English except for Turkish input. Worker-vs-reasoning is a keyword heuristic (verb + technical noun).

### JARVIS-014 — Conversation is in-memory only
Status: Open · FUTURE MILESTONE (V0.4/V0.8)
Description: Messages are Codable and bounded (500) but not persisted; cleared on quit. Provider-side sessions are kept by the CLIs.

## Resolved

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
