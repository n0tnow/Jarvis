# Web Research (V0.9)

> Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (live public web, this Mac) · **MANUAL TEST REQUIRED**. Not user-verified. Companion: `ASSET_ACQUISITION.md`. Decisions: DEC-088…103.

JARVIS can research any bounded question on the public web and answer with a **cited, evidence-backed report**. Unity asset research is the first practical consumer, not the design centre. Research is **not** an autonomous browsing agent: it is an ordinary V0.4 task with a fixed, budgeted, deterministic plan.

## 1. Authority levels (DEC-088)

| Level | What it allows | V0.9 |
|---|---|---|
| RESEARCH | search, fetch public pages, read metadata/licences, compare, recommend | implemented (this document) |
| ACQUISITION | download a public artifact into the **quarantine** | implemented (`ASSET_ACQUISITION.md`) |
| IMPORT / PROJECT WRITE | copy an inspected artifact into a project | implemented as a separate approval-gated V0.4 development task (V0.6 owns the Unity side) |
| ACCOUNT ACTION | sign in, accept terms, "add to my assets", OAuth | **no code path** |
| COMMERCIAL | purchase, subscription, paid trial, paid API | **no code path** (always a critical, never-automatic approval) |

`AuthorityLevel.isImplemented` is false for the last two. The task capabilities are typed (`researchWeb`, `downloadToQuarantine`, `importIntoProject`); the old `useNetwork` / `useBrowser` capabilities stay **ungrantable**.

## 2. Pipeline

`Conversation → GoalIntake (ResearchIntake) → TaskEngine.submitResearch → V0.5 policy → typed steps`

| Step | Does | Notes |
|---|---|---|
| `researchSearch` | deterministic queries (`QueryBuilder`; glossary for Turkish; ≤1 optional validated model rewrite) → providers | zero-result queries still count against the budget |
| `researchRead` | fetches the best sources (official first, ≤2–4 per domain), HTTP first, rendered tier only for JavaScript shells | injection scan on every page |
| `researchExtract` | candidates + claims; **a model-produced claim is accepted only if its quoted excerpt appears verbatim in the cited page** (`Grounding`) | provider/model recorded |
| `researchVerify` | re-fetches each candidate's OWN listing: price, licence, compatibility, download route | snippets are never evidence |
| `researchReport` | ranks, then writes the report (facts · assessments · recommendation kept apart) | a verified fact without a source fails validation |

Plans are fixed per research type (`ResearchPlanner`); "browse until satisfied" does not exist. The report is a stored artifact (JSON + Markdown); the Research screen renders it.

## 3. Request types

`documentation · troubleshooting · comparison · library · community · currentInfo · assetDiscovery · general`. Constraints are typed (`ResearchConstraints`: free only, commercial use, official only, open source only, no account, recent, Unity version, render pipeline, asset kind, preferred domains). Turkish and English intake (`ResearchIntake`, `ResearchText.fold` handles dotless ı etc.). Spoken requests use the same `ConversationService.submit(source: .voice)` path.

## 4. Providers (no paid search API, no API key, DEC-093)

| Provider | Used for | Notes |
|---|---|---|
| `unity-docs-direct` | `docs.unity3d.com/6000.0/.../ScriptReference/<Identifier>.html` for CamelCase identifiers | the page is still READ; a wrong guess is a failed source, never a fabrication |
| `duckduckgo-html` | general discovery | `robots.txt` allows it; ≥2 s between requests; a challenge page stops the provider (no evasion) |
| `github-repositories` | libraries/tools; SPDX licence from the API | queries are shortened (`SearchTerms.core`) because GitHub ANDs every word |
| `stack-exchange`, `hacker-news` | community experience | Stack Overflow answers HTML requests with 403 → the **public API** is used for the question and answers (no evasion) |
| `polyhaven` | CC0 3D models/textures with md5 per file | catalogue filtered locally, round-robin per subject word |
| `kenney` | CC0 packs, direct public .zip links | category pages parsed, scored on slug/title |

Excluded on purpose: Brave Search (needs a key), the Unity Asset Store (account-bound, no public API — not automated), any scraping behind a login.

## 5. Source quality, evidence and honesty (DEC-090/091)

* `SourceClassifier`: official **for the subject** (docs.unity3d.com is official for a Unity question, not in general); mirrors/aggregators are suspicious and ranked last. `mayDecide(kind, source, …)`: only an official/first-party, non-snippet source may decide price, licence, availability, compatibility, API behaviour.
* `PriceAnalyzer`: `FREE_VERIFIED` only from a zero price in structured data / visible price on an authoritative current page, or a publisher's own "available for free" statement; paid, promotion, subscription, login-required, region-dependent, unavailable, contradictory and **UNKNOWN** are separate states; >24 h old evidence is flagged for re-verification. **UNKNOWN is never free.**
* `LicenseAnalyzer`: permissive / attribution / marketplace EULA / copyleft / no-derivatives / non-commercial / custom / contradictory / **unknown (never safe)**; automatic acquisition needs a commercially usable, modifiable licence from an official source.
* `UnityCompatibilityAssessor`: compatible / likely / unknown / incompatible against the connected project's version and render pipeline (V0.6 descriptor, read-only).
* Prompt injection: page text is fenced (`UntrustedContent.fence`, preamble, invisible-character stripping), scanned for instruction patterns, and **can never create a step, approval, tool call or download**. Pages that try are listed in the report and ignored.

## 6. Ranking (DEC-098)

Explicit factors, weights sum to 1: licence safety 0.20 · price certainty 0.15 · compatibility 0.13 · acquisition friction 0.09 · source trust 0.08 · style fit 0.08 (a labelled MODEL ASSESSMENT from the description; images are not judged) · maintenance 0.04 · **topical relevance 0.23**. Hard constraint violations (not free, licence forbids commercial use, needs an account, incompatible, **matches none of the requested subject words**) mark a candidate *not recommended* whatever its score. Added after the first live run: three candidates scored identically (free, CC0, trusted) while being a plunger, a drain cleaner and a flower for a "bucket and sink" request.

## 7. Network safety (DEC-094)

`URLPolicy` / `URLGate`: http(s) only for reading; refuses loopback, RFC1918, link-local/metadata, CGNAT, multicast, IPv6 equivalents, numeric-IP spellings (decimal, hex, octal, short), `file:`, `ftp:`, `javascript:`, credentialed URLs, `%` in the authority; IDNA/NFKC folding so full-width digits cannot smuggle `127.0.0.1`. DNS is resolved and checked before connecting, **every redirect hop is revalidated**, and the connected remote address is checked again after connecting. Ephemeral session: no cookies, no credentials, no cache. Per-host rate limit. The production policy is used in tests too (fixture hosts are *virtual public hosts*; there is no loopback exemption).

## 8. Browser tier (DEC-092)

System WebKit (`WKWebView`, `WKWebsiteDataStore.nonPersistent()`): no profile, no cookies, no passwords, no Keychain, no extensions. A content-rule list blocks private/loopback/link-local/non-http(s) sub-resources and media/fonts; navigation is re-authorised through the URL gate; one constant extraction script (nothing from the network, page or a model is concatenated into it); offscreen window; torn down after 30 s idle and at quit. It **reads only** — never types, clicks, signs in or solves a CAPTCHA. Playwright was evaluated and not adopted (a Node runtime + browser download for no capability the system WebKit lacks here). Limited to `maxRendered` navigations per research. **ResourceManager (DEC-103):** under memory pressure or serious thermal state the tier is not offered (plain HTTP is preferred; a JavaScript-only page is then reported as needing the browser) and an idle web view is released at once (`releaseUnderPressure`); a navigation in progress finishes first. WebKit's own helper processes are system-launched, not JARVIS children — there is nothing of ours to track or kill beyond the web view (the user's Safari/Chrome are never touched).

## 9. Budgets (DEC-100)

Standard: 6 queries · 8 results/query · 12 sources · 1.5 MB/page · 14 MB total · 4 rendered pages · 8 candidates · 300 s · 3 model calls · 1 retry · 3 concurrent fetches. Deep ("research this more deeply"): 12 / 28 / 14 candidates / 600 s / 5 calls / 30 MB. Exhaustion is reported ("budget ended"), never silently extended. Nothing runs while idle: no timers, no polling, no crawling; the browser and every connection are released.

## 10. Persistence and restart (DEC-099)

Schema v7: `research_sessions`, `research_queries`, `research_sources` (URLs, hashes, bounded excerpts — **no page bodies, no HTML, no binaries**), `research_claims`, `research_candidates`, `acquisitions`. Reports are artifacts. A restart marks in-flight research/downloads **interrupted**; only an explicit user "Resume" continues. Verified for real: a SIGTERM in the middle of a live research and a fresh launch on the same data directory show the task and the session INTERRUPTED, nothing resumed, no network activity, and an explicit Resume continuing (`--research-live-test`). A failed or cancelled task also ends its research row (`markEnded`) — found by the live test, which exposed rows stuck on "searching".

## 11. UI

Full HUD → **Research**: sessions list, sources with trust/official badges, claims with evidence, candidates with factor bars, report preview, acquisitions, Stop/Resume/Open source/Reveal. Settings → **Web research**: master switch, browser tier switch, quarantine size, "Delete downloaded files". The Compact HUD shows the activity line ("Searching · query 3", "Reading · 5 sources") and stays 392×448.

## 12. Real findings from live runs (all fixed, `docs/DEVELOPMENT_LOG.md`)

GitHub returned 0 results for sentence queries · Stack Overflow 403 for HTML pages (→ API route) · research rows stuck in "searching/reading" after a failed task · identical scores for off-topic candidates (→ relevance factor) · filler words ("free commercial low poly") crowded the nouns out of the structured query · a popular asset for one word crowded out the only asset for another (→ per-word round-robin) · live-test expectation: a lying zip header is caught at extraction, not at listing.

## 13. Measurements (this Mac, M5, live public web)

| Case | Result |
|---|---|
| Idle (HUDs closed) | 0.02 CPU-s in 8 s, RSS 72 MB, 0 open connections |
| Official-docs research (BoxCollider), 4 queries / ~20 sources, 1 model call | 20–24 s |
| Library research (GitHub, 6 queries / ~25 sources) | 42–60 s |
| Community research (Stack Exchange API) | ≈ 23–27 s |
| Asset research, Turkish spoken request (Poly Haven, 6 queries / 8 sources, Claude Code + local Qwen) | ≈ 43–63 s |
| Rendered page (example.com) | 1.4–1.5 s |
| Process after a 3-minute run | 0.1–0.8 % CPU, ≈ 108–113 MB RSS |

Variation is mostly the model call and DuckDuckGo pacing (≥2 s per query).

## 14. Honest limits

See `KNOWN_ISSUES.md` JARVIS-V09-1…12: no human validation; Unity Asset Store not automated; discovery depends on a keyless HTML endpoint; word-based relevance (synonyms only via glossary/model queries); style fit is text-only; JavaScript-heavy or login-walled pages are reported as such, never bypassed.

## V0.10 — research memory

Completed, validated research sessions become ONE research finding plus asset decisions (recommended / alternative / rejected **with the recorded reason**) that point at the V0.9 records; nothing from a page, a snippet or an injected instruction is ever copied. Price/licence findings are `currentSensitive` (stale after 24 h) and must be re-verified through this pipeline before they are used for an action.
