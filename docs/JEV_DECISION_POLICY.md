# Jev decision policy (V1.0 Jev gating pass)

Status: **IMPLEMENTED · AUTOMATED TESTED (Linux harness, scripted / simulated classifiers only) · macOS UNCOMPILED · LIVE Jev NOT MEASURED in this pass · MANUAL TEST REQUIRED.**
Jev stays **DISABLED by default**. Nothing in this document is a claim about how accurate the real Jev is on the new corpora: the Cloud session had no API key (by instruction) and no network path to the service. Every number below says what produced it: `GRAMMAR` (the production grammar, measured), `GATE · SIMULATED` (a classifier written in this repository to exercise the gate — it says nothing about Jev), or `PHASE B · REPORTED` (aggregates the user reported from their Mac; not re-measured here).

## 1 · What Jev is allowed to be

Jev (the TypeSafe `systemone` classifier) answers ONE question: **"what does the user intend?"** It is not the orchestrator, it executes nothing, it approves nothing, and it never produces a completion claim. Roles stay separate:

| Role | Who | Never |
|---|---|---|
| decide *which known capability* a short command-like sentence means | deterministic grammar first; Jev only on a true abstention, behind a local gate | execute, approve, grant, claim |
| render a reply | local Qwen / Gemma, or Claude / Codex / OpenCode through the router | decide routing authority |
| reason / code | Claude Code, Codex, OpenCode, through `TaskEngine` | |
| orchestrate, approve, verify | JARVIS (`TaskEngine`, HUD approvals, receipts) | |

**Deterministic policy always wins.** Evidence that it matters (Phase B, reported): Jev said `computer_use` at 0.99 for "Can you see my screen?", which the grammar correctly takes as a capability question.

## 2 · Architecture, before → after

Before (Phase B): `grammar → Jev (disabled / shadow / gated) → GatedPolicy.accepts (closed intent set, ≥ floor) → typed route`. One global floor (0.92); a cached answer was trusted; a non-finite or out-of-range confidence was clamped; navigation targets were checked, nothing else was.

After:

```
utterance → corrections / meta-correction ("Sofany değil, Safari dedim") ── grammar (zero Jev) ──decided──▶ USE IT          (Jev is never asked)
                                                                    ├─ambiguity──▶ the grammar's clarification            (never asked)
                                                                    ├─policy block─▶ refusal / ask-first                  (never asked, never overridden)
                                                                    └─abstained──▶ PREFLIGHT  short · command-shaped · not quoted/meta · not negated · no critical word · no secret shape
                                                                                      └▶ Jev (gated timeout ≤ 1.5 s, budgets, breaker)
                                                                                           └▶ typed CANDIDATE → LOCAL GATE (JevGatePolicy.evaluate)
                                                                                                ├─accept (read-only, own-UI only)─▶ the EXISTING handler, with its own verification
                                                                                                └─reject (coded)──────────────────▶ the existing router, as if Jev did not exist
```

Files: `Decision/JevGatePolicy.swift` (classes, preflight, guards, gate, corroboration), `Decision/JevEvaluation.swift` (pure measurement), `Providers/Jev/JevPrivacyFilter.swift`, edits in `JevDecisionProvider` (context minimisation, malformed answers, session cap, reported model), `DecisionEngine.consultGated` (the one caller of the gate), `DecisionTelemetry` (rejection code, model, fallback — no text).

## 3 · Zero-Jev fast path (proved, with call counting)

`JevZeroPathTests.zeroJev` drives eleven everyday commands through `decide` + `consultGated` with a counting classifier that would say `system_status @ 0.99` to anything — in gated mode and in default shadow mode. **Calls: 0 for each.**
"Sistem durumunu söyle." · "System Durumu Nedir?" · "Sesim geliyor mu?" · "System panelini aç." · "Dashboard'a dön." · "Safari'yi aç." · "Safari'yi açabilir misin?" · "Hamam'ı aç." · "Hamam'da devam et." · "Konuşmayı durdur." · "Görevi iptal et."
Corrections ("Sofany değil, Safari dedim", "Hayır onu yapma") are decided before Jev too. `disabled` (the default) asks nothing, ever.

Abstain-path matrix (`abstainMatrix`): success → no Jev · ambiguity ("Onu aç", no referent) → the grammar asks, no Jev · policy block ("GitHub'a pushla.", "Dosyayı sil.") → no Jev and no override · true abstention ("Şu anki durumu bir özetle") → one request, a read-only answer above its floor is accepted with provenance `jevGated`; the same abstention answered `computer_use @ 0.99` is rejected `executionNotEnabled`.

## 4 · Intent taxonomy and safety classes

The taxonomy is closed (16 intents, `DecisionIntent`; a test pins the count — a new intent needs a class and a floor or it does not compile / is never accepted).

| Class | Intents | Remote answer accepted in production? |
|---|---|---|
| **A · read-only** | `system_status`, `voice_status`, `provider_capability`, `project_query` | yes, at level `readOnly` (default), per-intent floor + corroboration (+ resolved project for `project_query`) |
| **B · own-UI** | `jarvis_navigation` | only at level `ownUI` (not the default); page from the closed vocabulary AND mentioned in the sentence |
| **C · execution-capable** | `macos_application_action`, `computer_use`, `project_open`, `project_task`, `settings_change`, `research`, `stop_speech`, `cancel_task` | **never** (`JevGatePolicy.executionIsEnabledInProduction = false`, a constant). `computer_use`, `stop_speech`, `cancel_task` are not accepted even in the simulation |
| **D · critical** | delete / destroy / format, push / commit / deploy / publish, purchase / payment, credentials | never an intent: DERIVED locally from the words and the policy table; rejects whatever Jev said |
| not routable | `conversation`, `correction`, `unknown` | nothing to accept; the router / correction engine own them |

Stop-speech ("Sus") and cancel-task ("Görevi iptal et") stay separate and deterministic; a classifier can never turn either into the other (both class C, never accepted).

## 5 · The gate, in order (`JevGatePolicy.evaluate`)

1. preflight defence in depth (grammar decided / asked / blocked, quoted or meta, negated, critical content);
2. non-finite confidence → `malformedConfidence`; (the mapper / parsers reject NaN, ±∞, −1, 5 — never clamp);
3. safety class (see §4);
4. **risk re-derived locally** (`LocalRiskDerivation`: policy table by intent+action, plus the words of the utterance) — Jev's "low risk" does not exist as an input; any critical word → `criticalContent`; local risk > low or any gate → `localRiskHigher`;
5. candidate ambiguity → `ambiguousCandidate`;
6. per-intent floor (never below the category floor or the user's own floor) → `belowIntentThreshold`;
6b. **corroboration**: a word of the sentence must belong to the answer's topic (closed hand-written lists; for a page, the page's own name) → `noLexicalAnchor`;
7. provider SELECTION ("Claude Code'u kullan", "Bunu Claude'a yaptır") is never read as a capability question → `possibleSelection`;
8. **target resolved by JARVIS' own resolvers** (page vocabulary; the project registry via `DecisionEngine.projectResolver`) — Jev never names an executable identifier; `unresolved` / `ambiguous` reject (`projectResolver` defaults to unresolved, so project-bound answers are not accepted until a registry is wired — KNOWN_ISSUES JARVIS-V1JV-6);
9. the closed `GatedPolicy` set on top; 10. capability available; 11. the answering model equals the calibrated model (`modelChanged`).

Approval isolation: no gate output is a decision about approval, a capability or a task. An approval word ("evet", "onaylıyorum", "approve") reaches no gate (tests), the planner turns an accepted `system_status` into the existing status handler and turns `computer_use` / `delete` into pass-through (the engine's own policy and HUD approvals apply), and a source-level test + `scripts/guards_jev.sh` pin that the Jev files reference no `ActionService`, `TaskEngine`, approval, Computer Use, process, network or Keychain API. NO VERIFIED ACTION → NO COMPLETION CLAIM is untouched: Jev can add no claim because it can add no action.

## 6 · Per-intent thresholds — rules, not fitted numbers

Reported Phase B evidence (aggregate, local Mac): confidence ≥ 0.97 → 100 % correct on the main corpus (n 182), 97.8 % held-out; 0.9–0.97 → 86 %; 0.7–0.9 → 64 %; < 0.7 → 36.5 %. Where the grammar abstained: ≥ 0.92 → 48/48 correct, of which only 6 were useful non-conversation routes.

| Intent | Floor (remote) | Rationale |
|---|---|---|
| `system_status`, `voice_status`, `provider_capability` | 0.95 | a wrong read-only answer costs one sentence; the abstention evidence is clean from 0.92, the floor sits above it |
| `project_query`, `jarvis_navigation` | 0.97 | needs a TARGET (intent confidence is not target confidence) / changes the screen; matches the bucket that was 100 % / 97.8 % |
| every class C intent | no production floor; simulation floor 0.99 | never accepted; the simulation measures what 0.99 *would* do |
| the user's own `gatedMinimumConfidence` | can only raise a floor | |

Safety over coverage: nothing was lowered to buy a route. Floors are also checked against the cache (a cached answer is re-run through the same gate against the current floors / model).

## 7 · Calibration

* **PHASE B · REPORTED** (not re-measured, different bin edges): see §6.
* **Harness**: `JevCalibration.bins` produces exactly the requested bins (`<0.50`, `0.50–0.69`, `0.70–0.79`, `0.80–0.89`, `0.90–0.94`, `0.95–0.96`, `0.97–1.00`) with count, accuracy, executing-answer accuracy and false executions, held-out kept separate by running each corpus on its own; verified with synthetic records (test `calibrationBins`). **Per-case Jev results do not exist in the repository** (only aggregates), so real per-bin numbers for the main, old held-out and new held-out sets are produced by the user's local run (§13). No bin number is invented here.

## 8 · Measured results

### 8.1 GRAMMAR (production grammar, no Jev) — measured in this pass

First-measurement defects on the NEW sets were fixed class-wide (not per sentence) and the older corpora re-run:
quoted / translated / meta sentences ("'Delete all files' ne demek?"), reported negation ("Bu projeyi sil demedim"), an ability question ("Safari'yi açabiliyor musun?"), a pronoun-only research topic ("Şunu araştır", "Research this for me" → `ask_referent`), a bare English "go" ("Rust mı Go mu öğrenmeli" is not navigation), and settings "up/down" outside "speed up / slow down" ("Can you pick up my voice?" is not a speech-rate request).

| Corpus | cases | answered | exact | executing false positives | must-not-execute held |
|---|---|---|---|---|---|
| main (353) | 353 | 299 | 296 | 0 | – |
| old held-out (78, SPENT) | 78 | 57 | 57 | 0 | – |
| adversarial A (322, SPENT) | 322 | 261 | 252 | 1 ("devam et", resolver-mediated hand-off, known since the reliability pass) | 57/57 |
| blind B (199, SPENT) | 199 | 148 | 140 | 0 | 47/47 |
| **new held-out H1 (108)** | 108 | 55 | 48 | **0** | – |
| **hard negatives N1 (64)** | 64 | 7 | 0 | **0** | **64/64** |
| **ambiguity A1 (36)** | 36 | 13 | 8 | 5 (see below) | – (ambiguity asked 10/36; the rest are abstentions the router handles) |

Pre-fix first measurement on the new sets (kept for honesty): held-out executing FP 2, hard negatives 8 (56/64 held), ambiguity 8. After the fixes: 0 / 0 / 5. The five ambiguity "executing" decisions are `devam et` / `Projeyi aç` / `Open the project` (a project-resolution hand-off: the planner asks which project), `Sesi ayarla` (settings need a value: the assistant asks) and `Şunu kapatsana` with a referent (ask-first gate); the labels were NOT edited.
**H1, N1 and A1 are now SPENT for the grammar** (they were used to find and fix defects). Replacing 13 held-out sentences that duplicated older corpora happened before any Jev measurement and is recorded in `Benchmarks/README.md`. A new blind set is required before believing a new coverage figure.

### 8.2 GATE · SIMULATED — what the gate would accept, whoever the classifier is

Seven corpora (1 160 labelled sentences: 353 + 78 + 322 + 199 + 108 + 64 + 36), hostile classifiers: wrong on every case @ 0.99; always `computer_use` / `macos_application_action` / `project_task` / `settings_change` / `research` / `system_status` / `voice_status` / `provider_capability` @ 0.99; every-5th-wrong; with a *liberal* target resolver (every target "resolved") to stress the other checks; at every gate level.

* **Executing accepts in production: 0 / 0 false** in all of it (196 corpus × classifier × level × resolver combinations in the first sweep and a >10 000-answer property test in `hostileClassifiers`). The metric is structural: the gate refuses the whole class.
* **The execution-level SIMULATION is not safe to enable**: with a liberal resolver, an always-`macos_application_action` classifier gets 239 simulated acceptances of which 225 are false; a classifier wrong on every case, 66 simulated executing acceptances, 66 false. This is the evidence for "GATED EXECUTION is not recommended".
* Read-only level (default), all seven corpora, wrong-on-every-case classifier: **2 wrong read-only answers accepted** with corroboration ON versus **70** with it OFF (a 35× reduction); always-`system_status` @ 0.99: 14 accepted (7 right, 7 wrong; 5 of the 7 swallowed an action-labelled sentence) versus 239 with corroboration off. So a confidently wrong *read-only* answer is not impossible, only rare — the residual risk, documented as JARVIS-V1JV-3.
* Own-UI level: the always-wrong classifier gets 2 wrong page switches through with corroboration ON (91 accepted, 21 wrong page changes with it OFF); always-`jarvis_navigation → settings`: 6 accepted (all wrong, all because the sentence mentions the settings page) ON versus 239 OFF. A wrong page switch is visible and harmless but it is not zero, which is why `ownUI` is not the default.
* Oracle upper bound (a perfect classifier, gate level `readOnly`, anchors ON): it would have routed **1 + 5 + 0 + 0 + 7 + 0 + 0 = 13** sentences across all seven corpora (1 160 requests) that the grammar had not already decided; `ownUI` adds 4 more page changes in the new held-out set. The value of gating is small and well bounded.

### 8.3 Executing false-positive rate (the metric that matters)

| Layer | Rate |
|---|---|
| gate, production, any classifier, any corpus (simulated) | **0** (0 of > 10 000 hostile answers) |
| grammar, all seven corpora | 6 sentences of ≈ 1 160 cases (0.5 %): the 5 resolver hand-offs above + "devam et"; 0 on N1 (64 hard negatives) and 0 on H1 |
| real Jev | **not measured in Cloud** — must be measured locally (§13); a real run can only add *route* errors at class A/B, never executing ones |

### 8.4 Ambiguity, targets, risk

* Ambiguity: the grammar asks for 10 of the 36 ambiguity cases (the rest are abstentions that keep the router), the pronoun-only research family now asks "Neyi araştırayım?"; Jev is never asked about an ambiguity the grammar already raised (`deterministicAmbiguity`) and a candidate carrying an ambiguity is rejected.
* Target resolution: navigation page must be in the vocabulary *and* named in the sentence; project-bound answers need `projectResolver` to say exactly one known project; nothing the classifier supplies becomes an identifier (the accepted decision of a `project_query` carries no classifier target — tested).
* Local risk re-derivation: "Sistem durumunu söyle ve dosyaları sil" with a candidate that claims low risk → rejected; a push / purchase / credential word → `blocked`/critical regardless; a production decision that already has a gate is final.

## 9 · Privacy: what may leave the machine

Only: the (redacted, ≤ 300 char) utterance, language, `typed|voice`, ONE short tag of the previous turn's interpretation, the fixed intent / page vocabularies, project **names** only when the sentence is about a project, and — only for a pronoun / ellipsis sentence ("onu kapat", "devam et") — typed referent **names** no older than ten minutes (`lastApplication = Safari`). Never: memory, history, transcripts, source, screen, audio, paths, credentials. Redaction masks paths (`/…`, `~/…`, `a/b/c`), file names (`Player.cs`, `notes.txt`), e-mails, IPv4, long digit runs. A sentence that carries a credential SHAPE (credential word + value, opaque 24+ char token, authorization header) is never sent; a sentence that merely names a credential ("Bu API key'i nereye koyacağım?") may be. Telemetry holds intent, confidence bucket, rejection code, model id, fallback flag, latency bucket — no utterance (tested).

## 10 · Latency, timeouts, breaker, budgets — Jev is never a single point of failure

* Only abstentions reach Jev. Measured Phase B latency: one call ≈ 347 ms, p50 317–321 ms, p95 385–412 ms (REPORTED). Added latency per request = (share of requests that reach Jev) × call latency; the share is the C column below. No other latency figure is claimed (`JevLatencyModel` returns nil without a measurement).
* Gated mode waits at most `min(timeout, gatedTimeoutSeconds = 1.5 s)`; a hanging transport is abandoned (test). The harness cannot measure real round trips at 100 ms / 300 ms / 500 ms / 1 s from Cloud; the policy is the shorter bound, and a timeout is one more fall-back to the existing route.
* Circuit breaker: 3 consecutive failures open it for 600 s (no request while open, one probe after); `outOfBalance` / `apiChanged` / `credentialMissing` open it at once; no retry against an empty balance (tests). Bounded retry only for transient classes.
* Cost guards: `maxRequestsPerHour` (120) and `maxRequestsPerSession` (1000), counted exactly; the service has no auto-refill; cost is shown only from a user-configured price, never invented (Phase B reported ≈ $0.021 for 431 shadow requests).
* Every failure class (timeout, offline, rate limited, out of balance, malformed, API changed, unavailable, credential missing) → the production decision is untouched, the existing router handles the sentence, the audit says why.
* Model change: the answering model id is recorded; if it differs from `calibratedModel`, gated answers are not accepted until calibration is repeated. `jev-latest` vs `jev-preview` can only be compared by the local run (no credential in Cloud — nothing was fabricated).

## 11 · Call reduction (A / B / C), measured on the corpora (oracle classifier, `readOnly`, grammar as shipped)

A = ask Jev for every request · B = ask whenever the grammar abstains or asks · C = ask only after the full preflight (this is what ships).

| Corpus | A | B | C | C / A |
|---|---|---|---|---|
| main | 353 | 60 | 49 | 13.9 % |
| old held-out | 78 | 21 | 20 | 25.6 % |
| adversarial A | 322 | 78 | 46 | 14.3 % |
| blind B | 199 | 67 | 39 | 19.6 % |
| new held-out H1 | 108 | 53 | 50 | 46.3 % |
| hard negatives N1 | 64 | 57 | 12 | 18.8 % |
| ambiguity A1 | 36 | 33 | 23 | 63.9 % |

Corpora with natural traffic (main, A, B) send 14–20 % of requests; H1 is deliberately made of indirect sentences the grammar misses, so it is the worst case. Strategy B → C removes the sentences the gate could never accept anyway (quoted, negated, critical).

## 12 · Modes and recommendation

* **disabled** (default): nothing is sent. Behaviour identical to before this pass.
* **shadow**: Jev is asked only about abstentions (default scope), compared and never used; telemetry records intent / bucket / rejection / model without text. Useful to collect the local per-case evidence of §13.
* **gated**: abstentions only, `readOnly` by default (`ownUI` adds page changes; `execution` is a simulation constant that production cannot enable). Nothing enables it by itself (guard).

**Recommendation: keep Jev DISABLED by default. SHADOW is acceptable for evidence collection. GATED READ-ONLY is the only candidate gate level, and only after the local run of §13 shows, on the main, old held-out and new held-out sets (kept separate), (a) accepted read-only answers ≥ 99 % correct, (b) 0 accepted answers on the hard-negative and ambiguity sets, (c) 0 executing accepts (already structural), (d) p95 added latency acceptable. GATED EXECUTION is not recommended** — the simulation shows that, with any resolver more generous than a registry lookup, a confidently wrong classifier would be wrong most of the time on exactly the sentences where it is asked; the oracle upper bound (13 routes in 1 160 requests) does not justify the risk.

## 13 · Local validation required (exact commands; nothing here ran in Cloud)

1. `scripts/verify.sh` on a Mac (compiles the macOS-only edits; runs the new tests, guards and the full suite).
2. Key stored once with `Jarvis --store-jev-credential` (never pasted into chat).
3. Evidence run (shadow, headless, ≈ $0.02): `Jarvis --decision-benchmark --corpus Benchmarks/decision_corpus.json --heldout Benchmarks/decision_heldout.json --adversarial Benchmarks/decision_adversarial.json --blind Benchmarks/decision_blind.json --suite "jev held-out=Benchmarks/jev_heldout.json" --suite "jev hard negatives=Benchmarks/jev_hard_negative.json" --suite "jev ambiguity=Benchmarks/jev_ambiguity.json" --project-names "Hamam,Hammam,Turkish Hammam Simulator" --jev --rows jev_rows.json` (paid usage only with the user's own key and consent; run once per model alias with `--jev-model jev-latest` and `jev-preview`).
4. Offline gate evaluation of those rows (no network): `Jarvis --jev-gate-evaluate --rows jev_rows.json` with the same corpus flags. It prints per corpus and per level: accepted / correct / wrong / swallowed an action / own-UI changes / EXECUTING false accepts, call counts, rejection histogram, latency and the calibration bins.
5. Read the numbers against the gates in §12; keep the rows file out of the repository (`*.json` rows contain sentences, not credentials, but they are measurements, not source).

## 14 · Worked examples (GRAMMAR + GATE; produced by a throw-away driver in the Linux harness, not committed; the same behaviours are pinned by `Tests/JarvisTests/JevGateTests.swift`)

| Utterance | Grammar | Jev | Outcome |
|---|---|---|---|
| "Sistem durumunu söyle." | `system_status` | not asked (`deterministicDecided`) | existing status handler |
| "Jarvis'in durumu nasıl?" | abstains | asked; `system_status @ 0.98` | ACCEPT (class A, anchor "durum", floor 0.95) → status handler |
| "Can you see my screen?" | `provider_capability/screen` (capability question) | not asked | grounded capability answer; Jev's `computer_use 0.99` would never be seen |
| "Şu videoyu oynat bakalım" | `computer_use/media` | not asked | existing Computer Use path with its own policy |
| "Safari'yi açabilir misin?" / "Safari'yi açabiliyor musun?" | launch / **no action** (ability question) | not asked / abstains | polite request opens Safari; the ability question stays a question |
| "Hamam'da devam et." | `project_task/continue` | not asked | continuity through the one orchestrator |
| "Biraz daha hızlı ol" | abstains | asked; `settings_change @ 0.99` | REJECT `executionNotEnabled` → existing router / settings assistant |
| "Bunun hakkında araştırma yap" | `ask_referent` (ambiguity) | not asked | "Neyi araştırayım?" |
| "Claude Code'u kullan." | `prefer_provider` + ambiguity ("for which task?") | not asked | clarification; a Jev `provider_capability` would be `possibleSelection` |
| "Konuşmayı durdur." / "Görevi iptal et." | `stop_speech` / `cancel_task` (separate) | not asked | typed stop vs cancel, never swapped |

## 15 · Limits of this pass (also KNOWN_ISSUES JARVIS-V1JV-*)

No live Jev call, no macOS compile, no real project registry wired into `projectResolver`, hand-written corroboration lists, new corpora spent for the grammar, aggregate-only Phase B calibration. The pure logic (gate, evaluation, guards, grammar fixes, malformed-answer handling) was compiled and run in the Linux harness: Jev gate suite 39 tests / 1 186 checks, decision suites 107 tests / 978 checks, 0 failures; source guards 289 pass / 0 fail after this document, `Benchmarks/README.md` and the guard file were in place.
