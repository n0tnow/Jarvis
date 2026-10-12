# Roadmap

V0.1–V0.6 have been built (V0.3 … V0.6 await manual test). Everything else is PLANNED — do not start a milestone without explicit user approval.

| Version | Scope | Status |
|---|---|---|
| V0.1 | Native macOS foundation + HUD (user-tested, direction approved) | superseded by V0.1.1 below |
| V0.1.1 | Compact HUD fixed size · neural background · ⌥⌘ / ⌥⌘⌘ global shortcuts (UX fixes, no new capabilities) | READY FOR MANUAL TEST |
| V0.2 | Text conversation + intelligence/command router (deterministic EN/TR commands, conversation store/UI, IntelligenceRouter, provider boundary) | user-tested (V0.2.1 clipboard fix applied) |
| V0.3 | Real intelligence via the user's own Codex / Claude Code subscriptions: conversation-only, streaming, stop generation, continuity, provider selection (no API keys). **Autonomous worker execution is NOT part of V0.3 → V0.4** | READY FOR MANUAL TEST |
| V0.3.1 | Intelligence infrastructure: SQLite persistence + audit trail, OpenCode verified-free pool, local Qwen, ProviderSupervisor, policy-driven model router, bounded background-agent foundation (no autonomous task engine) | READY FOR MANUAL TEST |
| V0.3.2 | Agent Observatory & live consoles: provider/agent overview, sanitized live console, truthful progress/states, history, timeline, Stop, restart reconciliation, central sanitization boundary (no task engine, no shell) | READY FOR MANUAL TEST |
| V0.4 | Autonomous task engine: user-initiated goal → durable task → validated plan → scheduled agents/tools → deterministic validation → bounded repair/escalation → report; workspace + capabilities + leases; restart recovery (no proactive work) | READY FOR MANUAL TEST |
| V0.5 | Proactive reasoning + approval/autonomy policy: event-driven opportunities, deterministic policy, scope-bound proposals, conservative low-risk auto actions through the V0.4 engine | READY FOR MANUAL TEST |
| V0.6 | Unity Project Agent & Editor Bridge: JARVIS-owned typed Editor bridge (local file spool, no MCP/network), Unity step types inside the V0.4 engine, truthful connection state, scene/component/property edits with identity, dirty-scene and Play Mode protection, compile/tests/Console validation, validation authority over subjective review | READY FOR MANUAL TEST |
| V0.7 | Voice I/O (local STT + TTS, streaming voice). *Scope to be confirmed by the user:* the V0.6 brief also mentions web research / asset acquisition for "V0.7" — those are NOT part of V0.6 and not started | PLANNED |
| V0.8 | Wake word + interruption/barge-in | PLANNED |
| V0.9 | Project memory + reports + self-controlled UI | PLANNED |
| V0.10 | Unity multiplayer workflows (Multiplayer Play Mode, several editors) on top of V0.6 | PLANNED |
| V0.11 | Browser automation + macOS computer use; web research + asset acquisition (licences, free-price verification, purchases stay critical approvals) | PLANNED |
| V0.12 | Multi-agent orchestration + model routing | PLANNED |
| V1.0 | Stable general-purpose JARVIS | PLANNED |

V0.1 placeholders already in the UI that point at later milestones: Report/Memory sections (V0.9), Tools panel entries (V0.3/V0.9/V0.10), Launch at Login (disabled; later).
