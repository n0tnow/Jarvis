# AGENTS.md — operating instructions for AI coding agents

JARVIS is a native macOS menu-bar AI operating layer. The repository — not chat history — is the source of truth.

## Session bootstrap (do this BEFORE editing anything)

Read, in order:
1. `PROJECT_STATE.md`
2. `docs/CURRENT_TASK.md`
3. `docs/ARCHITECTURE.md`
4. `docs/DECISIONS.md`
5. `docs/KNOWN_ISSUES.md`
6. `docs/ROADMAP.md`

Then run `git status` and `git log --oneline -10` (always, before editing), and read the source files relevant to your task. Never assume earlier conversation context exists.

## Rules

- Do not start the next milestone without explicit user approval. V0.1 must be approved by the user's manual test first.
- Do not introduce paid API dependencies without explicit user approval. Never add API keys, tokens or secrets to the repo.
- Prefer native/macOS-supported approaches. Avoid third-party dependencies (V0.1 has zero).
- Do not silently change anything recorded in `docs/DECISIONS.md`; add a new decision (superseding the old one) instead.
- Preserve working systems unless the current task requires changing them. No speculative refactors.
- Verify after meaningful changes: `scripts/verify.sh` (tests + bundle + permission audit + smoke test + idle CPU).
- Distinguish automated testing from user manual verification. Never mark something working, verified or COMPLETE unless it was actually tested; never mark "manually verified" unless the user did it.
- Do not request macOS permissions (Microphone, Accessibility, Screen Recording, Automation) until the feature that needs them exists. Do not request them just to automate tests.
- Never drive per-frame animation from SwiftUI `TimelineView`/`Canvas` (≈30 % CPU, DEC-006/012): use the AppKit renderers (display link, torn down when hidden, off under Reduce Motion).
- No global event monitors/taps (`addGlobalMonitorForEvents`, `CGEventTap`, Carbon hotkeys) without explicit user approval — they need privacy permissions (DEC-008/013). `scripts/verify.sh` greps for them.
- Automated runs (unit tests, `--smoke-test`, `--capture`, `verify.sh`) must NEVER start real Claude Code / Codex or spend subscription quota: tests use fake CLIs; the app stubs providers in those modes. Real requests only via the explicit `--provider-live-test` (and report them as REAL TESTED).
- Provider rules (DEC-020/021): never handle credentials, never set API keys, never use `--bare`/dangerous flags/shells, never send deterministic commands or `workerRequired` requests to a provider, never silently fall back to another provider or a paid API. `verify.sh` enforces most of this.
- Keep demo data inside `Sources/Jarvis/Services/Demo`; production code must not depend on it.
- Update `docs/CURRENT_TASK.md` at meaningful checkpoints, `docs/DECISIONS.md` after architectural decisions, `docs/KNOWN_ISSUES.md` for persistent bugs (mark Resolved, don't delete). Before ending a significant session update `PROJECT_STATE.md`, `docs/CURRENT_TASK.md`, `docs/DEVELOPMENT_LOG.md`.
- Documentation must reflect reality. Use the states: PLANNED · IN PROGRESS · IMPLEMENTED · AUTOMATED TESTED · MANUAL TEST REQUIRED · MANUALLY VERIFIED · BLOCKED.
- Keep docs short and non-duplicated; link instead of copying.

## Environment notes

- No Xcode on the original dev machine (Command Line Tools only): the project is a Swift Package; `scripts/build_app.sh` assembles `build/Jarvis.app`. Tests need extra linker flags — always use `scripts/test.sh`, not bare `swift test`.
- Dev launch args (see `Sources/Jarvis/App/LaunchOptions.swift`): `--smoke-test`, `--capture <dir>` (renders JARVIS's own windows to PNG without Screen Recording permission), `--open-full`, `--open-compact`, `--section`, `--state`, `--close-after`.

## Git Workflow

- `main` is currently the only development branch. Remote: `origin` → https://github.com/n0tnow/Jarvis.git.
- Do not create branches (develop/feature/agent/release/…) or pull requests unless the user explicitly asks. Linear history on `main`.
- Before modifying code, inspect `git status` and `git log --oneline -10`. Never discard unexplained user changes.
- Commits: small enough to understand, large enough to be a coherent engineering change and a useful recovery point. No "update"/"fix"/"wip"/"misc" commits; don't commit every tiny edit.
- Message style: Conventional Commits — `feat|fix|refactor|perf|test|docs|build|chore(scope): summary`. The title describes the project change, not which AI produced it.
- Do not commit a knowingly broken build. Run the appropriate verification first (`scripts/verify.sh` before milestone commits).
- Docs describe the state contained in the commit: update `docs/CURRENT_TASK.md`, `PROJECT_STATE.md` (if milestone state changed) and `docs/DEVELOPMENT_LOG.md` (plus `DECISIONS.md` / `KNOWN_ISSUES.md` when relevant) **before** committing; never commit source and leave the memory docs describing the previous state.
- Checkpoint sequence: finish a coherent unit → build/test → update docs → review `git diff` → commit → push (only when verification is acceptable).
- Never commit secrets/credentials, build products (`build/`, `.build/`, `*.app`), or temp logs/screenshots (`captures/` is git-ignored and regenerable).
- Never force-push. Never rewrite shared history without explicit user approval.
- Do not push unrelated or unverified work. After an approved milestone/checkpoint: commit, push to `origin/main`, and report the commit hash.
- Tags only for USER-APPROVED milestones (e.g. `v0.1` after the user's manual test passes). No tags or GitHub releases for ordinary checkpoints. Do not configure GitHub features (Actions, Issues, Pages, protection) unless asked.
- If a push fails on authentication, do not retry in a loop — report the exact command/action needed.
