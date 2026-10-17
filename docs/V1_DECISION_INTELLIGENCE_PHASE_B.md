# V1.0 Decision Intelligence & Command Understanding — Phase B (local validation handoff)

Status of Phase A (Cloud): **IMPLEMENTED · AUTOMATED TESTED only where noted in `docs/DEVELOPMENT_LOG.md`**. Nothing below has been verified on a real Mac. Phase B is run by local Claude Code on the user's MacBook Air M5 (16 GB), with the user present for anything that needs a microphone, a permission prompt, a window or a key. Do not start V1.1, do not start Hamam autonomous work, and do not tag.

## 0. What Phase A built (so Phase B knows what to exercise)

| Piece | Where | Cloud state |
|---|---|---|
| Typed `Decision` (intent, confidence, target, action, flags, risk, gate, provenance, ambiguity) — advisory, no authority | `Sources/Jarvis/Decision/DecisionTypes.swift` | AUTOMATED TESTED (logic) |
| Level-0 deterministic grammar (voice status, tolerant system status, navigation, stop speech vs cancel task, project open / continue, media, observe, visibility, settings, restatements, safety-sensitive requests) | `DeterministicCommandRecognizer.swift` | AUTOMATED TESTED (logic, 353-case corpus) |
| Planner: Decision → existing capability (never executes) | `DecisionPlanner.swift` | AUTOMATED TESTED (logic) |
| Grounded answers: voice status, observation freshness, project-open resolver | `DecisionGrounding.swift` | AUTOMATED TESTED (logic) |
| Optional remote classifier **Jev**: protocol, minimised context, strict response parser, policy table, budget, circuit breaker, usage counters; `disabled` / `shadow` / `gated` (default `disabled`) | `JevDecisionProvider.swift`, `DecisionEngine.swift` | AUTOMATED TESTED with mocks; **no transport, no credential, no network exists in this build** |
| Pathological transcript guard (upstream of everything) + origin classification counters | `Voice/Natural/PathologicalTranscriptGuard.swift`, `VoiceCoordinator.swift` | AUTOMATED TESTED (logic); real microphone MANUAL TEST REQUIRED |
| Verified self-navigation: canonical selection + the window's own render acknowledgement + a settled second read-back | `ActionService.navigate`, `HUDState.renderedSection`, `FullHUDView` | state-level AUTOMATED TESTED; real window MANUAL TEST REQUIRED |
| Decision step in the conversation (before typed actions and models) | `ConversationService.submit` | wired; macOS-only tests written, run by `scripts/verify.sh` |
| Benchmarks: `Benchmarks/decision_corpus.json` (353 cases) + runner; `Benchmarks/local_model_probes.json` (41 probes) + dry-run-able harness | `DecisionBenchmark.swift`, `LocalModelBenchmark.swift` | AUTOMATED TESTED (dry run / mocks) |

Honest limits of Phase A: it was written in a Linux container with no Xcode and no macOS SDK. The pure logic (grammar, planner, grounding, Jev adapter, guard, benchmarks) was compiled and run there against slices of the real source. The macOS glue (`ConversationService`, `ActionService`, `VoiceCoordinator`, `FullHUDView`, `AppContext+Daily`, `Preferences`, `ComputerRuntime`) was syntax-checked only; its tests (`DecisionIntegrationTests.swift`) have **not run**. **Step 1 of Phase B is therefore `scripts/verify.sh` — expect to fix compile errors before anything else.**

## 1. Order of work

1. **Build and verify.** `scripts/verify.sh`. Fix compile errors / failing tests in the macOS glue first (they are in the files above). Do not weaken a guard. The new guards are in `scripts/guards_decision.sh`.
2. **Deterministic pipeline on the real Mac, no Jev:** README checks 1278–1294 (the README's V1.0 decision block). In particular:
   - "Sistem durumunu söyler misin?", "System Durumu Nedir?" → answer from the System page's snapshot; the numbers spoken equal the three tiles on the System page; zero model calls.
   - "Jarvis System Panelini aç." → the System page is really drawn; the reply appears only after. Try it with the Full HUD closed, on Dashboard, and already on System. If it says "doğrulayamadım" while the page is visibly open, the `renderedSection` acknowledgement in `FullHUDView` is not firing — fix that, do not remove the verification.
   - "Sesim geliyor mu?" typed and by voice; "Beni duyuyor musun?" with voice off and with the microphone denied.
   - "Safari'yi aç / açabilir misin?", then "Safari görebiliyor musun şu anda?" with no prior observation (must NOT say yes), after "Ekranıma bak" (may say yes with an age), and 30 s later (must say stale).
   - "Tarayıcıda açık olan videoyu devam ettirir misin?" — a real Computer Use task; an honest failure is correct, a false success is a bug.
   - Projects, with the user's real registry but **no writes**: "Hamam projesini aç." (Finder reveals the folder; no Unity Editor is launched — that is a deliberate Phase A limit, see DEC-272), "Unity projesini aç." (asks if two Unity projects exist), "En son çalıştığımız projeyi aç.", "Hamam'da kaldığımız yerden devam et." (must reach continuity with the project NAME; check the Project card / task title).
   - Corrections: "Sofany değil, Safari dedim." right after a mis-heard sentence; "Hayır Safari dedim."; "Wisp değil, sesim geliyor mu dedim sana."
3. **Voice reliability on the real Mac** (the user speaks; no raw audio is kept):
   - Provoke decoder loops: silence with the key held, a cough, a long breath, a TV in the background; confirm `Voice: dropped an implausible transcript` appears, no user turn is created, and the next utterance works. Read `VoiceDiagnostics.counts` — `origin.decoderHallucination` vs `origin.selfEcho` vs `origin.userInterruption` / `origin.userTurn` is how A (echo) / B (hallucination) / C (a real person) are told apart without audio.
   - Self-echo and barge-in regression (the Fix 4 scenarios): a long answer must play to the end; a real "Sus" while it speaks must stop it within ≈ 0.3 s.
   - Say "hayır hayır hayır", "dur dur dur", "çok çok önemli" — they must arrive as ordinary turns.
4. **Jev — only if the user agrees to use it.** The repository has **no credential store and no network transport** (AGENTS.md: "never handle credentials"; DEC-020/021). Phase A recorded a bounded exception (DEC-268); using it for real needs the user's explicit go-ahead *and* a new decision for the credential store:
   1. Store the TypeSafe/Jev API credential with the macOS Keychain through a **new** `JevCredentialSource` (one small file, `SecItem*` allowed only there; add the file to the `verify.sh` exemption list the same way `MCPInspectionRules.swift` is exempt, and write the decision). **Never print the key, never put it in a file, a log, a test, the repo or an environment dump.**
   2. Implement `JevTransport` (the only network call, one file; `URLSession` is allowed only there — extend the audited-network exemption explicitly). Model discovery: ask TypeSafe for its model list and let the user pick an alias (`prefs.decisionJevModel`); do **not** hard-code a model version. If the API contract differs from `JevPrompt`/`JevResponseParser`, change the adapter, not the grammar.
   3. Connectivity + a minimal live typed-decision request (one utterance, e.g. "Sistem durumunu söyle") and check balance/usage handling: out of balance must degrade (circuit opens), never auto-refill, never block JARVIS.
   4. **Shadow mode first:** there is no Settings control yet (no UI redesign in Phase A): `defaults write <the app's bundle identifier> prefs.decision.jev.mode shadow` (identifier: `AppInfo.bundleIdentifier`; the dev bundle has its own), then relaunch. `gated` is the same key; `prefs.decision.jev.minConfidence` (0.5–0.999, default 0.92) and `prefs.decision.jev.model` (alias) are the other two. JARVIS must behave exactly as before; read `DecisionEngine.audit.shadowReport`.
   5. **Benchmark:** there is no launch flag yet (Phase A did not touch `AppDelegate`/`LaunchOptions`): run it from a test, or add `--decision-benchmark` next to `--visual-benchmark` (it needs no isolated project, only the corpus path). `DecisionBenchmarkRunner.run(corpus, provider: JevDecisionProvider(...), config:, name:)` over `Benchmarks/decision_corpus.json`. Report: intent accuracy, confusion matrix, confidence calibration buckets, latency (mean / p95), API failures by code, approximate usage and cost (price must be supplied by the user — it is never invented). Compare with the deterministic baseline in `DecisionBenchmarkRunner.runDeterministic` (Cloud: 296/353 answered, 100 % of those correct, 0 wrong executing answers — measured on a corpus that was written next to the grammar, so also **write 30–50 fresh held-out utterances** before believing it).
   6. Decide whether **gated** mode is justified: only if Jev is right where the grammar abstains, its high-confidence bucket (≥ 0.92) is ≥ 97 % accurate on the non-deterministic cases, wrong executing answers are 0, and p95 latency is acceptable for speech. `GatedPolicy` already limits what can be accepted to read-only / own-UI intents regardless.
5. **Local conversational model benchmark (M5 / 16 GB):**
   1. Select a *small* set of current MLX-compatible candidates (check availability, licence, MLX support, size at 4-bit that fits 16 GB with the OS and JARVIS; e.g. one or two larger multilingual instruct models, and a 7–9 B class model). Do not decide from memory — look them up. Install via the existing pinned-script mechanism (`scripts/setup_local_ai.sh` conventions), never from the app.
   2. Wire a `ConversationalModelRunning` for the real local worker (wrap `LocalQwenProvider`'s transport): `load()`, `generate(_:)` with TTFT / total seconds / output tokens / context tokens, `residentMemoryMB()`, `unload()`.
   3. Run `LocalModelBenchmark.run(runner:probes:dryRun:false)` on the current Qwen3.5-4B first, then each candidate, same probes (`Benchmarks/local_model_probes.json`, 41 deterministic string-level checks over 8 categories). Add the human review for Turkish naturalness, mixed-language quality and tone (the report leaves those fields empty on purpose).
   4. Report load time, TTFT, tokens/s, peak and steady memory, context used, response length, failure rate and rubric pass per category. **Do not switch the production model until measured, and not without the user's decision.** A larger conversational model never fixes command routing or STT loops — those have their own layers.
6. **Final acceptance (only after 1–3 pass):** the user says **"Jarvis, Hamam projesini aç."** — it resolves from the registry, reveals the folder, the reply is produced from a verified receipt, the Hamam project is not modified. Only after that succeeds does any Hamam autonomous work begin, and only with the user's approval.

## 2. What must stay MANUAL TEST REQUIRED until a human does it

Accessibility · Screen Recording · Microphone · wake word · acoustic self-echo · real barge-in · Apple speech recognition · MLX performance · local model RAM and tokens/s · Keychain · TypeSafe/Jev live API, credential and balance · Safari UI · real Computer Use · NSWorkspace launching · the installed `/Applications/JARVIS.app` · Launch at Login · Unity Editor · the Hamam project · Finder · TCC · notifications. Phase A marked none of these verified.

## 3. Rules that still apply

No paid API is enabled automatically; Jev stays `disabled` unless the user sets it. No auto-refill. Jev only ever produces a `Decision`; policy re-derives its risk and gate; it cannot approve, execute or claim completion. A classifier's confidence is not execution proof; only the existing verified-receipt semantics create a completion claim. No raw audio, no transcript of a rejected utterance, no credential in a log. JARVIS must work with Jev disabled, offline, out of balance, rate limited or timed out.

---

# Phase B results (local Mac, 2026-10-17/18) — truth states

Legend: AUTOMATED TESTED = a test or `scripts/verify.sh` ran it here · REAL TESTED = the real system (NSWorkspace, Unity Editor, TypeSafe API, MLX models) did it on this Mac, driven by a live-test/CLI, no human · MANUAL TEST REQUIRED = needs a person (microphone, speakers, permissions, the real Hamam project).

## 1. Integration and build
* Phase A (`eb836b6…3e10fcb`) was fast-forwarded into `main` (no merge commit, no history rewrite). macOS build: clean. `scripts/verify.sh` first run: 1898 tests passed, 3 guards failed (the decision grammar's word lists matched older "forbidden word" guards) → narrow file-level exemptions, nothing weakened. Final: **1916 tests / 297 suites PASSED, 183 PASS / 0 FAIL / 2 SKIP** — AUTOMATED TESTED.
* Two real macOS-glue defects found by the tests: the integration rig held `ConversationService`'s weak readiness handler by a local variable (test-only), and a Phase A test used a `String` where Swift Testing wants a `Comment`.

## 2. Deterministic routing (no Jev, no model) — AUTOMATED TESTED + REAL TESTED
All 18 utterances of the brief resolve as required (probe over the real recognizer): system status ×2, voice status ×2, navigation ×3, Safari ×2, visibility, "Ekranıma bak", media, both corrections, speed, undo, "Hamam projesini aç" (project_open), "Hamam'da kaldığımız yerden devam et" (project_task/continue, name kept).
Grammar gaps closed (DEC-278): "Hamam'ı aç" / "Hamamı aç" / "Hamam'da devam et" (only when the registry knows the name), "Chrome açık mı?" (application list, never visibility), "geçelim/gidelim" navigation verbs. Real stack (`--daily-jarvis-live-test --daily-section actions|apps`, 20 checks, 0 failed): system status in 68 ms from the structured state; "System panelini aç" / "Dashboard'a dön" change the real Full HUD page with the render acknowledgement active; Calculator and Safari open through NSWorkspace and are verified (53–334 ms); "Safari görebiliyor musun şu anda?" with no observation is NOT a yes; "Sofany'yi aç" opens Safari and says what it understood; "Sofany değil, Safari dedim." / "Hayır Safari dedim." / "Wisp değil, sesim geliyor mu dedim sana." are corrections answered without a model call and without a Project Memory write; provider/capability questions never reached the language model (0 prompts).

## 3. Benchmarks
| set | cases | grammar answered | accuracy on answered | wrong executing |
|---|---|---|---|---|
| main corpus (written next to the grammar) | 353 | 296 (83 %) | 100 % | 0 |
| **held-out** (78, written before measuring, first measurement) | 78 | 46 (58 %) | 97 % | **1** ("Araştırma sayfasına geçelim" → research) |
| held-out after the fix (page noun ⇒ never web research) | 78 | 46 | 100 % | 0 |
The held-out set is spent for tuning purposes; the 32 cases the grammar abstains on are exactly the ones a router/model must handle (conversation, status phrasings, "Kes sesini" …).

## 4. Jev (TypeSafe) — REAL TESTED
* Contract read from docs.typesafe.ai (not guessed): `POST /v1/systemone`, bearer key, typed `choice` questions → `choice`/`probabilities`/`confidence`; `GET /v1/models` → `jev-latest`, `jev-preview` (aliases; answered by `jev-1.13.0`). Input $0.042 per million tokens, output free. The Phase A "prompt→JSON text" contract did not match the API and was replaced (DEC-276).
* Credential: entered by the user through the hidden prompt of `Jarvis --store-jev-credential`; stored only in the Keychain; presence verified, value never read by anything but the transport. (A previous prompt was killed twice by `verify.sh`'s process cleanup; the key was entered on the third attempt.)
* Connectivity: `--jev-check`: models listed, "Sistem durumunu söyle." → `system_status`, confidence 1.00, 347 ms, 1 177 input / 251 output tokens; nothing executed.
* Shadow benchmark (431 requests, **0 failures**, 507 803 input / 108 287 output tokens ≈ **$0.021** at the published price; latency p50 317–321 ms, p95 385–412 ms):
  * main corpus 79.6 % intent accuracy; held-out 88.5 %.
  * Calibration is monotonic: confidence < 0.7 → 36.5 % correct (n 74), 0.7–0.9 → 64 %, 0.9–0.97 → 86 %, ≥ 0.97 → 100 % (n 182) on the main corpus; held-out ≥ 0.97 → 97.8 %.
  * Where the grammar ABSTAINS (89 cases): 77 % main / 91 % held-out; at confidence ≥ 0.92 **48/48 correct**; of those, the gated-acceptable intents 25/25 — but only 6 are non-conversation routes the grammar could not already take ("JARVIS'in durumu nasıl?", "Give me a quick health check", …).
  * Where the grammar ANSWERS, Jev is worse and sometimes confidently wrong: "Can you see my screen?" → computer_use 0.99, "Bu klasörü sil" → computer_use 0.93, "No, I meant open the dashboard" → navigation 0.94. These are exactly what `GatedPolicy` (read-only / own-UI intents only) and the deterministic-first order exist for.
* **Decision: Jev stays `disabled` by default in the installed app; `shadow` is safe and cheap (≈ $0.00005 per utterance) and is how more evidence should be collected; `gated` is NOT enabled** — the benefit measured is six routes in 89 abstentions, every unrecognised utterance would wait ≈ 0.3 s for the classifier before the normal route, and the sample is small and partly written near the grammar. Turn shadow on with `defaults write dev.jarvis.Jarvis prefs.decision.jev.mode shadow` (after storing the key with the installed binary, see KNOWN_ISSUES JARVIS-V1PB-3).

## 5. Unity project open — REAL TESTED on a disposable fixture; the real Hamam project is NOT on this Mac
`--daily-jarvis-live-test --daily-section unity-open` copies `UnityBridge/Fixture` (Unity 6000.5.1f1, installed) to a temp folder and asks "UnityOpenFixture projesini aç.": the project's own editor version is started windowed with `-projectPath`, verified by the process + `Temp/UnityLockfile` + `Library/EditorInstance.json` naming that process in ≈ 5.7 s, the sentence is "UnityOpenFixture Unity'de açık."; asking again brings the same editor forward (no second editor); the test's own editor is quit afterwards. Two defects found by the real run and fixed: Unity's `AssetImportWorker` helper processes (same executable, same `-projectPath`) were counted as editors; the lock file alone was weaker evidence than the editor's own `EditorInstance.json`.
**Hamam:** `memory_projects` is empty and no Unity project named Hamam/Hammam exists under the home folder (only "Turkish Hammam Simulator" — a git repository with no Unity files — `~/Downloads/HammamSim`, a stock "My project", and the Unity Learn projects). Opening a project that does not exist cannot succeed, and JARVIS correctly says it does not know it. See KNOWN_ISSUES JARVIS-V1PB-1.

## 6. Local conversational models (MacBook Air M5, 16 GB; production worker; same 41 probes + 7 brief probes)
| model (licence, 4-bit) | rubric pass | load | TTFT p50 | tok/s | peak MLX | mean words |
|---|---|---|---|---|---|---|
| Qwen3.5-4B (baseline, Apache-2.0, 2.9 GB) | 75 % | 2.2 s | 251 ms | 46.2 | 3.6 GB | 19 |
| Qwen3.5-9B (Apache-2.0, 6.0 GB) | 80 % | 2.7 s | 484 ms | 26.2 | 6.4 GB | 23 |
| Gemma 4 E4B-it (Gemma terms, 5.2 GB) | **87 %** | 2.9 s | **194 ms** | 44.7 | 5.5 GB | 12 |
Per category (pass/probes) baseline → 9B → Gemma: capability_hallucination 2→2→4 of 5, correction 3→4→4, referent 3→3→4, mixed_language 3→5→4, grounded 4→4→4, turkish/stt/followup ≈ equal. All three models still say things like "Safari'yi açıyorum" / "öne getirdim" on the brief's action probes — the claim guard, not the model, keeps that out of the product. Gemma E4B is terse and answered two Turkish prompts in English; Qwen 9B is slower, wordy and refers to "JARVIS" in the third person. Turkish naturalness and tone are a HUMAN judgement nobody has made. **Production model unchanged (DEC-279).** Candidates were fetched by the pinned script `scripts/fetch_local_model_candidate.sh` (exact Hugging Face commits); ~11 GB on disk under `~/AI/models`.

## 7. Not done / MANUAL TEST REQUIRED
Real microphone and speakers (pathological loops from a real recogniser, self-echo, real barge-in, wake word), Accessibility / Screen Recording / Microphone for this ad-hoc build, the Computer Use media test on a real video, the real Hamam project, a human Turkish judgement of the local models, Jev `shadow` on the installed app. README 1295–1308.
