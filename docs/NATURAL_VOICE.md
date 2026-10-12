# Natural Voice & Presence (V0.8)

Status: IMPLEMENTED · AUTOMATED TESTED · **REAL TESTED with SYNTHETIC speech in a closed acoustic loop** (`--natural-voice-live-test`; the speaker→microphone coupling was measured on this Mac's real hardware) · **HUMAN SPEECH · WAKE/RECOGNITION IN A REAL ROOM · VOICE NATURALNESS · VOICEOVER · PHYSICAL FEEL: MANUAL TEST REQUIRED** (README 224–343). Decisions: DEC-069…087 (`DECISIONS.md`). Issues: JARVIS-V08-1…14 (`KNOWN_ISSUES.md`). Builds on `VOICE_IO.md` (V0.7), which stays valid for everything it describes (Push-to-Talk, STT providers, speech rendering).

## 1. What it is (and is not)

V0.8 makes the V0.7 voice layer feel like one assistant: say "Jarvis" (opt-in), speak, JARVIS notices when you are done, answers in a calm local neural voice, and you can talk over it. It is **still only an input/output layer**:

```
microphone ONE hub (engine exists only while someone subscribes)
   ├─ wake subscription (only if the user turned wake mode ON)        ─► energy gate ─► SENTINEL helper (local wake word + VAD, no STT, no network)
   └─ utterance / Push-to-Talk subscription                            ─► STTSession (Whisper / Apple, V0.7)
SENTINEL events ─► TurnMachine (pure) ─► HandsFreeCoordinator (effects) ─► VoiceCoordinator (V0.7 session) ─► FINAL transcript
   ─► ConversationService.submit(source: .voice)      ← the SAME call a typed message makes
   ─► router / commands / providers / TaskEngine unchanged ─► the shown answer
   ─► VoiceResponseSpeaker ─► SpeechChunker ─► SpeechRenderer ─► JARVIS voice (local neural | Apple) ─► SpeechPlayer (OWN output engine) ─► speaker
   while speaking: BargeInDetector(mic level vs. the level JARVIS itself is playing, VAD, duty cycle) ─► stop speech ─► new utterance
```

It is **not**: a second assistant, a second ConversationService/TaskEngine/approval system/router, speaker identification, voice cloning, spoken approvals, cloud speech, spontaneous speech (task completion is never announced aloud), or V0.9 (web research / asset acquisition).

## 2. Privacy model (the one real change from V0.7)

| | V0.7 | V0.8 |
|---|---|---|
| Microphone open | only while right ⌥ is held | same, **plus** continuously while wake mode is ON (opt-in, OFF by default, never at launch unless the user left it on) |
| Before the wake word | — | only the **local sentinel** hears bounded in-memory audio: no speech recognition, no transcript, no LLM, no network, no task, no log of audio, no file |
| After the wake word | — | an utterance session (full STT) exists only between "the user started speaking" and "the turn ended"; then back to wake-only listening |
| Persistence of audio | never | never (wake ring ≤ 3 s, utterance ≤ 60 s, helper buffers, synthesised speech: memory only; `verify.sh`, unit guards and the live test scan for audio files) |
| Privacy strings | `NSMicrophoneUsageDescription` only | unchanged (no new permission, no entitlement) |
| Visible state | mic glyph while held | WAKE chip (ear icon, "Wake mode on") is distinct from LISTENING (a conversation turn); VoiceOver announces states, never VAD transitions or partials |

* **Quiet rooms cost nothing:** an `EnergyGate` sends the sentinel NOTHING while the room is quiet (floor = 15th percentile of the last 40 s, +10 dB, never below −58 dBFS); when the level rises it sends 1.5 s of pre-roll from the ring, then the live stream until 1.5 s of quiet. Measured: **0.0 s of 8 s sent, 0.00 CPU-s** in the quiet-room test.
* A lone "Jarvis" **never opens the recogniser**: the machine waits `continuationSeconds` (0.45 s) to see whether speech continues in the same breath; if the VAD closes first, JARVIS only acknowledges.
* Wake mode off ⇒ the helper is stopped and the engine is gone (`hub.isCapturing == false`, checked). Quit ⇒ everything is killed synchronously.
* Wake is an **activation, not an authentication**: anyone near the microphone can wake JARVIS, and voice has exactly the authority of typing — approvals stay HUD buttons (DEC-065/072).

## 3. Wake word

### 3.1 Research (current as of 2026-10; what was measured vs only read)

| Candidate | Source / revision | Licence | Maintenance | macOS / Apple silicon | Custom "Jarvis" | Verdict |
|---|---|---|---|---|---|---|
| openWakeWord pretrained `hey_jarvis_v0.1` | github.com/dscripka/openWakeWord release v0.5.1 | code Apache-2.0; **weights CC BY-NC-SA 4.0** (training data) | last release v0.6.0, 2024-02 | ONNX Runtime arm64 ✓ (measured) | "hey jarvis" only | **MEASURED**: "Hey Jarvis" 90 %, but the bare word 19 % (quiet 14 %), "Hey Travis" 0.95 → rejected (phrase, licence) |
| **Custom head on openWakeWord's frozen features (selected)** | mel + speech-embedding ONNX from the same release (Apache-2.0, Google speech_embedding); head trained here | feature models Apache-2.0; head = own work from synthetic speech | feature models frozen | ONNX Runtime arm64 ✓ | the bare word, Turkish/English readers | **MEASURED** (below) |
| microWakeWord (OHF-Voice) | researched | licence not confirmed from the pages read (unknown ⇒ not auto-included) | active | TFLite-Micro oriented (ESP32) | trainable | not benchmarked |
| Picovoice Porcupine | public docs | requires an **AccessKey (API key)** | active | ✓ | console-trained | excluded by policy (no API key) |
| Snowboy / Mycroft Precise | public repos | — | discontinued / inactive | — | — | excluded |
| Wake via continuous STT (Whisper/Apple) | — | — | — | — | — | excluded: that is exactly the continuous full STT the privacy model forbids |

Nothing proprietary was installed. The head is trained on **synthetic** speech from Supertonic 3 (OpenRAIL-M weights: allowed use; no non-commercial data) — ten built-in voice styles × 11 pronunciation languages × speeds × a random "vocal-tract" resampling (±22 %), noise (pink/white/hum/clicks), reverb, level; 1,703 word clips, 1,033 look-alike clips, ≈ 2,300 sentences of English (macOS manual pages — public documentation — and the project docs) and Turkish (generated). Three rounds of hard-negative mining on speech the head had never seen (519 → 194 → 114 false windows per 34.6 k fresh windows). The test voices are a **different engine** (Apple system voices: Samantha, Daniel, Karen, Moira, Rishi, Tessa, Yelda) so the benchmark measures generalisation to an unseen synthesiser, not memorisation. **SYNTHETIC WAKE TESTED; human wake performance is MANUAL TEST REQUIRED.**

### 3.2 Benchmark (`scripts/voice-ai/bench/`, reproducible: `fixtures.py` → `make_long_negatives.py` → `bench_wake.py` → `tune_wake_rules.py`)

Held-out fixtures: 133 wake clips (7 Apple voices × 3 rates × {normal, quiet −17 dB, noisy 12 dB SNR} × {"Jarvis", "Hey Jarvis"}, Turkish "Carvis", wake+command), 90 look-alike words (Service, Harvest, Marvin, Jervis, Travis, Çarşı …), **2.9 hours of ordinary English/Turkish speech** (Apple voices, continuous), noise events.

| Rule set (all on the same traces) | positives (bare, Turkish reader, "Carvis", wake+command) | false events in 2.9 h of ordinary speech | look-alike words that fire | latency after the end of the word (p50) |
|---|---|---|---|---|
| pretrained hey_jarvis @ 0.5 (bare word) | 19 % | 4.4 / h (look-alikes only) | 1 | +103 ms |
| head v3, detector only, thr 0.8 | 100 % | 10 / h EN, 15 / h TR | — | −150 ms |
| + utterance-initial rule (thr 0.8, patience 2) | 70/70 | 6 EN + 3 TR in 2.9 h (3.1 / h) | 41/90 | −56 ms |
| **shipped: thr 0.9, patience 3 (240 ms), utterance-initial ≤ 1.6 s** | **70/70** | **0 in 2.9 h** (95 % upper bound ≈ 1 / h) | 26/90 | **+31 ms** |

Honest limits: the false-activation figure is for *continuous synthetic speech* (worse than daily life, where speech is a fraction of the time) and ~3 hours is a small sample; acoustic look-alikes ("Jervis", "Jarvik", "Cervix") do fire (a documented limit, JARVIS-V08-1); real voices differ from synthetic ones in both directions.

* **Utterance-initial rule** (`WakeContextGate`): the word must start a speech segment (the VAD segment containing the detection began ≤ 1.6 s ago). It removes essentially all false wakes from running conversation and costs "… so, Jarvis, do X" said in the middle of a long sentence.
* **Self-wake:** the detector keeps streaming while JARVIS speaks (continuous history), but a wake event is ignored unless the turn manager is in WAKE, nothing of JARVIS is audible (`speaker.isSpeaking/isActive`), and 0.7 s have passed since its speech ended; the ring is cleared when speech ends. Live test: JARVIS saying "Merhaba, ben Jarvis" over its own echo → 0 wake events; the user's own "Jarvis" right afterwards wakes it.
* Cost: ONNX Runtime single thread; **0.1 % of a core** with continuous speech in the room and **124 MB** resident (live test); streaming a full stream without gate ≈ 2.4 % of a core (Python/numpy overhead included, measured with other jobs running).

### 3.3 Installation and provenance

`scripts/setup_voice_ai.sh --natural` (explicit; JARVIS never downloads): `natural-venv` (onnxruntime 1.31.0, numpy 2.5.4, scipy 1.18.1, supertonic 1.3.1, soundfile, huggingface-hub; ≈ 190 MB), the three feature/VAD models from the openWakeWord **v0.5.1 release** with pinned SHA-256 (`melspectrogram.onnx` ba2b0e0f…, `embedding_model.onnx` 70d16429…, `silero_vad.onnx` a35ebf52…; ≈ 4 MB), and the Supertonic 3 voice (§6). `scripts/train_wake_head.sh` trains and installs `jarvis_head.npz` (≈ 0.6 MB) locally from synthetic speech (20–60 min). Nothing is committed (`verify.sh`: no `onnx/npz/safetensors/wav/…` tracked).

## 4. Voice activity detection

| Candidate | Result on the fixtures (silence, 12 dB noise, short words, pauses, commands) |
|---|---|
| **Silero VAD** (MIT, 1.8 MB ONNX, 30 ms frames, in the sentinel) | **selected.** start error median 50 ms (max 150), end error median −9 ms; no false speech in a noisy room; correct in 12 dB SNR; 0.4 % of a core (numpy, single thread) |
| Adaptive-energy VAD (reference in `bench_vad.py`, mirrored by `EnergyGate` for gating only) | speech start exact in quiet, but **never ends** in 12 dB noise and fires on a −40 dBFS fan → rejected as the VAD, kept only as the cheap gate |
| WebRTC-style / system VAD | researched; no native macOS VAD API; Silero already ships with the wake models, so no extra runtime was added |

VAD answers only "is someone speaking?" — it has no language understanding and no authority.

## 5. Natural endpointing

`EndpointPolicy` (pure; thresholds measured on the pause fixtures: Silero, silence needed to cut): 0.4 s cuts every pause; 0.6 s cuts the 0.55 s hesitation in Turkish; 0.8 s survives 0.55 s but cuts 0.9 s; **1.0 s survives a 0.9 s hesitation**; a deliberate 2.5 s pause is a new turn at any threshold ≤ 2.0 s.

| Hint from the provisional transcript | silence that ends the turn |
|---|---|
| finished sentence (stop/?/! after ≥ 3 words, or a known one-word command like "Dur."/"Stop.") | 0.65 s (0.5 s for a short command) |
| unknown (no text yet, no cue) | 1.0 s |
| visibly unfinished (comma, "…", "ve/and/the", Turkish «-deki» …; a stop after a hesitation like «Unity'deki.» is **not** trusted) | 1.5 s |
| hard cap | 1.7 s; a turn never lasts > 45 s |

The hint comes from the recogniser's own provisional transcript; when the VAD closes, JARVIS asks the recogniser for a fresh preview (≈ 0.2 s) so a finished sentence is recognised as such *before* the 1.0 s default elapses. Measured (live loop, Whisper): speech end → endpoint **0.50–0.68 s** (vs 1.0 s without the hint). No LLM call is ever made to decide this. The two example turns "Jarvis, Unity'deki … [0.9 s] … son testlerin durumunu söyle." stay ONE turn (live test).

## 6. Turn manager and the follow-up window

`TurnMachine` (pure reducer, time passed explicitly, unit tested with 30+ scripted timelines) emits effects; `HandsFreeCoordinator` performs them (start/end/discard utterance, stop speaking, acknowledge, single-shot timers). It never routes, plans, approves, edits or runs anything.

`DORMANT → WAKE_LISTENING → ATTENTIVE → USER_SPEAKING → ENDPOINTING → TRANSCRIBING → THINKING → JARVIS_SPEAKING → (INTERRUPTING →) USER_SPEAKING …`, plus `ERROR` (clears after 6 s). Rules: attentive window 7 s after the wake word; after an answer a **follow-up window of 8 s** needs no wake word, at most 8 consecutive follow-ups, a 0.4 s deaf period after speech (the room still rings); a transcript that is only the wake word keeps the window open; an unintelligible turn is retried twice; Push-to-Talk takes ownership at any time (a hands-free utterance is discarded, speech stops first; a press while the previous turn is being finalised is ignored — as in V0.7); a PTT answer opens **no** follow-up window; restarts never restore an active state.

## 7. Barge-in and self-speech suppression (no echo canceller)

**Design.** JARVIS plays through its **own** output engine (`SpeechPlayer`: AVAudioEngine + AVAudioPlayerNode, output only; the Apple synthesiser now renders with `AVSpeechSynthesizer.write` and the neural voice returns PCM, both played by the player), so it knows the level of every output slice. `BargeInDetector` predicts the echo (loudest reference level of the last 300 ms + learned coupling) and fires only when the microphone is **≥ 8 dB louder than the prediction, the VAD says speech, for ≥ 0.3 s with ≥ 65 % duty** (so clicks and gusts cannot). The coupling is learned in the first 0.8 s of each playback but may exceed the conservative prior (−24 dB) by 8 dB at most (a user cannot be learned as "echo"). After recognition a transcript that merely quotes what JARVIS just said (token overlap ≥ 70 % or a near-match of ≥ 85 % letter similarity) is dropped (`SelfSpeechFilter`).

**Evidence.**
* Real speaker→microphone loop on this MacBook Air (built-in, system volume 53 %): echo −46 dBFS vs quiet −53…−60 dBFS; coupling −26…−30 dB (σ 2 dB), delay 100–200 ms, envelope correlation 0.91–0.95. Simulation on three real recordings + a synthetic user: no false fire; user ≥ −40 dBFS detected in 0.28–0.9 s; a user below −45 dBFS (below the echo) is not (documented limit).
* Voice Processing I/O (Apple's AEC) was measured: with JARVIS' own playback in the same engine the echo disappeared (−72 dBFS vs −36 plain), but it costs **≈ 15 % of a core continuously**, partly cancels audio from other processes only (−61.7 dBFS residue), changes the input to 7 channels at 48 kHz, and its initialisation failed in several engine shapes and right after a previous VPIO teardown (`-10875`). Not adopted; documented as the alternative.
* Closed-loop live test (real sentinel + Whisper + neural voice, simulated speaker with this Mac's coupling): barge-in at the beginning / middle / near the end of a long answer — **onset → decision ≈ 320 ms, decision → speech silent 24–36 ms**, no stale phrase plays afterwards, the new turn is captured, transcribed and answered; a whole long answer over its own echo causes no false barge-in and no self-wake.

The barge-in level is measured after a 250 Hz high-pass in 20 ms slices (DEC-087): without it a +6 dB click train and a 90 Hz door thud interrupted the answer in the closed-loop test, because the VAD is saturated by JARVIS' own echo and only the level discriminates.

Limits (JARVIS-V08-5): a quiet voice, a very loud speaker volume, or headphones with leakage may not interrupt; Push-to-Talk and Stop Speaking always work; far-field/echo-heavy rooms need the manual test.

## 8. The JARVIS voice

### 8.1 Neural voice research

| Candidate | Licence | Size / memory (measured) | Turkish | Latency (measured) | Verdict |
|---|---|---|---|---|---|
| **Supertonic 3** (ONNX Runtime CPU, 31 languages, 10 fixed voice styles M1–M5/F1–F5) `Supertone/supertonic-3` @ `724fb5ab…` | code MIT; weights **BigScience OpenRAIL-M** (use-based restrictions: no impersonation, disclose machine-generated content — compatible; repo archived/read-only upstream) | 381 MB on disk (4 ONNX, 99 M params), **496–550 MB RSS**, load 0.3 s (+1.9 s first graph) | ✓ same style in every language | warm first block 0.28 s (1 word) … 0.97 s (2 sentences); RTF 0.15–0.28 on 2 threads (≈ 0.3 CPU-s per audio-s) | **selected** |
| Chatterbox Multilingual (MLX) | MIT | 3.0 GB disk, **1.8–3.2 GB RSS, 4.2 GB peak**; needs a reference voice | ✓ (23 languages) | first audio 1.9–2.7 s, RTF 0.72 | rejected: memory (Unity + Qwen + Whisper) and latency |
| Piper (ONNX; `piper-tts` 1.8.0 is **GPL-3**) | voices per dataset: Turkish `dfki` **CC BY-NC-SA 4.0**, British `alan` "see URL", `northern_english_male` CC-BY-SA; `fahrettin`/`fettah` Turkish voices were removed at the contributors' request | 63 MB per voice, 150–330 MB | one male voice | first chunk 20–270 ms, RTF 0.02 | not adopted: three unrelated speakers (no shared identity), non-commercial/unclear licences, GPL engine; fastest option, kept as a documented alternative |
| Kokoro (Apache-2.0, 82 M) | ✓ | small | **no Turkish** | — | researched only |
| XTTS-v2, Fish/OpenAudio, Qwen3-TTS | non-commercial / no Turkish | large | — | — | researched only |
| Apple premium/enhanced system voices | system | on demand | Yelda (female) only | — | stays the fallback; none installed here |

Median F0 of the same sentence (a coarse proxy, not a quality score): M5 ≈ 94–96 Hz (narrowest range p10–p90 77–111 Hz), M2 ≈ 95–98, M3 ≈ 97–107, M4 ≈ 126–133, M1 ≈ 139–160; Apple Daniel 117 Hz, Samantha 189 Hz, **Yelda 220 Hz (female)**. This is the only objective input to the default choice; **whether it SOUNDS like the target is a human judgement (MANUAL TEST REQUIRED, README 249, 254 and 309–317).**

### 8.2 Selection and identity

**JARVIS Voice Identity v1** (`JarvisVoiceIdentity`, provider-independent): mature male, calm, composed, precise, understated, warm but restrained, medium-low pitch (target 85–130 Hz), natural pace, short intentional pauses (phrase gap 0.12–0.35 s), clear diction; no theatrical/announcer/robotic/cheerful delivery; natural Turkish pronunciation and a neutral English; the **same speaker identity across Turkish and English** (one Supertonic style renders both). It is an **original** character: it does not copy, clone or imitate any actor, performer or person; the code accepts no reference voice (`verify.sh` forbids `ref_audio/speaker_wav/clone…`). A mapper turns the identity into provider settings: **JARVIS Default** = Supertonic M5 (speed 1.0, 6 denoising steps), **JARVIS Calm** = M3 (speed 0.94, longer sentence gap), **System Fallback** = Apple voices (prefers an installed male English voice such as Daniel; Turkish has only the female Yelda here — a documented compromise, not hidden).

**Auto** chooses the neural voice when installed, healthy and memory pressure is normal; otherwise Apple (reason shown in Settings). An explicit choice never falls back. Preview phrases are fixed ("Efendim? Sistemler hazır." / "Yes? All systems are ready.") and start no conversation. **Not yet listened to by a person** — the preferred status is technical (licence, latency, memory, offline, cancellation, stability), not a claim of naturalness.

### 8.3 Truthful streaming category

Supertonic is **not a streaming model**: this is **INCREMENTAL CHUNK TTS** — stable sentences/clauses from the response stream are synthesised one after another (two in flight) while the answer is still being generated; each phrase's audio is returned in 0.3 s blocks and played as it arrives. The Apple fallback is the same category (`write` returns a phrase's buffers as they are produced). First audible audio therefore needs one phrase to be synthesised (≈ 0.3–1 s neural, ≈ 0.15 s Apple).

### 8.4 Chunk naturalness

The neural model pads each phrase with ≈ 0.4 s of silence before and ≈ 0.55 s after; the helper trims to 30 ms before and a deliberate tail (160 ms after a sentence, 70 ms after a clause). Inter-phrase gaps are measured from the player queue in the live test (see §11). Prosody controls are provider-native only (speed, style, steps); no DSP pitch shifting.

## 9. Mixed-language, language continuity, speakable answers

* Language continuity (`LanguageContinuity`): inside one conversation the reply language does not flip because of "Unity/GameObject/BoxCollider"; a clearly different language needs a real sentence (≥ 4 words).
* `TechnicalTerms.normalize` (bounded post-processing of the FINAL transcript only): canonical spelling/spacing of a fixed list (Play Mode, EditMode, PlayMode, GameObject, BoxCollider, Rigidbody, OpenCode, Unity, Claude, Codex …); never adds/removes/reorders words, never guesses a mis-heard word, keeps Turkish suffixes (`Unity'deki`), idempotent (unit tested). Mixed-language recognition remains the weakest case (JARVIS-V07-2 / V08-7): a better model (Whisper turbo, 1.8 GB) stays optional.
* `voiceConversation` presentation: for voice turns the EXISTING provider is asked for a short, speakable answer (a one-line preamble in the prompt of Claude/Codex/OpenCode/Qwen); no second model call, no rewriting. The screen may show more structure than is spoken; both are the same answer. Deterministic answers (status, commands) are already short, natural sentences.

## 10. Resource policy

Sentinel: starts when wake mode is enabled, restarts at most 3× in 10 minutes then reports "unavailable" (PTT still works), liveness ping only while audio flows (no idle timer). Neural voice: on demand, unloads after 180 s idle and on memory-pressure rise (the 124 MB sentinel stays); Auto falls back to Apple under pressure; Whisper as in V0.7. All helpers go through `HelperHost` → `ManagedProcess` (audited launch point, killed with the tree at quit/SIGTERM — live-tested with a child JARVIS).

## 11. Measurements

All numbers: this Mac (Apple-silicon MacBook Air, 16 GB), release build, SYNTHETIC speech (Apple system voices) through a closed acoustic loop (scripted microphone + simulated speaker, echo −27 dB / 120 ms, the coupling measured on this Mac) unless marked REAL LOOP. Source: `JARVIS --natural-voice-live-test` (final runs: 55/55 with the loop simulated, 58/58 with `--natural-acoustic --natural-idle 6`). They are one machine, one room and synthetic voices — not a statement about human speech.

**Wake / VAD (shipped rules: threshold 0.9, patience 3, utterance-initial ≤ 1.6 s)**

| Item | Result |
|---|---|
| Held-out benchmark, 2.9 h of Apple-voice speech | positives 70/70, 0 false events, 26/90 acoustic look-alikes fire, latency p50 +31 ms after the word |
| Live stream, 24 s of Turkish/English speech + 30 keyboard clicks | 0 false wakes |
| Look-alikes in the live test («Service», «Marvin», «Hey Travis» …) | 0–1 of 6 wake (documented limit: near-homophones can) |
| Detection after the end of the word | 8–132 ms |
| Silero VAD | start error median 50 ms; no false speech in noise (the energy VAD failed in noise) |

**Turn latency (synthetic user, neural JARVIS voice)**

| Turn | speech end → endpoint | endpoint → final | endpoint → first audio | user speech end → first audio |
|---|---|---|---|---|
| TR two-step | 0.55–0.83 s | 0.24 s | 1.1–1.3 s | 1.7–2.0 s |
| EN two-step | 0.52–0.54 s | 0.25 s | 0.67–0.68 s | 1.2 s |
| TR one breath | 0.67–0.68 s | 0.29–0.30 s | 0.71–0.73 s | 1.4 s |
| EN one breath | 0.53–0.54 s | 0.28 s | 0.70 s | 1.2 s |

The first answer after a cold start of the neural voice includes its load (≈ 1.3 s helper launch + model + first phrase; model load 0.5–0.6 s). The Turkish two-step first audio is the longest because the first Turkish phrase is long (the answer is synthesised per phrase, not streamed). The speech-end → endpoint column is the deliberate natural-endpoint wait (complete sentence 0.65 s, short command 0.5 s, unknown 1.0 s, unfinished 1.5 s).

**Barge-in (closed loop)**: onset → decision 298–320 ms (the 0.3 s sustain rule), decision → silence 37–45 ms, 0 stale phrases after the stop, at the beginning, in the middle and near the end of an answer; 3 of 3. Self-speech: the complete bounded answer in the neural voice and in the Apple voice over its own echo causes 0 barge-ins, 0 self-wakes, 0 extra turns; JARVIS saying "Jarvis" never wakes it. Keyboard-click train (+6 dB) and a 90 Hz door thud while JARVIS speaks do not interrupt it (speech-band filter + 20 ms duty rule).

**REAL LOOP (real speaker → real microphone, levels only, audible)**: room floor −57 dBFS, JARVIS' own voice at the microphone −39 dBFS (17.6 dB above the floor), learned coupling −24 dB: the real echo alone never triggered a barge-in, and a synthetic user 14 dB above the real echo mixed into the real frames was detected 0.37 s after it began.

**Neural voice (Supertonic 3)**: RSS 530–562 MB loaded, model load 0.5–0.6 s, helper launch + first phrase ≈ 1.25–1.35 s cold, ≈ 0.6 s p50 warm, CPU 0.2 s for the whole test, unload 26–27 ms. Inter-phrase gap 0 ms (phrases are scheduled back to back in the player queue). Median F0 ≈ 95 Hz.

**Resources (wake mode on, JARVIS-owned processes)**: wake sentinel RSS 118–140 MB; quiet room: 0.0 s of audio reaches the helper, 0.00 CPU-s; continuous speech in the room: helper 0.2 % of one core; JARVIS 0.03 % (no HUD) / 0.07 % (Compact) / 0.29–0.31 % (Full HUD) of one core; Whisper helper 0.7–0.86 GB when loaded. **Long idle, 6.0 min**, silent room: helper 0.000 %, JARVIS 0.06 %, 0.0 s of audio sent, helper RSS 118 → 126 MB, JARVIS RSS 195 → 195 MB, no phantom wake, no restart.

**Combined state** (`--natural-combined` next to a real `--unity-live-test`, two runs): local Qwen worker loaded (1.7–1.8 GB at load, peak 3.4 GB; its RSS reads lower when sampled later because macOS compresses it), Whisper, the neural voice and the wake sentinel all resident, one natural Turkish turn completed in 7 s with CPU +0.01–0.02 CPU-s per process; JARVIS 125–127 MB + wake 79–80 MB + Whisper 180–463 MB + neural voice 465–481 MB + Qwen 29–251 MB + a Unity editor 362–575 MB (sampled while the editor was still starting) ≈ 1.5–1.75 GB at the sample; memory pressure stayed NORMAL (free memory 42–46 % after the turn; swap unchanged). Limit: the Unity editor was sampled during its start-up, not during a long Play Mode session.

## 12. Manual tests that remain

README 224–343: a human saying "Jarvis" (quietly, quickly, with a Turkish pronunciation, from a distance), false wakes from real conversation and media, real-room barge-in, speaker volume, keyboard/fan noise, headphones, VoiceOver, Reduce Motion, battery over a day, and above all **listening to the voices** (A/B: JARVIS Default / Calm / System Fallback).

## 13. V0.8 vs V0.9

V0.8 ends at hearing and speaking. Web research, asset acquisition, memory and computer use are untouched; nothing here gives voice a new capability.
