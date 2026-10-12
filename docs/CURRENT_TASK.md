# Current Task

Version:
V0.6 — Unity Project Agent & Editor Bridge — **IN PROGRESS**. Base: V0.5 (962c432, READY FOR MANUAL TEST), V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Make Unity a first-class controlled execution environment INSIDE the V0.4 task engine: JARVIS-owned typed Editor bridge (embedded package, local file spool, no socket/network, no third-party MCP), Unity step types, capability/policy layer, validation authority (hard facts outrank subjective review), fixtures, real-editor live test. NOT V0.7 (voice/web/assets), no real-game mutation.

Decisions taken (to be recorded as DEC-047…):
- Bridge = JARVIS-owned Editor package `Packages/com.jarvis.bridge` + request/response files under `Library/JarvisBridge` (event-driven on the JARVIS side; no polling while idle). No third-party Unity MCP installed or used.
- Closed typed operation enum (`UnityOperation`); no code/menu/shell/eval operation exists; the bridge rejects unknown operations itself.
- Unity steps (`unityInspect/Edit/Compile/Test/PlayMode/Validate`) are ordinary V0.4 steps; the provider only PROPOSES typed edit actions; JARVIS validates/applies/verifies.
- Review authority (generic, DEC-050): reviewer cannot fail a task that has passed hard validators unless it names verifiable evidence or the user asked for a review gate; hard failures are never rescued.

State (code on disk; see `git status` for commit status):
Bridge C# + fixture ✅ · Swift Unity layer (discovery, detector, protocol, spool transport, policy, service, lock, launcher, installer) ✅ · engine steps + plan validation + migration v5 + report/checkpoint ✅ · review authority ✅ · UI (project line, task Unity section, Compact phrase) ✅ · unit tests 637 green (simulated editor = MOCK) ✅ · `--unity-live-test` REAL (58/59 on the last full run; fixes applied) ⏳ rerun · verify.sh V0.6 guards ✅ written, rerun ⏳ · docs ⏳ · commits/push ⏳.

Next Step:
Rerun `--unity-live-test` (with provider), `scripts/verify.sh`, finish docs (UNITY_PROJECT_AGENT.md, DECISIONS, README checklist, PROJECT_STATE, …), commit (Conventional, no AI trailers), push, final report + status, STOP (no V0.7).

Blocked By:
Nothing.

Notes:
- Unity 6000.5.1f1 is installed and licensed on this Mac; fixtures run headless (`-batchmode -nographics`) and are copies in a temp folder — the user's real game is never opened.
- Git: main only, no tags, no AI trailers (user rule overrides the attribution reminder).
