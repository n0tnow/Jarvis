#!/usr/bin/env python3
"""Synthetic TRAINING audio for the JARVIS wake-word head (V0.8). Needs the Supertonic 3 runtime (scripts/setup_voice_ai.sh --tts).

    SUPERTONIC_CACHE_DIR=<dir> python gen_wake_train.py <out-dir> [--part pos|neg|hard] [--seed N]

Why synthetic and why Supertonic: the pretrained openWakeWord model only knows "hey jarvis" (CC BY-NC-SA weights); the bare word "Jarvis" needs its own small
classifier. The training voices (Supertonic 3, ten built-in styles, many languages for pronunciation diversity) are deliberately a DIFFERENT engine from the
test voices (Apple system voices, `fixtures.py`), so the benchmark measures generalisation to an unseen synthesiser rather than memorisation.
No recording of any person is used. Output is scratch data - never committed.
"""
import json, os, re, sys
import numpy as np
from scipy.io import wavfile

SR = 16000
VOICES = ["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"]
POS_LANGS = ["en", "tr", "de", "fr", "es", "it", "pt", "pl", "nl", "sv", "na"]
LOOKALIKES = ["Service", "Harvest", "Marvin", "Travis", "Jervis", "Davis", "Nervous", "Carpet", "Garbage", "Charlie", "Jarrett", "Parvis", "Harvey",
              "Jargon", "Mars is", "Sarvis", "Dervish", "Marvelous", "Hey Marvin", "Hey Travis", "Hey service", "Hey Davis", "Jarring", "Carve this",
              "Varsity", "Jar is", "Jarvik", "Gervais", "Harris", "Jarvis's", "Servis", "Çarşı", "Çarpı", "Carvis'in", "Hervis", "Jarl", "Marvis", "Karvis",
              "Hey Jerry", "Okay Travis", "Hey Siri", "Hey there", "Ah, I see", "Yes, sir", "Efendim", "Tamam", "Evet", "Hayır", "Dur", "Stop", "Hey", "Jar"]
EN_SENTENCES = []
TR_SENTENCES = []


def tr_sentences(rng, n):
    subj = ["Ben", "Sen", "Annem", "Babam", "Öğretmen", "Ekip", "Müşteri", "Komşumuz", "Arkadaşım", "Yazılımcı", "Çocuklar", "Doktor", "Ali", "Ayşe", "Mehmet",
            "Zeynep", "Müdür", "Sunucu", "Telefonum", "Bilgisayarım", "Hepimiz", "Birisi", "Kimse", "Herkes", "Şirket", "Takım arkadaşım"]
    obj = ["raporu", "kodu", "toplantıyı", "projeyi", "testi", "belgeyi", "yemeği", "arabayı", "kapıyı", "mesajı", "haberi", "planı", "oyunu", "sahneyi",
           "dosyayı", "ekranı", "sözleşmeyi", "faturayı", "fotoğrafı", "müziği", "şarkıyı", "defteri", "kitabı", "haritayı", "tarifi", "yolu", "çantayı", "anahtarı"]
    verb = ["kontrol ettim", "hazırladım", "gönderdim", "tamamladım", "okudum", "değiştirdim", "yarın bitireceğim", "bugün gördüm", "tekrar deneyeceğiz",
            "çok beğendim", "henüz görmedim", "hemen düzeltelim", "unutmuşum", "kaybetmişiz", "arıyorum", "bulamadım", "açmak istiyorum", "kapattım",
            "çalıştırdım", "sildim", "yazdırdım", "paylaştım", "anlatacağım", "merak ediyorum", "denemeliyiz", "bekliyorum"]
    tail = ["", " ama biraz zaman aldı", " çünkü acelemiz vardı", " ve herkes memnun kaldı", ", sonra eve döndük", " akşama kadar", " geçen hafta", " sabahtan beri",
            " ne zaman biteceğini bilmiyorum", " fakat sonuç iyi değildi", " ve hâlâ cevap yok"]
    out = []
    for _ in range(n):
        out.append(f"{rng.choice(subj)} {rng.choice(obj)} {rng.choice(verb)}{rng.choice(tail)}.")
    extra = ["Görevler ekranını aç.", "Unity'deki son testlerin durumunu söyle.", "Konsol hatası var mı?", "Bu gün hava nasıl olacak?",
             "Play Mode testlerini çalıştır.", "Yeni bir GameObject ekle.", "Ses seviyesini biraz azalt.", "Toplantı kaçta başlıyor?",
             "Şu dosyayı projeye kopyala.", "Dur, multiplayer testlerini soruyordum.", "Bana son görevin raporunu göster.", "Takvimde ne var?"]
    return out + extra


def en_sentences(rng, n):
    root = os.path.join(os.path.dirname(__file__), "..", "..", "..")
    text = ""
    for f in ("README.md", "docs/ARCHITECTURE.md", "docs/DEVELOPMENT_LOG.md", "docs/DECISIONS.md", "docs/UNITY_PROJECT_AGENT.md"):
        p = os.path.join(root, f)
        if os.path.exists(p):
            text += " " + open(p, encoding="utf-8").read()
    sents = [s.strip() for s in re.split(r"(?<=[.!?])\s+", re.sub(r"[`#*|>_\[\]()]", " ", text))
             if 25 < len(s.strip()) < 160 and "jarvis" not in s.lower() and all(ord(c) < 128 for c in s)]
    # ordinary English prose: the system manual pages (public documentation shipped with macOS)
    import glob
    for f in sorted(glob.glob("/usr/share/man/man1/*.1"))[:600]:
        try:
            raw = open(f, errors="ignore").read()
        except OSError:
            continue
        lines = [l for l in raw.split("\n") if l and not l.startswith((".", '\\"'))]
        txt = re.sub(r"\\f[BIRP]|\\-|\\&|\\\(..|\\e", "", " ".join(lines))
        for s2 in re.split(r"(?<=[.!?])\s+", txt):
            s2 = s2.strip()
            if 30 < len(s2) < 150 and s2[0].isalpha() and all(ord(c) < 128 for c in s2) and "jarvis" not in s2.lower() and sum(c.isalpha() or c == " " for c in s2) / len(s2) > 0.9:
                sents.append(s2)
    rng.shuffle(sents)
    extra = ["Open the Tasks screen.", "What is the status of the Unity tests?", "Check the Console for errors.", "Run the EditMode tests again.",
             "Please add a new GameObject to the scene.", "Stop talking.", "What time is the meeting?", "Show me the latest report.",
             "Wait, I was asking about the multiplayer tests.", "Turn the volume down a little."]
    return sents[:n] + extra


def save(path, x):
    x = np.asarray(x, dtype=np.float32).reshape(-1)
    wavfile.write(path, SR, (np.clip(x, -1, 1) * 32767).astype(np.int16))


def to16k(wav, sr):
    from scipy.signal import resample_poly
    from math import gcd
    g = gcd(int(sr), SR)
    return resample_poly(np.asarray(wav, dtype=np.float32).reshape(-1), SR // g, int(sr) // g).astype(np.float32)


def trim(x, thr=0.004):
    idx = np.where(np.abs(x) > thr)[0]
    return x[idx[0]:idx[-1] + 1] if len(idx) else x[:0]


def main():
    out = sys.argv[1]
    part = sys.argv[sys.argv.index("--part") + 1] if "--part" in sys.argv else "pos"
    name_part = sys.argv[sys.argv.index("--name") + 1] if "--name" in sys.argv else part
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1
    from supertonic import TTS
    rng = np.random.default_rng(seed)
    tts = TTS()
    sr = tts.sample_rate
    styles = {v: tts.get_voice_style(v) for v in VOICES}
    os.makedirs(os.path.join(out, name_part), exist_ok=True)
    man = {}

    def synth(text, voice, lang, speed, steps=5):
        wav, _ = tts.synthesize(text, voice_style=styles[voice], lang=lang, speed=speed, total_steps=steps, silence_duration=0.1)
        return trim(to16k(wav, sr))

    if part == "pos":
        # The word alone, every voice x language (pronunciation diversity) x speed x spelling.
        n = 0
        for v in VOICES:
            for lang in POS_LANGS:
                for spelling in ("Jarvis", "Jarvis.", "Jarvis,", "Carvis" if lang == "tr" else "Jarvis!"):
                    for speed in (0.8, 0.95, 1.1, 1.3):
                        x = synth(spelling, v, lang, speed * rng.uniform(0.97, 1.03), steps=int(rng.integers(4, 9)))
                        if len(x) < 2000:
                            continue
                        name = f"pos_{n:05d}"
                        save(os.path.join(out, name_part, name + ".wav"), x)
                        man[name] = dict(kind="word", voice=v, lang=lang, spelling=spelling, speed=speed, seconds=len(x) / SR)
                        n += 1
            print("voice", v, n, flush=True)
    elif part == "hard":
        n = 0
        for v in VOICES:
            for w in LOOKALIKES:
                for lang in ("en", "tr"):
                    x = synth(w, v, lang, float(rng.choice([0.9, 1.0, 1.2])), steps=int(rng.integers(4, 9)))
                    if len(x) < 1500:
                        continue
                    name = f"hard_{n:05d}"
                    save(os.path.join(out, name_part, name + ".wav"), x)
                    man[name] = dict(kind="lookalike", voice=v, lang=lang, text=w, seconds=len(x) / SR)
                    n += 1
            print("voice", v, n, flush=True)
    else:  # neg: ordinary speech
        n_en = int(sys.argv[sys.argv.index("--count-en") + 1]) if "--count-en" in sys.argv else 160
        n_tr = int(sys.argv[sys.argv.index("--count-tr") + 1]) if "--count-tr" in sys.argv else 140
        en = en_sentences(rng, n_en)
        tr = tr_sentences(rng, n_tr)
        items = [(s, "en") for s in en] + [(s, "tr") for s in tr]
        rng.shuffle(items)
        n = 0
        total = 0.0
        for text, lang in items:
            v = VOICES[int(rng.integers(len(VOICES)))]
            x = synth(text, v, lang, float(rng.uniform(0.85, 1.25)), steps=int(rng.integers(4, 9)))
            if len(x) < 3000:
                continue
            name = f"neg_{n:05d}"
            save(os.path.join(out, name_part, name + ".wav"), x)
            man[name] = dict(kind="speech", voice=v, lang=lang, text=text[:80], seconds=len(x) / SR)
            total += len(x) / SR
            n += 1
            if n % 25 == 0:
                print(n, f"{total:.0f}s", flush=True)
    json.dump(man, open(os.path.join(out, name_part + ".json"), "w"), indent=1, ensure_ascii=False)
    print(f"{name_part}: {len(man)} clips")


if __name__ == "__main__":
    main()
