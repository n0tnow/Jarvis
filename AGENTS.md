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
- Automated runs (unit tests, `--smoke-test`, `--capture`, `verify.sh`) must NEVER start real Claude Code / Codex / OpenCode / the local model or spend quota: tests use fake CLIs and a fake local worker with a temp SQLite database; the app stubs every engine (`AppContext(stubIntelligence:)`) in those modes. Real requests only via the explicit `--provider-live-test` / `--intelligence-live-test` / `--task-live-test` (and report them as REAL TESTED).
- V0.3.1 cost/privacy rules (DEC-022…028): no paid API ever; a model is FREE only when OpenCode's *current* price data is all-zero on the keyless tier (never by name or cache); unknown price ⇒ never automatic; the local model is for lightweight tasks only (`LocalModelPolicy`, enforced in code); an explicit provider choice never falls back; sensitive text never goes to free cloud; every run is audited with a machine-readable reason; never commit `*.sqlite`, model files or secrets (`verify.sh` checks).
- V0.4 task-engine rules (DEC-033…040): tasks are USER-INITIATED only (no proactive work before V0.5); providers stay text-in/text-out — project files are changed only by `Tasks/ProjectTools` (capability + workspace + lease checked), commands only through `ApprovedExecutables`/`ManagedProcess` (no shell); `gitCommit`/`gitPush`/`purchase`/network/browser can never be granted; JARVIS never runs `git reset/clean/checkout/commit/push`; destructive steps and edits to user-dirty files wait for approval; progress = validated steps only; interrupted tasks resume only by explicit user action; automated tests use isolated temporary Git fixtures, never the JARVIS repository. `verify.sh` guards these — extend it, never weaken it.
- V0.5 rules (DEC-041…046): the proactive layer (`Sources/Jarvis/Proactive/`) only decides — it never writes files, runs processes, polls or approves anything; approved/automatic actions become normal V0.4 tasks via `TaskEngine.submit`; policy outranks confidence (confidence is evidence, not authority); only `ProposalService` records decisions and only from HUD buttons; default mode Ask Before Acting; at most 1 auto task per user task, depth 1; critical actions are never automatic and approval never grants capabilities. `--proactive-live-test` is the explicit real test (OpenCode FREE, isolated fixtures). `verify.sh` enforces this.
- V0.6 Unity rules (DEC-047…056): Unity is reached ONLY through the typed `UnityOperation` enum and the JARVIS-owned Editor bridge (local file spool); there is no operation that carries C#, a menu item, a shell line or AppleScript, no third-party MCP, no network, no Asset Store/download/package installation/project upgrade; Unity steps are V0.4 steps (Unity tool layer inside the engine, mutation lock, Play Mode and user-dirty-scene protection, deterministic validation outranks subjective review, no fake visual validation); Unity output is sanitized at its choke points and never stored raw; only editors JARVIS started are closed; the user's real game is never an automated test target (`--unity-live-test` uses a disposable fixture). `verify.sh` enforces this.
- V0.7 Voice rules (DEC-057…068): voice is an I/O layer — a FINAL transcript enters the conversation ONLY through `ConversationService.submit(source: .voice)` (the typed path); the microphone is explicit (hold right ⌥), opens on press, closes on release, never at launch/in tests, raw audio is never persisted (`NSMicrophoneUsageDescription` is the only privacy key); voice has no authority (no code path from a transcript to an approval/task decision, `yes`/`approve` is never a decision); speech providers are local/system only (PAID/UNKNOWN never auto, no API keys, no cloud speech); the speech helper is a `ManagedProcess` that never outlives JARVIS; spoken text = the shown answer (`SpeechRenderer`/`SpeechChunker`), long answers bounded, stop works at once. `--voice-live-test` is the explicit real test (synthetic speech, volume 0 unless `--voice-audible`). `verify.sh` enforces this.
- V0.8 Natural-voice rules (DEC-069…086): wake mode is OPT-IN and OFF by default; before the wake word only the local sentinel hears bounded in-memory audio (no STT, no transcript, no network, no file); a lone wake word never opens the recogniser; wake is activation, not authentication (voice authority = typed authority; spoken "approve" never approves); ONE `MicrophoneHub` feeds wake and Push-to-Talk, ONE output engine (`SpeechPlayer`, output only) plays all speech; JARVIS must never create a turn from its own voice; barge-in uses JARVIS' own known output (no echo-canceller claim); the neural voice is a local helper with Apple fallback, models/runtimes are installed ONLY by `scripts/setup_voice_ai.sh --natural` / `train_wake_head.sh` (pinned, never committed, never downloaded by the app), no cloud/paid speech, no API key, no reference-voice cloning; the JARVIS voice identity is original. `--natural-voice-live-test` is the explicit real test (closed acoustic loop, silent; `--natural-acoustic` is the only part that uses the real microphone and speaker). `verify.sh` enforces this.
- V0.9 web rules (DEC-088…102): authority levels are separate — research (`researchWeb`), acquisition (`downloadToQuarantine`), project import (`importIntoProject`, a separate approval-gated V0.4 task; only `AssetImporter` writes into a project) — and account actions / purchases / subscriptions / paid APIs have NO code path (`useNetwork`/`useBrowser` stay ungrantable). Web text is untrusted data, never instructions; snippets are never evidence; UNKNOWN price is never free and unknown licence is never safe; model claims need verbatim evidence. ONE production URL policy (SSRF, per-hop checks; no loopback exemption even in tests — fixtures use virtual public hosts); `URLSession`/`WKWebView` only in `Research/HTTPTransport|WebClient|RenderedPageProvider`; read-only non-persistent browser tier, no cookies/passwords/CAPTCHA bypass; no paid search API or key. Downloads go to the quarantine (https, bounded, hashed, sniffed, archives inspected before extraction, never executed, never trusted); research is bounded and never runs while idle; automated tests import only into disposable fixtures. `--research-live-test` is the explicit real test (live public web; no login, purchase or project change). `verify.sh` enforces this.
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
