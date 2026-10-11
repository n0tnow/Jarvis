# Roadmap

V0.1–V0.3.2 have been built (V0.3, V0.3.1 and V0.3.2 await manual test). Everything else is PLANNED — do not start a milestone without explicit user approval.

| Version | Scope | Status |
|---|---|---|
| V0.1 | Native macOS foundation + HUD (user-tested, direction approved) | superseded by V0.1.1 below |
| V0.1.1 | Compact HUD fixed size · neural background · ⌥⌘ / ⌥⌘⌘ global shortcuts (UX fixes, no new capabilities) | READY FOR MANUAL TEST |
| V0.2 | Text conversation + intelligence/command router (deterministic EN/TR commands, conversation store/UI, IntelligenceRouter, provider boundary) | user-tested (V0.2.1 clipboard fix applied) |
| V0.3 | Real intelligence via the user's own Codex / Claude Code subscriptions: conversation-only, streaming, stop generation, continuity, provider selection (no API keys). **Autonomous worker execution is NOT part of V0.3 → V0.4** | READY FOR MANUAL TEST |
| V0.3.1 | Intelligence infrastructure: SQLite persistence + audit trail, OpenCode verified-free pool, local Qwen, ProviderSupervisor, policy-driven model router, bounded background-agent foundation (no autonomous task engine) | READY FOR MANUAL TEST |
| V0.3.2 | Agent Observatory & live consoles: provider/agent overview, sanitized live console, truthful progress/states, history, timeline, Stop, restart reconciliation, central sanitization boundary (no task engine, no shell) | READY FOR MANUAL TEST |
| V0.4 | Persistent task engine + long-running background jobs (builds on V0.3.1 persistence/agents/routing) | PLANNED |
| V0.5 | Local STT + microphone | PLANNED |
| V0.6 | Local/approved TTS + streaming voice | PLANNED |
| V0.7 | Wake word + interruption/barge-in | PLANNED |
| V0.8 | Project memory + reports + self-controlled UI | PLANNED |
| V0.9 | Unity MCP development workflow | PLANNED |
| V0.10 | Browser automation + macOS computer use | PLANNED |
| V0.11 | Multi-agent orchestration + model routing | PLANNED |
| V1.0 | Stable general-purpose JARVIS | PLANNED |

V0.1 placeholders already in the UI that point at later milestones: Report/Memory sections (V0.8), Tools panel entries (V0.3/V0.9/V0.10), Launch at Login (disabled; later).
