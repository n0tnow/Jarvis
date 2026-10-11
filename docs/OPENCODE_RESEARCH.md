# OpenCode Research (V0.3.1)

Researched 2026-10-11 against the **installed binary** `opencode 1.18.34` (`~/.opencode/bin/opencode`) and the official docs (opencode.ai/docs: cli, permissions, zen). **The user then updated to 1.19.0 ("v2" CLI): the capability matrix and v2 findings are in the section "OpenCode 1.19.0" near the end; everything in the first sections is the 1.18.x generation unless noted.** Nothing here is assumed from memory: every row says how it was established. No credentials were read or modified (`opencode providers list` only shows that one credential — an "OpenCode Go" API credential — exists; JARVIS never touches `auth.json`).

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

## OpenCode 1.19.0 ("v2") — the version installed now (the user updated deliberately)

OpenCode moved from the classic CLI (1.18.x) to the "v2" CLI (docs: opencode.ai/v2/docs; the binary reports internal version 2.0.x). The user chose the newer version, so JARVIS supports **both generations** and decides at every refresh from the CLI's own `--help` (`OpenCodeCapabilities`).

| | 1.18.x classic | 1.19.0 v2 | JARVIS status on v2 |
|---|---|---|---|
| prices / status | `models --verbose [--refresh]` → JSON incl. `cost` | `models` prints nothing; **documented API operation `model.list`** (`GET /api/model`, `Model.Info`: `cost[]` tiers, `status` alpha/beta/**deprecated**/active, `enabled`, `limit`) via `opencode api model.list` | **SUPPORTED WITH LIMITATIONS** — "the snapshot may precede initial plugin settlement": a fresh server answers `data: []`, so JARVIS retries (≤8 × 2.5 s); the call goes to OpenCode's own shared background service (started by OpenCode itself, not by JARVIS). A model is free only if EVERY cost tier component is 0. Only the fixed operation id `model.list` is ever invoked. |
| run | `run --pure --format json -m …` | `run --standalone --format json -m …` (`--standalone` = private in-process server; the default would use the shared service) | **SUPPORTED** |
| JSON events | `step_start`, `text`, `step_finish{reason,tokens}`, `error` | same shapes, **but the stream sometimes ends after `text` with no `step_finish`** (non-deterministic, observed 4/4 runs) | exit code 0 + text + no error = complete; token usage then unavailable |
| tool restriction | project `opencode.json`: `"*":"ask"` + denies | project **`opencode.jsonc`**: ordered `permissions: [{action,resource,effect}]`; non-interactive `ask` is **explicitly rejected** ("This non-interactive run cannot ask the user for permission, so the request was rejected") | **SUPPORTED WITH LIMITATIONS**, see below |
| 403 trap | denying `bash` | denying `shell` **or `read`** | neither is denied outright |
| daemon | none | background service (`opencode serve --service`) | JARVIS's own runs use `--standalone`; the service only serves the price lookup / the user's own OpenCode |

**v2 tool restriction — a real gap found and closed.** With the classic-style config the canaries still passed (shell → rejected; outside read → denied; write → rejected) **but a new tool called `execute` ("Code Mode") completed a real HTTP request to `example.com`** — the legacy webfetch/web denies do not cover it. Fix, verified with canaries on 1.19.0: `opencode.jsonc` = `* ask`, then `execute`, `edit`, `webfetch`, `websearch` = deny. Canaries (shell touch, write file, read `/etc/hosts`, fetch via curl/shell/code execution, sub-agent, glob): **every attempt rejected or denied, no file created, no network request made**. Docs say a trailing `* deny` "would" deny everything but do not confirm it — and in practice `read`/`shell` denials trigger the free-tier 403 — so it is not used.

**Never call `credential.*` / `integration.*`.** While exploring the v2 API I (the agent) invoked `credential.list`, which returns credential *values*; that put the user's OpenCode Go key into this session's tool output (not stored by JARVIS; the user was told to rotate it). JARVIS now ships guards: only the fixed operation `model.list` is ever passed to `opencode api`, and `scripts/verify.sh` fails if any credential/integration operation name appears in sources.

Real evidence: with 1.18.34 the live test passed 27/27 (free model answer, canaries, STOP, routing, SQLite); with 1.19.0 it passes 27/27 again (real free model `longcat-2.5-preview-free`, v2 canaries, STOP killing both processes).

## Free models can be deprecated server-side
`opencode/exo-free` was listed `status: active`, cost 0 in 1.18.34's catalog while the API answered `410 Model exo-free has been deprecated`. JARVIS maps 404/410 to a typed removal, blocks the model for 24 h (sticky across refreshes) and aborts its benchmark after the first such error; Auto also requires benchmark evidence, which such a model can never produce.
