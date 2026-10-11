# Current Task

Version:
V0.2.1 (native text-editing fix on top of V0.2) → V0.3 (real intelligence providers) IN PROGRESS

Task:
V0.2.1 DONE and pushed (see git log: `fix(input): restore native clipboard and text editing`). V0.3 starts: provider research → ProviderManager → real subscription-backed provider(s) (Codex / Claude Code, officially supported mechanisms only; NO API keys) → streaming → cancellation → Settings/UI → real tests.

State:
V0.3 IN PROGRESS — A research ✅ · B discovery ✅ · C ProviderManager ✅ · D Claude Code provider ✅ · E Codex provider ✅ · F streaming ✅ · G cancellation ✅ (all MOCK/fake-CLI tested + CLI-level real probes) · H Settings/UI ⏳ · I REAL test through the JARVIS architecture ⏳ (`--provider-live-test`) · J final verification/docs ⏳

Last Successful Step:
Provider layer implemented and tested: 170 unit tests (serial, real child processes incl. orphan/tree-kill checks), `scripts/verify.sh` PASS with the new focused provider policy (DEC-020/021). V0.2.1 + Full-HUD level fix already pushed (`244cfcf`, `73c932a`); research doc `58c6948`.

Current Step:
H: Settings provider section (preference picker, per-provider status, refresh, path overrides, login instructions), Conversation panel provider badge + STOP GENERATION button, System panel row; then I: live test.

Next Step:
I `--provider-live-test` (real Claude Code + Codex through ConversationService→ProviderManager→provider→ConversationStore: exact-reply, streaming, follow-up context, cancel + no orphan), J docs (README/ARCHITECTURE/KNOWN_ISSUES/ROADMAP/PROJECT_STATE/DEV_LOG), final verify, commit+push. STOP at V0.3 status. Do NOT start V0.4.

Files Being Worked On:
Sources/Jarvis/UI/Settings/SettingsView.swift, UI/FullHUD/ConversationPanel.swift, Panels.swift

Blocked By:
Nothing. Key research facts: Claude Code 2.1.277 + Codex 0.153.4 (bundled in ChatGPT.app) are BOTH installed and subscription-authenticated; Claude=token streaming, Codex=message-level; both verified tool-restricted; auth must be pre-checked (unauth codex exec loops on 401).

Notes:
- Subscription-first (DEC-017) still binds: no API keys, no paid endpoints, no scraping, no cookies/tokens extraction. verify.sh currently forbids ALL network/provider code — its policy must be replaced by a focused rule when providers land (V0.3 item).
- Git: main only, no tags, no AI trailers.
