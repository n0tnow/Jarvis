# Development Log

Append-only engineering history. Newest entries at the bottom.

## 2026-10-10 — V0.1 Foundation (sessions 1–3, including two interruptions)

### Goal
Native macOS foundation + HUD, no AI. Then recover from interruptions, finish verification, write project memory.

### Environment
macOS 26.4, arm64 (M5), Swift 6.3.2, SDK 26.5, **Command Line Tools only (no Xcode)**; empty directory, no git history.

### Changes
- Swift Package + `scripts/build_app.sh` (ad-hoc signed bundle), `scripts/test.sh`, later `scripts/verify.sh`.
- Models/Core/Services/UI layers; `NSStatusItem` + Compact HUD panel + Full HUD window via `WindowManager`; design tokens; glass surfaces; 7-state core visualization; demo data/dev tooling; settings.
- Visual-inspection loop using an in-process capture tool (Screen Recording permission deliberately not requested).
- CPU investigation: SwiftUI Canvas/TimelineView ≈ 30 % of a core (independent of canvas content/fps) → AppKit `CoreNSView` + `CADisplayLink` ≈ 9 %; menu-bar icon caching.
- Recovery session: repo health re-verified; read-only reviews (architecture: no blockers; UI/a11y; test gaps) → fixes: state↔task coherence, narrow-width dev strip, approval VoiceOver announcement, Settings ESC/⌘W, accessibility identifiers, stronger smoke test (28 checks), `scripts/verify.sh`, 6 coherence unit tests.

### Tests
- Unit 17/17; smoke 28 PASS / 0 FAIL / 2 SKIP; `scripts/verify.sh` → VERIFY PASSED; screenshots of all states + minimum size; CPU idle 0 %, Full HUD animating ≈ 9 %.
- Earlier in recovery: real menu-bar click open/close and compact ESC observed via System Events (host-terminal AX).

### Problems Found (all fixed unless in KNOWN_ISSUES.md)
Incoherent dev state switching; text too small; truncation; min size (0,0); layout collapse at min width; high animation CPU; icon re-rasterization. Open: JARVIS-001…010.

### Decisions
DEC-001…DEC-010 (`DECISIONS.md`).

### Process notes
The user interrupted External-UI-automation (System Events) tool calls twice; not retried. Real OPEN JARVIS click and physical ESC on Full HUD are MANUAL TEST REQUIRED. Docs were not written until the final session — written now.

### Remaining Work
User manual test of V0.1 (README checklist). Then, only with approval: V0.2.

## 2026-10-10 — Git workflow + V0.1 baseline publish

### Goal
Establish a simple durable Git workflow and publish the verified V0.1 candidate.

### Changes
- Added `origin` = https://github.com/n0tnow/Jarvis.git; `main` only (DEC-011); "Git Workflow" section in `AGENTS.md`.
- `.gitignore` audited (build products, `.build/`, `captures/`, Xcode/macOS noise, secret-file patterns) — unchanged.
- Secret scan of the working tree: nothing found.
- Single baseline commit `feat(v0.1): establish native macOS Jarvis foundation` (no fabricated history). Repo-local author identity uses the GitHub noreply address.

### Tests
`scripts/verify.sh` re-run before the commit (see commit/PROJECT_STATE for results).

### Decisions
DEC-011. JARVIS-009 resolved.

### Remaining Work
User manual test of V0.1. No `v0.1` tag until approved.

## 2026-10-10 — V0.1.1: compact stability, neural background, global hotkeys

### Goal
Three user-requested fixes after manual V0.1 testing (overall direction approved): (A) Compact HUD must not resize between states, (B) subtle ambient neural-network visuals, (C) global ⌥⌘ / ⌥⌘⌘ shortcuts. No V0.2 work.

### Changes
- **A** `CompactHUDLayout` (392×448), window `sizingOptions=[]`, fixed-height task card, 0.2 s inner crossfade (off under Reduce Motion). Root cause: `.preferredContentSize` + `fittingSize`. Commit `fix(compact-hud)`.
- **B** `NeuralGraph`/`NeuralSimulation` (pure, seeded) + `NeuralNetworkNSView` (Core Graphics, CADisplayLink 5–15 fps by state, torn down when hidden/Reduce Motion) behind the Full HUD only; core frame rate made state-based. Commit `feat(hud)`; DEC-012.
- **C** `ModifierChordMachine` (pure) + `GlobalHotkeyService` (permission-free polling) + `toggleFullHUD`; Settings info rows + off switch; version → 0.1.1. DEC-013, DEC-014.

### Tests
Unit 36/36 (was 17): chord machine (single, double, timeout, early Option release, repeat flood, resets, invalidation by other key/click/Shift, cooldown), service, neural graph/simulation, compact constants. Smoke: compact frame constant across 7 states × dev strip on/off × task/no task; neural lifecycle + Reduce Motion + hidden stop; scripted ⌥⌘/⌥⌘⌘ → real WindowManager (Compact never flashes during Full chord, no duplicate windows). CPU table in PROJECT_STATE.

### Problems found
Settings window too short for the new section (fixed); capture tool lost compact focus intermittently (retry added); first neural pass was nearly invisible and +3 pts CPU (visibility raised, frame rates lowered, core fps made state-based).

### Decisions
DEC-012, DEC-013, DEC-014.

### Remaining Work
User manual test (README checklist: fixed compact size, global shortcuts from another app, neural look, Reduce Motion). No tag until approved.
