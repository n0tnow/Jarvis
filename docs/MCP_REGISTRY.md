# MCP / Capability Registry (V0.14)

Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (fixture server under the real Seatbelt profile; one real open-source candidate built and benchmarked in the sandbox) · MANUAL TEST REQUIRED.

An MCP server provides **capabilities** to JARVIS. It is not an orchestrator and never an authority. Tool descriptions, schemas and results are untrusted data.

## Lifecycle

DISCOVERED → INSPECTED → SANDBOXED → BENCHMARKED → RECOMMENDED → (HUD approval) APPROVED → INSTALLED → ACTIVE ⇄ DEGRADED / DISABLED → REMOVED; also REJECTED / BLOCKED. The status machine has **no edge** from any pre-approval state to ACTIVE (`MCPStatus.allowedNext`, guarded). Install, update and removal are created only as *requests* (HUD button, typed or spoken sentence, test) and executed only by `AdaptiveDecisionService` after an HUD decision. A spoken "yes/evet" is not a decision.

## Discovery (V0.9 research stack)

`Research/MCPDiscovery.swift`: the official MCP registry (`registry.modelcontextprotocol.io`) and the GitHub API (unauthenticated; no key), README evidence kept as data. Bar for a recommendation: licence known, active within a year, repository present, not archived, no arbitrary-code tool, macOS-compatible, price verifiably free (UNKNOWN is never free), no credential requirement that JARVIS would have to supply. Domains: 3D/Blender, design, audio, animation, Unity, general. Discovery is on demand only.

## Static inspection

`MCPInspector` + `MCPInspectionRules` scan manifests / source snapshots / tool descriptions for: shell or arbitrary-code tools (BROAD), credential reads, network egress, filesystem breadth, instruction-shaped text in descriptions (injection), install hooks. Findings carry severities; a high finding blocks recommendation.

## Sandbox — what it is and is not (`MCPSandbox`, DEC-225)

Enforced by the kernel (Seatbelt via `/usr/bin/sandbox-exec`, deprecated by Apple but present): network denied unless the envelope allows it; file writes only inside the sandbox directory; reads of the home directory denied except the sandbox and the runtime folder; Keychain / security daemons denied by Mach service name (best effort). Enforced by JARVIS: environment built from scratch (no HOME, SSH_AUTH_SOCK, API keys, tokens), private directory removed afterwards, own process tree, timeouts, bounded output, memory sampling. **NOT enforced**: CPU/memory caps (sampled and killed), reading world-readable system files, an exhaustive Mach filter, a separate user account or VM. Every report prints this boundary.

## Benchmark (`MCPBenchmark`)

Runs in the sandbox: start/list tools, domain read-only cases, optional write cases on fixtures, determinism (two identical calls), cold/warm latency, resident memory, permissions implied by the tools used, network need, clean rejection of an unknown tool, confinement cases (`expectsFailure`), cleanup. Recommendation rule: ≥ 75 % of applicable cases pass, clean cleanup, known licence, verified-free price, no uncontained high finding, no credential need.

## Envelope and wrappers

Registered envelope = maximum permission (read, projectWrite, network, process, account, credential, destructive). Agents never see a raw tool: only typed `MCPWrapper`s inside the envelope; BROAD tools (shell / code) are never exposed; account / credential / destructive envelopes need the user present for every use. Allowed projects are an explicit list (no wildcard).

## Runtime

Client = newline-delimited JSON-RPC over a `ManagedProcess` transport. A server starts on demand and stops after a one-shot idle timeout; nothing runs at idle. Restart budget is spent only by *failures*. Health, drift (hash of the approved definition; change ⇒ revalidation required), update requests (never automatic), unused detection (advice only, never auto-delete) and activity records are visible on the Capabilities screen.

## Removal

Deletes only recorded owned files (exact paths in JARVIS' server folder; symlinks removed, not followed; the folder only if empty). The active-task check is re-run at execution time. Disabled ≠ removed.

## Tests

Unit: `MCPRegistryTests` (in-process fake transport). Real: `--mcp-live-test` sections research, sandbox, registry, security, voice, ui, candidate (fixture server variants normal / adversarial / shell / env / crash / slow / flaky / hang; credential isolation probes; injection; active-delete; ownership-delete).
