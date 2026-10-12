#!/usr/bin/env python3
"""JARVIS neural text-to-speech worker (V0.8): Supertonic 3 (ONNX Runtime, CPU) behind a tiny JSON-lines protocol.

Launched and supervised by JARVIS only, fully offline (the model is read from a local folder; this process never downloads anything and has no network
code), exits as soon as stdin closes. It synthesises ONE complete phrase per request (incremental chunk synthesis — Supertonic is not a streaming model) and
returns the audio in small blocks so JARVIS can start playing the first block immediately. Audio exists only in memory.

Protocol (one JSON object per line)
  in : {"op":"synth","id":"7","text":"...","lang":"tr"|"en","style":"M5","speed":1.0,"steps":6,"tail_ms":160}
       {"op":"cancel","id":"7"}   {"op":"ping"}   {"op":"shutdown"}
  out: {"type":"ready","load_seconds":0.4,"model":"supertonic-3","sample_rate":44100,"styles":["M1",...]}
       {"type":"audio","id":"7","seq":0,"rate":44100,"pcm":"<base64 int16 LE mono>"}
       {"type":"done","id":"7","audio_seconds":3.2,"synth_seconds":0.7,"blocks":9}
       {"type":"error","id":"7","message":".."}     {"type":"pong"}
stdout carries ONLY protocol lines; anything libraries print goes to stderr.
"""
import base64
import json
import os
import queue
import sys
import threading
import time

_proto = sys.stdout
sys.stdout = sys.stderr
os.environ.setdefault("HF_HUB_OFFLINE", "1")          # never download anything
os.environ.setdefault("SUPERTONIC_INTRA_OP_THREADS", "2")
os.environ.setdefault("SUPERTONIC_INTER_OP_THREADS", "1")

BLOCK_SECONDS = 0.30
MAX_TEXT = 600
LANGS = {"tr", "en"}
_emit_lock = threading.Lock()
_cancelled = set()
_cancel_lock = threading.Lock()


def emit(obj):
    with _emit_lock:
        _proto.write(json.dumps(obj, ensure_ascii=False) + "\n")
        _proto.flush()


def trim(x, rate, tail_ms):
    """Supertonic pads each phrase with ~0.4 s of silence before and ~0.55 s after; keep a short lead and a deliberate, short tail."""
    import numpy as np
    idx = np.where(np.abs(x) > 0.01)[0]
    if len(idx) == 0:
        return x[: int(0.05 * rate)]
    start = max(0, idx[0] - int(0.03 * rate))
    end = min(len(x), idx[-1] + int(max(tail_ms, 40) / 1000 * rate))
    return x[start:end]


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--model-dir":
        emit({"type": "error", "id": None, "message": "usage: --model-dir <supertonic-3 folder>"})
        return 2
    model_dir = sys.argv[2]
    t0 = time.time()
    try:
        import numpy as np
        from supertonic import TTS
        tts = TTS(model="supertonic-3", model_dir=model_dir, auto_download=False)
        styles = {}
        for name in ("M1", "M2", "M3", "M4", "M5"):
            try:
                styles[name] = tts.get_voice_style(name)
            except Exception:  # noqa: BLE001
                pass
        if not styles:
            raise RuntimeError("no voice styles")
        first = next(iter(styles.values()))
        tts.synthesize("Merhaba.", voice_style=first, lang="tr", total_steps=4)       # warm-up: builds the graphs
    except Exception as e:  # noqa: BLE001
        print("load failed:", repr(e), file=sys.stderr)
        emit({"type": "error", "id": None, "message": "load failed: %s" % type(e).__name__})
        return 3
    rate = int(tts.sample_rate)
    emit({"type": "ready", "load_seconds": round(time.time() - t0, 3), "model": "supertonic-3", "sample_rate": rate, "styles": sorted(styles)})

    inbox = queue.Queue()

    def reader():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            op = msg.get("op")
            if op == "cancel":
                with _cancel_lock:
                    _cancelled.add(msg.get("id"))
            elif op == "shutdown":
                inbox.put(None)
                return
            else:
                inbox.put(msg)
        inbox.put(None)                                  # stdin closed: JARVIS is gone → exit

    threading.Thread(target=reader, daemon=True).start()

    def is_cancelled(rid):
        with _cancel_lock:
            return rid in _cancelled

    while True:
        msg = inbox.get()
        if msg is None:
            break
        op, rid = msg.get("op"), msg.get("id")
        if op == "ping":
            emit({"type": "pong"})
            continue
        if op != "synth":
            continue
        if is_cancelled(rid):
            continue
        try:
            text = str(msg.get("text", ""))[:MAX_TEXT]
            lang = msg.get("lang") if msg.get("lang") in LANGS else "en"
            style = styles.get(msg.get("style"), first)
            speed = max(0.6, min(float(msg.get("speed", 1.0)), 1.6))
            steps = max(2, min(int(msg.get("steps", 6)), 12))
            tail_ms = max(0, min(int(msg.get("tail_ms", 160)), 600))
            started = time.time()
            wav, _ = tts.synthesize(text, voice_style=style, lang=lang, speed=speed, total_steps=steps, silence_duration=0.2)
            synth = time.time() - started
            if is_cancelled(rid):
                continue
            x = trim(np.asarray(wav, dtype=np.float32).reshape(-1), rate, tail_ms)
            pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
            step = int(BLOCK_SECONDS * rate)
            seq = 0
            for i in range(0, len(pcm), step):
                if is_cancelled(rid):
                    break
                emit({"type": "audio", "id": rid, "seq": seq, "rate": rate, "pcm": base64.b64encode(pcm[i:i + step].tobytes()).decode("ascii")})
                seq += 1
            if not is_cancelled(rid):
                emit({"type": "done", "id": rid, "audio_seconds": round(len(pcm) / rate, 3), "synth_seconds": round(synth, 3), "blocks": seq})
        except Exception as e:  # noqa: BLE001
            print("synth failed:", repr(e), file=sys.stderr)
            emit({"type": "error", "id": rid, "message": type(e).__name__})
        finally:
            with _cancel_lock:
                _cancelled.discard(rid)
    return 0


if __name__ == "__main__":
    rc = main()
    _proto.flush()
    os._exit(rc)          # leave at once: interpreter teardown would wait for ONNX Runtime's thread pools
