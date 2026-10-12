#!/usr/bin/env python3
"""JARVIS sentinel worker (V0.8): the LOCAL wake-word detector and the voice-activity detector (VAD), in one tiny process.

Launched and supervised by JARVIS only (never by hand), fully offline, no network, no API key. It receives 16 kHz mono int16 audio from JARVIS,
keeps only the few seconds of mel/embedding/VAD state the two models need IN MEMORY (nothing is ever written to disk; no transcript exists here),
and answers with small events. It exits as soon as stdin closes, so it cannot outlive JARVIS.

Models (all small ONNX, CPU, one thread):
  * wake: openWakeWord's frozen mel-spectrogram + speech-embedding models (Apache-2.0)  +  the JARVIS head (`jarvis_head.npz`, trained on synthetic speech)
  * VAD : Silero VAD v4-style ONNX (MIT), 30 ms frames

Protocol (one JSON object per line)
  in : {"op":"audio","pcm":"<base64 int16 LE mono 16 kHz>"}   any length; the worker re-frames it
       {"op":"config","wake":true|false,"vad":true|false,"threshold":0.8,"patience":2,"vad_start":0.5,"vad_end":0.35,"vad_hangover_ms":150}
       {"op":"reset"}          forget the audio history (after a gap in the stream)
       {"op":"stats"}  {"op":"ping"}  {"op":"shutdown"}
  out: {"type":"ready","load_seconds":0.4,"wake_model":"jarvis_head","vad_model":"silero","onnxruntime":"1.31.0"}
       {"type":"wake","score":0.93,"stream_ms":123456,"cpu_ms":..}
       {"type":"vad","speech":true|false,"stream_ms":..,"p":0.91}                        (transitions only)
       {"type":"stats","audio_s":..,"cpu_s":..,"wake_frames":..,"vad_frames":..,"max_wake_score":..}
       {"type":"pong"}   {"type":"error","message":".."}
stdout carries ONLY protocol lines; anything libraries print goes to stderr.
"""
import base64
import json
import os
import sys
import time

_proto = sys.stdout
sys.stdout = sys.stderr
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")

SAMPLE_RATE = 16000
WAKE_FRAME = 1280          # 80 ms
VAD_FRAME = 480            # 30 ms
MAX_LINE = 1 << 20          # a protocol line longer than 1 MiB is ignored


def emit(obj):
    _proto.write(json.dumps(obj, ensure_ascii=False) + "\n")
    _proto.flush()


class Sentinel:
    def __init__(self, models_dir):
        import numpy as np
        import onnxruntime as ort
        here = os.path.dirname(os.path.abspath(__file__))
        sys.path.insert(0, here)
        from jarvis_wake_head import HeadMLP, WakeStream
        self.np = np
        self.ort = ort
        self.wake = WakeStream(HeadMLP.load(os.path.join(models_dir, "jarvis_head.npz")), models_dir)
        so = ort.SessionOptions()
        so.intra_op_num_threads = 1
        so.inter_op_num_threads = 1
        self.vad_session = ort.InferenceSession(os.path.join(models_dir, "silero_vad.onnx"), sess_options=so, providers=["CPUExecutionProvider"])
        self.sr = np.array(16000, dtype=np.int64)
        self.reset()
        self.cfg = {"wake": True, "vad": True, "threshold": 0.9, "patience": 3, "vad_start": 0.5, "vad_end": 0.35, "vad_hangover_ms": 150}
        self.stream_samples = 0
        self.wake_frames = 0
        self.vad_frames = 0
        self.max_score = 0.0

    def reset(self):
        np = self.np
        self.buf = np.zeros(0, dtype=np.int16)
        self.vad_buf = np.zeros(0, dtype=np.float32)
        self.h = np.zeros((2, 1, 64), dtype=np.float32)
        self.c = np.zeros((2, 1, 64), dtype=np.float32)
        self.wake.reset()
        self.over = 0
        self.refractory_until = 0
        self.vad_speech = False
        self.vad_hits = 0
        self.vad_quiet_ms = 0

    def feed(self, pcm_bytes):
        np = self.np
        x = np.frombuffer(pcm_bytes[: len(pcm_bytes) // 2 * 2], dtype="<i2").astype(np.int16)
        if x.size == 0:
            return
        start_sample = self.stream_samples
        self.stream_samples += x.size
        if self.cfg["vad"]:
            self.vad_buf = np.concatenate([self.vad_buf, x.astype(np.float32) / 32768.0])
            while len(self.vad_buf) >= VAD_FRAME:
                chunk, self.vad_buf = self.vad_buf[:VAD_FRAME], self.vad_buf[VAD_FRAME:]
                p, self.h, self.c = self.vad_session.run(None, {"input": chunk[None, :], "h": self.h, "c": self.c, "sr": self.sr})
                self.vad_frames += 1
                self._vad_step(float(p[0][0]), start_sample)
        if self.cfg["wake"]:
            self.buf = np.concatenate([self.buf, x])
            while len(self.buf) >= WAKE_FRAME:
                frame, self.buf = self.buf[:WAKE_FRAME], self.buf[WAKE_FRAME:]
                score = self.wake.feed(frame)
                self.wake_frames += 1
                self.max_score = max(self.max_score, score)
                self._wake_step(score)

    def _vad_step(self, p, base):
        c = self.cfg
        if not self.vad_speech:
            self.vad_hits = self.vad_hits + 1 if p >= c["vad_start"] else 0
            if self.vad_hits >= 2:                                     # 60 ms of speech
                self.vad_speech = True
                self.vad_quiet_ms = 0
                emit({"type": "vad", "speech": True, "stream_ms": int(self.stream_samples * 1000 / SAMPLE_RATE), "p": round(p, 3)})
        else:
            if p < c["vad_end"]:
                self.vad_quiet_ms += 30
                if self.vad_quiet_ms >= c["vad_hangover_ms"]:
                    self.vad_speech = False
                    self.vad_hits = 0
                    emit({"type": "vad", "speech": False, "stream_ms": int(self.stream_samples * 1000 / SAMPLE_RATE), "p": round(p, 3)})
            else:
                self.vad_quiet_ms = 0

    def _wake_step(self, score):
        c = self.cfg
        self.over = self.over + 1 if score >= c["threshold"] else 0
        now_ms = self.stream_samples * 1000 / SAMPLE_RATE
        if self.over >= c["patience"] and now_ms >= self.refractory_until:
            self.refractory_until = now_ms + 2000
            self.over = 0
            emit({"type": "wake", "score": round(score, 3), "stream_ms": int(now_ms)})


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--models":
        emit({"type": "error", "message": "usage: --models <folder with melspectrogram.onnx embedding_model.onnx silero_vad.onnx jarvis_head.npz>"})
        return 2
    t0 = time.time()
    try:
        s = Sentinel(sys.argv[2])
        # warm-up: build the ONNX graphs so the first real frame is not slow
        s.feed(b"\x00\x00" * SAMPLE_RATE)
        s.reset()
        s.stream_samples = 0
    except Exception as e:  # noqa: BLE001
        print("load failed:", repr(e), file=sys.stderr)
        emit({"type": "error", "message": "load failed: %s" % type(e).__name__})
        return 3
    emit({"type": "ready", "load_seconds": round(time.time() - t0, 3), "wake_model": "jarvis_head", "vad_model": "silero", "onnxruntime": s.ort.__version__})
    cpu0 = time.process_time()
    for line in sys.stdin:
        if len(line) > MAX_LINE:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        op = msg.get("op")
        try:
            if op == "audio":
                s.feed(base64.b64decode(msg.get("pcm", "")))
            elif op == "config":
                for k in ("wake", "vad", "threshold", "patience", "vad_start", "vad_end", "vad_hangover_ms"):
                    if k in msg:
                        s.cfg[k] = msg[k]
                if not s.cfg["wake"]:
                    s.over = 0
            elif op == "reset":
                s.reset()
            elif op == "stats":
                emit({"type": "stats", "audio_s": round(s.stream_samples / SAMPLE_RATE, 1), "cpu_s": round(time.process_time() - cpu0, 3),
                      "wake_frames": s.wake_frames, "vad_frames": s.vad_frames, "max_wake_score": round(s.max_score, 3)})
                s.max_score = 0.0
            elif op == "ping":
                emit({"type": "pong"})
            elif op == "shutdown":
                break
        except Exception as e:  # noqa: BLE001
            print("op failed:", op, repr(e), file=sys.stderr)
            emit({"type": "error", "message": type(e).__name__})
    return 0          # stdin closed: JARVIS is gone


if __name__ == "__main__":
    rc = main()
    _proto.flush()
    os._exit(rc)          # leave at once: interpreter teardown would wait for ONNX Runtime's thread pools
