#!/usr/bin/env python3
"""Runs the visual-grounding cases against ONE local model through the production worker protocol and prints a JSON report (accuracy, abstention, latency, RAM, security).
Usage: vlm_bench.py <model_dir> <cases_dir> [--runs 2]"""
import base64, json, os, subprocess, sys, time, resource

def main():
    model, cases_dir = sys.argv[1], sys.argv[2]
    py = os.path.expanduser("~/Library/Application Support/JARVIS/runtime/vision-venv/bin/python")
    worker = os.path.join(os.path.dirname(__file__), "..", "jarvis_vision_worker.py")
    cases = json.load(open(os.path.join(cases_dir, "cases.json")))
    t0 = time.time()
    p = subprocess.Popen([py, worker, "--model-dir", model], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    ready = json.loads(p.stdout.readline()); load = time.time() - t0
    if ready.get("type") != "ready": print(json.dumps({"error": ready})); return
    def ask(req):
        p.stdin.write(json.dumps(req) + "\n"); p.stdin.flush(); return json.loads(p.stdout.readline())
    def rss_mb():
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
        return int(out) // 1024 if out else -1
    results, lat_cold, lat_warm = [], None, []
    for c in cases:
        img = base64.b64encode(open(os.path.join(cases_dir, c["image"]), "rb").read()).decode()
        e = c["expect"]
        t1 = time.time()
        if "answer" in e:
            r = ask({"op": "describe", "id": c["id"], "image": img, "question": c["query"]})
            text = (r.get("text") or "").lower()
            ok = any(a in text.split() or text.strip(" .!").startswith(a) for a in e["answer"])
            res = {"id": c["id"], "kind": c["kind"], "ok": ok, "answer": text[:80]}
        else:
            r = ask({"op": "ground", "id": c["id"], "image": img, "query": c["query"]})
            cands = r.get("candidates") or []
            if e.get("abstain"):
                ok = (not r.get("found")) or r.get("ambiguous")
                res = {"id": c["id"], "kind": c["kind"], "ok": bool(ok), "found": r.get("found"), "ambiguous": r.get("ambiguous"), "n": len(cands)}
            else:
                gt = e["box"]; hit = False; best = 0
                for cd in cands:
                    b = cd["box"]; cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
                    inside = gt[0] <= cx <= gt[2] and gt[1] <= cy <= gt[3]
                    ix = max(0, min(b[2], gt[2]) - max(b[0], gt[0])); iy = max(0, min(b[3], gt[3]) - max(b[1], gt[1]))
                    iou = ix * iy / max(1e-9, (b[2]-b[0])*(b[3]-b[1]) + (gt[2]-gt[0])*(gt[3]-gt[1]) - ix*iy); best = max(best, iou); hit = hit or inside
                ok = hit and len(cands) >= 1 and not (r.get("ambiguous") and len(cands) > 1 and not hit)
                res = {"id": c["id"], "kind": c["kind"], "ok": bool(ok), "n": len(cands), "iou": round(best, 2), "ambiguous": r.get("ambiguous")}
        dt = time.time() - t1
        if lat_cold is None: lat_cold = dt
        else: lat_warm.append(dt)
        res["seconds"] = round(dt, 2); results.append(res)
    rss = rss_mb()
    p.stdin.write('{"op":"shutdown"}\n'); p.stdin.flush(); p.wait(timeout=20)
    n_ok = sum(r["ok"] for r in results)
    print(json.dumps({"model": os.path.basename(model.rstrip("/")), "load_seconds": round(load, 1), "cold_first_call_s": round(lat_cold, 2), "warm_median_s": round(sorted(lat_warm)[len(lat_warm)//2], 2), "warm_max_s": round(max(lat_warm), 2),
                      "rss_mb_after": rss, "accuracy": f"{n_ok}/{len(results)}", "results": results}, indent=1))
if __name__ == "__main__": main()
