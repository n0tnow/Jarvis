#!/usr/bin/env python3
"""JARVIS speech-to-text worker (V0.7).

A small, long-lived process that keeps ONE Whisper model (MLX, Apple silicon) loaded and transcribes push-to-talk utterances. It is
launched and supervised by JARVIS (never by hand), runs fully offline, keeps audio ONLY in memory for the lifetime of one utterance
(nothing is ever written to disk) and exits as soon as stdin closes, so it cannot outlive JARVIS.

Protocol (one JSON object per line)
  in : {"op":"begin","id":"<id>","language":null|"tr"|"en","prompt":"..."}
       {"op":"audio","id":"<id>","pcm":"<base64 of 16 kHz mono little-endian int16>"}
       {"op":"preview","id":"<id>"}      decode the audio received so far, emit "partial" (a preview, not a final)
       {"op":"finish","id":"<id>"}       decode everything, emit "final", forget the utterance
       {"op":"cancel","id":"<id>"}       forget the utterance, emit nothing
       {"op":"ping"}   {"op":"shutdown"}
  out: {"type":"ready","load_seconds":1.4,"mlx":"0.32.3","model":"whisper-small-mlx"}
       {"type":"partial","id":..,"text":..,"language":..,"audio_seconds":..,"decode_seconds":..}
       {"type":"final","id":..,"text":..,"language":..,"language_probs":{"tr":..,"en":..},"confidence":..,"audio_seconds":..,"decode_seconds":..}
       {"type":"error","id":..,"message":".."}     {"type":"pong"}
stdout carries ONLY protocol lines; anything libraries print is redirected to stderr.
Language: a concrete "tr"/"en" is used as given; null means DETECT, restricted to Turkish or English (real detection, not a guess).
"""
import base64
import json
import math
import os
import queue
import sys
import threading
import time

_proto = sys.stdout
sys.stdout = sys.stderr
os.environ.setdefault("HF_HUB_OFFLINE", "1")          # never download anything
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

SAMPLE_RATE = 16000
MAX_SECONDS = 75                      # bounded buffer per utterance (JARVIS caps a hold at 60 s)
MIN_DECODE_SECONDS = 0.5
SILENCE_RMS = 0.0008                  # digital silence: do not ask the model (it would hallucinate)
ALLOWED_LANGUAGES = ("tr", "en")
_emit_lock = threading.Lock()
_sessions = {}
_sessions_lock = threading.Lock()


def emit(obj):
    with _emit_lock:
        _proto.write(json.dumps(obj, ensure_ascii=False) + "\n")
        _proto.flush()


class Utterance:
    def __init__(self, language, prompt):
        self.language = language if language in ALLOWED_LANGUAGES else None
        self.prompt = (prompt or "")[:400]
        self.pcm = bytearray()
        self.cancelled = False


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--model":
        emit({"type": "error", "id": None, "message": "usage: --model <path>"})
        return 2
    model_path = sys.argv[2]
    t0 = time.time()
    try:
        import mlx.core as mx
        import numpy as np
        import mlx_whisper
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
        from mlx_whisper.transcribe import ModelHolder
        model = ModelHolder.get_model(model_path, mx.float16)
        # Warm-up: compiles kernels so the first real utterance is not slow.
        mlx_whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), path_or_hf_repo=model_path, language="en", condition_on_previous_text=False)
    except Exception as e:  # noqa: BLE001
        emit({"type": "error", "id": None, "message": "load failed: %s" % type(e).__name__})
        print("load failed:", repr(e), file=sys.stderr)
        return 3
    emit({"type": "ready", "load_seconds": round(time.time() - t0, 3), "mlx": getattr(mx, "__version__", "?"), "model": os.path.basename(model_path.rstrip("/"))})

    inbox = queue.Queue()
    shutdown = threading.Event()

    def reader():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            op, rid = msg.get("op"), msg.get("id")
            if op == "begin":
                with _sessions_lock:
                    _sessions[rid] = Utterance(msg.get("language"), msg.get("prompt"))
            elif op == "audio":
                with _sessions_lock:
                    u = _sessions.get(rid)
                    if u is not None and len(u.pcm) < MAX_SECONDS * SAMPLE_RATE * 2:
                        try:
                            u.pcm.extend(base64.b64decode(msg.get("pcm", "")))
                        except ValueError:
                            pass
            elif op == "cancel":
                with _sessions_lock:
                    u = _sessions.pop(rid, None)
                    if u is not None:
                        u.cancelled = True
            elif op == "shutdown":
                shutdown.set(); inbox.put(None); return
            else:
                inbox.put(msg)                      # preview / finish / ping: decoded in order on the main thread
        shutdown.set(); inbox.put(None)             # stdin closed: JARVIS is gone → exit

    threading.Thread(target=reader, daemon=True).start()

    def samples_of(u):
        with _sessions_lock:
            raw = bytes(u.pcm)
        return np.frombuffer(raw[: len(raw) // 2 * 2], dtype=np.int16).astype(np.float32) / 32768.0

    def detect_language(audio):
        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        _, probs = model.detect_language(segment)
        scores = {l: float(probs.get(l, 0.0)) for l in ALLOWED_LANGUAGES}
        return max(scores, key=scores.get), scores

    def decode(u, final):
        audio = samples_of(u)
        seconds = len(audio) / SAMPLE_RATE
        if seconds < MIN_DECODE_SECONDS:
            return "", u.language, None, None, seconds
        if float(np.sqrt(np.mean(audio * audio))) < SILENCE_RMS:
            return "", u.language, None, None, seconds
        probs = None
        language = u.language
        if language is None:
            language, probs = detect_language(audio)
        result = mlx_whisper.transcribe(audio, path_or_hf_repo=model_path, language=language, initial_prompt=u.prompt or None,
                                        condition_on_previous_text=False, temperature=(0.0, 0.4), fp16=True)
        segments = result.get("segments") or []
        keep = [s for s in segments if not (s.get("no_speech_prob", 0.0) > 0.6 and s.get("avg_logprob", 0.0) < -1.0)]
        text = " ".join(s.get("text", "").strip() for s in keep).strip() if segments else result.get("text", "").strip()
        logprobs = [s["avg_logprob"] for s in keep if "avg_logprob" in s]
        confidence = round(math.exp(sum(logprobs) / len(logprobs)), 3) if logprobs else None
        return text, language, probs, confidence, seconds

    while not shutdown.is_set():
        msg = inbox.get()
        if msg is None:
            break
        op, rid = msg.get("op"), msg.get("id")
        if op == "ping":
            emit({"type": "pong"})
            continue
        with _sessions_lock:
            u = _sessions.get(rid)
        if u is None or u.cancelled:
            continue
        try:
            started = time.time()
            text, language, probs, confidence, seconds = decode(u, op == "finish")
            took = round(time.time() - started, 3)
            if u.cancelled:
                continue
            if op == "preview":
                emit({"type": "partial", "id": rid, "text": text, "language": language, "audio_seconds": round(seconds, 2), "decode_seconds": took})
            elif op == "finish":
                with _sessions_lock:
                    _sessions.pop(rid, None)
                emit({"type": "final", "id": rid, "text": text, "language": language, "language_probs": probs, "confidence": confidence,
                      "audio_seconds": round(seconds, 2), "decode_seconds": took})
            try:
                mx.clear_cache()
            except Exception:  # noqa: BLE001
                pass
        except Exception as e:  # noqa: BLE001
            print("decode failed:", repr(e), file=sys.stderr)
            if op == "finish":
                with _sessions_lock:
                    _sessions.pop(rid, None)
            emit({"type": "error", "id": rid, "message": type(e).__name__})
    return 0


if __name__ == "__main__":
    sys.exit(main())
