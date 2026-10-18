# V1.0 intelligence & reliability optimization — the overnight Cloud pass

Branch `claude/laughing-albattani-uzdlr6`, based on `origin/main` e9dfd5f (Phase B, build 125). Not merged, not tagged. **Everything below is AUTOMATED TESTED in a Linux container (SwiftWasm toolchain's native `swiftc`, Foundation only) or UNCOMPILED on macOS — nothing here was run on a Mac, nothing needing a microphone, speaker, permission, window, Finder, Safari, Unity, MLX, Keychain or the real Hamam project was touched.** `scripts/verify.sh` has NOT been run on this branch (JARVIS-V1RP-1). Hamam was not touched; V1.1 was not started.

Legend: AUTOMATED TESTED = a test ran it in the Linux harness · UNCOMPILED = macOS-only glue edited, syntax-reviewed, never compiled · MANUAL TEST REQUIRED = needs a person or a Mac.

## 1. Measurements (deterministic grammar only; no model, no network)

Ground truth is hand-written; no model edited any label. Before = `e9dfd5f`'s recognizer measured with the SAME corpora and runner. A registry stand-in (Hamam, Hammam, Turkish Hammam Simulator — injected, never hard-coded in the grammar) is used for bare project names.

| set | cases | before: answered · accuracy · exact · executing FP | after: answered · accuracy · exact · executing FP | status of the set |
|---|---|---|---|---|
| main corpus | 353 | 296 (83 %) · 100 % · 295 · 0 | 298 (84 %) · 100 % · 295 · 0 | tuned at authoring time |
| held-out (Phase B) | 78 | 46 (58 %) · 100 % · 46 · 0 | 57 (73 %) · 100 % · 57 · 0 | **SPENT for tuning** — I saw its abstentions; the +15 points are not evidence of generalisation |
| adversarial **A** | 322 | 170 (52 %) · 96 % · 46.9 % · **5** (1.55 %) | 261 (81 %) · 98 % · 78.9 % · **1** (0.31 %) | written BEFORE the lexicon, used during development; 2 labels corrected after the baseline run (below) |
| blind **B** | 199 | 92 (46 %) · 92 % · 39.2 % · **4** (2.0 %) | **first measurement of the frozen implementation: 146 (73 %) · 97 % · 68.3 % · 1** | written after A + lexicon were frozen, never run during development, measured ONCE |
| blind B after fixing what B found | 199 | — | 148 (74 %) · 99 % · 70.9 % · 0 · must-not-execute 47/47 | now SPENT too |

* **The honest generalisation figure is the blind-B first measurement: coverage 46 % → 73 %, executing false positives 2.0 % → 0.5 % (one: "Görevi iptal etme" read as cancel), intent accuracy on answered 92 % → 97 %.** The five real executing false positives of the OLD grammar that A found: "Is Safari open?" → launch Safari, "Görevi nasıl iptal ederim" → cancel task, "Safari'nin ayarlarını nasıl açarım" → open Settings, "Safari'yi aç aç aç aç" → launch, and "devam et" (below).
* One executing "false positive" remains on A on purpose: bare **"devam et"** is handed to Project Continuity, which picks the current project or asks (`DecisionPlanner` passes `.projectTask/continue` with no target through). The label I wrote before measuring says "ask"; the existing behaviour is also a question one layer down, and replacing it would bypass real logic (DEC-282). Counted, not hidden.
* Label disagreements (mine, left standing): A-referent-024 (nothing to repeat: I labelled `correction/repeat_previous`, the grammar says `unknown` + ask — A-referent-020, the same sentence, I labelled `unknown`), A-correction-004 and B-correction-007 ("X dedim, Y değil": I labelled `restate`, the grammar's `restate_replacing` is the more precise one), B-project-004 ("Hamammı aç": a typo — correct behaviour is to abstain, I labelled it `hammam`). Corrections I DID make to A after its baseline run, recorded in the file's authoring script: "o proje neydi" (a recall question, relabelled non-executing) and "onu geri al" (a settings REVERT, not a change).
* Latency: 0.54 ms per decision on the Linux harness (19 040 decisions, `-O`); a regression test bounds it at 5 ms.
* Executing false-positive rate is the metric weighted most; its definition: an answer that executes although the truth is a different intent/action or "do not execute at all" (a mention, a negation, an approval word, an injection attempt, a stutter, a multi-step sentence).

## 2. What was built

| piece | files | state |
|---|---|---|
| **Semantic command lexicon**: concepts (OPEN CLOSE SHOW LOOK CONTINUE STOP CANCEL STATUS NAVIGATE RESEARCH USE CHANGE UNDO RETRY) × targets (APPLICATION PROJECT JARVIS_PAGE SETTING MEDIA TASK PROVIDER SCREEN), closed Turkish morphology (plural · possessive · case chains, exact stems only), closed verb morphology (imperative · -sana/-iver · aorist before "mısın" · -abilir), polite-form canonicaliser for the existing typed parsers, negation / how-to / conjunction / stutter guards | `Decision/CommandLexicon.swift`, `DeterministicCommandRecognizer.swift` | AUTOMATED TESTED |
| Typed referents (application · project · page · setting · task) with ages, 10-minute TTL, 60 s recency margin; a closing verb never resolves from recency; unresolved ⇒ the planner ASKS (names the fresh candidates) | `Decision/DecisionReferents.swift`, `DecisionPlanner.swift`; tracker + wiring in `ConversationService` | logic AUTOMATED TESTED · wiring UNCOMPILED |
| Planner: lexicon launches typed, negation answered honestly ("I cannot undo anything that already happened"), "same again" bounded (refuses a repeat of a repeat / correction / risky request), near-miss project names become a "did you mean" question | `DecisionPlanner.swift` | AUTOMATED TESTED |
| **Confidence policy** (per-category floors; remote accepts only read-only ≥ 0.88 and own-UI ≥ 0.92; confidence never overrides gate / risk / ambiguity) | `Decision/ConfidencePolicy.swift`, `GatedPolicy` | AUTOMATED TESTED |
| **Jev routing**: asked only for a short command-shaped ABSTENTION; shadow default scope `abstentionsOnly`; bounded retry (1) for transient transport failures only; salted-hash in-memory pattern cache (no text kept, 64 entries, 6 h, ≥ 0.97, read-only only); project names sent only for project sentences; shadow calibration buckets | `ConfidencePolicy.swift`, `JevDecisionProvider.swift`, `DecisionEngine.swift` | AUTOMATED TESTED with a scripted transport; real Jev NOT called |
| **Presentation contract + claim firewall**: structured facts, response provenance, structural TR/EN claim detection for action · perception · state · task result (and progress percentages), a claim survives only with a VERIFIED fact of its kind naming the same thing; Turkish language directive for any engine + model-free mismatch check | `Decision/ResponseContract.swift`, `IntelligenceRequest.providerPrompt`, `ConversationService.applyCapabilityFirewall` | logic AUTOMATED TESTED · wiring UNCOMPILED · `PresentationContract.block` (facts → model) is NOT yet fed anything (JARVIS-V1RP-4) |
| One observation-freshness policy (per-kind TTLs); `ObservationGrounding` uses it | `Decision/ObservationFreshness.swift` | AUTOMATED TESTED |
| Content-free decision telemetry (intent, bucketed confidence/latency, route, outcome, reason code; ring of 500, 7 days, memory only) | `Decision/DecisionTelemetry.swift` | AUTOMATED TESTED · not yet fed from the engine |
| **Project discovery** (explicit roots, bounded, read-only, no symlinks, system/home roots refused; candidate ≠ registration; suggested aliases from the folder's own name) + exact alias resolution (fuzzy only suggests) | `Continuity/ProjectDiscovery.swift`; `Jarvis --discover-projects <folder>…` | AUTOMATED TESTED on temp folders · the CLI is UNCOMPILED · nothing registers anything |
| **Reliability policies** (pure): stuck-task detector, provider circuit + fallback (never paid, never from an explicit choice), 16 GB resource budget, overnight policy + morning report, derived-only progress, checkpoint hygiene + resume revalidation | `Reliability/*.swift` | AUTOMATED TESTED · **NOT wired into `TaskEngine`** (see §3) |
| Seeded soak / fuzz (3 seeds × ≈ 35 300 generated cases) | `Tests/…/SoakFuzzTests.swift` | AUTOMATED TESTED — found and fixed one real bug (a registry predicate that tolerates a suffix let "Hamam'daa" through as hamam + da + a) |
| Voice guard hardening (generated loops, mixed repetition, emphasis, wake echo, rate, order-in-pipeline) | `Tests/…/VoiceGuardHardeningTests.swift` | AUTOMATED TESTED; real recogniser MANUAL TEST REQUIRED |
| Guards (authority, quiet/pure, fuzzy-never-executes, cost, bounded loops, credential literals, corpus recorded) | `scripts/guards_reliability.sh` (sourced by `verify.sh`) | 7 guards pass in the Linux guard runner; `verify.sh` itself NOT run |

## 3. TaskEngine reliability audit — what exists, what this pass added, what is still to wire

| concern | already in the repo (read, not changed) | gap found | this pass | local hookup (Phase C) |
|---|---|---|---|---|
| checkpoints | `writeCheckpoint` at every coherent boundary (plan version, step states + evidence, change hashes, git baseline, leases, approvals, diff) | no schema rule for what must NOT be stored | `CheckpointHygiene` (secrets, chain-of-thought markers, audio refs) | call `CheckpointHygiene.safeEvidence` in `writeCheckpoint` for `validationEvidence` / `failure` |
| resume after restart | `reconcileOnLaunch` marks running tasks INTERRUPTED; resume is explicit; waiting tasks restored; Computer tasks never auto-resume | resume does not compare recorded vs current truth beyond the workspace | `ResumeValidator` (git head, file hashes, plan version, missing workspace; approvals informational) | build a `ResumeSnapshot` from `Checkpoint` in `loadContext`, refuse + explain on blocking issues |
| provider timeout | `limits.providerTimeout = 600` per job | a provider that streams nothing for minutes is only cut at 600 s; no stall signal | `StuckTaskDetector` (no output / transition / tool activity / identical failure / provider unavailable → retry once → fallback → pause/ask/fail) | feed `TaskLiveness` from `AgentRunManager` output events and step transitions; evaluate on events and on the existing timeout, not on a poll |
| bounded retries | repair ≤ 1 per step, escalation ≤ 1, capacity waits ≤ 40, bounded Jev retry (new) | no single schedule for transient provider failures | `RetrySchedule` (2 s · ×2 · cap 30 s · 2 retries, transient only) | use from the provider layer on `offline`/`crashed` |
| provider health | `ProviderSupervisor`: persisted failure/cooldown per engine, local worker one bounded restart, unload under memory pressure | no half-open probe, no "never paid fallback" rule in one place | `ProviderResilienceBook` + `FallbackPolicy` (mirrors `CooldownPolicy`) | route `ModelRouter` candidate filtering through `FallbackPolicy.candidates` |
| 16 GB budget | `ConcurrencyLimits` (1 local job, 2 free-cloud, 1 heavy, 3 total), memory-pressure unload | no declared resident-memory rule (one local model, no large pair, Unity + 9B) | `ResourceBudget` (declared MB from the measured peaks, 75 % limit) | consult `mayStart` before `LocalRuntime` loads a model |
| overnight | approvals, leases, user-dirty protection, `critical` has no path | no explicit unattended policy or morning report | `OvernightPolicy` + `MorningReport` | drive the engine's "next step" choice and `onFinished` summary from it when the user has been away |
| progress | `TaskView.passedCount / measurableCount`, "progress = validated steps only" | a model could say "%80 tamamlandı" | `ProgressReport` (derived % only) + the firewall treats a model percentage as an unbacked task claim | answer "görev durumu" from `ProgressReport.line` |

No second scheduler, orchestrator or approval path was added; nothing runs on a timer; the engine itself was not edited.

## 4. What stays MANUAL TEST REQUIRED / local

1. `scripts/verify.sh` — compile errors in the macOS glue are likely to the extent of what `swiftc` on Linux cannot see (JARVIS-V1RP-1): `ConversationService` (referent tracker, `freshPreviousUserText`, the firewall call), `IntelligenceProvider.providerPrompt`, `DecisionTools` (`--discover-projects`, benchmark flags), `JevConfig` call sites. The new test files were converted for Swift Testing (`Comment(rawValue:)` for non-literal messages) but never compiled by it.
2. Real typed and spoken forms on the Mac: README 1306–1320.
3. Real Hamam: still absent from this Mac (JARVIS-V1PB-1); `Jarvis --discover-projects ~/Projects` is the read-only way to see what exists before registering anything.
4. Jev: shadow now asks ONLY about abstentions of the grammar that are short and command-shaped (the Phase B benchmark sent every case) — request count, cost and latency fall accordingly; whether gated is justified is still a human decision on real data. No key, no network, no request was made by this pass.
5. The Turkish directive in `providerPrompt` changes the prompt of every Turkish request: confirm real answers stay Turkish (JARVIS-V1RP-5).

## 5. Rules this pass added (DEC-280…286)

Lexicon is Level 0b and only fills what the closed grammar leaves open; full understanding or abstain; exact stems; one action per sentence; closing asks and never resolves from recency; references resolve through typed ages or ask; a remote classifier is asked only for an abstention and never executes; a claim needs a verified fact; progress is derived; the reliability policies are pure data; a candidate is not a registration and a fuzzy match only asks. See `docs/DECISIONS.md`.
