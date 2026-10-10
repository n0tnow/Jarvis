# Current Task

Version:
V0.2 — Text conversation + intelligence router (V0.1.1 final fix `1b64d07` pushed first; V0.1.1 gate passed)

Task:
V0.2 IN PROGRESS. Checkpoints: A models+ConversationStore ✅ · B normalizer+command router ✅ · C executor ✅ · D IntelligenceRouter + provider boundary ✅ · G unit tests (72 total) ✅ · E Full HUD conversation UI ⏳ · F Compact command feedback ⏳ · acceptance scenarios (smoke) ⏳ · docs/verify/captures ⏳.

State:
IN PROGRESS

Last Successful Step:
Domain + routing + execution + provider boundary implemented and unit-tested (72/72). `LocalCommandHandler` (V0.1 demo) removed; `AppContext.conversationService` replaces it.

Current Step:
Build Full HUD `ConversationPanel` (center column) and Compact one-line feedback in the command field (Compact stays 392×448).

Next Step:
Smoke-test the 7 acceptance scenarios against the real WindowManager; captures; docs (README/ARCHITECTURE/DECISIONS/KNOWN_ISSUES/ROADMAP/PROJECT_STATE); verify.sh; commit+push; STOP at "V0.2 — READY FOR MANUAL TEST". Do NOT start V0.3 / connect any real AI provider.

Files Being Worked On:
Sources/Jarvis/UI/FullHUD/{CenterStage,ConversationPanel}.swift, UI/Components/CommandField.swift, UI/CompactHUD/CompactHUDView.swift

Blocked By:
Nothing.

Notes:
- Pipeline: raw → InputNormalizer → IntelligenceRouter {CommandRouter | LocalConversation | worker/reasoning heuristics} → ConversationService → CommandExecutor (→ JarvisWindowControlling / JarvisStore) / provider registry (EMPTY in V0.2) → ConversationStore → UI.
- Subscription-first rule: no API keys, no paid-API code, no ChatGPT/Claude web scraping (provider boundary only).
- Git: main only, no tags, no AI trailer on new commits.
