# Current Task

Version:
V0.8 — Natural Voice & Presence — **READY FOR MANUAL TEST** (AUTOMATED TESTED · REAL TESTED with SYNTHETIC speech; not user-verified). Base: V0.7 (e5014bf), V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Natural voice presence on the SAME conversation pipeline: opt-in local wake word "Jarvis", local VAD, natural endpointing, hands-free turn taking with a bounded follow-up window, barge-in with self-speech suppression, local neural JARVIS voice (Apple voices stay the fallback), original voice identity, low-latency flow. No spoken approvals, no tag, not COMPLETE, NOT V0.9.

Done (IMPLEMENTED · AUTOMATED TESTED · REAL TESTED with synthetic speech):
Research + benchmarks (wake, VAD, echo, neural TTS) · `Sources/Jarvis/Voice/Natural/*`, `Voice/SpeechPlayer.swift`, `Voice/PlayerBackedTTS.swift` · helpers `scripts/voice-ai/jarvis_sentinel_worker.py`, `jarvis_tts_worker.py`, `scripts/setup_voice_ai.sh --natural`, `scripts/train_wake_head.sh` · Settings / Full HUD / Compact HUD / menu bar · 897 unit tests · `--natural-voice-live-test` (55/55; 58/58 with the real speaker→microphone loop and a 6 min idle; combined sample next to a real Unity editor) · `scripts/verify.sh` → VERIFY PASSED · docs (`docs/NATURAL_VOICE.md`, DEC-069…087, JARVIS-V08-1…14, README checklist 224–343).

Next Step:
USER manual test (README 224–343; install the voice stack first: `scripts/setup_voice_ai.sh --natural`, then `scripts/train_wake_head.sh`, then Settings → Voice → Wake word). Do NOT start V0.9 (Web Research & Asset Acquisition) without explicit approval. No tag until the user approves.

Blocked By:
Nothing.

Notes:
- Wake mode is OFF by default. Models/runtimes are installed ONLY by the explicit scripts; JARVIS never downloads anything.
- Automated runs never open the microphone, a helper or a permission dialog; `--natural-voice-live-test` uses a scripted microphone and a simulated speaker (silent); `--natural-acoustic` is the only part that touches the real microphone/speaker (audible, levels only).
- Git: main only, no tags, no AI trailers (user rule).
