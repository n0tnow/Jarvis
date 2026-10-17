#!/usr/bin/env python3
"""Runs the JARVIS conversational probes (Benchmarks/local_model_probes.json) against ONE local MLX model through the production worker protocol (V1.0 Phase B).

  python bench_model.py --model ~/AI/models/Qwen3.5-4B-MLX-4bit --out /tmp/qwen4b.json [--max-tokens 256]

It starts `jarvis_local_worker.py --model <path>` exactly like the app does (offline, one model, stdin/stdout JSON lines), builds the same prompt shape the app builds
(instruction + bounded history + request), and records answers plus what the worker measured: load seconds, first-token seconds, generation tokens/s, peak MLX memory,
and the worker process' resident set (ps). The rubric itself is scored by `Jarvis --local-model-score` (Swift, the same RubricCheck code the tests cover).
Nothing is downloaded, nothing is sent anywhere; the model directory is only read.
"""
import argparse, json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def instruction():
    src = open(os.path.join(ROOT, "Sources/Jarvis/Providers/CLIProviderSpecs.swift"), encoding="utf-8").read()
    m = re.search(r'static let text = "((?:[^"\\]|\\.)*)"', src)
    text = m.group(1).replace('\\"', '"').replace("\\n", "\n") if m else "You are the language engine inside JARVIS, a macOS assistant."
    return text + " Keep answers short (a few sentences) unless asked otherwise."


def build_prompt(probe, instr):
    parts = ["[Instructions] " + instr]
    if probe.get("history"):
        lines = []
        for t in probe["history"]:
            who = "User" if t["role"] == "user" else "JARVIS"
            lines.append("%s: %s" % (who, t["text"]))
        parts.append("[Conversation so far]\n" + "\n".join(lines))
    req = probe["prompt"]
    if probe.get("groundingContext"):
        req = "[Facts from JARVIS' own state — use only these, do not invent]\n" + probe["groundingContext"] + "\n\n" + req
    parts.append("[Request]\n" + req)
    return "\n\n".join(parts)


def rss_mb(pid):
    try:
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).split()[0]) / 1024.0
    except Exception:  # noqa: BLE001
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--probes", default=os.path.join(ROOT, "Benchmarks/local_model_probes.json"))
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--worker", default=os.path.join(ROOT, "scripts/local-ai/jarvis_local_worker.py"))
    a = ap.parse_args()
    probes = json.load(open(a.probes, encoding="utf-8"))["probes"]
    instr = instruction()
    env = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    p = subprocess.Popen([a.python, a.worker, "--model", os.path.expanduser(a.model)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
    t0 = time.time()
    ready = json.loads(p.stdout.readline())
    if ready.get("type") != "ready":
        print(json.dumps({"error": ready}), file=sys.stderr); return 3
    result = {"model": a.model, "load_seconds": ready.get("load_seconds"), "wall_load_seconds": round(time.time() - t0, 3), "rss_after_load_mb": rss_mb(p.pid), "runs": []}
    for i, pr in enumerate(probes):
        rid = "p%d" % i
        prompt = build_prompt(pr, instr)
        started = time.time()
        p.stdin.write(json.dumps({"op": "generate", "id": rid, "prompt": prompt, "max_tokens": a.max_tokens, "temperature": 0.0}) + "\n"); p.stdin.flush()
        text, done, err = "", None, None
        while True:
            line = p.stdout.readline()
            if not line:
                err = "worker ended"; break
            m = json.loads(line)
            if m.get("id") != rid:
                continue
            if m["type"] == "token":
                text += m["text"]
            elif m["type"] == "done":
                done = m; break
            elif m["type"] == "error":
                err = m.get("message"); break
        run = {"id": pr["id"], "text": text, "failed": err is not None or done is None, "error": err, "total_seconds": round(time.time() - started, 3)}
        if done:
            run.update({"ttft": done.get("first_token_seconds"), "generation_tps": done.get("generation_tps"), "prompt_tokens": done.get("prompt_tokens"),
                        "generation_tokens": done.get("generation_tokens"), "peak_memory_gb": done.get("peak_memory_gb")})
        result["runs"].append(run)
        print("%s  %.1fs  %s" % (pr["id"], run["total_seconds"], text.replace("\n", " ")[:110]), file=sys.stderr)
    result["rss_after_run_mb"] = rss_mb(p.pid)
    try:
        p.stdin.write(json.dumps({"op": "shutdown"}) + "\n"); p.stdin.flush(); p.wait(timeout=10)
    except Exception:  # noqa: BLE001
        p.kill()
    json.dump(result, open(a.out, "w"), ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
