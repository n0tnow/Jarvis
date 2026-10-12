#!/usr/bin/env python3
"""Sweeps the production wake rules (threshold x patience x utterance-initial segment length) over cached score traces.

    JARVIS_BENCH_CACHE=<traces.pkl> JARVIS_WAKE_MODELS=<wake dir> python tune_wake_rules.py <fixtures-dir>

`traces.pkl` is written by bench_wake.py. Silero speech segments are computed once and cached next to it. Prints positives detected and false events per hour of
ordinary synthetic speech for every combination, so the shipped defaults (threshold 0.9, patience 2, segment <= 1.6 s) are an evidence-based choice.
"""
import json, os, pickle, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from bench_wake import gated, vad_segments, load  # noqa: E402

fx = sys.argv[1]
traces = pickle.load(open(os.environ["JARVIS_BENCH_CACHE"], "rb"))
models = os.environ["JARVIS_WAKE_MODELS"]
man = {k: v for k, v in json.load(open(os.path.join(fx, "manifest.json"))).items() if k.startswith("wake_")}
seg_path = os.environ["JARVIS_BENCH_CACHE"] + ".segments"
segs = pickle.load(open(seg_path, "rb")) if os.path.exists(seg_path) else {}
for k in man:
    if k not in segs and k in traces:
        segs[k] = vad_segments(load(os.path.join(fx, k + ".wav")), models)
pickle.dump(segs, open(seg_path, "wb"))
pos = [k for k, m in man.items() if m["kind"] == "wake_pos" and m.get("cls") in ("bare", "tr-orthography", "command")]
neg = {c: [k for k, m in man.items() if m["kind"] == "wake_neg" and m.get("cls") == c] for c in ("lookalike", "speech-en", "speech-tr", "noise")}
hours = {c: sum(man[k]["seconds"] for k in ks) / 3600 for c, ks in neg.items()}
print(f"ordinary speech: en {hours['speech-en'] * 60:.0f} min, tr {hours['speech-tr'] * 60:.0f} min | positives {len(pos)}")
print(f"{'thr':>5} {'pat':>3} {'seg':>4}  {'positives':>10}  {'FA en':>6} {'FA tr':>6}  {'FA/h speech':>11}  {'look-alike':>10}  latency p50")
for thr in (0.8, 0.9, 0.95, 0.98):
    for pat in (2, 3, 4):
        for seg in (1.2, 1.6):
            hit = sum(1 for k in pos if gated(traces[k], segs[k], thr, pat, seg))
            fa = {c: sum(len(gated(traces[k], segs[k], thr, pat, seg)) for k in neg[c]) for c in ("speech-en", "speech-tr", "lookalike")}
            rate = (fa["speech-en"] + fa["speech-tr"]) / (hours["speech-en"] + hours["speech-tr"])
            lat = [gated(traces[k], segs[k], thr, pat, seg)[0] - man[k]["word_end"] for k in pos if gated(traces[k], segs[k], thr, pat, seg)]
            print(f"{thr:5.2f} {pat:3d} {seg:4.1f}  {hit:4d}/{len(pos):<4d}  {fa['speech-en']:6d} {fa['speech-tr']:6d}  {rate:11.2f}  {fa['lookalike']:4d}/90     {np.percentile(lat, 50) * 1000:6.0f} ms")
