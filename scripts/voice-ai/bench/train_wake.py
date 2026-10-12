#!/usr/bin/env python3
"""Trains the JARVIS wake-word head on SYNTHETIC speech (see `gen_wake_train.py`) and exports it.

    python train_wake.py <train-dir> <head-out.npz> --models <dir with melspectrogram.onnx embedding_model.onnx> [--epochs 30] [--hidden 96] [--seed 1] [--hard-rounds 1]

* positives: the spoken word placed in a noisy/reverberant clip (optionally after other speech and before a spoken command); a classifier window counts
  as POSITIVE when it ends within [-50 ms, +300 ms] of the end of the word (the moment the word has just been said)
* negatives: every other window of ordinary speech (en/tr), look-alike words, noise-only clips and the windows of positive clips where the word has
  barely begun or is long past
* hard-negative rounds: the trained head is run over a freshly composed negative set, false activations are added and training repeats
The feature extractor (mel + speech-embedding ONNX) is frozen openWakeWord (Apache-2.0); only the small head is learned. Pure numpy (no PyTorch).
"""
import json, os, sys, time
import numpy as np
from scipy.io import wavfile
from scipy.signal import fftconvolve

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from jarvis_wake_head import FRAME, WINDOW, EMBED_DIM, HeadMLP, embedding_end_seconds  # noqa: E402
from jarvis_audio_features import SpeechFeatures  # noqa: E402

SR = 16000
CLIP_S = 6.0


def pink(n, rng):
    f = np.fft.rfft(rng.standard_normal(n).astype(np.float32))
    k = np.arange(len(f), dtype=np.float32); k[0] = 1
    x = np.fft.irfft(f / np.sqrt(k), n).astype(np.float32)
    return x / (np.std(x) + 1e-9)


def noise_like(n, rng, level_db):
    kind = rng.integers(4)
    if kind == 0:
        x = pink(n, rng)
    elif kind == 1:
        x = rng.standard_normal(n).astype(np.float32)
    elif kind == 2:                                   # mains hum + harmonics
        t = np.arange(n) / SR
        x = sum(np.sin(2 * np.pi * 50 * h * t + rng.uniform(0, 6)) / h for h in (1, 2, 3)).astype(np.float32) + 0.2 * pink(n, rng)
    else:                                             # keyboard-ish clicks over a floor
        x = 0.1 * pink(n, rng)
        for t in rng.uniform(0, n / SR, int(rng.integers(3, 25))):
            i = int(t * SR)
            if i + 400 < n:
                x[i:i + 400] += (rng.standard_normal(400) * np.exp(-np.arange(400) / 50) * 2).astype(np.float32)
    x = x / (np.std(x) + 1e-9)
    return x * 10 ** (level_db / 20)


def reverb(x, rng):
    t = rng.uniform(0.08, 0.45)
    n = int(t * SR)
    ir = (rng.standard_normal(n) * np.exp(-6.9 * np.arange(n) / n)).astype(np.float32)
    ir[0] = 1.0
    y = fftconvolve(x, ir * 0.35 / np.sqrt(np.sum(ir ** 2)))[:len(x)]
    return (0.65 * x + y).astype(np.float32)


def load_dir(d, man):
    out = {}
    for name, meta in man.items():
        sr, x = wavfile.read(os.path.join(d, name + ".wav"))
        out[name] = (x.astype(np.float32) / 32768.0, meta)
    return out


def place_clip(parts, rng, floor_db=None):
    """parts: list of (audio, gap_before_s, tag). Returns (clip_int16 of CLIP_S, tags {tag: (start_s, end_s)})."""
    n = int(CLIP_S * SR)
    floor_db = rng.uniform(-68, -48) if floor_db is None else floor_db
    clip = noise_like(n, rng, floor_db)
    t = rng.uniform(0.3, 1.2)
    marks = {}
    for audio, gap, tag in parts:
        t += gap
        s = int(t * SR)
        if s + len(audio) > n - int(0.2 * SR):
            audio = audio[: max(0, n - int(0.2 * SR) - s)]
        clip[s:s + len(audio)] += audio
        marks.setdefault(tag, (t, t + len(audio) / SR))
        t += len(audio) / SR
    return clip, marks


def normalise(x, peak_db):
    p = np.max(np.abs(x)) + 1e-9
    return x * 10 ** (peak_db / 20) / p


def vocal_tract(x, rng):
    """Resampling by r changes pitch and tempo together (≈ a speaker of a different size): cheap timbre diversity beyond the ten built-in voices."""
    from math import gcd
    from scipy.signal import resample_poly
    r = float(rng.choice([0.82, 0.88, 0.94, 1.0, 1.0, 1.07, 1.14, 1.22]))
    if r == 1.0 or len(x) < 400:
        return x
    up, down = int(round(r * 100)), 100
    g = gcd(up, down)
    return resample_poly(x, up // g, down // g).astype(np.float32)


def augment_speech(x, rng, peak_range=(-26, -4)):
    if rng.random() < 0.7:
        x = vocal_tract(x, rng)
    x = normalise(x, rng.uniform(*peak_range))
    if rng.random() < 0.3:
        x = reverb(x, rng)
    return x


def embed(clips_i16, feats):
    return np.stack([feats.embed_clip(c) for c in clips_i16])          # (n, frames, 96)


def windows_of(e, j_list):
    return np.stack([e[j - WINDOW + 1:j + 1].reshape(-1) for j in j_list])


def to_i16(x):
    return (np.clip(x, -1, 1) * 32767).astype(np.int16)


def load_sets(train_dir, names):
    out = {}
    for n in names:
        man = json.load(open(os.path.join(train_dir, n + ".json")))
        for k, v in load_dir(os.path.join(train_dir, n), man).items():
            out[n + "/" + k] = v
    return out


def build(train_dir, rng, feats, speech_sets, n_pos_aug=2):
    pos = json.load(open(os.path.join(train_dir, "pos.json")))
    hard = json.load(open(os.path.join(train_dir, "hard.json")))
    words = load_dir(os.path.join(train_dir, "pos"), pos)
    hards = load_dir(os.path.join(train_dir, "hard"), hard)
    speech = load_sets(train_dir, speech_sets)
    speech_list = [v[0] for v in speech.values()]
    X, y = [], []

    def stride_ok(j):
        return True

    def add_clip(clip, marks, positive_tag=None):
        e = embed([to_i16(clip)], feats)[0]
        n = len(e)
        for j in range(WINDOW - 1, n):
            t_end = embedding_end_seconds(j)
            label = None
            if positive_tag is not None and positive_tag in marks:
                ws, we = marks[positive_tag]
                if we - 0.05 <= t_end <= we + 0.30:
                    label = 1
                elif t_end < ws + 0.35 or t_end > we + 0.9:
                    label = 0
            else:
                label = 0
            if label is not None and (label == 1 or stride_ok(j)):
                X.append(e[j - WINDOW + 1:j + 1].reshape(-1).astype(np.float16)); y.append(label)

    t0 = time.time()
    names = list(words)
    for k, name in enumerate(names):
        w = words[name][0]
        for a in range(n_pos_aug):
            parts = []
            if rng.random() < 0.3:                                                       # other speech right before the word
                s = speech_list[int(rng.integers(len(speech_list)))]
                seg = s[: int(rng.uniform(0.6, 1.8) * SR)]
                parts.append((augment_speech(seg, rng), 0.0, "pre"))
            parts.append((augment_speech(w, rng), rng.uniform(0.15, 0.6) if parts else 0.0, "word"))
            if rng.random() < 0.5:                                                       # a command after it
                s = speech_list[int(rng.integers(len(speech_list)))]
                parts.append((augment_speech(s[: int(rng.uniform(0.8, 2.2) * SR)], rng), rng.uniform(0.15, 0.6), "post"))
            clip, marks = place_clip(parts, rng)
            snr = rng.choice([None, 20, 12, 8])
            if snr is not None:
                clip = clip + noise_like(len(clip), rng, 20 * np.log10(np.std(clip) + 1e-9) - snr)
            add_clip(clip, marks, "word")
        if k % 200 == 0:
            print(f"  positives {k}/{len(names)}  windows {len(y)}  {time.time() - t0:.0f}s", flush=True)
    npos = int(sum(y))
    # look-alikes and speech as negatives (also composited in noise)
    for name, (x, meta) in hards.items():
        for a in range(2):
            clip, marks = place_clip([(augment_speech(x, rng), 0.0, "w")], rng)
            add_clip(clip, marks, None)
    print(f"  look-alike negatives done, windows {len(y)}  {time.time() - t0:.0f}s", flush=True)
    stride = {"n": 0}
    stride_ok = lambda j: (j % 2 == 0)      # speech windows overlap almost completely: every other one is enough
    for name, (x, meta) in speech.items():
        for a in range(2 if len(x) < CLIP_S * SR * 1.5 else 3):
            start = 0 if a == 0 else int(rng.uniform(0, max(1, len(x) - (CLIP_S - 0.6) * SR)))
            seg = x[start: start + int((CLIP_S - 0.6) * SR)]
            clip, marks = place_clip([(augment_speech(seg, rng), 0.0, "s")], rng)
            add_clip(clip, marks, None)
    for _ in range(60):                                                                  # noise-only clips
        clip = noise_like(int(CLIP_S * SR), rng, rng.uniform(-60, -25))
        add_clip(clip, {}, None)
    print(f"  total windows {len(y)} (positives {npos})  {time.time() - t0:.0f}s", flush=True)
    return np.array(X, dtype=np.float16), np.array(y, dtype=np.float32)


class Trainer:
    def __init__(self, hidden, seed):
        self.hidden, self.rng = hidden, np.random.default_rng(seed)

    def fit(self, X, y, epochs=30, lr=2e-3, pos_weight=6.0, l2=1e-4, dropout=0.25, verbose=True):
        n, d = X.shape
        total = np.zeros(d, np.float64); total2 = np.zeros(d, np.float64)
        for i in range(0, n, 20000):
            blk = X[i:i + 20000].astype(np.float64)
            total += blk.sum(0); total2 += (blk ** 2).sum(0)
        mean = (total / n).astype(np.float32); std = (np.sqrt(np.maximum(total2 / n - (total / n) ** 2, 0)) + 1e-6).astype(np.float32)
        Xn = X
        rng, H = self.rng, self.hidden
        w1 = (rng.standard_normal((d, H)) * np.sqrt(2.0 / d)).astype(np.float32); b1 = np.zeros(H, np.float32)
        w2 = (rng.standard_normal(H) * np.sqrt(1.0 / H)).astype(np.float32); b2 = np.float32(-3.0)
        params = [w1, b1, w2, np.array(b2)]
        m = [np.zeros_like(p) for p in params]; v = [np.zeros_like(p) for p in params]
        step = 0
        for ep in range(epochs):
            perm = rng.permutation(n)
            loss_sum = 0.0
            for i in range(0, n, 512):
                idx = perm[i:i + 512]
                xb, yb = (Xn[idx].astype(np.float32) - mean) / std, y[idx]
                h_pre = xb @ params[0] + params[1]
                h = np.maximum(h_pre, 0)
                mask = (rng.random(h.shape) > dropout).astype(np.float32) / (1 - dropout)
                hd = h * mask
                z = hd @ params[2] + params[3]
                p = 1 / (1 + np.exp(-np.clip(z, -30, 30)))
                wgt = np.where(yb > 0.5, pos_weight, 1.0).astype(np.float32)
                loss_sum += float(np.sum(wgt * -(yb * np.log(p + 1e-7) + (1 - yb) * np.log(1 - p + 1e-7))))
                dz = wgt * (p - yb) / len(idx)
                g2 = hd.T @ dz; gb2 = np.array(dz.sum())
                dh = np.outer(dz, params[2]) * mask * (h_pre > 0)
                g1 = xb.T @ dh + l2 * params[0]; gb1 = dh.sum(0)
                grads = [g1, gb1, g2, gb2]
                step += 1
                for k in range(4):
                    m[k] = 0.9 * m[k] + 0.1 * grads[k]; v[k] = 0.999 * v[k] + 0.001 * grads[k] ** 2
                    mh = m[k] / (1 - 0.9 ** step); vh = v[k] / (1 - 0.999 ** step)
                    params[k] = params[k] - lr * (0.5 ** (ep // 10)) * mh / (np.sqrt(vh) + 1e-8)
            if verbose and (ep % 5 == 4 or ep == epochs - 1):
                print(f"  epoch {ep + 1:2d} loss {loss_sum / n:.4f}", flush=True)
        return HeadMLP(params[0], params[1], params[2], np.float32(params[3]), mean.astype(np.float32), std.astype(np.float32))


def save_head(head, path):
    np.savez(path, w1=head.w1, b1=head.b1, w2=head.w2, b2=head.b2, mean=head.mean, std=head.std)


def stream_scores(head, x_i16, models_dir):
    from jarvis_wake_head import WakeStream
    s = WakeStream(head, models_dir)
    s.reset()
    n = len(x_i16) // FRAME * FRAME
    return np.array([s.feed(x_i16[i:i + FRAME]) for i in range(0, n, FRAME)])


def main():
    train_dir, out = sys.argv[1], sys.argv[2]
    def arg(name, default):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default
    epochs, hidden, seed = int(arg("--epochs", 25)), int(arg("--hidden", 96)), int(arg("--seed", 1))
    train_sets = arg("--neg-sets", "neg").split(",")
    mine_sets = [m for m in arg("--mine-sets", "").split(",") if m]
    pos_weight = float(arg("--pos-weight", 6.0))
    feats = SpeechFeatures(arg("--models", None))
    rng = np.random.default_rng(seed)
    t0 = time.time()
    X, y = build(train_dir, rng, feats, train_sets)
    head = Trainer(hidden, seed).fit(X, y, epochs=epochs, pos_weight=pos_weight)
    save_head(head, out)
    print(f"trained in {time.time() - t0:.0f}s -> {out}  positives {int(y.sum())} negatives {int((1 - y).sum())}", flush=True)
    for r, pool in enumerate(mine_sets):
        # hard-negative mining on speech the head has never seen
        Xn, _ = build_negatives_only(train_dir, np.random.default_rng(seed + 100 + r), feats, [pool])
        p = np.concatenate([head.predict(Xn[i:i + 20000].astype(np.float32)) for i in range(0, len(Xn), 20000)])
        hard_idx = np.where(p > 0.3)[0]
        print(f"round {r + 1} ({pool}): {len(hard_idx)} false activations of {len(Xn)} fresh negative windows", flush=True)
        if len(hard_idx) == 0:
            continue
        X = np.concatenate([X, np.repeat(Xn[hard_idx], 3, axis=0)]); y = np.concatenate([y, np.zeros(len(hard_idx) * 3, np.float32)])
        head = Trainer(hidden, seed + r + 1).fit(X, y, epochs=epochs, pos_weight=pos_weight)
        save_head(head, out)
    print("saved", out)


def build_negatives_only(train_dir, rng, feats, speech_sets):
    hard = json.load(open(os.path.join(train_dir, "hard.json")))
    hards = load_dir(os.path.join(train_dir, "hard"), hard)
    speech = load_sets(train_dir, speech_sets)
    X = []
    items = [(v[0], False) for v in speech.values()] + [(v[0], True) for v in list(hards.values())[:600]]
    for x, short in items:
        seg = x if short else x[int(rng.uniform(0, max(1, len(x) - 4 * SR))):][: int(4.5 * SR)]
        parts = [(augment_speech(seg, rng), 0.0, "s")]
        if short:                                             # look-alike inside a sentence
            s = speech[list(speech)[int(rng.integers(len(speech)))]][0]
            parts = [(augment_speech(s[: int(rng.uniform(0.5, 1.5) * SR)], rng), 0.0, "p"), (augment_speech(seg, rng), 0.2, "s")]
        clip, _ = place_clip(parts, rng)
        e = embed([to_i16(clip)], feats)[0]
        for j in range(WINDOW - 1, len(e), 2):
            X.append(e[j - WINDOW + 1:j + 1].reshape(-1).astype(np.float16))
    return np.array(X, dtype=np.float16), np.zeros(len(X), np.float32)


if __name__ == "__main__":
    main()
