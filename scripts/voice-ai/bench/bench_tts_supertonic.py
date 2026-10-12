#!/usr/bin/env python3
"""Supertonic 3 (ONNX, CPU) benchmark: cold/warm start, time to first audio, real-time factor, memory, per voice and language.

    SUPERTONIC_CACHE_DIR=<model dir parent> python bench_tts_supertonic.py <out-dir>

Writes one wav per (voice, phrase) for the manual A/B listening test. The audio is synthetic and non-sensitive.
"""
import os, subprocess, sys, time
import numpy as np

PHRASES = {
    "tr1": ("tr", "Unity testleri tamamlandı. Tüm EditMode ve PlayMode testleri geçti."),
    "tr2": ("tr", "Efendim? Son görevin sonuçlarını kontrol ediyorum."),
    "en1": ("en", "The Unity tests are complete. No new Console errors were detected."),
    "en2": ("en", "Of course. I'm checking the latest task now."),
    "mix1": ("tr", "Play Mode tamamlandı ve BoxCollider değişikliği doğrulandı."),
    "mix2": ("tr", "Unity projesinde iki GameObject güncellendi."),
}


def rss_mb():
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())]).split()[0]) / 1024


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    voices = sys.argv[2].split(",") if len(sys.argv) > 2 else ["M1", "M2", "M3", "M4", "M5"]
    r0 = rss_mb()
    t = time.time()
    c0 = time.process_time()
    from supertonic import TTS
    t_import = time.time() - t
    tts = TTS()
    t_load = time.time() - t
    print(f"import {t_import:.2f}s  load total {t_load:.2f}s  cpu {time.process_time() - c0:.2f}s  RSS {r0:.0f} -> {rss_mb():.0f} MB")
    # warm-up
    style = tts.get_voice_style(voices[0])
    t = time.time()
    tts.synthesize("Merhaba.", voice_style=style, lang="tr")
    print(f"first synthesis (cold graph) {time.time() - t:.2f}s")
    rows = []
    for v in voices:
        style = tts.get_voice_style(v)
        for key, (lang, text) in PHRASES.items():
            c0 = time.process_time(); t = time.time()
            wav, dur = tts.synthesize(text, voice_style=style, lang=lang)
            wall = time.time() - t
            cpu = time.process_time() - c0
            d = float(np.asarray(dur).sum()) if np.ndim(dur) else float(dur)
            rows.append((v, key, wall, d, cpu))
            tts.save_audio(wav, os.path.join(out, f"supertonic_{v}_{key}.wav"))
    print(f"{'voice':5s} {'phrase':5s} {'wall s':>7s} {'audio s':>7s} {'RTF':>6s} {'cpu s':>6s}")
    for v, k, w, d, c in rows:
        print(f"{v:5s} {k:5s} {w:7.3f} {d:7.2f} {w / d:6.3f} {c:6.2f}")
    print(f"mean RTF {np.mean([w / d for _, _, w, d, _ in rows]):.3f}  peak RSS now {rss_mb():.0f} MB")


if __name__ == "__main__":
    main()
