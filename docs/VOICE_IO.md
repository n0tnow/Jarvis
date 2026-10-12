# Voice I/O (V0.7)

Status: IMPLEMENTED · AUTOMATED TESTED · **REAL TESTED with SYNTHETIC speech** (`--voice-live-test`) · **HUMAN SPEECH · TTS QUALITY · VOICEOVER: MANUAL TEST REQUIRED** (README 154–223). Decisions: DEC-057…068 (`DECISIONS.md`). Issues: JARVIS-V07-1…9 (`KNOWN_ISSUES.md`).

## 1. What it is (and is not)

Voice is an **input/output layer** around the existing conversation pipeline — not a second assistant:

```
hold right ⌥ → microphone (explicit, bounded) → streaming STT → partial transcripts (provisional) → FINAL transcript
   → ConversationService.submit(source: .voice)   ← the SAME call a typed message makes
   → IntelligenceRouter → deterministic command │ local │ provider │ TaskEngine (GoalIntake)
   → the answer the UI shows → VoiceResponseSpeaker → SpeechChunker → SpeechRenderer → TTS → speaker
```

A spoken request has exactly the authority of the typed one. V0.7 deliberately does **not** have a wake word, always-on listening, VAD endpointing, hands-free turns, barge-in, speaker identification, voice cloning, spoken approvals or cloud speech (V0.8 owns the first five; the rest are out of scope or forbidden).

## 2. Privacy model

* The microphone is **OFF** unless voice is enabled (Settings → Voice, off by default) **and** the user is physically holding the Push-to-Talk key. The audio engine is created on press and destroyed on release; nothing exists while idle. It never starts at launch, from a timer, from the UI or in automated runs (`verify.sh`, unit tests, smoke test: guarded structurally and behaviourally).
* Raw audio lives only in memory for one utterance (hold limit 60 s, bounded frame queue, 75 s helper buffer). It is never written to disk, SQLite, artifacts, logs or the repo; there is no audio/waveform/transcript-history column or table (`verify.sh` + live test scan of the data directory).
* Only the **final** transcript becomes a message, under the existing conversation persistence policy (in-memory; the audit trail stores hashes/redacted excerpts as before). Partial transcripts are never stored. Voice diagnostics are content-free (lengths, language, provider, latency).
* `NSMicrophoneUsageDescription` is the **only** privacy string; no entitlement. Speech recognition runs on this Mac (Apple on-device model or the local helper); there is no network client, API key or cloud endpoint in the voice path (`verify.sh`; live test: no socket in JARVIS or the helper).
* All recogniser/helper text passes `TranscriptText.clean` → `OutputSanitizer` (fake keys/passwords/tokens masked) before any UI, log or database sees it.

## 3. Microphone permission

Truthful states `NOT ASKED YET · ALLOWED · DENIED · RESTRICTED` (read from macOS, never faked). The system dialog appears on the first Push-to-Talk (never at launch, never in tests; a press that is released while the dialog is open starts nothing). Denied/restricted → a clear explanation (typing keeps working), no repeated prompts, System Settings only opens from an explicit button. Device loss/route change mid-capture ends the session with a message (no stuck LISTENING).

## 4. Push-to-Talk

**Hold the RIGHT Option (⌥) key by itself.** Chosen because it needs no permission (same permission-free modifier sampling as the ⌥⌘ / ⌥⌘⌘ HUD chords — one `GlobalHotkeyService`, no event tap/global monitor/Carbon hotkey, DEC-008/013), it types no character, it is not part of the ⌥⌘ chords, and holding it is a natural "talk" gesture. The side is read from the session flag state (`NSEvent.modifierFlags` hides the device bits — measured on macOS 26.4). Rules (pure `PushToTalkMachine`, unit tested with scripted timelines):

| Situation | Result |
|---|---|
| right ⌥ alone, held ≥ 0.25 s | `press` → capture starts |
| shorter tap | nothing |
| another key/click while arming (typing AltGr characters on a Turkish layout) | attempt cancelled — never opens the microphone |
| left ⌥, both ⌥, or ⌘/⇧/⌃ with it | not Push-to-Talk (⌥⌘ chords unaffected) |
| key repeat / repeated identical samples | exactly one `press` |
| extra modifier joins while talking | `release(interrupted)` → audio discarded |
| release | `release` → microphone stops IMMEDIATELY |
| service stopped / handler removed / voice turned off while held | released, microphone closed |

Release is the authoritative end of the utterance. Recordings shorter than 0.35 s are discarded; a press while the previous transcript is still being finalised (≈0.1–0.4 s) is ignored (no queue, no double submission). A press while JARVIS speaks first **stops the speech**, then listens (explicit stop — not barge-in; JARVIS never listens while speaking, there is no echo cancellation). Verified with **real OS-level key events** (`CGEvent` flagsChanged for key code 61, posted to the HID tap) in the live test with Full HUD open, Compact open and no HUD open (key repeat included) — the keyboard-feel remains MANUAL TEST REQUIRED.

## 5. Voice session state (`VoiceCoordinator`)

`IDLE → (REQUESTING PERMISSION) → LISTENING → TRANSCRIBING → THINKING → SPEAKING → IDLE`, plus `ERROR` (clears itself after 6 s). `LISTENING` is shown only while capture really runs (a failed start never shows it); `SPEAKING` only once audio started (`started` event of the first phrase); `JarvisState.listening` is claimed only if JARVIS was idle/completed and released at once (never clobbers working/waiting). Sessions are ephemeral: every launch starts IDLE (tested). One session owns the microphone; every async continuation is guarded by a per-session token so a late callback of an old session can never leak into a new one.

## 6. Providers

### 6.1 Speech-to-text

| Candidate | Evidence | Verdict |
|---|---|---|
| Apple `SpeechAnalyzer` + `DictationTranscriber` (macOS 26, on-device) | **measured**: tr-TR and en-US work; native streaming partials; ≈60 ms finalisation; no setup beyond Apple's model; needs no extra permission (verified from a CLI and the app) | **Fallback / zero-setup provider** (`apple-speech`) |
| Apple `SpeechAnalyzer` + `SpeechTranscriber` | **measured**: 30 locales, **no Turkish**; English needed a 15.7 s asset install; first partial only at the end of the audio | rejected for Turkish; not used |
| `SFSpeechRecognizer` (on-device) | researched/probed (tr_TR, en_US report on-device support) but needs a second privacy permission (speech recognition) | not used |
| **Whisper small (MLX)** via `mlx-whisper`, helper process | **measured**: best accuracy on technical/Turkish words, real language detection, confidence, 0.2 s per utterance (RTF ≈ 0.04), ≈0.86 GB resident, 1.6 s cold start | **Default when installed** (`whisper-local`) |
| Whisper large-v3-turbo (MLX) | **measured separately** (scratch benchmark, same fixtures): better on code-switched speech, 0.76 s/utterance, ≈1.8 GB resident, 1.6 GB download | optional (point "Whisper model folder" at it); not default (memory) |
| WhisperKit (Core ML) | researched | rejected: a SwiftPM dependency (the project has zero) |
| whisper.cpp | researched | not chosen: needs a native build/brew install; no advantage over MLX here |
| Moonshine / Parakeet / other streaming models | researched | no credible Turkish support |
| Any paid/cloud STT | — | **never** (cost policy; documented as an optional future provider only) |

Both shipped providers are local/system, **offline, key-less and free** (`VoiceCostClass`: `LOCAL` / `SYSTEM`). Apple's analyzer requires macOS 26; on macOS 14/15 only the optional Whisper helper provides speech input.

### 6.2 STT benchmark (synthetic speech — flatters real-world accuracy)

Fixtures are rendered in memory with the macOS voices (Yelda tr-TR, Samantha en-US; the mixed ones are stitched from both) and fed at **real-time pace in 100 ms frames**; the same 8 sentences, same host (M5, 16 GB), release build, 3 runs each, identical text across 3 complete live runs. WER normalisation keeps Turkish letters; Turkish suffix tokenisation (`task'ın` vs `taskın`) inflates WER, so **CER is the fairer figure**.

| Fixture (reference) | Apple Speech heard (WER / CER) | Whisper-small heard (WER / CER) |
|---|---|---|
| tr_short "Jarvis, Unity'deki son task'ın durumunu göster." | "Jarvis Youte'deki son task'ın durumunu göster" (.12/.11) | "Jarvis, Unity'deki son taskın durumunu göster." (.25/.00) |
| tr_long "…Play Mode testlerini çalıştır ve yeni Console hatası varsa bana söyle." | "…Play more testlerini … yeni Jon Soli hatası var bana söyle" (.33/.08) | "…Play Mode testlerini … yeni ConeSole hatası varsa bana söyle." (.08/.02) |
| tr_cmd "Jarvis, görevler ekranını aç." | exact (0/0) | exact (0/0) |
| en_short "Jarvis, run the EditMode tests." | "…run the added mode tests" (.40/.16) | exact (0/0) |
| en_long "Show me the latest task report." | exact (0/0) | exact (0/0) |
| en_cmd "Jarvis, open the Tasks screen." | "…open the task screen" (.20/.04) | "…Open the task screen." (.20/.04) |
| mixed "Jarvis, BoxCollider değişikliğini kontrol et and run the relevant test." | "Jarvis Bucks color değişikliğini kontrol et Wonder royal test" (.60/.35) | "Jarvis, BoxCollider, DeishiCleanicontrolit, and run the relevant test." (.30/.15) |
| mixed_cmd "Jarvis, Unity Play Mode testlerini kontrol et." | "Jarvis United Play testlerini kontrol et" (.29/.16) | "Jarvis, Unity, Play Mode, Test, PlayRenek, Control it." (.57/.18) |
| **mean WER / CER** | **0.24 / 0.11** | **0.18 / 0.05** |
| language | explicit (no detection) | **auto-detected correctly** (tr, tr, tr, en, en, en, en, en) |
| first partial after speech starts | ≈1.05 s (21 native partials on the 4 s clip) | ≈1.2–1.3 s (2–5 re-decode previews) |
| finalisation after release (p50 / min / max, 24 runs, small sample) | **57 ms** / 23 / 112 | **198–228 ms** / 179 / 566 |
| startup | 1 ms | 1.6–1.9 s COLD (helper start + model load), ≈0.1 s warm |
| confidence | none (never invented) | derived mean token probability (not thresholded) |

Mixed Turkish/English technical speech is the weakest case for both (see JARVIS-V07-2): Whisper commits to one language per utterance (Auto heard the mixed sentences as English; the earlier scratch test showed forced-Turkish small is worse on that fixture and turbo better); Apple's Turkish model mishears the English words. The live test requires only that **at least one** recogniser keeps the key words (it does — Apple, with explicit Turkish) and records every transcript. Quality for a real human voice is **MANUAL TEST REQUIRED**.

Domain hint: Whisper receives a bounded product-vocabulary prompt ("Jarvis, Unity, Play Mode, EditMode, PlayMode, Console, BoxCollider, GameObject, prefab, task, compile, test."); on the synthetic set it turned "edit mode" into "EditMode" and "Play Mode" correctly. It contains no user data.

### 6.3 Selected STT (DEC-061)

`Auto` = **Whisper when installed and memory pressure is normal; otherwise Apple Speech** (reason shown in Settings and recorded). Why: measured accuracy on technical/Turkish terms, **real** language detection restricted to Turkish/English, confidence, 0.2 s decode; cost: a one-time ≈460 MB download (explicit script), ≈0.86 GB RAM while loaded (unloads itself), 0.15 s more latency than Apple. Apple stays as the instant, zero-setup, native-streaming provider and as the fallback. An explicit choice never falls back. **Cost class: Whisper LOCAL, Apple SYSTEM; no API key; no network.**

Partial/final semantics (`SpeechTranscriptEvent{text,isFinal,language,confidence?,timestamp}`): partials are revisable and shown only in the composer/voice strip; **only the final event enters the pipeline**. Apple partials are native streaming; Whisper "partials" are **preview re-decodes** of the audio so far (first after 1 s of speech, then about every 1.2 s, never two at once) — stated as such in the UI and docs, not marketed as streaming.

Language: Turkish and English are first-class. Settings → Auto/Turkish/English: Whisper detects (Turkish vs English only); Apple cannot, so Auto → system language and the UI says so. Turkish text is never ASCII-folded; the existing `InputNormalizer` runs after the transcript exactly as for typed text (and the router accepts the Turkish possessive screen words "ekranını/sayfasını/bölümünü" so "görevler ekranını aç" is a command).

### 6.4 Text-to-speech

| Candidate | Evidence | Verdict |
|---|---|---|
| **`AVSpeechSynthesizer`** (Yelda tr-TR, Samantha en-US, Daniel/Karen/Moira/Rishi/Tessa en-*) | **measured**: first buffer 140–170 ms, RTF ≈ 0.04, on-device, free, no network; playback start 21 ms after `speak` | **Default** (`apple-synthesizer`, cost SYSTEM) |
| Piper (ONNX, `tr_TR-dfki-medium`, `en_US-lessac-medium`) | **measured** (scratch): load 0.55 s, first chunk 0.04–0.27 s, RTF 0.02–0.07, 210–290 MB, 63 MB per voice | optional future provider: `piper-tts` 1.x is GPL-3 and voice licences vary; quality is a human judgement |
| Kokoro / MLX-Audio, XTTS-v2 | researched | no Turkish (Kokoro) / non-commercial licence + 1.8 GB (XTTS) |
| Any paid/cloud TTS | — | **never** by default |

Only compact/standard voices are installed on the dev Mac (premium ones can be added in System Settings). **Naturalness, pronunciation of "BoxCollider"/"Play Mode", speed, fatigue: MANUAL TEST REQUIRED** — no number substitutes for listening.

Truthful streaming: `AVSpeechSynthesizer` has no native streaming; JARVIS synthesises **complete sentences/phrases one after another** ("incremental sentence synthesis"). Speech starts at the first stable sentence while the rest of the answer is still arriving (live test: audio started while the message was still `streaming`).

## 7. Spoken answer = shown answer

`VoiceResponseSpeaker` follows the very messages the conversation shows after the voice-submitted user message (no second model call, no "text to say"):

* **`SpeechChunker`** (pure, deterministic): releases only stable sentences (terminator + whitespace; a terminator at the end of the buffer waits); handles decimals/versions/file names/abbreviations (EN + TR: e.g., "e.g.", "Dr.", "vb.", "örn."), ellipsis and `?!` runs, inline code, merges tiny fragments (except the first phrase, which may be short so speech starts early), splits over-long sentences at a clause then a space (≤ 320 characters), headings/list items as their own phrases, never speaks fenced code or tables (one note). **Property-tested: chunking is identical however the stream is cut** (character-by-character and 100 random cuts).
* **`SpeechRenderer`** (pure): markdown, links (→ text), bare URLs (→ host), long paths (→ file name), long inline code (→ "code"/"kod"), emoji/control characters, `%`/`→`/`&`/`e.g.` per language; Turkish letters never folded; no content is added.
* **`LongAnswerPolicy`**: at most ≈520 characters / 7 phrases spoken, then one note ("The full answer is on screen." / "Yanıtın tamamı ekranda."); the first phrase is always allowed. No second LLM call, ever.
* Typed turns are **not** spoken (voice turns only); task completion/proposals/approvals are never announced spontaneously. A task started by voice gets its normal acknowledgement ("On it. I created the task …") and runs on its own — the voice turn never waits for it.

## 8. Stop, cancel, ownership

`stopSpeaking()` (Stop buttons in Compact/Full, the menu-bar "Stop Speaking", spoken/typed "stop talking", a new typed message, a new Push-to-Talk) drops queued and in-flight phrases and silences playback at once — live test: **stop latency 0–3 ms**, nothing stale plays afterwards (chunk ids are unique across turns and checked against the in-flight set). Cancellation exists at every layer: cancel listening, cancel STT finalisation, device loss, provider failure (text stays), quit. The speech helper is a `ManagedProcess` (one audited launch point): on-demand start, 120 s idle unload, unload on memory-pressure rise (0.03 s, never during an utterance), killed with the tree on quit/SIGTERM (**live-tested with a child JARVIS: helper gone**), exits on stdin EOF. Apple's recogniser/synthesiser are system services (nothing of ours to kill).

## 9. Latency (measured, synthetic speech, release build, real STT/TTS; silent runs at volume 0 and one AUDIBLE final run)

End to end for the deterministic command "open the Tasks screen" through the real coordinator and the real typed pipeline:

| Interval | Apple Speech | Whisper-small |
|---|---|---|
| key release → final transcript | 23–88 ms | 235–251 ms |
| transcript → router → first reply text | (same call as typed; < 1 ms measured as part of the next step) | same |
| first stable text → handed to TTS | ≈55 ms | ≈55 ms |
| handed to TTS → audio started | 46–73 ms | 43–61 ms |
| **key release → first audible JARVIS audio** | **≈240–310 ms** | **≈400–430 ms** |
| speech start → first partial | ≈1.06 s | ≈1.22 s (preview) |

TTS alone: `speak()` → audio started 21 ms; rendering first buffer 140–170 ms. A provider-routed answer adds the provider's own latency before the first text; the speech starts at the first stable sentence of that stream.

## 10. Resources (measured separately; helpers are NOT attributed to JARVIS)

| State | JARVIS process | Helper / services |
|---|---|---|
| closed, voice enabled, idle | RSS 108–147 MB, **0.00 CPU-s over 6 s** (0.01 % of a core) | none |
| Whisper loaded, idle | — | helper RSS **855 MB**, 0.000 CPU-s over 5 s, load 1.6–1.9 s |
| one active 5 s utterance | +0.00 CPU-s | helper +0.01 CPU-s, decode 0.22–0.23 s (RTF 0.04), RSS 700–860 MB |
| real TTS playback (4 s) | **+0.004 CPU-s (0.1 % of a core)** | `SpeechSynthesisServerXPC` ≈1 MB, `sirittsd` ≈6 MB |
| Apple recogniser in use | — | `localspeechrecognition` ≈5–68 MB (system service) |
| after STT+TTS use, HUD closed | RSS 113–162 MB | — |
| Whisper + local Qwen resident + one voice cycle | JARVIS 111–125 MB | Whisper 694–856 MB + Qwen worker 333–526 MB RSS (Metal peak 3.4 GB) ≈ 1.3–1.4 GB resident sum |
| memory-pressure WARNING | — | helper unloaded in 0.03 s |

**Representative combined state (measured simultaneously, `--voice-live-test --voice-combined` next to `--unity-live-test`):** a real headless Unity editor (12 processes, 983 MB resident early in its life; ≈2.1 GB once fully loaded per the V0.6 run) + local Qwen worker loaded (RSS 369–526 MB, but **3.4 GB peak unified memory** while generating) + the Whisper helper (470 MB, later 856 MB) + JARVIS (39–130 MB) while one full voice cycle ran: **memory pressure stayed NORMAL**, swap used rose from 2.16 GB to 2.69 GB on a machine that already had 2.1 GB of swap in use (free memory 65 % → 38 %). macOS compresses idle processes under load, so RSS of idle helpers shrinks (JARVIS 39 MB, helper 150–470 MB) — RSS is a floor, not the footprint. A memory-pressure WARNING unloads the speech helper in 0.03 s; Auto then falls back to Apple Speech. Total resident sum in the tests: ≈1.4 GB (Qwen+Whisper+JARVIS) to ≈1.9 GB with Unity early; ≈5.5 GB if Unity is fully loaded and Qwen is generating (sum of separately measured components, not a single sample).

Policy (DEC-067): no polling anywhere in the voice layer (event-driven; `verify.sh` forbids timers/display links/dispatch sources there); the HUD chord service already runs at 12 Hz at rest (60 Hz only while an Option key is down) and is shared. Verify idle: 0.02 CPU-s in 8 s, RSS 48 MB with voice present but disabled.

## 11. Settings and UI

Settings → **Voice**: enable (off by default), Push-to-Talk on/off with the shortcut explained, microphone status, recognition language, recogniser (Auto / Whisper / Apple) with availability, cost class and the reason Auto chose what it chose, Install buttons (Apple model: asks the system; Whisper: documented script), speak-responses toggle, Turkish/English voice pickers (installed voices only), rate, Test/Stop, developer diagnostics. Compact (392×448 unchanged): a state chip beside the state chip + a stop button, and the partial transcript in the command field's placeholder; Full: a voice strip above the Conversation panel (state, level bar, provisional transcript, STOP SPEAKING), System panel "Voice" row, a small mic mark on voice-origin messages; menu bar: the listening glyph and a "Stop Speaking" item while speaking. Accessibility: states are words + icons (never colour alone), partials are hidden from VoiceOver, the level bar is static (Reduce Motion safe).

## 12. Tests

* **Unit (≈160 voice tests):** chunker (incl. delta-cut invariance), renderer, language guess, long-answer policy, PTT machine + hotkey service, coordinator lifecycle (nothing at launch, press/release/permission/denied/start failure/device loss/cancel/shutdown/limit), submission path (voice ≡ typed, partial never a message, empty/short/failed transcripts, pre-buffered audio, rapid cycles), speaking (streaming start, markdown/code, long answer, Turkish voice, stop, PTT-during-speech, typed-during-speech, TTS failure, stale events), provider selection/cost, authority (no approval/task/file/network path, approvals HUD-only, task channel), Whisper runtime against a **fake helper with real processes** (round trip, preview limits, idle unload, crash, hang, cancel, quit kill, sanitizer), WER/CER, fixtures, preferences, structural guards (`verify.sh` mirrors them).
* **REAL (`--voice-live-test`, 37–38 checks; the final run was AUDIBLE — the Mac spoke aloud — and used the real microphone for 1.5 s):** providers/availability, synthetic fixtures, STT benchmark (both recognisers), partial/final semantics, Whisper language detection, TTS rendering + real playback timing + stop, incremental synthesis while text streams, **end to end Turkish and English through both recognisers**, typed-twin equality, mixed language, voice → V0.4 task (scripted planner on an isolated fixture), rapid PTT, PTT during speech, **real OS-level Right-Option key events** in three HUD states, optional real microphone open/close (`--voice-real-mic`), resources, no sockets, no audio on disk, sanitization, restart reconciliation, **SIGTERM of a child JARVIS leaves no helper**.
* Labels: **SYNTHETIC AUDIO TESTED** (everything above that uses speech), **HUMAN SPEECH MANUAL TEST REQUIRED**, real-microphone *plumbing* REAL TESTED (frames flow, engine stops), voice quality/VoiceOver/physical key feel MANUAL.

## 13. Model provenance and removal

| | |
|---|---|
| Model | `mlx-community/whisper-small-mlx` (OpenAI Whisper "small" converted to MLX) |
| Revision | `45f3915923c7a79a5a5b5a7d909d39aeb0e5630e` (pinned in `scripts/setup_voice_ai.sh`) |
| Licence | upstream OpenAI Whisper: MIT (the conversion repo carries no separate licence) |
| Size | ≈459 MB (`weights.npz` 481 MB) |
| Location | `~/AI/models/whisper-small-mlx` (outside the repo, same convention as the Qwen model; override `JARVIS_WHISPER_DIR`) |
| Runtime | `~/Library/Application Support/JARVIS/runtime/voice-venv` (≈480 MB; pinned requirements in `scripts/voice-ai/requirements.txt`; `mlx-whisper` 0.4.3 installed `--no-deps` so PyTorch is not pulled in) + `jarvis_stt_worker.py` |
| Installed by | only `scripts/setup_voice_ai.sh` (explicit); JARVIS never downloads anything. Apple's dictation model install is a system action (Settings → Install asks the system). |
| Remove | `rm -rf "$HOME/Library/Application Support/JARVIS/runtime/voice-venv" "$HOME/Library/Application Support/JARVIS/runtime/jarvis_stt_worker.py" "$HOME/AI/models/whisper-small-mlx"` |

Model weights are never committed (`verify.sh`: no `npz/safetensors/onnx/gguf/audio` file tracked). Side effect of the research phase on the dev Mac: the system's en-US `SpeechTranscriber` assets were installed once through Apple's asset service (≈16 s).

## 14. Known limitations (see KNOWN_ISSUES V07-1…9)

Mixed-language speech; Whisper previews are re-decodes; Apple provider needs macOS 26; compact voices only; the shortcut is fixed to right ⌥ (on/off only); a press during finalisation is ignored; VoiceOver and spoken replies can overlap; no spontaneous speech; no echo cancellation; Apple speech services cannot be attributed or inspected.

## 15. V0.7 vs V0.8 (preparation, not implementation)

Extension points that exist: `AudioInput` (any capture source), `VoiceCoordinator.pushToTalkPressed/Released` (any trigger), `VoiceResponseSpeaker.stop` (barge-in hook), `STTSession` / `TextToSpeechProvider` (streaming providers), `VoiceSettings`. **Not implemented:** wake word, VAD/auto-endpointing, hands-free turn-taking, barge-in, full-duplex/echo handling, spoken confirmations. They need their own decisions (privacy: continuous capture; approvals: a confirmation protocol) — V0.8 may begin only with the user's approval.

## 16. V0.8 (natural voice & presence)
V0.8 builds on everything above and changes three things: wake mode (opt-in) adds a continuous, local, bounded listening path before Push-to-Talk is needed; speech is now played by JARVIS' own output engine (the Apple synthesiser renders with `write`, the neural voice returns PCM) so barge-in can tell the user from JARVIS; and the preferred voice is a local neural voice with the Apple voices as fallback. §1 "does not have a wake word …" and §15 are superseded for those items; everything else (privacy of raw audio, PTT rules, providers, sanitization, authority, stop semantics) is unchanged. See `NATURAL_VOICE.md`.

## V0.9 — spoken research

A spoken research request ("Hamam oyunum için ücretsiz bir kova modeli araştır") is a normal final transcript: `ConversationService.submit(source: .voice)` → `ResearchIntake` → `TaskEngine.submitResearch`. JARVIS answers with the usual short opening line; the cited report stays on the Research screen (`SpeechRenderer` never reads a long report aloud, task completion is not announced — DEC-083). A spoken "yes"/"approve" can never approve a download or import (voice has no authority).
