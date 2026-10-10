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

### JARVIS-003 — Real-click OPEN JARVIS, real ESC on Full HUD, resize-drag, click-outside dismissal not externally automated
Status: Open · MANUAL TEST REQUIRED
Description: The user declined further System Events automation; per policy no permission was added. Covered instead by in-process checks (real ESC `NSEvent` through the responder chain; `showFullHUD`; `windowWillResize`). Real menu-bar click open/close and compact ESC *were* observed earlier via System Events.

### JARVIS-004 — Dev tooling is compiled into the release binary
Status: Open · NON-BLOCKING
Description: `--smoke-test`, `--capture` (looks up `CGWindowListCreateImage` via `dlsym`; only captures own windows), `DevStateStrip` ship in release. Inert without launch args; strip is hidden via Settings.
Next: gate behind `#if DEBUG`/a dev build config when a distribution build exists.

### JARVIS-005 — Memory is not released after closing the Full HUD
Status: Open · NON-BLOCKING
Description: RSS ≈ 40 MB idle → ≈ 95 MB after Full HUD is first opened; windows/hosting views are kept for fast reopen. Acceptable for V0.1.

### JARVIS-006 — Menu-bar icon animation costs ~1.5 % of a core in animated states
Status: Open · NON-BLOCKING
Description: 0.5 s timer redraws the status button in listening/thinking/working. 0 % otherwise. Reduce Motion stops it.

### JARVIS-007 — Minimum window (980×620) is dense; centre column scrolls
Status: Open · NON-BLOCKING (polish)
Description: At minimum size the centre column falls back to a scroll view without indicators; side panels may clip. Content remains reachable.

### JARVIS-008 — Keyboard/focus polish
Status: Open · NON-BLOCKING / FUTURE
Description: No @FocusState management, no shortcuts for Approve/Deny or section switching; section tabs aren't grouped as a labelled container; decorative-size nits.

### JARVIS-010 — Architecture items for later milestones (from review)
Status: Open · FUTURE MILESTONE
Description: Store mutations target "first active task" (need task-id addressing for V0.4); `AgentSlot/ToolSlot/ProjectSummary/ApprovalRequest` not Codable; no "interrupted" task status; `setState` has no arbitration among STT/LLM/task engine; `LocalCommandHandler` has no response channel (V0.2); `isFullHUDOpen` is `isVisible` (true even if occluded); `observeContinuously` has no cancel handle. See `ARCHITECTURE.md` → extension points.

## Resolved

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
