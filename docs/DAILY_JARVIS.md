# Daily JARVIS (V0.15)

Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`--daily-jarvis-live-test`) · MANUAL TEST REQUIRED (README 1153+).

V0.15 makes the machinery of V0.7–V0.14 usable every day. It adds **no capability** and **no orchestrator**: the execution chain is unchanged —
User → voice/text I/O → `ConversationService` → routing / task intake → `TaskEngine` → V0.12 orchestrator → typed capabilities → validation → result → *response presentation* → text / voice.
Personality, follow-up references, readiness and packaging are presentation, references, inspection and app lifecycle. They cannot approve, grant, plan, run or decide (DEC-234…245; `scripts/guards_v15.sh`).

## Response presentation (`Sources/Jarvis/Daily/ResponsePolicy.swift`)

* **Calm, concise, direct.** Default style *Concise* (≈ 240 characters before the rest is offered); *Balanced* (≈ 420) and *Detailed* are in Settings → Daily JARVIS. No second model rewrites answers: shortening is deterministic.
* **Depth on request, per turn.** `ResponseDepthDetector` (Turkish + English): *terse* (“kısa söyle”, “briefly”), *detailed* (“detaylı anlat”, “explain in detail”, “neden?”, “why?”), *instructional* (“adım adım”, “step by step”, “öğret”), *report* (“rapor ver”, “full report”). A request that is only a depth word (“Detaylı anlat.”) applies to the PREVIOUS answer: the full text was kept and is shown (or shortened again) without a model call. Navigation phrases such as “raporu aç” are not depth requests.
* **Shortening never hides a negative fact.** Sentences that carry a failure, refusal, unknown, missing piece, permission, warning or pending decision are always kept (`ReplyShaper.critical`). Evidence-bearing answers (Project Memory with citations) are shown whole unless a short one is requested.
* **Acknowledgement ≠ result.** A created task is acknowledged briefly and truthfully (“Başlıyorum.”, “İnceliyorum.”, “On it.”): it says the task exists, never that a specific step has happened. The original long explanation appears for detailed turns or the Detailed style. Completion and failure use the persisted report summary.
* **“Efendim”** (`AddressPolicy`): Turkish only; at wake (“Efendim?”), at a decision request (always), and — in *Natural* style — at greeting, task acceptance and completion, never twice within 4 replies. *Minimal* limits it to wake and decisions; *Off* never. English never uses a form of address.
* **Status questions** (“Hamam ne durumda?”, “Nerede kaldık?”, “Testler geçti mi?”) are answered from persisted evidence (Project Continuity, graph state, Git, memory) — never by a model.
* **Errors**: the user sees one concise sentence; detail stays in the activity log / report.

## Readiness questions
“Claude hazır mı?”, “Ses sistemi hazır mı?”, “MCP’ler sağlıklı mı?”, “Is Whisper installed?”, “Her şey hazır mı?” are answered from the readiness picture (`ReadinessAssistant`; see `FIRST_RUN_SETUP.md`). Typed and spoken text take the same path.

## Stop speech ≠ stop task
“Sus.”, “Sessiz ol.”, “Stop talking.” silence speech and stop an answer being generated (`.cancelGeneration`); “Görevi durdur.”, “Stop task.” request task cancellation through the normal path (`.stopTask`). Stopping speech never cancels a task.

## Approval boundary (unchanged, extended)
A bare “evet / yes / tamam / olur / approve” — typed or spoken — is caught by `ApprovalGuard` whenever **any** decision is pending (task approval, adaptive request, proposal) and approves nothing (V0.7, V0.14). While JARVIS is asking “which one?” a bare yes/no cannot choose either.

## Notifications and spoken completions
* Opt-in (Settings → “Notify me when a long task finishes or needs a decision”); macOS is asked only when it is switched on. The text is generic (“JARVIS completed your task.”) — never project content. Not sent for sub-steps, hand-offs, tool calls or file writes.
* Spoken completion (Settings → Speak task completions) only when voice is enabled and nothing else is being spoken; the microphone is never opened by it. Spoken task acknowledgements can be switched off (they are still shown).

## Voice architecture (preserved)
One microphone path (`MicrophoneHub`), push-to-talk (right ⌥), opt-in wake mode, one output engine, barge-in, raw audio never persisted, a final transcript enters only through `ConversationService.submit(source: .voice)`. Output is behind `TextToSpeechProvider` (`id`, `capabilities`, `availability()`, `voices()`, `speak`, `stop`, `render`): Apple system voices and the local neural voice are two providers; **a final custom JARVIS voice is added later as another provider without touching `ConversationService` or `TaskEngine`**. It is intentionally not selected yet, no voice is cloned, and none is downloaded.

## Settings
Settings → Startup (Launch at Login, Open Compact on launch), Daily JARVIS (response style, address style, conversational follow-ups + Clear context, task notifications, speak acknowledgements / completions, link to System & Readiness), Voice (unchanged), About (version, build, macOS, architecture, schema, diagnostics).

## Evidence (this Mac)
`--daily-jarvis-live-test`: see `PROJECT_STATE.md` (conversation 47 checks, latency p50/p95, readiness without starting anything).
