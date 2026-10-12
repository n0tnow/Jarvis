#!/usr/bin/env python3
"""JARVIS project-memory embedding worker (V0.10): paraphrase-multilingual-MiniLM-L12-v2 (int8, ONNX Runtime, CPU) behind a tiny JSON-lines protocol.

Launched and supervised by JARVIS only. Fully offline: the model is read from a local folder; this process has no network code and never downloads anything.
It exits as soon as stdin closes. Texts arrive already sanitized by JARVIS (the curator refuses credential-shaped text before it is ever stored or embedded).

Protocol (one JSON object per line)
  in : {"op":"embed","id":"7","texts":["…","…"]}     {"op":"ping"}     {"op":"shutdown"}
  out: {"type":"ready","load_seconds":0.3,"model":"paraphrase-multilingual-MiniLM-L12-v2-int8","dim":384}
       {"type":"embedding","id":"7","dim":384,"count":2,"vectors":"<base64 float32 LE, count*dim values, L2-normalised>"}
       {"type":"error","id":"7","message":".."}     {"type":"pong"}
stdout carries ONLY protocol lines; anything libraries print goes to stderr.
"""
import base64, json, os, sys, time

_proto = sys.stdout
sys.stdout = sys.stderr
os.environ.setdefault("HF_HUB_OFFLINE", "1")
MAX_TEXTS = 64
MAX_CHARS = 1200
MAX_TOKENS = 128          # the model was trained with 128-token sequences


def emit(o):
    _proto.write(json.dumps(o, ensure_ascii=False) + "\n"); _proto.flush()


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--model-dir":
        emit({"type": "error", "id": None, "message": "usage: --model-dir <folder with model.onnx and tokenizer.json>"}); return 2
    d = sys.argv[2]
    t0 = time.time()
    try:
        import numpy as np, onnxruntime as ort
        from tokenizers import Tokenizer
        so = ort.SessionOptions(); so.intra_op_num_threads = int(os.environ.get("JARVIS_EMBED_THREADS", "2")); so.inter_op_num_threads = 1
        sess = ort.InferenceSession(os.path.join(d, "model.onnx"), so, providers=["CPUExecutionProvider"])
        tok = Tokenizer.from_file(os.path.join(d, "tokenizer.json")); tok.enable_truncation(max_length=MAX_TOKENS); tok.enable_padding()
        names = [i.name for i in sess.get_inputs()]
    except Exception as e:                                   # missing runtime / model: tell JARVIS, exit
        emit({"type": "error", "id": None, "message": "load failed: %s" % str(e)[:200]}); return 3

    def embed(texts):
        enc = tok.encode_batch(texts)
        ids = np.array([e.ids for e in enc], dtype=np.int64); mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in names: feed["token_type_ids"] = np.zeros_like(ids)
        h = sess.run(None, feed)[0]
        v = (h * mask[:, :, None]).sum(1) / np.maximum(mask.sum(1, keepdims=True), 1)
        v = v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-9)
        return v.astype("<f4")

    dim = int(embed(["warm up"]).shape[1])
    emit({"type": "ready", "load_seconds": round(time.time() - t0, 3), "model": "paraphrase-multilingual-MiniLM-L12-v2-int8", "dim": dim})
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: req = json.loads(line)
        except Exception: continue
        op = req.get("op")
        if op == "shutdown": break
        if op == "ping": emit({"type": "pong"}); continue
        if op != "embed": continue
        rid = req.get("id")
        texts = req.get("texts")
        if not isinstance(texts, list) or not texts or len(texts) > MAX_TEXTS or not all(isinstance(t, str) for t in texts):
            emit({"type": "error", "id": rid, "message": "bad request"}); continue
        try:
            v = embed([t[:MAX_CHARS] for t in texts])
            emit({"type": "embedding", "id": rid, "dim": dim, "count": len(texts), "vectors": base64.b64encode(v.tobytes()).decode("ascii")})
        except Exception as e:
            emit({"type": "error", "id": rid, "message": "embed failed: %s" % str(e)[:160]})
    return 0


if __name__ == "__main__":
    sys.exit(main())
