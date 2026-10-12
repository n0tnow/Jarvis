#!/usr/bin/env python3
"""Lexical (BM25 over folded, prefix-stemmed tokens) vs semantic vs weighted-hybrid on the benchmark corpus, per embedding model (uses emb_<key>.npz from embed_bench.py)."""
import sys, os, json, math, re, unicodedata
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/jarvis-memory-bench"
TR = str.maketrans("çğıöşüÇĞİÖŞÜ", "cgiosuCGIOSU")
STOP = set("the a an of to in on and or is are was were be do does did we our us what why how which can could should it that this for with from by at as not no".split()) | set("bir ve ile mi mı mu mü ne neden nasıl hangi bu şu o da de ki için gibi mı".split()) | {"nasil", "icin", "mi", "mu"}
def toks(s):
    s = s.translate(TR).lower(); out = []
    for w in re.findall(r"[a-z0-9]+", s):
        if w in STOP or len(w) < 2: continue
        out.append(w[:6])      # crude prefix stem: Turkish suffixes and English plurals fold together
    return out
corpus = json.load(open(os.path.join(HERE, "corpus.json"))); mem, qs = corpus["memories"], corpus["queries"]; ids = [m["id"] for m in mem]
docs = [toks(m["text"]) for m in mem]; N = len(docs); avg = sum(map(len, docs)) / N
df = {}
for d in docs:
    for t in set(d): df[t] = df.get(t, 0) + 1
def bm25(q, k1=1.4, b=0.75):
    s = np.zeros(N)
    for t in set(toks(q)):
        if t not in df: continue
        idf = math.log(1 + (N - df[t] + .5) / (df[t] + .5))
        for i, d in enumerate(docs):
            f = d.count(t)
            if f: s[i] += idf * f * (k1 + 1) / (f + k1 * (1 - b + b * len(d) / avg))
    return s
def norm(x):
    lo, hi = x.min(), x.max(); return (x - lo) / (hi - lo) if hi > lo else np.zeros_like(x)
def score(order_fn, kinds=None):
    res = {}
    for q in qs:
        order = [ids[i] for i in order_fn(q)]
        ranks = [order.index(r) + 1 for r in q["relevant"]]; first = min(ranks)
        for k in ("all", q["kind"]):
            r = res.setdefault(k, []); r.append((first <= 1, first <= 3, first <= 5, 1 / first))
    return {k: {"R@1": round(float(np.mean([x[0] for x in v])), 3), "R@3": round(float(np.mean([x[1] for x in v])), 3), "R@5": round(float(np.mean([x[2] for x in v])), 3), "MRR": round(float(np.mean([x[3] for x in v])), 3)} for k, v in res.items()}
LEX = {q["id"]: bm25(q["text"]) for q in qs}
print("lexical only", json.dumps(score(lambda q: np.argsort(-LEX[q["id"]]))["all"]))
for f in sorted(os.listdir(OUT)):
    if not f.startswith("emb_"): continue
    key = f[4:-4]; z = np.load(os.path.join(OUT, f)); D, Q = z["D"], z["Q"]; qi = {q["id"]: i for i, q in enumerate(qs)}
    sem = lambda q: D @ Q[qi[q["id"]]]
    print(f"\n== {key}\n semantic only", json.dumps(score(lambda q: np.argsort(-sem(q)))["all"]))
    for w in (0.5, 0.6, 0.7, 0.8, 0.9):
        r = score(lambda q: np.argsort(-(w * norm(sem(q)) + (1 - w) * norm(LEX[q["id"]]))))
        print(f" hybrid w_sem={w}", json.dumps({k: r[k] for k in ("all", "tr-en", "mixed")}))
