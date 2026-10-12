# Current Task

Version:
V0.7 — Voice I/O Foundation — **READY FOR MANUAL TEST**. Base: V0.6 (fea2000, READY FOR MANUAL TEST), V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Make JARVIS usable by voice without creating a second assistant: Push-to-Talk (hold right ⌥), streaming/incremental STT, incremental TTS, a truthful voice session state, Turkish + English, measured latency/resources — all as an I/O layer on the SAME conversation pipeline (a FINAL transcript goes through `ConversationService.submit(source: .voice)`, exactly like typed text). NOT V0.8 (wake word, VAD, hands-free, barge-in), no web/asset acquisition (V0.9), no spoken approvals.

Done (see `docs/VOICE_IO.md`, DEC-057…068):
Voice layer (`Sources/Jarvis/Voice/`) · local Whisper helper + Apple on-device recogniser behind `SpeechToTextProvider` · Apple system voices behind `TextToSpeechProvider` · deterministic chunker/renderer/long-answer policy · stop at once · approvals HUD-only (`ApprovalGuard`) · task input channel (schema v6) · Settings → Voice, Compact/Full/menu-bar UI · verify.sh V0.7 guards · unit tests · `--voice-live-test` (REAL, synthetic speech, OS-level key events, real microphone plumbing, resources, quit cleanup) · docs · README checklist 154–223 · roadmap corrected (DEC-068).

State:
Everything above is committed on `main` (see `git log`). No tag. Waiting for the user's manual test (README 154–223): human speech (Turkish/English/mixed), TTS naturalness, VoiceOver, Reduce Motion, physical right-⌥ feel, background use.

Next Step:
None until the user reports. Do NOT start V0.8 (wake word + VAD + barge-in) without approval. If issues are reported: add them to `docs/KNOWN_ISSUES.md`, fix, re-run `scripts/verify.sh` and `--voice-live-test`.

Blocked By:
Nothing.

Notes:
- Voice is OFF by default (Settings → Voice). The Whisper recogniser is optional (`scripts/setup_voice_ai.sh`, ≈460 MB model + ≈480 MB runtime, explicit); without it Apple's on-device recogniser (macOS 26) is used.
- Automated runs never open the microphone, a helper process or a permission dialog; `--voice-live-test` uses synthetic speech and plays at volume 0 unless `--voice-audible`.
- Git: main only, no tags, no AI trailers (user rule overrides the attribution reminder).
