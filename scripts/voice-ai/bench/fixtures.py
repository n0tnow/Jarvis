#!/usr/bin/env python3
"""Synthetic, NON-SENSITIVE audio fixtures for the V0.8 wake-word / VAD / endpoint benchmarks.

Everything is generated on this Mac with the system `say` command (Apple voices) and plain numpy (noise, pauses, gain). Nothing is recorded from a
person, nothing is committed (the output directory is a scratch folder), and the same call always produces the same audio.

    python fixtures.py <output-dir>

Layout of <output-dir>:
    wake_pos/<name>.wav     the wake word spoken (voices x rates x levels x noise), lead-in/out silence, ground truth in manifest.json
    wake_neg/<name>.wav     look-alike words, ordinary Turkish/English speech (never containing "Jarvis"), noise and click events
    wake_ctx/<name>.wav     speech that CONTAINS the literal word (JARVIS' own sentences, a sentence about Jarvis) - the self-wake class
    vad/<name>.wav          speech / silence / noise / mid-sentence pause / long pause with exact speech boundaries in manifest.json
    manifest.json           ground truth: kind, voice, rate, word_start/word_end (s), speech segments

Audio is mono 16 kHz float32 inside numpy and 16-bit PCM on disk (for the Python benchmarks only).
"""
import json, os, subprocess, sys, tempfile
import numpy as np
from scipy.io import wavfile

SR = 16000
EN_VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Tessa"]
TR_VOICES = ["Yelda"]
RATES = [135, 180, 230]


def say(text, voice, rate):
    """Speech for `text` as float32 mono 16 kHz (no padding)."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "x.wav")
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", path, "--data-format=LEI16@16000", text], check=True)
        sr, data = wavfile.read(path)
        assert sr == SR, sr
        x = data.astype(np.float32) / 32768.0
        # trim the synthesiser's own leading/trailing silence so ground truth is exact
        idx = np.where(np.abs(x) > 0.004)[0]
        if len(idx) == 0:
            return x[:0]
        return x[idx[0]:idx[-1] + 1]


def pink_noise(n, rng):
    white = rng.standard_normal(n).astype(np.float32)
    f = np.fft.rfft(white)
    k = np.arange(len(f), dtype=np.float32)
    k[0] = 1
    f = f / np.sqrt(k)
    x = np.fft.irfft(f, n).astype(np.float32)
    return x / (np.std(x) + 1e-9)


def mix_noise(x, snr_db, rng):
    if snr_db is None:
        return x
    sig = np.sqrt(np.mean(x ** 2) + 1e-12)
    noise = pink_noise(len(x), rng) * sig / (10 ** (snr_db / 20))
    return x + noise


def room(n_seconds, rng, level=0.0008):
    """Quiet room noise floor (about -62 dBFS)."""
    return pink_noise(int(n_seconds * SR), rng) * level


def save(path, x):
    x = np.clip(x, -1, 1)
    wavfile.write(path, SR, (x * 32767).astype(np.int16))


def place(speech, lead, tail, rng, floor=0.0008):
    n = int((lead + tail) * SR) + len(speech)
    out = room(n / SR, rng, floor)
    s = int(lead * SR)
    out[s:s + len(speech)] += speech
    return out, s / SR, (s + len(speech)) / SR


def main(out):
    rng = np.random.default_rng(8)
    for d in ("wake_pos", "wake_neg", "wake_ctx", "vad"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    man = {}

    def add(kind, name, x, **meta):
        save(os.path.join(out, kind, name + ".wav"), x)
        man[f"{kind}/{name}"] = dict(kind=kind, seconds=round(len(x) / SR, 3), **meta)

    # --- wake positives ------------------------------------------------------------------------------------------------------------------
    phrases = [("Jarvis", "bare"), ("Hey Jarvis", "hey"), ("Jarvis.", "bare")]
    for voice in EN_VOICES + TR_VOICES:
        for rate in RATES:
            for text, cls in phrases:
                sp = say(text, voice, rate)
                if len(sp) == 0:
                    continue
                for level_name, gain, snr in (("normal", 0.5, None), ("quiet", 0.07, None), ("noisy", 0.5, 12)):
                    x = mix_noise(sp * gain / max(np.max(np.abs(sp)), 1e-6), snr, rng)
                    y, a, b = place(x, 1.2, 1.2, rng)
                    add("wake_pos", f"{voice}_{rate}_{cls}_{level_name}_{text.replace(' ', '').replace('.', '')}", y,
                        voice=voice, rate=rate, phrase=text, cls=cls, level=level_name, word_start=round(a, 3), word_end=round(b, 3))
    # Turkish orthography: "Carvis" is how a Turkish reader says Jarvis (c = dʒ)
    for rate in RATES:
        sp = say("Carvis", "Yelda", rate)
        y, a, b = place(sp * 0.5 / max(np.max(np.abs(sp)), 1e-6), 1.2, 1.2, rng)
        add("wake_pos", f"Yelda_{rate}_tr_Carvis", y, voice="Yelda", rate=rate, phrase="Carvis", cls="tr-orthography", level="normal", word_start=round(a, 3), word_end=round(b, 3))
    # wake word followed by a command (the real use)
    ctx = [("Jarvis, open the Tasks screen.", "Samantha"), ("Jarvis, what is the status of the Unity tests?", "Daniel"),
           ("Jarvis, görevler ekranını aç.", "Yelda"), ("Jarvis, Unity'deki son testlerin durumunu söyle.", "Yelda")]
    for text, voice in ctx:
        word = say("Jarvis", voice, 180)
        sp = say(text, voice, 180)
        y, a, b = place(sp * 0.5 / max(np.max(np.abs(sp)), 1e-6), 1.2, 1.5, rng)
        add("wake_pos", f"cmd_{voice}_{abs(hash(text)) % 9999}", y, voice=voice, rate=180, phrase=text, cls="command", level="normal",
            word_start=round(a, 3), word_end=round(a + len(word) / SR, 3))

    # --- wake negatives: look-alike words --------------------------------------------------------------------------------------------------
    lookalikes = ["Service", "Harvest", "Marvin", "Travis", "Jervis", "Davis", "Nervous", "Carpet", "Garbage", "Charlie", "Jarrett", "Parvis",
                  "Harvey", "Jargon", "Jarvik", "Mars is", "Sarvis", "Jarls", "Çarşı", "Jaws", "Dervish", "Marvelous", "Hey Marvin", "Hey Travis",
                  "Hey service", "Oh my god", "Jarring is", "Carve this", "Cervix", "Varsity"]
    for voice in ["Samantha", "Daniel", "Yelda"]:
        for w in lookalikes:
            sp = say(w, voice, 180)
            if len(sp) == 0:
                continue
            y, a, b = place(sp * 0.5 / max(np.max(np.abs(sp)), 1e-6), 1.2, 1.2, rng)
            add("wake_neg", f"look_{voice}_{w.replace(' ', '_')}", y, voice=voice, cls="lookalike", phrase=w)

    # --- wake negatives: ordinary speech (this repository's documentation with every "Jarvis" sentence removed) ------------------------------
    docs = []
    for f in ("README.md", "docs/ARCHITECTURE.md", "docs/DEVELOPMENT_LOG.md"):
        p = os.path.join(os.path.dirname(__file__), "..", "..", "..", f)
        if os.path.exists(p):
            docs.append(open(p, encoding="utf-8").read())
    text = " ".join(docs)
    import re
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", re.sub(r"[`#*|>\-_\[\]()]", " ", text)) if 40 < len(s.strip()) < 220 and "jarvis" not in s.lower()]
    rng2 = np.random.default_rng(3)
    rng2.shuffle(sentences)
    en_block = [s for s in sentences if all(ord(c) < 128 for c in s)][:60]
    for i in range(0, len(en_block), 6):
        voice = EN_VOICES[(i // 6) % len(EN_VOICES)]
        rate = RATES[(i // 6) % len(RATES)]
        sp = say(" ".join(en_block[i:i + 6]), voice, rate)
        if len(sp) == 0:
            continue
        add("wake_neg", f"speech_en_{i // 6}", mix_noise(sp * 0.5 / max(np.max(np.abs(sp)), 1e-6), 25, rng) + room(len(sp) / SR, rng), voice=voice, cls="speech-en")
    tr_text = ["Bugün hava çok güzel, dışarı çıkıp biraz yürümek istiyorum.", "Görevler ekranında son testlerin sonucunu görebilirsin.",
               "Toplantı yarın sabah dokuzda başlayacak, lütfen zamanında gel.", "Unity projesinde iki nesne güncellendi ve testler başarıyla geçti.",
               "Bu hafta sonu ailemle birlikte denize gitmeyi düşünüyoruz.", "Yeni sürümde birkaç hatayı düzelttik ama hâlâ bir sorun var.",
               "Akşam yemeğinde ne yapacağımıza henüz karar vermedik.", "Lütfen kapıyı kapat ve ışıkları söndür.",
               "Dün gece uzun bir film izledim ve çok geç yattım.", "Kod değişikliğini kontrol edip sana haber vereceğim.",
               "Çocuklar bahçede oynarken biz de çay içiyorduk.", "Bilgisayarın ekran parlaklığını biraz azaltabilir misin?"]
    for i in range(0, len(tr_text), 4):
        sp = say(" ".join(tr_text[i:i + 4]), "Yelda", RATES[(i // 4) % 3])
        add("wake_neg", f"speech_tr_{i // 4}", mix_noise(sp * 0.5 / max(np.max(np.abs(sp)), 1e-6), 25, rng) + room(len(sp) / SR, rng), voice="Yelda", cls="speech-tr")
    # noise-only events: room, loud fan, keyboard clicks, a door thud
    add("wake_neg", "noise_room_60s", room(60, rng), cls="noise")
    add("wake_neg", "noise_fan_30s", pink_noise(30 * SR, rng) * 0.02, cls="noise")
    clicks = np.zeros(30 * SR, dtype=np.float32) + room(30, rng)
    for t in np.cumsum(rng.uniform(0.08, 0.45, 80)):
        i = int(t * SR)
        if i + 400 < len(clicks):
            clicks[i:i + 400] += (rng.standard_normal(400) * np.exp(-np.arange(400) / 60) * 0.25).astype(np.float32)
    add("wake_neg", "noise_keyboard_30s", clicks, cls="noise")
    thud = room(10, rng)
    thud[int(3 * SR):int(3.3 * SR)] += (np.sin(2 * np.pi * 90 * np.arange(int(0.3 * SR)) / SR) * np.exp(-np.arange(int(0.3 * SR)) / 1500) * 0.5).astype(np.float32)
    add("wake_neg", "noise_thud_10s", thud, cls="noise")

    # --- wake context: speech that contains the literal word (self-speech / talking about it) ---------------------------------------------
    own = [("Merhaba, ben Jarvis. Sesim böyle.", "Yelda"), ("Hello, I am Jarvis. This is how I sound.", "Samantha"),
           ("Efendim? Ben Jarvis, size nasıl yardımcı olabilirim?", "Yelda"), ("Yes? This is Jarvis. All systems are ready.", "Daniel"),
           ("We renamed the project to Jarvis last week and the team is happy about it.", "Samantha"),
           ("Geçen hafta projenin adını Jarvis yaptık ve herkes çok memnun.", "Yelda")]
    for text, voice in own:
        sp = say(text, voice, 180)
        y, a, b = place(sp * 0.5 / max(np.max(np.abs(sp)), 1e-6), 1.0, 1.0, rng)
        add("wake_ctx", f"ctx_{voice}_{abs(hash(text)) % 9999}", y, voice=voice, cls="contains-word", phrase=text)

    # --- VAD / endpointing fixtures --------------------------------------------------------------------------------------------------------
    def vad_item(name, parts, noise_snr=None, floor=0.0008):
        """parts: list of ('speech', text, voice, rate) | ('pause', seconds) | ('silence', seconds)."""
        chunks, segs, t = [], [], 0.0
        for p in parts:
            if p[0] == "speech":
                sp = say(p[1], p[2], p[3])
                sp = sp * 0.5 / max(np.max(np.abs(sp)), 1e-6)
                segs.append([round(t, 3), round(t + len(sp) / SR, 3), p[1]])
                chunks.append(sp)
                t += len(sp) / SR
            else:
                chunks.append(np.zeros(int(p[1] * SR), dtype=np.float32))
                t += p[1]
        x = np.concatenate(chunks)
        x = x + room(len(x) / SR, rng, floor)
        if noise_snr:
            x = mix_noise(x, noise_snr, rng)
        add("vad", name, x, speech=segs, floor=floor, noise_snr=noise_snr)

    vad_item("silence_5s", [("silence", 5.0)])
    vad_item("noise_5s", [("silence", 5.0)], floor=0.01)
    vad_item("tr_command", [("silence", 1.0), ("speech", "Jarvis, görevler ekranını aç.", "Yelda", 180), ("silence", 2.0)])
    vad_item("en_command", [("silence", 1.0), ("speech", "Jarvis, open the Tasks screen.", "Samantha", 180), ("silence", 2.0)])
    vad_item("tr_pause_short", [("silence", 1.0), ("speech", "Jarvis, Unity'deki", "Yelda", 180), ("pause", 0.55),
                                ("speech", "son multiplayer testlerine bak.", "Yelda", 180), ("silence", 2.0)])
    vad_item("tr_pause_medium", [("silence", 1.0), ("speech", "Jarvis, Unity'deki", "Yelda", 180), ("pause", 0.9),
                                 ("speech", "son multiplayer testlerine bak.", "Yelda", 180), ("silence", 2.0)])
    vad_item("en_pause_short", [("silence", 1.0), ("speech", "Jarvis, check the", "Samantha", 180), ("pause", 0.55),
                                ("speech", "latest multiplayer tests.", "Samantha", 180), ("silence", 2.0)])
    vad_item("en_pause_medium", [("silence", 1.0), ("speech", "Jarvis, check the", "Samantha", 180), ("pause", 0.9),
                                 ("speech", "latest multiplayer tests.", "Samantha", 180), ("silence", 2.0)])
    vad_item("tr_pause_long", [("silence", 1.0), ("speech", "Jarvis, Unity'deki son testlere bak.", "Yelda", 180), ("pause", 2.5),
                               ("speech", "Bir de konsol hatalarını söyle.", "Yelda", 180), ("silence", 2.0)])
    vad_item("tr_command_noisy", [("silence", 1.0), ("speech", "Jarvis, görevler ekranını aç.", "Yelda", 180), ("silence", 2.0)], noise_snr=12)
    vad_item("en_command_noisy", [("silence", 1.0), ("speech", "Jarvis, open the Tasks screen.", "Samantha", 180), ("silence", 2.0)], noise_snr=12)
    vad_item("en_short_word", [("silence", 1.0), ("speech", "Stop.", "Daniel", 180), ("silence", 2.0)])
    vad_item("tr_short_word", [("silence", 1.0), ("speech", "Dur.", "Yelda", 180), ("silence", 2.0)])
    vad_item("tr_interruption", [("speech", "Dur, multiplayer testlerini soruyordum.", "Yelda", 180), ("silence", 2.0)])
    json.dump(man, open(os.path.join(out, "manifest.json"), "w"), indent=1, ensure_ascii=False)
    print(f"{len(man)} fixtures -> {out}")


if __name__ == "__main__":
    main(sys.argv[1])
