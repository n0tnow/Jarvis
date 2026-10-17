# Conversational working context (V0.15)

Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · MANUAL TEST REQUIRED.

Purpose: understand short follow-ups — “onu kullan”, “ikincisini dene”, “biraz sola al”, “tekrar dene”, “uygunsa projeye koy”, “bunu kaldır”, “use the previous asset”, “try the second one”, “move it left”. It is **not** Project Memory, **not** learning and **not** authority.

## What it is
`ConversationWorkingContext` (`Sources/Jarvis/Daily/WorkingContext.swift`): at most **16** typed referents, **30 minutes**, **30 turns**; each has a kind (project, task, asset, Unity object, application, document, completed action), a structured id (never copied prose), a sanitised ≤ 80-character label, a source (`userStated` / `validatedResult` / `systemState`), an evidence pointer and a confidence. It lives in memory only (not Codable, not persisted, never written to Project Memory or the learning layer); a restart forgets it. A project change drops what belonged to the old project.

## What enters
Only validated, user-visible things: a finished research task's ranked candidate records (V0.9), the project the user named (“Hamam’a dön”), the user's own earlier request (for “tekrar dene”), a typed Unity result's object. Labels that look like an instruction, a secret or markup are refused, so model / MCP / web text cannot become a referent or smuggle “from now on ‘it’ means …”.

## Resolution (`ReferenceResolver`, pure and conservative)
* A follow-up is a SHORT imperative whose verb opens or closes the sentence (a verb in the middle of a longer sentence is an ordinary request).
* Ordinals refer to the newest list; a pronoun refers to a unique referent, or to the one the user chose; otherwise JARVIS **asks** (“Hangisini kastediyorsunuz? 1) … 2) …”) and starts nothing. The answer is a bare number; a bare yes/no answers nothing.
* **Destructive** verbs (“sil”, “kaldır”, “delete”) never resolve from recency: only an explicit, single choice resolves, otherwise JARVIS asks (“Silinecek hedefi tahmin etmem”); the normal approval policy still applies afterwards.
* A resolved follow-up is **rewritten into an explicit sentence** (“Analyze whether the asset “Bucket B” (url) is suitable and compatible for this project: check its license, price and Unity compatibility, then recommend.”) that takes the normal route — router → task intake → V0.12. “Uygunsa projeye koy” asks only for the suitability check; importing stays a separate, approval-gated step you ask for in words of your own.
* “Devam et” / “nerede kaldık” are NOT handled here: they use Project Continuity (current truth outranks conversational context). “Hamam’a dön” sets the project later unnamed questions mean (`ProjectContinuity.focus`); it grants no permission.

## Settings
Settings → Daily JARVIS → *Conversational follow-ups* (off = follow-ups are ordinary sentences again) and *Clear current conversation context*.

## Tests
`FollowUpParsingTests`, `ReferenceResolutionTests`, `DestructiveReferenceTests`, `WorkingContextBoundsTests`, `DailyFollowUpTests`, `DailyProjectFocusTests`, structural tests; live: `--daily-jarvis-live-test` (resolution p50 ≈ 0.01 ms).

## V1.0 stabilisation fix 2 — the context also remembers the last turn
`ConversationWorkingContext.lastTurn` / `correction` keep (bounded, memory only, cleared with the context) the previous user utterance, how JARVIS interpreted it, its answer and a correction marker, so “Hayır, demek istediğim …” can be re-resolved instead of repeating the old route. A short fragment after a settings change (“yavaşlat”) takes that setting as its subject. Nothing here is persisted or authoritative; Project Memory is never used for preferences.
