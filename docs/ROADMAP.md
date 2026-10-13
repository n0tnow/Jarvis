# Roadmap

V0.1–V0.11 have been built (V0.3 … V0.11 await manual test). Everything else is PLANNED — do not start a milestone without explicit user approval.

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
| V0.7 | **Voice I/O Foundation**: Push-to-Talk (hold right ⌥), streaming/incremental STT (Apple on-device + local Whisper), incremental sentence TTS (system voices), voice session state, Turkish + English, latency/resource benchmark (`docs/VOICE_IO.md`). Voice is an I/O layer on the SAME conversation pipeline | READY FOR MANUAL TEST |
| V0.8 | **Natural Voice & Presence**: opt-in local wake word, local VAD, natural endpointing, hands-free turn taking with a bounded follow-up window, barge-in, self-speech suppression, local neural JARVIS voice (Apple fallback), original voice identity, conversational latency (`docs/NATURAL_VOICE.md`, DEC-069…087). Voice stays an I/O layer: no spoken approvals, no cloud speech | READY FOR MANUAL TEST |
| V0.9 | **Web Research & Asset Acquisition**: cited, evidence-backed web research (any topic; Unity assets first), source quality, licence/price verification (UNKNOWN is never free), quarantined downloads with archive inspection, approval-gated import through V0.4/V0.6; account actions and purchases have no code path (`docs/WEB_RESEARCH.md`, `docs/ASSET_ACQUISITION.md`, DEC-088…103) | READY FOR MANUAL TEST |
| V0.10 | **Project Memory**: derived, provenance-backed project knowledge (decisions, constraints, failures, lessons, research/asset decisions, facts) with contradiction / supersession / staleness, hybrid TR/EN retrieval on a rebuildable local index, a bounded per-agent Context Builder, remember / correct / forget / pin, a Memory screen (`docs/PROJECT_MEMORY.md`, DEC-104…126). Reports stay a placeholder | READY FOR MANUAL TEST |
| V0.11 | **General Computer Use**: typed, observed, policy-checked, verified control of ordinary macOS applications through Accessibility when no stronger mechanism exists (capability ladder; V0.4/V0.6/V0.9 outrank the GUI); secure-field/terminal/purchase protections; window-scoped on-device vision fallback; stale-screen protection; cancel + ⌃⌥⌘ emergency stop; sessions interrupted — never auto-resumed — after a restart (`docs/GENERAL_COMPUTER_USE.md`, DEC-127…156) | READY FOR MANUAL TEST |
| V0.12 | **Advanced Multi-Agent / Routing** (orchestration; Unity multiplayer workflows with several editors are unscheduled backlog here) | PLANNED |
| V1.0 | **Integration / Stabilization / Final Voice & UX Polish** (DEC-126) | PLANNED |

*V0.8 (DEC-086):* named "Natural Voice & Presence" (earlier "Natural Voice Session"); the order of the later milestones is unchanged.

*Roadmap correction (DEC-068):* earlier documents listed "V0.7 voice / web research / asset acquisition", "V0.9 project memory + reports + self-controlled UI" and "V0.10 Unity multiplayer". The table above is authoritative; asset acquisition is not part of V0.7.

V0.1 placeholders already in the UI that point at later milestones: Report section, Tools panel entries (V0.3/V0.9/V0.10), Launch at Login (disabled; later).
