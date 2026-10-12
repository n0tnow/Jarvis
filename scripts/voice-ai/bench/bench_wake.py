#!/usr/bin/env python3
"""Wake-word benchmark over the synthetic fixtures (`fixtures.py`). SYNTHETIC WAKE TESTED - never a substitute for a human saying the word.

    python bench_wake.py <fixtures-dir> <model.onnx> [--vad 0.0]

For every file the detector is fed 80 ms frames exactly as the live helper does; the score trace is kept so that any threshold can be evaluated
afterwards. Output: per-class detection rate for a threshold sweep, detection latency (end of the spoken word -> first frame over the threshold),
false activations per hour on the negative set, and the real-time factor (CPU time / audio time).
"""
import json, os, sys, time
import numpy as np
from scipy.io import wavfile

FRAME = 1280


def load(path):
    sr, x = wavfile.read(path)
    assert sr == 16000
    return x.astype(np.int16)


def traces(model, x, vad_threshold=0.0):
    model.reset()
    out = []
    n = len(x) // FRAME * FRAME
    for i in range(0, n, FRAME):
        p = model.predict(x[i:i + FRAME])
        out.append(max(p.values()) if p else 0.0)
    return np.array(out)


SILERO = None


def vad_segments(x_int16, models_dir):
    """Speech segments [(start_s, end_s)] with the SAME hysteresis as jarvis_sentinel_worker (30 ms frames, start 2 x 0.5, end 150 ms below 0.35)."""
    import onnxruntime as ort
    global SILERO
    if SILERO is None:
        so = ort.SessionOptions(); so.intra_op_num_threads = 1; so.inter_op_num_threads = 1
        SILERO = ort.InferenceSession(os.path.join(models_dir, "silero_vad.onnx"), sess_options=so, providers=["CPUExecutionProvider"])
    h = np.zeros((2, 1, 64), np.float32); c = np.zeros((2, 1, 64), np.float32); sr = np.array(16000, np.int64)
    x = x_int16.astype(np.float32) / 32768.0
    segs, active, hits, quiet, start = [], False, 0, 0, 0.0
    for i in range(len(x) // 480):
        p, h, c = SILERO.run(None, {"input": x[i * 480:(i + 1) * 480][None, :], "h": h, "c": c, "sr": sr})
        p = float(p[0][0]); t = (i + 1) * 480 / 16000
        if not active:
            hits = hits + 1 if p >= 0.5 else 0
            if hits >= 2: active, quiet, start = True, 0, t - 0.06
        else:
            if p < 0.35:
                quiet += 30
                if quiet >= 150: active, hits = False, 0; segs.append((start, t))
            else: quiet = 0
    if active: segs.append((start, len(x) / 16000))
    return segs


def gated(trace, segs, thr, patience=2, max_segment=1.6):
    """Wake events (times) of a score trace under the production rules: threshold + patience, and the word must be UTTERANCE-INITIAL
    (the speech segment it belongs to began at most `max_segment` seconds before the event)."""
    events, over, refractory = [], 0, 0.0
    for i, s_ in enumerate(trace):
        t = (i + 1) * FRAME / 16000
        over = over + 1 if s_ >= thr else 0
        if over >= patience and t >= refractory:
            over = 0; refractory = t + 2.0
            seg = next(((a, b) for a, b in segs if a <= t + 0.05 and (b >= t - 0.4)), None)
            if seg is not None and t - seg[0] <= max_segment: events.append(t)
    return events


def main():
    fx, path = sys.argv[1], sys.argv[2]
    vad = float(sys.argv[sys.argv.index("--vad") + 1]) if "--vad" in sys.argv else 0.0
    if path.endswith(".npz"):                       # the JARVIS head (bare "Jarvis") on the frozen openWakeWord features
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
        from jarvis_wake_head import HeadMLP, WakeStream
        models_dir = os.environ["JARVIS_WAKE_MODELS"]            # folder with melspectrogram.onnx + embedding_model.onnx

        class HeadModel:
            def __init__(self):
                self.s = WakeStream(HeadMLP.load(path), models_dir)
            def reset(self):
                self.s.reset()
            def predict(self, frame):
                return {"jarvis": self.s.feed(frame)}
        model = HeadModel()
    else:
        from openwakeword.model import Model
        model = Model(wakeword_models=[path], inference_framework="onnx", vad_threshold=vad)
    man = json.load(open(os.path.join(fx, "manifest.json")))
    thresholds = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
    rows = {}
    cpu0, wall0, audio = time.process_time(), time.time(), 0.0
    cache_path = os.environ.get("JARVIS_BENCH_CACHE")
    cache = {}
    if cache_path and os.path.exists(cache_path):
        import pickle
        cache = pickle.load(open(cache_path, "rb"))
    for key, meta in man.items():
        if not key.startswith("wake_"):
            continue
        x = load(os.path.join(fx, key + ".wav"))
        audio += len(x) / 16000
        rows[key] = (meta, cache[key] if key in cache else traces(model, x))
    if cache_path:
        import pickle
        pickle.dump({k: v[1] for k, v in rows.items()}, open(cache_path, "wb"))
    cpu, wall = time.process_time() - cpu0, time.time() - wall0
    print(f"model {os.path.basename(path)} vad={vad}  audio {audio:.0f}s  cpu {cpu:.1f}s  RTF(cpu)={cpu / audio:.4f}  -> {100 * cpu / audio:.2f}% of one core when streaming real time\n")

    def group(pred):
        return {k: v for k, v in rows.items() if pred(v[0])}

    classes = {
        "pos all": group(lambda m: m["kind"] == "wake_pos"),
        "pos bare/normal": group(lambda m: m["kind"] == "wake_pos" and m.get("cls") == "bare" and m.get("level") == "normal"),
        "pos bare/quiet": group(lambda m: m["kind"] == "wake_pos" and m.get("cls") == "bare" and m.get("level") == "quiet"),
        "pos bare/noisy": group(lambda m: m["kind"] == "wake_pos" and m.get("cls") == "bare" and m.get("level") == "noisy"),
        "pos hey/normal": group(lambda m: m["kind"] == "wake_pos" and m.get("cls") == "hey" and m.get("level") == "normal"),
        "pos Turkish voice": group(lambda m: m["kind"] == "wake_pos" and m.get("voice") == "Yelda" and m.get("cls") != "command"),
        "pos Carvis": group(lambda m: m["kind"] == "wake_pos" and m.get("cls") == "tr-orthography"),
        "pos command": group(lambda m: m["kind"] == "wake_pos" and m.get("cls") == "command"),
    }
    print(f"{'class':20s} n   " + " ".join(f"{t:>5.1f}" for t in thresholds))
    for name, grp in classes.items():
        hits = [[float(tr.max() >= t) for t in thresholds] for _, (m, tr) in grp.items()]
        print(f"{name:20s} {len(grp):<3d} " + " ".join(f"{100 * np.mean([h[i] for h in hits]):5.0f}" for i in range(len(thresholds))) + "  (% detected)")
    # latency at 0.5
    print()
    for thr in (0.3, 0.5, 0.7):
        lat = []
        for k, (m, tr) in classes["pos all"].items():
            idx = np.where(tr >= thr)[0]
            if len(idx):
                lat.append((idx[0] + 1) * FRAME / 16000 - m["word_end"])
        if lat:
            print(f"latency after end of word @ {thr}: p50 {np.percentile(lat, 50) * 1000:.0f} ms  p90 {np.percentile(lat, 90) * 1000:.0f} ms  min {min(lat) * 1000:.0f}  max {max(lat) * 1000:.0f}  (n={len(lat)}; negative = fired before the word ended)")
    # false activations
    print()
    neg = group(lambda m: m["kind"] == "wake_neg")
    hours = sum(m["seconds"] for m, _ in neg.values()) / 3600
    print(f"negative audio: {sum(m['seconds'] for m, _ in neg.values()):.0f} s ({hours:.3f} h) in {len(neg)} files")
    print(f"{'threshold':10s} " + " ".join(f"{t:>6.1f}" for t in thresholds))
    print(f"{'FA files':10s} " + " ".join(f"{sum(1 for _, (m, tr) in neg.items() if tr.max() >= t):6d}" for t in thresholds))
    print(f"{'FA / hour':10s} " + " ".join(f"{sum(int(((tr >= t) & (np.concatenate([[0], tr[:-1]]) < t)).sum()) for _, (m, tr) in neg.items()) / hours:6.1f}" for t in thresholds))
    for cls in ("lookalike", "speech-en", "speech-tr", "noise"):
        sub = {k: v for k, v in neg.items() if v[0].get("cls") == cls}
        hrs = sum(m["seconds"] for m, _ in sub.values()) / 3600
        print(f"  {cls:10s} n={len(sub):<3d} files over thr: " + " ".join(f"{sum(1 for _, (m, tr) in sub.items() if tr.max() >= t):4d}" for t in thresholds) + f"   | events/hour ({hrs * 60:.1f} min): " +
              " ".join(f"{sum(int(((tr >= t) & (np.concatenate([[0], tr[:-1]]) < t)).sum()) for _, (m, tr) in sub.items()) / max(hrs, 1e-9):6.1f}" for t in thresholds))
    worst = sorted(((tr.max(), k) for k, (m, tr) in neg.items()), reverse=True)[:6]
    print("highest negative scores:", [(round(float(s), 2), k.split('/')[1]) for s, k in worst])
    ctx = group(lambda m: m["kind"] == "wake_ctx")
    print("\nspeech containing the literal word (self-speech class):")
    for k, (m, tr) in ctx.items():
        print(f"  max {tr.max():.2f}  {m['phrase'][:60]}")
    # production gating: threshold + patience 2 + utterance-initial constraint (needs silero_vad.onnx in JARVIS_WAKE_MODELS)
    mdir = os.environ.get("JARVIS_WAKE_MODELS")
    if mdir and os.path.exists(os.path.join(mdir, "silero_vad.onnx")):
        print("\nPRODUCTION RULES (threshold, patience 2, utterance-initial: speech segment <= 1.6 s old; the shipped defaults are 0.9 and patience 3 — see tune_wake_rules.py):")
        segs = {k: vad_segments(load(os.path.join(fx, k + ".wav")), mdir) for k in rows if rows[k][0]["kind"] in ("wake_neg", "wake_pos")}
        for thr in (0.6, 0.7, 0.8, 0.9):
            pos = [k for k in rows if rows[k][0]["kind"] == "wake_pos" and rows[k][0].get("cls") in ("bare", "tr-orthography", "command")]
            hit = sum(1 for k in pos if gated(rows[k][1], segs[k], thr))
            by_level = {lv: (sum(1 for k in pos if rows[k][0].get("level") == lv and rows[k][0].get("cls") == "bare" and gated(rows[k][1], segs[k], thr)),
                             sum(1 for k in pos if rows[k][0].get("level") == lv and rows[k][0].get("cls") == "bare")) for lv in ("normal", "quiet", "noisy")}
            negs = [k for k in rows if rows[k][0]["kind"] == "wake_neg"]
            ev = {c: sum(len(gated(rows[k][1], segs[k], thr)) for k in negs if rows[k][0].get("cls") == c) for c in ("lookalike", "speech-en", "speech-tr", "noise")}
            hrs = {c: sum(rows[k][0]["seconds"] for k in negs if rows[k][0].get("cls") == c) / 3600 for c in ev}
            lat = [gated(rows[k][1], segs[k], thr)[0] - rows[k][0]["word_end"] for k in pos if gated(rows[k][1], segs[k], thr)]
            print(f"  thr {thr}: positives {hit}/{len(pos)} (bare: " + ", ".join(f"{lv} {a}/{b}" for lv, (a, b) in by_level.items()) + f") | latency p50 {np.percentile(lat, 50) * 1000:.0f} ms | "
                  f"false events: look-alike {ev['lookalike']} ({hrs['lookalike'] * 60:.1f} min), speech-en {ev['speech-en']} ({hrs['speech-en'] * 60:.1f} min), speech-tr {ev['speech-tr']} ({hrs['speech-tr'] * 60:.1f} min), noise {ev['noise']}")
        ctx = [k for k in rows if rows[k][0]["kind"] == "wake_ctx"]
        print("  literal word inside longer speech (self-speech class), events at thr 0.8:", {rows[k][0]["phrase"][:28]: len(gated(rows[k][1], vad_segments(load(os.path.join(fx, k + ".wav")), mdir), 0.8)) for k in ctx})
    # per-voice misses at 0.5
    miss = [(k.split('/')[1], round(float(tr.max()), 2)) for k, (m, tr) in classes["pos all"].items() if tr.max() < 0.5]
    print(f"\npositives below 0.5: {len(miss)} of {len(classes['pos all'])}")
    for k, s in miss[:40]:
        print("  ", k, s)


if __name__ == "__main__":
    main()
