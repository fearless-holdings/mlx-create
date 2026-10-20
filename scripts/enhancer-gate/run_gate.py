#!/usr/bin/python3
"""Enhancer model gate (plan U6, KTD2, R11-R13): probe + timing against the real pinned engine.

Launches mlx-serve exactly as the app does (EngineLaunch: 127.0.0.1, per-launch key via env, --api-key-strict,
private HOME, models symlinked under HOME/.mlx-serve/models) with --max-resident-models 1, loads one candidate,
sends the recorded enhancer requests (requests.json, dumped from PromptEnhancer.request) and writes raw
outputs and timings to a results file. Scoring is a separate, blind step (a reader given only input, key terms and
output, see docs/lld/enhancer.md); this script never judges.

    run_gate.py --engine DIR/mlx-serve --weights /tmp/.../weights --model-id ORG/NAME --out results.json
                [--requests requests.json] [--limit N] [--workdir DIR]
"""
import argparse, json, os, secrets, socket, subprocess, sys, time, urllib.request, urllib.error, shutil

HERE = os.path.dirname(os.path.abspath(__file__))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def call(port, key, method, path, body=None, timeout=600):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/{path}", method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode()



def stream_chat(port, key, model, request, timeout=180):
    """Returns text, seconds to first content, total seconds, finish reason, whether any reasoning text appeared."""
    body = {
        "model": model, "messages": request["messages"], "stream": True, "enable_thinking": False,
        "temperature": request["temperature"], "top_p": request["top_p"], "max_tokens": request["max_tokens"],
    }
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions", method="POST", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "Accept": "text/event-stream"})
    t0 = time.monotonic()
    first = None
    text, reasoning, finish = [], False, None
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                ev = json.loads(payload)
            except ValueError:
                continue
            for ch in ev.get("choices", []):
                d = ch.get("delta", {})
                if d.get("reasoning_content") or d.get("reasoning"):
                    reasoning = True
                c = d.get("content")
                if c:
                    if first is None:
                        first = time.monotonic() - t0
                    text.append(c)
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
    total = time.monotonic() - t0
    joined = "".join(text)
    if "<think>" in joined or "<|channel>" in joined:
        reasoning = True
    return joined, first, total, finish, reasoning


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--weights", required=True, help="dir holding ORG/NAME model folders")
    ap.add_argument("--model-id", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--requests", default=os.path.join(HERE, "requests.json"), help="recorded enhancer requests to send")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--workdir", default="/tmp/mc-enhancer-gate/run")
    a = ap.parse_args()

    shutil.rmtree(a.workdir, ignore_errors=True)
    home = os.path.join(a.workdir, "home")
    tmp = os.path.join(a.workdir, "tmp")
    os.makedirs(os.path.join(home, ".mlx-serve"))
    os.makedirs(tmp)
    os.symlink(a.weights, os.path.join(home, ".mlx-serve", "models"))
    port, key = free_port(), secrets.token_hex(24)
    argv = [
        a.engine, "--serve", "--host", "127.0.0.1", "--port", str(port),
        "--api-key-env", "MLXC_ENGINE_KEY", "--api-key-strict", "--model-dir", a.weights,
        "--max-resident-mem", "auto", "--max-resident-models", "1", "--log-level", "info",
    ]
    env = {"HOME": home, "MLXC_ENGINE_KEY": key, "PATH": "/usr/bin:/bin", "TMPDIR": tmp}
    log = open(os.path.join(a.workdir, "engine.log"), "w")
    proc = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT)
    result = {"model_id": a.model_id, "engine": "26.10.2", "max_resident_models": 1}
    try:
        for _ in range(120):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                    if json.loads(r.read()).get("status") == "ok":
                        break
            except Exception:
                time.sleep(0.5)
        else:
            raise SystemExit("engine never became healthy; see " + log.name)
        status, body = call(port, key, "GET", "v1/models")
        models = json.loads(body)["data"]
        result["models_entry"] = next((m for m in models if m["id"] == a.model_id), None)
        if result["models_entry"] is None:
            raise SystemExit(f"model {a.model_id} not listed: {[m['id'] for m in models]}")
        # Cold load: the image model is not resident, as on a 16 GB Mac.
        t0 = time.monotonic()
        status, body = call(port, key, "POST", "v1/load-model", {"model": a.model_id})
        result["cold_load_seconds"] = round(time.monotonic() - t0, 2)
        result["load_response"] = body[:2000]
        reqs = json.load(open(a.requests))["requests"]
        if a.limit:
            reqs = reqs[: a.limit]
        rows = []
        for q in reqs:
            try:
                text, first, total, finish, reasoning = stream_chat(port, key, a.model_id, q)
                err = None
            except (urllib.error.URLError, OSError, TimeoutError) as e:
                text, first, total, finish, reasoning, err = "", None, None, None, False, repr(e)
            rows.append({
                "id": q["id"], "cat": q["cat"], "family": q["family"], "input": q["text"], "keep": q["keep"],
                "output": text, "first_text_seconds": None if first is None else round(first, 3),
                "total_seconds": None if total is None else round(total, 3), "finish": finish,
                "reasoning_text_seen": reasoning, "error": err,
            })
            print(f"{q['id']} first={rows[-1]['first_text_seconds']} total={rows[-1]['total_seconds']} :: {text[:90]!r}", flush=True)
        result["rows"] = rows
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    json.dump(result, open(a.out, "w"), indent=2)
    print("wrote", a.out)


if __name__ == "__main__":
    sys.exit(main())
