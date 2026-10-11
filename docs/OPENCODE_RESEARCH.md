# OpenCode Research (V0.3.1)

Researched 2026-10-11 against the **installed binary** `opencode 1.18.34` (`~/.opencode/bin/opencode`) and the official docs (opencode.ai/docs: cli, permissions, zen). Nothing here is assumed from memory: every row says how it was established. No credentials were read or modified (`opencode providers list` only shows that one credential — an "OpenCode Go" API credential — exists; JARVIS never touches `auth.json`).

Legend: **SUPPORTED** (documented + verified) · **SUPPORTED WITH LIMITATIONS** · **UNVERIFIED** · **UNSUPPORTED**.

## Capability matrix

| Capability | Status | Evidence |
|---|---|---|
| Headless one-shot run | SUPPORTED | `opencode run [message..]`; `--format json` = raw JSON events (docs + REAL TESTED) |
| Prompt via stdin | SUPPORTED (undocumented but REAL TESTED) | `echo "…" \| opencode run …` answered correctly; JARVIS uses stdin so prompts never appear in `ps` and a leading `-` can't be parsed as a flag. (`-- "-v …"` positional form **hung** → never used.) |
| Model selection | SUPPORTED | `-m provider/model` (docs + REAL TESTED) |
| Model discovery | SUPPORTED | `opencode models [provider]` lists ids; `--verbose` prints JSON metadata per model; `--refresh` refreshes the cache from models.dev (REAL TESTED, ≈2 s) |
| **Programmatic price discovery** | **SUPPORTED** | `--verbose` JSON has `cost.{input,output,cache.read,cache.write}` (USD / 1M tokens), `status`, `api.url`, `limit.context`, `capabilities.{toolcall,reasoning,…}`. The cache (`~/.cache/opencode/models.json`) is OpenCode's snapshot of models.dev — JARVIS therefore refreshes (`--refresh`) before trusting a price and expires verification after 24 h (DEC-022). |
| Free-model identification | SUPPORTED, **by price only** | Zen free models have `cost` all 0 **and** provider `opencode` (keyless Zen endpoint `opencode.ai/zen/v1`). `opencode/big-pickle` is free but has no "free" in its name; `opencode-go/*` models are priced and use a credentialed plan. The name is never consulted. |
| Authentication state | SUPPORTED WITH LIMITATIONS | `opencode providers list` shows credentials (path + provider names). Free Zen models need **no** credential (REAL TESTED with no `opencode` credential present). JARVIS does not read `auth.json` or run `providers login`. |
| Streaming | SUPPORTED WITH LIMITATIONS | Output is **message-level**: one `text` event holding the whole part (REAL TESTED, 437-char answer = 1 event). Like Codex; not faked. |
| Event schema (`--format json`) | SUPPORTED (observed) | `step_start`, `text{part.text}`, `tool_use{part.tool, state.status/error}`, `step_finish{part.reason, part.tokens{total,input,output,reasoning,cache}, part.cost}`, `error{error.name, data.statusCode, data.message}`. Every event carries `sessionID`. The page does not list event types — schema is from observation. |
| Sessions / follow-ups | SUPPORTED | `-s <sessionID>`, `-c`, `--fork` (docs); session id taken from events. |
| Cancellation | SUPPORTED (same machinery as V0.3) | OpenCode is a child process; JARVIS `ManagedProcess` SIGINT→SIGTERM→SIGKILL of the tree. REAL TESTED in the live test. |
| Background agents / sub-agents | SUPPORTED WITH LIMITATIONS | `opencode agent list/create`; JARVIS does **not** use OpenCode's own sub-agent system: JARVIS is the orchestrator (V0.3.1 prompt §2), each OpenCode run is one bounded worker. |
| SDK / server | SUPPORTED, **not used** | `opencode serve` (HTTP, `OPENCODE_SERVER_PASSWORD`), `--attach`. Using it would need a JARVIS HTTP client (forbidden by `verify.sh`) and a long-lived daemon. CLI-per-task is the verified, supported path. |
| Tool restriction | **SUPPORTED WITH LIMITATIONS** | See next section — the part that needed the most care. |
| Usage / limits | UNVERIFIED | `opencode stats` shows token/cost statistics; the docs do not describe free-tier rate limits. A 403/429 is surfaced as a typed provider error and puts the model in cooldown. |
| Privacy of free models | SUPPORTED (docs) | Zen docs: Big Pickle, MiMo-V2.6-Flash Free, Ling 3.1 Flash Free, Ling 3.0 Flash Fin Free (and others) **may use collected data to improve the model**; Space Bunny Free, LongCat 2.5 Preview Free, Step 5 Preview Free are **zero-retention**; Nemotron free models are **trial, logged, no confidential data**; Muse Spark Contributor trains on prompts. ⇒ JARVIS stores a `DataPolicy` per model and never sends sensitive tasks to free cloud; project code only to zero-retention models. |

## Tool restriction (conversation-only mode) — findings

OpenCode is a coding agent: by default **most permissions are `allow`** (docs), including `bash` and `edit`. JARVIS must never let a free model act on the machine in V0.3.1.

Experiments (all REAL, free model `opencode/big-pickle`, empty temp dir, via a project `opencode.json`):

1. `OPENCODE_PERMISSION` env or `OPENCODE_CONFIG_CONTENT` with a deny-all → **HTTP 403 "OpenCode's free tier can only be used from within OpenCode"**. Bisect: *denying the `bash` tool* (`"bash":"deny"`, `"bash":{"*":"deny"}`, `"*":"deny"`) triggers it — the free tier rejects requests whose tool list does not look like OpenCode's. `edit: deny`, `*: ask`, `share:disabled`, empty config all work. **JARVIS does not try to evade this check**; it picks a restriction that keeps the tool list intact.
2. **`"*": "ask"` is auto-rejected in non-interactive `run`** (observed: tool state `error: "The user rejected permission to use this specific tool call."`, nothing executed, exit 0). The docs do not state this behaviour → **SUPPORTED WITH LIMITATIONS (observed, not documented)** and covered by a live canary test + a unit test pinning the exact config.
3. Adopted `opencode.json` in a private empty workspace:
   `{"permission":{"*":"ask","edit":"deny","webfetch":"deny","websearch":"deny","external_directory":"deny","task":"deny","skill":"deny","doom_loop":"deny","question":"deny","lsp":"deny"},"share":"disabled","autoupdate":false}`
   Canaries (prompts demanding tool use): bash → rejected; write → model fell back to bash → rejected; read `/etc/hosts` → **denied by rule** (`external_directory`); webfetch → model tried `curl` via bash → rejected; glob/grep → rejected. **No file was created, no command ran** in any canary.
4. Additional hardening: `--pure` (no external plugins), env `OPENCODE_DISABLE_AUTOUPDATE/LSP_DOWNLOAD/CLAUDE_CODE/DEFAULT_PLUGINS=1`, scrubbed environment (same allowlist as V0.3), `--auto` is forbidden (`verify.sh`), JARVIS system instruction "you have NO tools".
5. Residual risk (documented in KNOWN_ISSUES): the restriction depends on OpenCode honouring `ask` as reject in headless mode. If a future version changes that, the run would stall waiting for approval and JARVIS's idle watchdog kills it; the live canary test (`--provider-live-test`) re-verifies after upgrades. OpenCode's own config precedence (global `~/.config/opencode`, env) could in principle override the project file — JARVIS launches with a scrubbed env and records nothing it cannot verify.

## Decision summary
- Integration: **CLI per task** (`opencode run --pure --format json -m <verified-free-model> [-s <session>]`, prompt on stdin, private workspace with the restrictive `opencode.json`).
- FREE pool = provider `opencode` models whose current metadata says price 0 and status active, verified ≤ 24 h ago. `opencode-go/*` (even zero-priced ones such as `space-bunny-free`) are **excluded**: they go through a credentialed plan, not the keyless free tier.
- No server, no SDK, no `--attach`, no credentials, no OpenCode-owned orchestration.
