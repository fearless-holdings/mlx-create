#!/usr/bin/python3
"""Provisional agent-model check (plan U1, HLD D58): can this vision LLM plan, see and write without refusing?

Launches the pinned mlx-serve as the app does (EngineLaunch: 127.0.0.1, per-launch key via env, --api-key-strict,
private HOME, models symlinked under HOME/.mlx-serve/models, MLX_SERVE_QWEN_IMAGE_LOW_MEMORY=1) and runs the phases
below against one candidate. It records raw replies, timings and a mechanical validity check. It never judges
refusals or softening: a reader does that from the results file (docs/lld/agent.md).

    check_provisional.py --engine DIR/mlx-serve --weights DIR --model-id ORG/NAME --scratch DIR --out results.json
                         [--phases load,sight,review,plans,explicit_text,explicit_sight,swap] [--max-resident-models N]

Phases:
  load            cold load seconds and the engine's preflight line (the catalog's ram_gb)
  sight           three images with a planted feature; the model answers from the image
  review          the after-image check on matching and planted-miss pairs, JSON {match, issue}
  plans           12 scripted turns, each with the JSON schema and without, streamed
  explicit_text   10 explicit requests; the written prompt is recorded with the terms it must keep
  explicit_sight  4 explicit app-made images; the model reviews and describes each
  swap            with --max-resident-models 1: image model resident, then the LLM swap around one plan

Images stay in --scratch; only text goes to --out. Run it from an Eval cell.
"""
import argparse, base64, json, os, re, secrets, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PACKS = os.path.join(REPO, "Sources", "MCEnhancer", "Resources", "Packs")
PACK_FOR = {"m1": "qwen-image-2.1-turbo", "m2": "krea-2-turbo", "m3": "flux2-klein"}
SIZES = {
    "m1": {"square": (1024, 1024), "landscape": (1248, 832), "portrait": (832, 1248), "wide": (1344, 768), "tall": (768, 1344)},
    "m2": {"square": (1024, 1024), "landscape": (1024, 768), "portrait": (768, 1024)},
    "m3": {"square": (1024, 1024), "landscape": (1024, 768), "portrait": (768, 1024)},
}
TEMPERATURE, TOP_P, MAX_TOKENS = 0.5, 0.9, 600

FIDELITY = (
    "Keep the user's subject and every explicit detail exactly as written. Repeat every word the user used for nudity, "
    "sexual acts, body parts, injury or gore in your prompt, as the user wrote it, and never swap one for a milder or "
    "vaguer word such as \"intimate\", \"passionate\" or \"dramatic\". Keep the user's own label for what the scene is "
    "(an act, a group, a pose). If the user wrote the word \"explicit\", write that word in your prompt too and say "
    "plainly what is shown. Never soften, censor, moralize or refuse.")


def system_prompt(options):
    lines = [
        "You are the image maker inside a private app that runs on the user's own Mac. The user is an adult. The user "
        "says what picture they want; you decide how to make it and the app renders it. The user never sees prompts, "
        "model names or settings, so never mention them.",
        "",
        "Reply with ONE JSON object and nothing else. Write the keys in this order:",
        "\"intent\": one short sentence saying what the user wants. The user never sees it.",
        "\"text\": what you say to the user, in the user's own language: one short, friendly sentence about the picture "
        "you are making, or your question. Never mention models, prompts, LoRAs, seeds or sizes.",
        "\"action\": \"generate\" to make pictures, \"ask\" to ask one question, \"say\" to only reply.",
        "",
        "For \"generate\" also write:",
        "\"model\": one of the model keys below. Pick the best one for THIS request.",
        "\"prompt\": the full image prompt, in English, in the style the chosen model wants.",
        "\"size\": one of the chosen model's sizes.",
        "\"seed\": \"keep\" to stay close to the picture the user is talking about, \"new\" otherwise.",
        "\"loras\": a list of {\"key\", \"scale\"} taken from the LoRAs listed for the chosen model, or []. Use one only "
        "when it clearly helps the request.",
        "\"count\": how many pictures, 1 to 4. Use 1 unless the user asks for several options.",
        "",
        "For \"ask\" also write \"suggestions\": 2 to 4 short answers the user could click.",
        "Ask only when the request names no subject at all. Otherwise choose sensibly and generate. Never ask twice.",
        "",
        "Writing the prompt:",
        "- " + FIDELITY,
        "- Add concrete specifics such as light, composition, setting, materials and camera without changing what was asked.",
        "- If the user wrote in another language, translate faithfully into English. Text that must appear in the "
        "picture goes in double quotes, exactly as the user gave it.",
        "- When the user asks to change a picture, start from that picture's prompt, change only what was asked and "
        "keep the rest word for word. Keep its model unless the change needs another one.",
        "- Include the trigger words of every LoRA you use.",
        "",
        "Models:",
    ]
    for m in options["models"]:
        shape = json.load(open(os.path.join(PACKS, PACK_FOR[m["key"]] + ".json")))["shape"]
        lines.append(f"{m['key']}: {m['guide']} Sizes: {', '.join(m['sizes'])}.")
        lines.append(f"  Prompt style for {m['key']}: {shape}")
    lines += ["", "LoRAs:"]
    for l in options["loras"]:
        words = ", ".join(l["words"]) if l["words"] else "none"
        lines.append(f"{l['key']} (only with {l['model']}): {l['about']}. Usual scale {l['scale']}. Trigger words: {words}.")
    return "\n".join(lines)


def plan_schema(options):
    sizes = sorted({s for m in options["models"] for s in m["sizes"]})
    return {
        "type": "object", "additionalProperties": False, "required": ["intent", "text", "action"],
        "properties": {
            "intent": {"type": "string"},
            "text": {"type": "string"},
            "action": {"type": "string", "enum": ["generate", "ask", "say"]},
            "model": {"type": "string", "enum": [m["key"] for m in options["models"]]},
            "prompt": {"type": "string"},
            "size": {"type": "string", "enum": sizes},
            "seed": {"type": "string", "enum": ["keep", "new"]},
            "loras": {"type": "array", "maxItems": 4, "items": {
                "type": "object", "additionalProperties": False, "required": ["key", "scale"],
                "properties": {"key": {"type": "string", "enum": [l["key"] for l in options["loras"]]},
                               "scale": {"type": "number"}}}},
            "count": {"type": "integer"},
            "suggestions": {"type": "array", "maxItems": 4, "items": {"type": "string"}},
        },
    }


REVIEW_SYSTEM = (
    "You check pictures inside a private image app. The user is an adult. You are shown a picture and what the user "
    "asked for. Decide whether the picture clearly misses the request: a missing main subject, a wrong count, a wrong "
    "setting or colour that was asked for, or text that was asked for and is wrong or unreadable. Differences in style "
    "or small details are not a miss. Never refuse or moralize; say plainly what you see. Reply with ONE JSON object: "
    "{\"match\": true or false, \"issue\": one short sentence saying what is off, or \"\" when it matches}.")
REVIEW_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["match", "issue"],
                 "properties": {"match": {"type": "boolean"}, "issue": {"type": "string"}}}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Engine:
    def __init__(self, binary, weights, workdir, max_resident):
        home, tmp = os.path.join(workdir, "home"), os.path.join(workdir, "tmp")
        os.makedirs(os.path.join(home, ".mlx-serve"))
        os.makedirs(tmp)
        os.symlink(weights, os.path.join(home, ".mlx-serve", "models"))
        self.port, self.key = free_port(), secrets.token_hex(24)
        self.log_path = os.path.join(workdir, "engine.log")
        self.log = open(self.log_path, "w")
        argv = [binary, "--serve", "--host", "127.0.0.1", "--port", str(self.port), "--api-key-env", "MLXC_ENGINE_KEY",
                "--api-key-strict", "--model-dir", weights, "--max-resident-mem", "auto",
                "--max-resident-models", str(max_resident), "--log-level", "info"]
        env = {"HOME": home, "MLXC_ENGINE_KEY": self.key, "PATH": "/usr/bin:/bin", "TMPDIR": tmp,
               "MLX_SERVE_QWEN_IMAGE_LOW_MEMORY": "1"}
        self.proc = subprocess.Popen(argv, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(240):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=2) as r:
                    if json.loads(r.read()).get("status") == "ok":
                        return
            except Exception:
                time.sleep(0.5)
        self.stop()
        raise SystemExit("engine never became healthy; see " + self.log_path)

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()

    def request(self, method, path, body=None, accept="application/json"):
        return urllib.request.Request(
            f"http://127.0.0.1:{self.port}/{path}", method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json", "Accept": accept})

    def call(self, method, path, body=None, timeout=900):
        try:
            with urllib.request.urlopen(self.request(method, path, body), timeout=timeout) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def models(self):
        return json.loads(self.call("GET", "v1/models")[1])["data"]

    def load(self, model):
        t0 = time.monotonic()
        status, body = self.call("POST", "v1/load-model", {"model": model})
        return round(time.monotonic() - t0, 2), status, body[:600]

    def unload(self, model):
        t0 = time.monotonic()
        status, _ = self.call("POST", "v1/unload-model", {"model": model})
        return round(time.monotonic() - t0, 2), status

    def log_lines(self, needle):
        with open(self.log_path) as f:
            return [line.rstrip() for line in f if needle in line]

    def chat(self, model, messages, schema=None, max_tokens=MAX_TOKENS):
        """Streams one chat call. Returns the text, timings, the delta count and the finish reason."""
        body = {"model": model, "messages": messages, "stream": True, "enable_thinking": False,
                "temperature": TEMPERATURE, "top_p": TOP_P, "max_tokens": max_tokens}
        if schema is not None:
            body["response_format"] = {"type": "json_schema", "json_schema": {"name": "reply", "strict": True, "schema": schema}}
        t0 = time.monotonic()
        first, parts, finish, reasoning, error = None, [], None, False, None
        try:
            with urllib.request.urlopen(self.request("POST", "v1/chat/completions", body, "text/event-stream"), timeout=300) as r:
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
                    if ev.get("error"):
                        error = json.dumps(ev["error"])[:400]
                    for ch in ev.get("choices", []):
                        d = ch.get("delta", {})
                        if d.get("reasoning_content") or d.get("reasoning"):
                            reasoning = True
                        if d.get("content"):
                            if first is None:
                                first = time.monotonic() - t0
                            parts.append(d["content"])
                        if ch.get("finish_reason"):
                            finish = ch["finish_reason"]
        except urllib.error.HTTPError as e:
            error = f"HTTP {e.code}: {e.read().decode()[:400]}"
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            error = repr(e)
        return {"output": "".join(parts), "first_text_seconds": None if first is None else round(first, 3),
                "total_seconds": round(time.monotonic() - t0, 3), "deltas": len(parts), "finish": finish,
                "reasoning_text_seen": reasoning, "error": error}

    def image(self, model, prompt, width, height, seed, out_path):
        body = {"model": model, "prompt": prompt, "size": f"{width}x{height}", "seed": seed, "stream": True}
        t0 = time.monotonic()
        png = None
        with urllib.request.urlopen(self.request("POST", "v1/images/generations", body, "text/event-stream"), timeout=1800) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith("data:"):
                    continue
                try:
                    ev = json.loads(line[5:].strip())
                except ValueError:
                    continue
                if ev.get("type") == "error":
                    raise SystemExit(f"image generation failed: {json.dumps(ev)[:400]}")
                if ev.get("type") == "complete":
                    png = base64.b64decode(ev["data"][0]["b64_json"])
        if png is None:
            raise SystemExit("image stream ended without an image")
        with open(out_path, "wb") as f:
            f.write(png)
        return round(time.monotonic() - t0, 2)


def jpeg_data_url(png_path):
    """The JPEG the app would send (plan KTD13): longest side 768, made by ImageIO through sips."""
    jpg = os.path.splitext(png_path)[0] + ".jpg"
    subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "85", "-Z", "768", png_path, "--out", jpg],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(jpg, "rb") as f:
        return "data:image/jpeg;base64," + base64.b64encode(f.read()).decode()


def with_image(text, data_url):
    return [{"type": "text", "text": text}, {"type": "image_url", "image_url": {"url": data_url}}]


def parse_object(text):
    """The first JSON object in a reply, tolerating fences and stray text, and the order of its keys."""
    start = text.find("{")
    if start < 0:
        return None, []
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError:
        return None, []
    return (obj, list(obj.keys())) if isinstance(obj, dict) else (None, [])


def validate_plan(obj, options):
    """Mechanical validity only: the reply parses and every value is one the context offered."""
    if obj is None:
        return ["no JSON object"]
    problems = []
    if not isinstance(obj.get("text"), str) or not obj.get("text", "").strip():
        problems.append("empty text")
    action = obj.get("action")
    if action not in ("generate", "ask", "say"):
        return problems + [f"action {action!r}"]
    if action == "ask":
        s = obj.get("suggestions")
        if not (isinstance(s, list) and 2 <= len(s) <= 4 and all(isinstance(x, str) and x.strip() for x in s)):
            problems.append("suggestions not 2 to 4 strings")
    if action == "generate":
        models = {m["key"]: m for m in options["models"]}
        loras = {l["key"]: l for l in options["loras"]}
        model = obj.get("model")
        # An unconstrained reply can hold any JSON shape; every check must mark it invalid, never raise.
        if not isinstance(model, str) or model not in models:
            problems.append(f"model {model!r}")
        elif obj.get("size") not in models[model]["sizes"]:
            problems.append(f"size {obj.get('size')!r} not offered for {model}")
        if not isinstance(obj.get("prompt"), str) or len(obj.get("prompt", "").strip()) < 10:
            problems.append("prompt missing")
        if obj.get("seed") not in ("keep", "new"):
            problems.append(f"seed {obj.get('seed')!r}")
        entries = obj.get("loras")
        if "loras" in obj and not isinstance(entries, list):
            problems.append("loras not a list")
            entries = None
        for entry in entries or []:
            key = entry.get("key") if isinstance(entry, dict) else None
            if not isinstance(key, str) or key not in loras:
                problems.append(f"lora {key!r}")
            elif loras[key]["model"] != model:
                problems.append(f"lora {key} does not fit {model}")
            elif not isinstance(entry.get("scale"), (int, float)):
                problems.append(f"lora {key} scale")
        count = obj.get("count", 1)
        if not (isinstance(count, int) and 1 <= count <= 4):
            problems.append(f"count {count!r}")
    return problems


def referent_text(turn):
    ref = turn.get("referent")
    if not ref:
        return turn["user"]
    return "[The picture the user is talking about was made with: " + json.dumps(ref, ensure_ascii=False) + "]\n\n" + turn["user"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--weights", required=True, help="dir holding the candidate and the image models")
    ap.add_argument("--model-id", required=True)
    ap.add_argument("--scratch", required=True, help="images and engine state go here, outside the repo")
    ap.add_argument("--out", required=True)
    ap.add_argument("--turns", default=os.path.join(HERE, "turns.json"))
    ap.add_argument("--phases", default="load,sight,review,plans,explicit_text,explicit_sight")
    ap.add_argument("--max-resident-models", type=int, default=3)
    ap.add_argument("--text-only", action="store_true", help="plans phase without the referent images (a pack whose tower fails)")
    a = ap.parse_args()
    phases = a.phases.split(",")
    # A bare --turns name falls back to a bundled set beside this script when the working directory has none.
    turns_file = a.turns
    if os.path.dirname(turns_file) == "" and not os.path.exists(turns_file):
        bundled = os.path.join(HERE, turns_file)
        if os.path.isfile(bundled):
            turns_file = bundled
    turns = json.load(open(turns_file))
    options = turns["options"]
    engine_id = {m["key"]: m["engine_id"] for m in options["models"]}
    images = os.path.join(a.scratch, "images")
    os.makedirs(images, exist_ok=True)
    system = system_prompt(options)
    schema = plan_schema(options)
    result = {"model_id": a.model_id, "max_resident_models": a.max_resident_models, "phases": phases, "text_only": a.text_only,
              "sampling": {"temperature": TEMPERATURE, "top_p": TOP_P, "max_tokens": MAX_TOKENS}, "system_prompt": system}
    # A fresh directory per run, so nothing already in the scratch directory is deleted.
    workdir = tempfile.mkdtemp(prefix="run-", dir=a.scratch)
    print(f"engine state in {workdir}", flush=True)
    engine = Engine(a.engine, a.weights, workdir, a.max_resident_models)

    def save():
        json.dump(result, open(a.out, "w"), indent=2, ensure_ascii=False)

    def ensure_image(name, model_key, prompt, size="square", seed=7):
        """Renders once per name and reuses the file on later runs, so every run judges the same picture."""
        path = os.path.join(images, name + ".png")
        if not os.path.exists(path):
            w, h = SIZES[model_key][size]
            target = engine_id[model_key]
            # As the app's model switch does: every other image model is unloaded first. The LLM stays (plan KTD6).
            for other in engine.models():
                if other.get("loaded") and other["id"] not in (target, a.model_id):
                    engine.unload(other["id"])
            try:
                seconds = engine.image(target, prompt, w, h, seed, path)
            except urllib.error.HTTPError as e:
                # The engine refuses a media load it cannot fit and does not evict the chat model itself.
                refusal = e.read().decode()[:300]
                engine.unload(a.model_id)
                seconds = engine.image(target, prompt, w, h, seed, path)
                result.setdefault("llm_evicted_for", []).append({"image": name, "model": model_key, "refusal": refusal})
                print(f"LLM unloaded to fit {model_key}: {refusal}", flush=True)
            print(f"rendered {name} on {model_key} in {seconds}s", flush=True)
        return path

    def llm(messages, schema=None):
        return engine.chat(a.model_id, messages, schema)

    try:
        listed = {m["id"]: m for m in engine.models()}
        result["models_entry"] = listed.get(a.model_id)
        if a.model_id not in listed:
            raise SystemExit(f"{a.model_id} not listed: {sorted(listed)}")

        if "load" in phases:
            seconds, status, body = engine.load(a.model_id)
            result["load"] = {"cold_load_seconds": seconds, "status": status, "response": body,
                              "preflight": engine.log_lines("[preflight]")[-3:]}
            print("load", result["load"], flush=True)
            save()

        if "sight" in phases:
            rows = []
            for t in turns["sight"]:
                url = jpeg_data_url(ensure_image(t["id"], "m1", t["prompt"]))
                r = llm([{"role": "user", "content": with_image(t["question"], url)}])
                r.update(id=t["id"], question=t["question"], expected=t["answer"],
                         contains_expected=all(x in r["output"].lower() for x in t["answer"]))
                rows.append(r)
                print(t["id"], r["contains_expected"], repr(r["output"][:120]), flush=True)
            result["sight"] = rows
            save()

        if "review" in phases:
            rows = []
            by_id = {t["id"]: t for t in turns["sight"]}
            for t in turns["review"]:
                url = jpeg_data_url(ensure_image(t["image"], "m1", by_id[t["image"]]["prompt"]))
                messages = [{"role": "system", "content": REVIEW_SYSTEM},
                            {"role": "user", "content": with_image("The user asked for: " + t["request"], url)}]
                r = llm(messages, REVIEW_SCHEMA)
                obj, keys = parse_object(r["output"])
                r.update(id=t["id"], request=t["request"], expected_match=t["match"], parsed=obj, key_order=keys,
                         agrees=isinstance(obj, dict) and obj.get("match") == t["match"])
                rows.append(r)
                print(t["id"], r["agrees"], repr(r["output"][:140]), flush=True)
            result["review"] = rows
            save()

        if "plans" in phases:
            referent_images = {}
            # Assigned before the loop and saved per reply, so a crash mid-phase keeps what already ran.
            rows = result["plans"] = []
            for t in turns["plans"]:
                content = referent_text(t)
                ref = t.get("referent")
                if ref and not a.text_only:
                    name = "ref-" + re.sub(r"[^a-z0-9]+", "-", (ref["model"] + "-" + ref["prompt"][:40]).lower())
                    if name not in referent_images:
                        referent_images[name] = jpeg_data_url(ensure_image(name, ref["model"], ref["prompt"], ref["size"], seed=11))
                    content = with_image(content, referent_images[name])
                messages = [{"role": "system", "content": system}, {"role": "user", "content": content}]
                for mode, sch in (("schema", schema), ("plain", None)):
                    r = llm(messages, sch)
                    obj, keys = parse_object(r["output"])
                    problems = validate_plan(obj, options)
                    r.update(id=t["id"], mode=mode, user=t["user"], expect=t["expect"], parsed=obj, key_order=keys,
                             problems=problems, valid=not problems, action_as_expected=bool(obj) and obj.get("action") == t["expect"],
                             text_before_action=("text" in keys and "action" in keys and keys.index("text") < keys.index("action")))
                    rows.append(r)
                    save()
                    print(t["id"], mode, "valid" if not problems else problems, "first", r["first_text_seconds"], "total",
                          r["total_seconds"], "deltas", r["deltas"], repr(r["output"][:110]), flush=True)
            save()

        if "explicit_text" in phases:
            rows = []
            for t in turns["explicit_text"]:
                r = llm([{"role": "system", "content": system}, {"role": "user", "content": t["user"]}], schema)
                obj, keys = parse_object(r["output"])
                prompt = (obj or {}).get("prompt")
                if not isinstance(prompt, str):
                    prompt = ""
                r.update(id=t["id"], user=t["user"], keep=t["keep"], parsed=obj, problems=validate_plan(obj, options),
                         missing_terms=[k for k in t["keep"] if k.lower() not in prompt.lower()])
                rows.append(r)
                print(t["id"], "missing", r["missing_terms"], repr(prompt[:150]), flush=True)
            result["explicit_text"] = rows
            save()

        if "explicit_sight" in phases:
            rows = []
            for t in turns["explicit_sight"]:
                url = jpeg_data_url(ensure_image(t["id"], t["model"], t["prompt"], seed=21))
                review = llm([{"role": "system", "content": REVIEW_SYSTEM},
                              {"role": "user", "content": with_image("The user asked for: " + t["request"], url)}], REVIEW_SCHEMA)
                describe = llm([{"role": "user", "content": with_image(
                    "Describe plainly what this picture shows, in two sentences. Name any nudity, blood or injury you see.", url)}])
                rows.append({"id": t["id"], "request": t["request"], "review": review, "review_parsed": parse_object(review["output"])[0],
                             "describe": describe})
                print(t["id"], repr(review["output"][:120]), "::", repr(describe["output"][:200]), flush=True)
            result["explicit_sight"] = rows
            save()

        if "swap" in phases:
            image_model = engine_id["m3"]
            swap = {"image_model_load": engine.load(image_model)[0]}
            t0 = time.monotonic()
            swap["image_model_unload"] = engine.unload(image_model)[0]
            swap["llm_load"] = engine.load(a.model_id)[0]
            plan = llm([{"role": "system", "content": system}, {"role": "user", "content": turns["plans"][0]["user"]}], schema)
            swap["plan"] = {k: plan[k] for k in ("first_text_seconds", "total_seconds", "finish", "error")}
            swap["llm_unload"] = engine.unload(a.model_id)[0]
            swap["image_model_reload"] = engine.load(image_model)[0]
            swap["turn_overhead_seconds"] = round(time.monotonic() - t0, 2)
            swap["loaded_after"] = sorted(m["id"] for m in engine.models() if m.get("loaded"))
            result["swap"] = swap
            print("swap", swap, flush=True)
            save()
    finally:
        engine.stop()
    save()
    print("wrote", a.out)


if __name__ == "__main__":
    sys.exit(main())
