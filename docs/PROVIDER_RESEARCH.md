# Provider Research (V0.3)

Researched 2026-10-10 from official docs + the actually installed tools. **Evidence level is stated per claim.**
No account identifiers, tokens or credentials are recorded here (and none were read).

Sources (official): Anthropic — *Run Claude Code programmatically* (code.claude.com/docs/en/headless), *Legal and compliance* (code.claude.com/docs/en/legal-and-compliance), `claude --help`. OpenAI — *Non-interactive mode* (learn.chatgpt.com/docs/non-interactive-mode, formerly developers.openai.com/codex/noninteractive), *App server* (learn.chatgpt.com/docs/app-server), `codex --help` / `codex exec --help` / `codex features list`.

## Summary

| | Claude Code | Codex |
|---|---|---|
| Installed | yes | yes — **bundled in ChatGPT.app, not on PATH** |
| Version tested | 2.1.277 (`~/.local/bin/claude`); 2.1.267 also present (Homebrew cask) | codex-cli 0.153.4 (OpenAI-signed, arm64) |
| Integration mechanism | `claude -p --output-format stream-json …` (documented "Agent SDK via CLI") | `codex exec --json …` (documented) |
| Subscription-backed | yes (`auth status`: claude.ai login, Pro plan) | yes (`login status`: "Logged in using ChatGPT") |
| Streaming | **token-level** (`stream_event` / `text_delta`) — REAL TESTED | **message-level** (`item.completed` / `agent_message`) — REAL TESTED; no token deltas in `exec` |
| Session continuation | `--session-id <uuid>` then `--resume <uuid>` (documented) | `thread_id` from `thread.started`, then `codex exec resume <id>` (documented) |
| Cancellation | SIGINT ends the turn cleanly; SIGTERM kills (exit 143), documented | no documented signal contract; SIGINT→SIGTERM→SIGKILL escalation planned, TO BE REAL TESTED |
| Tool restriction (verified) | `--tools ""` ⇒ 0 `tool_use` blocks (REAL TESTED). Needs an explicit "no tools" system instruction: without it the model *wrote fake* "I'll run that command" text | `-s read-only` + `--disable shell_tool --disable browser_use --disable browser_use_external --disable computer_use --disable plugins --disable hooks --disable apps --disable memories` ⇒ no `command_execution` (REAL TESTED; control run without the switches executed commands) |
| **Status** | **SUPPORTED WITH LIMITATIONS** | **SUPPORTED WITH LIMITATIONS** |

Nothing is marked plain SUPPORTED: both have real policy/semantic limits below. Both are **CLI-level REAL TESTED** only; a real request *through the JARVIS provider architecture* is recorded in KNOWN/DEV LOG when done.

## Claude Code

- **Executable discovery.** Two installs found: `~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.277` and `/opt/homebrew/bin/claude` (Caskroom 2.1.267). A GUI app does not inherit the shell PATH, so JARVIS probes explicit locations and picks the **highest version**.
- **Auth.** Official flow only: `claude auth login` (Anthropic's own browser flow). State check: `claude auth status` → JSON `{"loggedIn": bool, "authMethod": …}`; exit 0 logged in, **1 logged out** (REAL TESTED with an empty `CLAUDE_CONFIG_DIR`, real credentials untouched). Logged-out `claude -p` result: `is_error:true`, `result:"Not logged in · Please run /login"`, `assistant.error:"authentication_failed"`, exit 1.
- **Headless.** `-p` reads the prompt from stdin (cap 10 MB; it warns after 3 s if no stdin is attached → JARVIS always attaches stdin). Output: `--output-format stream-json --verbose --include-partial-messages`. Event shapes seen: `system/init` (has `session_id`), `stream_event` {`message_start`, `content_block_start/delta/stop`, `message_delta`, `message_stop`}, `assistant`, `rate_limit_event` (`rate_limit_info.status`, `unifiedWindows.five_hour|seven_day.utilization`), `system/post_turn_summary`, final `result` (`is_error`, `result`, `session_id`, `total_cost_usd` *client-side estimate*, `usage`). Text is in `stream_event.event.delta.type == "text_delta"` → `.text`.
- **Restrictions JARVIS uses:** `--tools ""`, `--safe-mode` (disables CLAUDE.md/hooks/MCP/plugins/skills; auth unaffected), `--permission-prompts none`, `--append-system-prompt <short JARVIS instruction>`, private empty working dir. **Forbidden:** `--bare` (API-key only, never reads OAuth — would force paid API), `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, `bypassPermissions`.
- **Policy (Anthropic, Legal & compliance).** Anthropic does **not** permit third-party developers to offer Claude.ai login in their apps, route requests through Free/Pro/Max credentials on behalf of users, or collect/store/intermediate Claude.ai credentials or session tokens; developers building products should use API keys. It **does** state this "does not prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription". Pro/Max limits "assume ordinary, individual usage". ⇒ JARVIS is a personal local app that **drives the user's own, unmodified, already-signed-in `claude` binary**; it never reads/stores/forwards credentials, never implements login, never sets API keys. **Limitation:** if JARVIS were ever distributed or offered as a service, this mechanism must be re-reviewed with Anthropic (UNVERIFIED for redistribution).
- **Known limitations.** Subscription five-hour/weekly windows are shared with the user's other Claude Code use (a `rate_limit_event` showed 85 % of the five-hour window used during research). Startup context overhead ≈ 5k tokens per request even for a trivial prompt.

## Codex

- **Executable discovery.** Not installed via npm/brew. The official binary ships inside the ChatGPT desktop app: `/Applications/ChatGPT.app/Contents/Resources/codex` (also `~/.codex` config dir exists). Not on PATH → JARVIS probes `PATH`, Homebrew/npm/cargo/`~/.local` locations **and** the ChatGPT.app bundle path, plus a user override.
- **Auth.** Official: `codex login` (ChatGPT sign-in). State check: `codex login status` → "Logged in using ChatGPT", exit 0; "Not logged in", **exit 1** (REAL TESTED with empty `CODEX_HOME`). An *unauthenticated* `codex exec` does not fail fast: it loops "Reconnecting… 401 Unauthorized" ≈5× then exits 1 ⇒ **JARVIS must pre-check status before launching**. Never read `~/.codex/auth.json` (OpenAI: "treat like a password").
- **Headless.** `codex exec --json` writes JSONL to stdout, progress to stderr. Seen: `thread.started{thread_id}`, `turn.started`, `item.completed{item:{type:"agent_message",text}}` (also `reasoning`, `command_execution`, …), `turn.completed{usage}`, `turn.failed`, `error{message}`. Prompt via stdin with `-`. `exec` needs a git repo unless `--skip-git-repo-check`. Default sandbox read-only; `--dangerously-bypass-approvals-and-sandbox`, `-s danger-full-access`, `--full-auto` are forbidden in JARVIS. Useful: `--ignore-user-config` (skips `config.toml`, auth still from `CODEX_HOME`), `--ignore-rules`, `-C <dir>`.
- **Streaming reality.** Documented `exec --json` has no token-delta event: each `agent_message` arrives complete. JARVIS streams it **as it arrives (message-level)** and does not fake token streaming. True deltas (`item/agentMessage/delta`) exist only in `codex app-server`, which OpenAI labels "experimental and aren't supported for production workloads" ⇒ **not used**.
- **Policy (OpenAI docs).** `codex exec` reuses saved CLI auth by default. For CI the docs call API keys "the right default for automation" and describe ChatGPT-managed auth in automation as "advanced" for trusted runners. They do not address ChatGPT-subscription use by other desktop apps. JARVIS runs the user's own signed-in Codex locally as the user, sets no API key (and **scrubs** `CODEX_API_KEY`/`OPENAI_API_KEY`), never handles tokens. **Limitation:** not an explicitly blessed third-party-embedding path (UNVERIFIED beyond the documented `exec` CLI); the binary used is a bundled copy inside ChatGPT.app and may move or change flags with app updates.
- **Known limitations.** ≈14k input tokens per trivial request (system prompt/tools) — counts against the ChatGPT plan. Session files persist under `~/.codex` (normal Codex behaviour).

## Shared design consequences (implemented in V0.3)

1. API-key and cloud-provider env vars are **scrubbed** from the child environment so a stray key can never turn into silent paid usage.
2. Prompts go over **stdin** (no `sh -c`, no argv exposure); executables launched with `Process` + argument arrays.
3. Always pre-check auth; `installed ≠ ready`.
4. Conversation-only mode: tools disabled / read-only, empty private working dir, short "no tools, never claim actions" instruction (verified necessary for Claude).
5. Continuity via the official session mechanisms, with a bounded history preface as fallback (and after a provider switch).
6. Cancellation must kill the process tree (SIGINT → SIGTERM → SIGKILL) and is verified with a real run; app termination cleans up.
7. `workerRequired` requests never reach a provider in V0.3 (autonomous execution is V0.4).

## V0.4 handoff
Claude: `--permission-mode`/`--allowedTools`/`--permission-prompts host` with a permission host (Agent SDK-style) and `--session-id` per task. Codex: `exec` with `-s workspace-write` + approvals, or revisit `app-server` once OpenAI supports it for production. Both need explicit user approval boundaries (none exist in V0.3).
