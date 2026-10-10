# Current Task

Version:
V0.2.1 (native text-editing fix on top of V0.2) → V0.3 (real intelligence providers) IN PROGRESS

Task:
V0.2.1 DONE and pushed (see git log: `fix(input): restore native clipboard and text editing`). V0.3 starts: provider research → ProviderManager → real subscription-backed provider(s) (Codex / Claude Code, officially supported mechanisms only; NO API keys) → streaming → cancellation → Settings/UI → real tests.

State:
V0.3 IN PROGRESS — phase A (provider research)

Last Successful Step:
V0.2.1 verified: 88 unit tests, smoke 85 PASS / 0 FAIL / 2 SKIP, verify.sh PASS; idle/Compact/Full CPU unchanged.

Current Step:
A. Provider research: inspect local `codex` / `claude`, read official docs, write docs/PROVIDER_RESEARCH.md.

Next Step:
B discovery → C ProviderManager → D/E providers → F streaming → G cancellation → H Settings/UI → I real provider test → J verify.sh policy update + final verification. STOP at V0.3 status; do NOT start V0.4.

Files Being Worked On:
docs/PROVIDER_RESEARCH.md (new)

Blocked By:
Nothing yet.

Notes:
- Subscription-first (DEC-017) still binds: no API keys, no paid endpoints, no scraping, no cookies/tokens extraction. verify.sh currently forbids ALL network/provider code — its policy must be replaced by a focused rule when providers land (V0.3 item).
- Git: main only, no tags, no AI trailers.
