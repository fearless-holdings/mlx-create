#!/usr/bin/python3
"""LoRA gate (plan U2; KTD8; R14-R17, R22, R23): pre-screen LoRA candidates against the pinned engine.

Launches mlx-serve exactly as the app does -- loopback, per-launch key through --api-key-env with
--api-key-strict, a private HOME with the weights symlinked as .mlx-serve/models, no --skip-mem-preflight --
and runs the four automatic checks of R15 per candidate:

  1. header fit through `mc-catalog lora classify` (unmatched or ambiguous is a rejection, with the reason);
  2. the engine loads and applies the file (a 400 naming `no modules matching` is a rejection);
  3. two same-seed runs reproduce the same image;
  4. strength 0 reproduces the no-LoRA baseline.

Role effect and quality are never judged here: that is the author's call in U3. Verdicts are JSON under
results/; every string passes through `scrub`, so no local path or file name reaches the repo (R23), and usage
counts stay in the verdict as a number only.

    run_gate.py --engine BIN --weights DIR --model-id ORG/NAME --scratch DIR \\
                (--candidates LIST.json | --local-dir DIR) [--png-dir DIR] \\
                [--mc-catalog BIN] [--family ID] [--size 512] [--steps 4] [--prompt-id ID]

See README.md for the Eval-cell invocation and the candidate list schema.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
KEY_ENV = "MLXC_ENGINE_KEY"
NO_MODULES = "no modules matching"
# The order the verdict lists its checks in, and the order a reason is chosen from.
CHECK_ORDER = ["header_fit", "engine_load", "reproducible", "strength_zero"]


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-")


def stable_id(candidate, sha):
    """Public identity only: Civitai ids or the Hugging Face repo and file, else the file's SHA-256 prefix."""
    public = candidate["public"]
    if public.get("model_id") and public.get("version_id"):
        return f"civitai-{public['model_id']}-{public['version_id']}"
    if public.get("repo") and public.get("file"):
        return f"hf-{slug(public['repo'])}-{slug(public['file'])}"
    return f"sha256-{sha[:12]}"


# An absolute path, with or without `file://`, up to and including its last directory separator, so only the file name is
# left. Directory names may hold spaces and the path may sit inside quotes or after `key=`, so the match runs to the
# nearest quote, bracket or line end. A URL is left alone: its `//` and `:` are not a path start. Over-scrubbing free
# text that happens to hold a slash is the safe error here.
ABSOLUTE_PATH = re.compile(r"(?<![\w./:])(?:file://)?/(?:[^/'\"<>()\n]+/)*")


def scrub(value):
    """Drops every absolute path from a verdict, recursively, so nothing local reaches the repo (R23)."""
    if isinstance(value, dict):
        return {key: scrub(item) for key, item in value.items()}
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, str):
        return ABSOLUTE_PATH.sub("", value)
    return value


# --- candidates -------------------------------------------------------------------------------------------------


def candidate_from_entry(entry):
    """One candidate: a local file read in place, plus whatever public identity identifies it."""
    source = entry.get("source") or "local"
    public = {}
    if source == "civitai" and entry.get("model_id") and entry.get("version_id"):
        public = {"source": source, "model_id": entry["model_id"], "version_id": entry["version_id"]}
    elif source == "huggingface" and entry.get("repo") and entry.get("file"):
        public = {"source": source, "repo": entry["repo"], "file": entry["file"]}
    stem = os.path.splitext(os.path.basename(entry["path"]))[0]
    names = [name for name in (entry.get("name"), stem) if name]
    return {"source": source, "public": public, "path": entry["path"], "family": entry.get("family"), "names": names}


def first_key(mapping, *keys):
    for key in keys:
        if mapping.get(key):
            return mapping[key]
    return None


def candidate_from_local_file(path):
    """A file in place. A sibling `.cm-info.json` supplies the Civitai ids it was downloaded with, when present."""
    info = {}
    sibling = os.path.splitext(path)[0] + ".cm-info.json"
    if os.path.exists(sibling):
        try:
            with open(sibling) as handle:
                info = json.load(handle)
        except (OSError, ValueError):
            info = {}
    if not isinstance(info, dict):
        info = {}
    entry = {"path": path, "name": first_key(info, "modelName", "model_name", "name")}
    model_id = first_key(info, "modelId", "model_id")
    version_id = first_key(info, "modelVersionId", "versionId", "model_version_id", "version_id")
    if model_id and version_id:
        entry.update({"source": "civitai", "model_id": model_id, "version_id": version_id})
    return candidate_from_entry(entry)


def load_candidates(args):
    if args.candidates:
        with open(args.candidates) as handle:
            data = json.load(handle)
        entries = data.get("candidates") if isinstance(data, dict) else data
        return [candidate_from_entry(entry) for entry in entries or []]
    if not os.path.isdir(args.local_dir):
        raise SystemExit(f"--local-dir is not a directory: {args.local_dir}")
    found = [
        os.path.join(args.local_dir, name)
        for name in sorted(os.listdir(args.local_dir))
        if name.lower().endswith(".safetensors")
    ]
    return [candidate_from_local_file(path) for path in found]


# --- usage counts (harness-internal) ----------------------------------------------------------------------------


def png_text_chunks(path):
    """Yields (keyword, text) for every tEXt chunk of a PNG, reading chunk headers only."""
    with open(path, "rb") as handle:
        if handle.read(8) != b"\x89PNG\r\n\x1a\n":
            return
        while True:
            header = handle.read(8)
            if len(header) < 8:
                return
            length = int.from_bytes(header[:4], "big")
            kind = header[4:]
            payload = handle.read(length)
            handle.read(4)  # CRC
            if kind == b"tEXt":
                keyword, _, text = payload.partition(b"\x00")
                yield keyword.decode("latin-1"), text.decode("latin-1")
            if kind == b"IEND":
                return


def usage_counts(png_dir):
    """LoRA name (lowercased) to the number of InvokeAI images that applied it. Counts only; names never ship."""
    counts = {}
    if not png_dir or not os.path.isdir(png_dir):
        return counts
    for name in sorted(os.listdir(png_dir)):
        if not name.lower().endswith(".png"):
            continue
        for keyword, text in png_text_chunks(os.path.join(png_dir, name)):
            if keyword != "invokeai_metadata":
                continue
            try:
                metadata = json.loads(text)
            except ValueError:
                continue
            for lora in metadata.get("loras") or []:
                model = (lora or {}).get("model") or {}
                label = model.get("name") if isinstance(model, dict) else None
                if label:
                    key = label.strip().lower()
                    counts[key] = counts.get(key, 0) + 1
    return counts


def usage_for(candidate, counts):
    keys = [name.strip().lower() for name in candidate["names"]]
    return max([counts.get(key, 0) for key in keys] or [0])


# --- engine -----------------------------------------------------------------------------------------------------


class EngineRejected(Exception):
    """The engine refused a request; `message` is its own text and is scrubbed before it reaches a verdict."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def request(port, key, method, path, body=None, timeout=600):
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/{path}",
        method=method,
        data=payload,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.status, response.read().decode()


def generate(port, key, prompt, context, lora_paths=None, lora_scales=None, timeout=900):
    """One image as PNG bytes. Field names and the SSE shape follow Sources/MCEngine/ImageRequest.swift."""
    body = {
        "model": context["model_id"],
        "prompt": prompt,
        "size": f"{context['size']}x{context['size']}",
        "steps": context["steps"],
        "seed": context["seed"],
        "stream": True,
    }
    if lora_paths:
        body["lora_paths"] = lora_paths
        body["lora_scales"] = lora_scales
    req = urllib.request.Request(
        f"http://127.0.0.1:{context['port']}/v1/images/generations",
        method="POST",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {context['key']}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            for raw in response:
                line = raw.decode().strip()
                if not line.startswith("data:"):
                    continue
                try:
                    event = json.loads(line[5:].strip())
                except ValueError:
                    continue
                kind = event.get("type")
                if kind == "complete":
                    encoded = ((event.get("data") or [{}])[0] or {}).get("b64_json")
                    if not encoded:
                        raise EngineRejected(200, "the complete event carried no image")
                    return base64.b64decode(encoded)
                if kind == "error":
                    raise EngineRejected(200, (event.get("error") or {}).get("message") or "engine error")
    except urllib.error.HTTPError as error:
        raise EngineRejected(error.code, error.read().decode(errors="replace")) from error
    except (urllib.error.URLError, OSError) as error:
        raise EngineRejected(0, f"lost the connection to the engine: {error}") from error
    raise EngineRejected(0, "the stream ended before an image arrived")


def engine_version(binary):
    try:
        done = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    lines = (done.stdout or done.stderr).strip().splitlines()
    return lines[0].replace("mlx-serve", "").strip() if lines else "unknown"


def launch(engine, weights, scratch):
    """Starts the pinned engine per AGENTS.md rules 3-5 and docs/lld/engine.md section 5.9."""
    home = os.path.join(scratch, "home")
    host_tmp = os.path.join(scratch, "tmp")
    model_dir = os.path.join(scratch, "model-dir")
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(model_dir, ignore_errors=True)
    os.makedirs(os.path.join(home, ".mlx-serve"))
    os.makedirs(host_tmp, exist_ok=True)
    os.makedirs(model_dir)
    for org in sorted(os.listdir(weights)):
        source = os.path.join(weights, org)
        if os.path.isdir(source):
            os.symlink(source, os.path.join(model_dir, org))
    os.symlink(model_dir, os.path.join(home, ".mlx-serve", "models"))
    port, key = free_port(), secrets.token_hex(24)
    argv = [
        engine,
        "--serve",
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--api-key-env",
        KEY_ENV,
        "--api-key-strict",
        "--model-dir",
        model_dir,
        "--max-resident-mem",
        "auto",
        "--max-resident-models",
        "1",
        "--log-level",
        "info",
    ]
    env = {"HOME": home, KEY_ENV: key, "PATH": "/usr/bin:/bin", "TMPDIR": host_tmp}
    log_path = os.path.join(scratch, "engine.log")
    log = open(log_path, "w")
    proc = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT)
    return proc, log, port, key


def wait_healthy(port, timeout=240):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                if json.loads(response.read()).get("status") == "ok":
                    return
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(0.5)
    raise SystemExit("the engine never became healthy; see engine.log in the scratch directory")


# --- checks -----------------------------------------------------------------------------------------------------


def classify(command, path, family):
    """Runs `mc-catalog lora classify`; the fingerprint rules stay in families.json, never in Python (KTD8)."""
    argv = list(command) + ["lora", "classify", path]
    if family:
        argv += ["--family", family]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, cwd=REPO, timeout=900)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"result": "error", "reason": f"mc-catalog did not run: {error}"}
    if done.returncode != 0:
        return {"result": "error", "reason": (done.stderr or done.stdout).strip()[:2000]}
    try:
        return json.loads(done.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"result": "error", "reason": "mc-catalog printed no JSON"}


def write_image(scratch, ident, suffix, png):
    with open(os.path.join(scratch, f"{ident}-{suffix}.png"), "wb") as handle:
        handle.write(png)


def finish(verdict):
    failed = [name for name in CHECK_ORDER if not (verdict["checks"].get(name) or {}).get("ok")]
    if failed:
        verdict["verdict"] = "reject"
        verdict["reason"] = f"{failed[0]}: {verdict['checks'][failed[0]]['reason']}"
    else:
        verdict["verdict"] = "pass"
        verdict["reason"] = "all four checks passed"
    return verdict


def run_candidate(candidate, context, prompt, baseline, counts):
    path = candidate["path"]
    sha = sha256_of(path)
    ident = stable_id(candidate, sha)
    verdict = {
        "id": ident,
        "source": candidate["source"],
        "public": candidate["public"],
        "sha256": sha,
        "family": None,
        "variant": None,
        "engine": context["engine"],
        "model_id": context["model_id"],
        "prompt_id": context["prompt_id"],
        "size": context["size"],
        "steps": context["steps"],
        "seed": context["seed"],
        "checks": {},
        "verdict": "reject",
        "reason": "",
        # Harness-internal: the author weighs it when judging (R16) and it never reaches the catalog (R23).
        "usage_count": usage_for(candidate, counts),
    }
    checks = verdict["checks"]

    fit = classify(context["mc_catalog"], path, candidate["family"] or context["family"])
    verdict["family"] = fit.get("family")
    verdict["variant"] = fit.get("variant")
    checks["header_fit"] = {
        "ok": fit.get("result") == "matched",
        "result": fit.get("result"),
        "reason": fit.get("reason") or "no reason reported",
    }
    if not checks["header_fit"]["ok"]:
        return finish(verdict)

    try:
        png = generate(context["port"], context["key"], prompt, context, [path], [1.0])
    except EngineRejected as error:
        checks["engine_load"] = {
            "ok": False,
            "reason": (
                "the engine reported no modules matching, so the file does not map onto this model"
                if NO_MODULES in error.message
                else "engine rejected the request: " + error.message[:500]
            ),
        }
        return finish(verdict)
    checks["engine_load"] = {"ok": True, "reason": "applied at scale 1.0"}
    write_image(context["scratch"], ident, "lora", png)

    try:
        repeat = generate(context["port"], context["key"], prompt, context, [path], [1.0])
    except EngineRejected as error:
        checks["reproducible"] = {"ok": False, "reason": "engine rejected the repeat request: " + error.message[:500]}
        return finish(verdict)
    write_image(context["scratch"], ident, "repeat", repeat)
    checks["reproducible"] = {
        "ok": repeat == png,
        "reason": "identical bytes at the same seed" if repeat == png else "the same seed returned a different image",
    }
    if not checks["reproducible"]["ok"]:
        return finish(verdict)

    try:
        zero = generate(context["port"], context["key"], prompt, context, [path], [0.0])
    except EngineRejected as error:
        checks["strength_zero"] = {
            "ok": False,
            "reason": "engine rejected the strength-0 request: " + error.message[:500],
        }
        return finish(verdict)
    write_image(context["scratch"], ident, "scale0", zero)
    matches = zero == baseline
    checks["strength_zero"] = {
        "ok": matches,
        "reason": (
            "strength 0 matches the no-LoRA baseline byte for byte"
            if matches
            else "strength 0 differs from the no-LoRA baseline"
        ),
    }
    return finish(verdict)


def selected_prompt(path, prompt_id):
    with open(path) as handle:
        prompt_set = json.load(handle)
    prompts = prompt_set.get("prompts") or []
    if prompt_id:
        prompts = [entry for entry in prompts if entry.get("id") == prompt_id]
    if not prompts:
        raise SystemExit(f"{os.path.basename(path)} carries no prompt to run (status {prompt_set.get('status')!r})")
    return prompts[0]


def main(argv):
    parser = argparse.ArgumentParser(description="Pre-screen LoRA candidates against the pinned engine (plan U2).")
    parser.add_argument("--engine", default=os.environ.get("MLXC_ENGINE_BIN"), help="pinned mlx-serve binary")
    parser.add_argument("--weights", required=True, help="directory holding ORG/NAME model folders, read only")
    parser.add_argument("--model-id", required=True, help="installed image model id, e.g. ORG/NAME")
    parser.add_argument("--scratch", required=True, help="scratch directory outside the repo for images and state")
    parser.add_argument("--candidates", help="candidate list JSON; each entry names a local file and its public ids")
    parser.add_argument("--local-dir", help="directory of *.safetensors to read in place, with sibling *.cm-info.json")
    parser.add_argument("--png-dir", help="InvokeAI PNGs, read for usage counts only")
    parser.add_argument("--mc-catalog", help="mc-catalog binary (default: swift run mc-catalog in this repo)")
    parser.add_argument("--family", help="expected family for every candidate without its own")
    parser.add_argument("--prompt-set", default=os.path.join(HERE, "prompts", "ordinary.json"))
    parser.add_argument("--prompt-id", help="prompt in the set to run; the first one by default")
    parser.add_argument("--size", type=int, default=512, help="square image side in pixels")
    parser.add_argument("--steps", type=int, default=4)
    parser.add_argument("--seed", type=int, default=None, help="overrides the prompt set's seed")
    parser.add_argument("--limit", type=int, default=0, help="first N candidates only")
    parser.add_argument("--results", default=os.path.join(HERE, "results"))
    args = parser.parse_args(argv)

    if not args.engine:
        raise SystemExit("pass --engine or set MLXC_ENGINE_BIN to the pinned mlx-serve binary")
    if not (os.path.exists(args.engine) or shutil.which(args.engine)):
        raise SystemExit(f"--engine is not an executable: {args.engine}")
    if not os.path.isdir(args.weights):
        raise SystemExit(f"--weights is not a directory: {args.weights}")
    if bool(args.candidates) == bool(args.local_dir):
        raise SystemExit("pass exactly one of --candidates and --local-dir")
    if os.path.abspath(args.scratch).startswith(REPO + os.sep):
        raise SystemExit("--scratch must be outside the repo: images and engine state never get committed")

    prompt = selected_prompt(args.prompt_set, args.prompt_id)
    seed = args.seed if args.seed is not None else int(prompt["seed"])
    candidates = load_candidates(args)
    if args.limit:
        candidates = candidates[: args.limit]
    if not candidates:
        raise SystemExit("no candidates found")
    counts = usage_counts(args.png_dir)

    os.makedirs(args.scratch, exist_ok=True)
    os.makedirs(args.results, exist_ok=True)
    context = {
        "engine": engine_version(args.engine),
        "model_id": args.model_id,
        "prompt_id": prompt.get("id"),
        "size": args.size,
        "steps": args.steps,
        "seed": seed,
        "scratch": args.scratch,
        "family": args.family,
        "mc_catalog": [args.mc_catalog] if args.mc_catalog else ["swift", "run", "mc-catalog"],
    }

    proc, log, port, key = launch(args.engine, args.weights, args.scratch)
    context.update({"port": port, "key": key})
    try:
        wait_healthy(port)
        _, body = request(port, key, "GET", "v1/models")
        listed = [model.get("id") for model in json.loads(body).get("data", [])]
        if args.model_id not in listed:
            raise SystemExit(f"{args.model_id} is not installed: {', '.join(sorted(filter(None, listed)))}")
        baseline = generate(port, key, prompt["text"], context)
        write_image(args.scratch, "baseline", prompt.get("id") or "prompt", baseline)
        for candidate in candidates:
            verdict = scrub(run_candidate(candidate, context, prompt["text"], baseline, counts))
            with open(os.path.join(args.results, f"{verdict['id']}.json"), "w") as handle:
                json.dump(verdict, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print(
                f"{verdict['id']} {verdict['verdict']} fit={verdict['checks'].get('header_fit', {}).get('result')}"
                f" usage={verdict['usage_count']} :: {verdict['reason']}",
                flush=True,
            )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    print(f"wrote {len(candidates)} verdict(s) to {os.path.basename(args.results)}")
    return 0


def self_check():
    """Offline: the scrub and stable-id rules the verdicts depend on. Starts no engine and reads no files."""
    sample = {
        "id": "sha256-0123456789ab",
        "path": "/Users/someone/Models/LoRAs/personal-name.safetensors",
        "checks": {
            "engine_load": {
                "ok": False,
                "reason": "rejected /Users/someone/weights/model.safetensors: no modules matching",
            }
        },
        "scratch": ["/tmp/lora-gate/run/x.png"],
    }
    cleaned = scrub(sample)
    assert "Users" not in json.dumps(cleaned), cleaned
    assert cleaned["path"] == "personal-name.safetensors", cleaned["path"]
    assert cleaned["checks"]["engine_load"]["reason"] == "rejected model.safetensors: no modules matching"
    assert cleaned["scratch"] == ["x.png"]
    for text, kept in [
        ("failed '/Users/someone/x/lora.safetensors'", "failed 'lora.safetensors'"),
        ("path=/Users/someone/x/lora.safetensors", "path=lora.safetensors"),
        ("(/Applications/Data/Models/lora.safetensors)", "(lora.safetensors)"),
        ("file:///Users/someone/x/lora.safetensors", "lora.safetensors"),
        ("/Users/someone/My Models/lora.safetensors", "lora.safetensors"),
        ("see https://civitai.com/api/v1/models/1", "see https://civitai.com/api/v1/models/1"),
    ]:
        assert scrub(text) == kept, (text, scrub(text))
    assert stable_id({"public": {"model_id": 2775340, "version_id": 3359022}}, "ab" * 32) == "civitai-2775340-3359022"
    assert stable_id({"public": {"repo": "org/name", "file": "a/b.safetensors"}}, "ab" * 32) == "hf-org-name-a-b-safetensors"
    assert stable_id({"public": {}}, "abcdef0123456789" + "0" * 48) == "sha256-abcdef012345"
    print("self-check ok")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        self_check()
    else:
        sys.exit(main(sys.argv[1:]))
