#!/usr/bin/env python3
"""V0.10 embedding benchmark (one model per process, so RAM figures are clean).
   embed_bench.py <key> [--out DIR]   keys: see MODELS.  Needs the memory-venv (onnxruntime, numpy, tokenizers) and the pinned model files
   downloaded by scripts/setup_memory_ai.sh --bench.   Output: one JSON line with latency / RAM / Recall@k / MRR per query kind,
   plus <out>/emb_<key>.npz (query + document vectors) for hybrid_analysis.py."""
import sys, os, json, time, resource, argparse
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

ROOT = os.path.expanduser(os.environ.get("JARVIS_MEMORY_BENCH_DIR", "~/AI/models/memory-bench"))
HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = {  # key: (dir, onnx file, pooling, query prefix, doc prefix)
    "e5-small":   ("intfloat__multilingual-e5-small", "onnx/model.onnx", "mean", "query: ", "passage: "),
    "e5-base":    ("intfloat__multilingual-e5-base", "onnx/model.onnx", "mean", "query: ", "passage: "),
    "minilm-l12": ("sentence-transformers__paraphrase-multilingual-MiniLM-L12-v2", "onnx/model_qint8_arm64.onnx", "mean", "", ""),
    "granite-107m": ("ibm-granite__granite-embedding-107m-multilingual", "model.onnx", "cls", "", ""),
    "arctic-m-v2": ("Snowflake__snowflake-arctic-embed-m-v2.0", "onnx/model_int8.onnx", "cls", "query: ", ""),
}
MAXLEN = 256

class Embedder:
    def __init__(self, key):
        d, f, self.pool, self.qp, self.dp = MODELS[key]
        base = os.path.join(ROOT, d)
        so = ort.SessionOptions(); so.intra_op_num_threads = 4; so.inter_op_num_threads = 1
        self.sess = ort.InferenceSession(os.path.join(base, f), so, providers=["CPUExecutionProvider"])
        self.names = [i.name for i in self.sess.get_inputs()]
        self.tok = Tokenizer.from_file(os.path.join(base, "tokenizer.json"))
        self.tok.enable_truncation(max_length=MAXLEN)
        self.tok.enable_padding()
    def encode(self, texts, prefix=""):
        enc = self.tok.encode_batch([prefix + t for t in texts])
        ids = np.array([e.ids for e in enc], dtype=np.int64); mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self.names: feed["token_type_ids"] = np.zeros_like(ids)
        h = self.sess.run(None, feed)[0]
        v = h[:, 0, :] if self.pool == "cls" else (h * mask[:, :, None]).sum(1) / np.maximum(mask.sum(1, keepdims=True), 1)
        return (v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-9)).astype(np.float32)

def metrics(order, rel):
    ranks = [order.index(r) + 1 for r in rel if r in order]
    first = min(ranks) if ranks else 10**6
    return {"r1": first <= 1, "r3": first <= 3, "r5": first <= 5, "mrr": 1.0 / first if first < 10**6 else 0.0}

def rss_mb():
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return r / (1024 * 1024) if sys.platform == "darwin" else r / 1024

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("key"); ap.add_argument("--out", default="/tmp/jarvis-memory-bench")
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    corpus = json.load(open(os.path.join(HERE, "corpus.json")))
    mem, qs = corpus["memories"], corpus["queries"]
    base_rss = rss_mb()
    t0 = time.time(); emb = Embedder(a.key); emb.encode(["warm up"]); cold = time.time() - t0
    loaded_rss = rss_mb()
    t0 = time.time(); D = emb.encode([m["text"] for m in mem], emb.dp); batch = time.time() - t0
    single = []
    for q in qs * 2:
        t0 = time.time(); emb.encode([q["text"]], emb.qp); single.append((time.time() - t0) * 1000)
    Q = emb.encode([q["text"] for q in qs], emb.qp)
    ids = [m["id"] for m in mem]
    per = {}
    for q, qv in zip(qs, Q):
        order = [ids[i] for i in np.argsort(-(D @ qv))]
        m = metrics(order, q["relevant"]); per.setdefault(q["kind"], []).append(m); per.setdefault("all", []).append(m)
    summ = {k: {"n": len(v), "R@1": round(sum(x["r1"] for x in v) / len(v), 3), "R@3": round(sum(x["r3"] for x in v) / len(v), 3),
                "R@5": round(sum(x["r5"] for x in v) / len(v), 3), "MRR": round(sum(x["mrr"] for x in v) / len(v), 3)} for k, v in per.items()}
    np.savez(os.path.join(a.out, f"emb_{a.key}.npz"), D=D, Q=Q)
    single.sort()
    print(json.dumps({"model": a.key, "dim": int(D.shape[1]), "onnx_mb": round(os.path.getsize(os.path.join(ROOT, MODELS[a.key][0], MODELS[a.key][1])) / 1e6, 1),
                      "cold_load_s": round(cold, 2), "rss_after_load_mb": round(loaded_rss, 0), "rss_peak_mb": round(rss_mb(), 0),
                      "batch62_s": round(batch, 2), "query_median_ms": round(single[len(single) // 2], 1), "query_p95_ms": round(single[int(len(single) * .95)], 1),
                      "metrics": summ}, ensure_ascii=False))

if __name__ == "__main__": main()
