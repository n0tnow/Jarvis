# Current Task

Version:
V0.2.1 (native text-editing fix on top of V0.2) → V0.3 (real intelligence providers) IN PROGRESS

Task:
V0.2.1 DONE and pushed (see git log: `fix(input): restore native clipboard and text editing`). V0.3 starts: provider research → ProviderManager → real subscription-backed provider(s) (Codex / Claude Code, officially supported mechanisms only; NO API keys) → streaming → cancellation → Settings/UI → real tests.

State:
V0.3 IN PROGRESS — A research ✅ (docs/PROVIDER_RESEARCH.md); next B discovery → C ProviderManager → D/E providers → F streaming → G cancellation → H Settings/UI → I real test → J verify

Last Successful Step:
V0.2.1 verified: 88 unit tests, smoke 85 PASS / 0 FAIL / 2 SKIP, verify.sh PASS; idle/Compact/Full CPU unchanged.

Current Step:
B/C: implement Providers layer: ExecutableLocator, ManagedProcess (stdin prompt, line-split stdout, SIGINT→SIGTERM→SIGKILL tree kill, env scrub), pure parsers (Claude stream-json, Codex JSONL), ProviderManager (states, selection, Auto), then the two providers.

Next Step:
B discovery → C ProviderManager → D/E providers → F streaming → G cancellation → H Settings/UI → I real provider test → J verify.sh policy update + final verification. STOP at V0.3 status; do NOT start V0.4.

Files Being Worked On:
Sources/Jarvis/Providers/** (new)

Blocked By:
Nothing. Key research facts: Claude Code 2.1.277 + Codex 0.153.4 (bundled in ChatGPT.app) are BOTH installed and subscription-authenticated; Claude=token streaming, Codex=message-level; both verified tool-restricted; auth must be pre-checked (unauth codex exec loops on 401).

Notes:
- Subscription-first (DEC-017) still binds: no API keys, no paid endpoints, no scraping, no cookies/tokens extraction. verify.sh currently forbids ALL network/provider code — its policy must be replaced by a focused rule when providers land (V0.3 item).
- Git: main only, no tags, no AI trailers.
