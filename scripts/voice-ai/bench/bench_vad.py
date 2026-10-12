#!/usr/bin/env python3
"""VAD / endpoint benchmark over the synthetic fixtures (`fixtures.py`, folder `vad/`).

    python bench_vad.py <fixtures-dir> <silero_vad.onnx>

Compares two voice-activity detectors on the same files:
  * `silero`  - Silero VAD (MIT, 1.8 MB ONNX) in onnxruntime, 30 ms frames, threshold 0.5
  * `energy`  - the dependency-free adaptive-energy detector JARVIS implements natively in Swift (`EnergyVAD`): 20 ms frames, pre-emphasis, tracked noise
                floor, margin above the floor + absolute minimum, N consecutive frames to start.  This file is the REFERENCE the Swift unit tests mirror.
and reports speech-start latency, false speech in silence/noise, the longest silence INSIDE speech (pauses), and the premature-endpoint matrix for a
sweep of end-of-turn silence thresholds.
"""
import json, os, sys, time
import numpy as np
from scipy.io import wavfile

SR = 16000


def load(p):
    sr, x = wavfile.read(p)
    return x.astype(np.float32) / 32768.0


# ----- reference energy VAD (mirrored in Swift) -------------------------------------------------------------------------------------------------
class EnergyVAD:
    FRAME = 320                 # 20 ms
    MARGIN_DB = 10.0            # speech must exceed the tracked noise floor by this much
    MIN_DB = -50.0              # ... and be louder than this absolute level (dBFS of the pre-emphasised frame)
    START_FRAMES = 3            # 60 ms of consecutive speech frames
    FLOOR_RISE_DB_PER_S = 3.0   # the floor may rise this fast (slowly follows a louder room)
    FLOOR_INIT_DB = -60.0

    def __init__(self):
        self.prev = 0.0
        self.floor = self.FLOOR_INIT_DB
        self.run = 0
        self.active = False

    def process(self, frame):
        x = np.asarray(frame, dtype=np.float64)
        y = np.empty_like(x)
        y[0] = x[0] - 0.97 * self.prev
        y[1:] = x[1:] - 0.97 * x[:-1]
        self.prev = x[-1]
        db = 10 * np.log10(np.mean(y * y) + 1e-12)
        hot = db > max(self.floor + self.MARGIN_DB, self.MIN_DB)
        if not hot:
            # only quiet frames move the floor: down quickly, up slowly
            if db < self.floor:
                self.floor += 0.3 * (db - self.floor)
            else:
                self.floor = min(self.floor + self.FLOOR_RISE_DB_PER_S * self.FRAME / SR, db)
        self.run = self.run + 1 if hot else 0
        if self.run >= self.START_FRAMES:
            self.active = True
        if not hot:
            self.active = False if self.run == 0 and self.active and False else self.active
        return hot


def run_energy(x):
    v = EnergyVAD()
    n = len(x) // v.FRAME
    return np.array([v.process(x[i * v.FRAME:(i + 1) * v.FRAME]) for i in range(n)], dtype=bool), v.FRAME / SR


def run_silero(x, model_path):
    import onnxruntime as ort
    so = ort.SessionOptions(); so.intra_op_num_threads = 1; so.inter_op_num_threads = 1
    s = ort.InferenceSession(model_path, sess_options=so, providers=["CPUExecutionProvider"])
    h = np.zeros((2, 1, 64), np.float32); c = np.zeros((2, 1, 64), np.float32)
    sr = np.array(16000, np.int64)
    out = []
    n = len(x) // 480
    for i in range(n):
        chunk = x[i * 480:(i + 1) * 480][None, :].astype(np.float32)
        p, h, c = s.run(None, {"input": chunk, "h": h, "c": c, "sr": sr})
        out.append(float(p[0][0]))
    return np.array(out) > 0.5, 480 / SR


def runs(mask, step):
    """(start, end) seconds of consecutive True runs, joining gaps shorter than 80 ms."""
    segs, i, n = [], 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            segs.append([i * step, j * step])
            i = j
        else:
            i += 1
    merged = []
    for s in segs:
        if merged and s[0] - merged[-1][1] < 0.08:
            merged[-1][1] = s[1]
        else:
            merged.append(s)
    return [m for m in merged if m[1] - m[0] >= 0.06]


def main():
    fx, model = sys.argv[1], sys.argv[2]
    man = {k: v for k, v in json.load(open(os.path.join(fx, "manifest.json"))).items() if k.startswith("vad/")}
    detectors = {"energy": lambda x: run_energy(x), "silero": lambda x: run_silero(x, model)}
    thresholds = [0.4, 0.6, 0.8, 1.0, 1.2, 1.5, 2.0]
    for dname, det in detectors.items():
        print(f"\n=== {dname} ===")
        t0, cpu0, audio = time.time(), time.process_time(), 0.0
        results = {}
        for key, meta in man.items():
            x = load(os.path.join(fx, key + ".wav"))
            audio += len(x) / SR
            mask, step = det(x)
            results[key] = (meta, runs(mask, step))
        cpu = time.process_time() - cpu0
        print(f"audio {audio:.0f}s  cpu {cpu:.2f}s  -> {100 * cpu / audio:.2f}% of one core streaming (numpy/onnx, single thread; Swift will be cheaper for energy)")
        print(f"{'fixture':22s} {'truth segments':34s} detected segments")
        for key, (meta, segs) in results.items():
            truth = [(s[0], s[1]) for s in meta["speech"]]
            print(f"{key[4:]:22s} " + str([(round(a, 2), round(b, 2)) for a, b in truth])[:34].ljust(34) + " " + str([(round(a, 2), round(b, 2)) for a, b in segs])[:110])
        # start latency / end offset where one utterance exists
        starts, ends = [], []
        for key, (meta, segs) in results.items():
            if not meta["speech"] or not segs:
                continue
            ts, te = meta["speech"][0][0], meta["speech"][-1][1]
            starts.append(segs[0][0] - ts); ends.append(segs[-1][1] - te)
        print(f"speech start error: median {np.median(starts) * 1000:.0f} ms  max {max(starts) * 1000:.0f} ms | speech end error: median {np.median(ends) * 1000:.0f} ms  min {min(ends) * 1000:.0f} ms max {max(ends) * 1000:.0f} ms")
        fp = [k for k, (m, s) in results.items() if not m["speech"] and s]
        print("false speech in silence/noise fixtures:", fp or "none")
        # premature endpoint matrix: an endpoint fires when silence >= T after speech; premature when it fires inside the designed pause
        print("\nend-of-turn silence threshold -> pause fixtures cut in two (premature) | latency after the true end of the last word")
        print(f"{'T (s)':>6s}  " + "  ".join(f"{k[4:]:>16s}" for k in results if len(results[k][0]["speech"]) == 2) + "   latency median")
        for T in thresholds:
            cells, lat = [], []
            for key, (meta, segs) in results.items():
                sp = meta["speech"]
                if len(sp) == 2:
                    pause = sp[1][0] - sp[0][1]
                    inner = [segs[i + 1][0] - segs[i][1] for i in range(len(segs) - 1)]
                    cut = bool(inner) and max(inner) >= T
                    cells.append("CUT" if cut else "ok")
                if len(sp) >= 1 and segs:
                    # the turn ends T after the last detected speech
                    lat.append(max(segs[-1][1] - sp[-1][1], 0) + T)
            print(f"{T:6.1f}  " + "  ".join(f"{c:>16s}" for c in cells) + f"   {np.median(lat) * 1000:.0f} ms")


if __name__ == "__main__":
    main()
