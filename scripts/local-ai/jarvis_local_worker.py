#!/usr/bin/env python3
"""JARVIS local-model worker (V0.3.1).

A tiny, long-lived process that keeps ONE MLX model loaded and answers JSON-lines requests on stdin.
It is launched and supervised by JARVIS (never by hand), runs fully offline, and exits as soon as stdin closes
(so it cannot outlive JARVIS).

Protocol (one JSON object per line)
  in : {"op":"generate","id":"<id>","prompt":"...","max_tokens":256,"temperature":0.0}
       {"op":"cancel","id":"<id>"}   {"op":"ping"}   {"op":"shutdown"}
  out: {"type":"ready","load_seconds":1.4,"mlx":"0.32.3"}
       {"type":"token","id":"<id>","text":"..."}
       {"type":"done","id":"<id>","prompt_tokens":21,"generation_tokens":5,"prompt_tps":..,"generation_tps":..,
        "first_token_seconds":..,"peak_memory_gb":..,"cancelled":false}
       {"type":"error","id":"<id>","message":"..."}     {"type":"pong"}
stdout carries ONLY protocol lines; anything libraries print is redirected to stderr.
"""
import json
import os
import queue
import sys
import threading
import time

# Protocol channel = the real stdout; everything else goes to stderr.
_proto = sys.stdout
sys.stdout = sys.stderr
os.environ.setdefault("HF_HUB_OFFLINE", "1")          # never download anything
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

MAX_TOKENS_CAP = 1024
_lock = threading.Lock()


def emit(obj):
    with _lock:
        _proto.write(json.dumps(obj, ensure_ascii=False) + "\n")
        _proto.flush()


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--model":
        emit({"type": "error", "id": None, "message": "usage: --model <path>"})
        return 2
    model_path = sys.argv[2]
    t0 = time.time()
    try:
        import mlx.core as mx
        from mlx_vlm import load, stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        model, processor = load(model_path)
        config = getattr(model, "config", None)
    except Exception as e:  # noqa: BLE001
        emit({"type": "error", "id": None, "message": "load failed: %s" % type(e).__name__})
        print("load failed:", repr(e), file=sys.stderr)
        return 3
    emit({"type": "ready", "load_seconds": round(time.time() - t0, 3), "mlx": getattr(mx, "__version__", "?")})

    inbox = queue.Queue()
    cancelled = set()
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
            op = msg.get("op")
            if op == "cancel":
                cancelled.add(msg.get("id"))
            elif op == "shutdown":
                shutdown.set(); inbox.put(None); return
            else:
                inbox.put(msg)
        shutdown.set(); inbox.put(None)           # stdin closed: parent is gone → exit

    threading.Thread(target=reader, daemon=True).start()

    while not shutdown.is_set():
        msg = inbox.get()
        if msg is None:
            break
        op = msg.get("op")
        if op == "ping":
            emit({"type": "pong"})
            continue
        if op != "generate":
            continue
        rid = msg.get("id")
        try:
            prompt = apply_chat_template(processor, config, str(msg.get("prompt", "")), num_images=0)
            max_tokens = max(1, min(int(msg.get("max_tokens", 256)), MAX_TOKENS_CAP))
            temperature = float(msg.get("temperature", 0.0))
            started = time.time(); first = None; last = None; was_cancelled = False
            for r in stream_generate(model, processor, prompt, max_tokens=max_tokens, temperature=temperature):
                if rid in cancelled:
                    was_cancelled = True
                    break
                if first is None:
                    first = time.time() - started
                if r.text:
                    emit({"type": "token", "id": rid, "text": r.text})
                last = r
            cancelled.discard(rid)
            emit({"type": "done", "id": rid, "cancelled": was_cancelled,
                  "prompt_tokens": getattr(last, "prompt_tokens", None), "generation_tokens": getattr(last, "generation_tokens", None),
                  "prompt_tps": getattr(last, "prompt_tps", None), "generation_tps": getattr(last, "generation_tps", None),
                  "first_token_seconds": round(first, 3) if first is not None else None,
                  "peak_memory_gb": getattr(last, "peak_memory", None)})
            try:
                mx.clear_cache()
            except Exception:  # noqa: BLE001
                pass
        except Exception as e:  # noqa: BLE001
            print("generate failed:", repr(e), file=sys.stderr)
            emit({"type": "error", "id": rid, "message": type(e).__name__})
    return 0


if __name__ == "__main__":
    sys.exit(main())
