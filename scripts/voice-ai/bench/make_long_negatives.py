#!/usr/bin/env python3
"""Hours of ordinary speech for the wake-word false-activation rate (synthetic, held out from training): Apple system voices reading macOS manual-page
prose (English) and generated everyday Turkish sentences. Sentences containing "Jarvis" are removed. Output: <out>/long_neg/*.wav + manifest entries
compatible with bench_wake.py (kind=wake_neg, cls=speech-en|speech-tr).

    python make_long_negatives.py <fixtures-dir> [minutes-per-voice]
"""
import glob, json, os, re, subprocess, sys, tempfile
import numpy as np
from scipy.io import wavfile

out = sys.argv[1]
minutes = float(sys.argv[2]) if len(sys.argv) > 2 else 8
os.makedirs(os.path.join(out, "wake_neg"), exist_ok=True)
man = json.load(open(os.path.join(out, "manifest.json")))
rng = np.random.default_rng(11)

sents = []
for f in sorted(glob.glob("/usr/share/man/man1/*.1"))[600:1100]:
    try:
        raw = open(f, errors="ignore").read()
    except OSError:
        continue
    lines = [l for l in raw.split("\n") if l and not l.startswith((".", '\\"'))]
    txt = re.sub(r"\\f[BIRP]|\\-|\\&|\\\(..|\\e", "", " ".join(lines))
    for s in re.split(r"(?<=[.!?])\s+", txt):
        s = s.strip()
        if 30 < len(s) < 170 and s[0].isalpha() and all(ord(c) < 128 for c in s) and "jarvis" not in s.lower() and sum(c.isalpha() or c == " " for c in s) / len(s) > 0.9:
            sents.append(s)
rng.shuffle(sents)
subj = ["Ben", "Sen", "Annem", "Babam", "Öğretmen", "Ekip", "Müşteri", "Komşumuz", "Arkadaşım", "Yazılımcı", "Çocuklar", "Doktor", "Ali", "Ayşe", "Mehmet", "Zeynep", "Müdür"]
obj = ["raporu", "kodu", "toplantıyı", "projeyi", "testi", "belgeyi", "yemeği", "arabayı", "kapıyı", "mesajı", "haberi", "planı", "oyunu", "sahneyi", "dosyayı", "ekranı", "faturayı", "müziği"]
verb = ["kontrol ettim", "hazırladım", "gönderdim", "tamamladım", "okudum", "değiştirdim", "yarın bitireceğim", "bugün gördüm", "tekrar deneyeceğiz", "çok beğendim", "henüz görmedim", "hemen düzeltelim", "unutmuşum", "arıyorum"]
tail = ["", " ama biraz zaman aldı", " çünkü acelemiz vardı", " ve herkes memnun kaldı", ", sonra eve döndük", " akşama kadar", " geçen hafta", " sabahtan beri"]
tr = [f"{rng.choice(subj)} {rng.choice(obj)} {rng.choice(verb)}{rng.choice(tail)}." for _ in range(3000)]

jobs = [("Samantha", sents), ("Daniel", sents[1000:] + sents[:1000]), ("Karen", sents[2000:] + sents[:2000]), ("Moira", sents[3000:] + sents[:3000]),
        ("Rishi", sents[4000:] + sents[:4000]), ("Tessa", sents[5000:] + sents[:5000]), ("Yelda", tr), ("Yelda", tr[1500:] + tr[:1500])]
total = 0.0
for i, (voice, pool) in enumerate(jobs):
    chunk, n = [], 0
    for s in pool:
        chunk.append(s); n += len(s)
        if n > minutes * 60 * 14: break           # ≈ 14 characters per second of speech
    text = " ".join(chunk)
    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "x.wav")
        subprocess.run(["say", "-v", voice, "-r", str(150 + 25 * (i % 3)), "-o", wav, "--data-format=LEI16@16000", text], check=True)
        sr, x = wavfile.read(wav)
    name = f"long_{i}_{voice}"
    wavfile.write(os.path.join(out, "wake_neg", name + ".wav"), 16000, x)
    man[f"wake_neg/{name}"] = dict(kind="wake_neg", cls="speech-tr" if voice == "Yelda" else "speech-en", voice=voice, seconds=round(len(x) / 16000, 3))
    total += len(x) / 16000
    print(name, round(len(x) / 16000 / 60, 1), "min", flush=True)
json.dump(man, open(os.path.join(out, "manifest.json"), "w"), indent=1, ensure_ascii=False)
print(f"{total / 3600:.2f} h of ordinary speech added")
