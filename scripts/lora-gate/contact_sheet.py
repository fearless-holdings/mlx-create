#!/usr/bin/env python3
"""Contact sheets for the author's judging (plan U3, R16, R12). Renders images, never scores them.

A sheet is prompts down, variants across, written as images plus one index.html in the scratch directory. A blind sheet
(two variants) hides the labels behind A and B, shuffles the order per prompt, and keeps the answer in key.json beside it.
Nothing here goes in the repo: the plan file names local paths and the images are the author's to see (R23).

    contact_sheet.py --plan PLAN.json --engine BIN --weights DIR --model-id ORG/NAME --scratch DIR [--size 512] [--steps 4]

PLAN.json (kept outside the repo):

    {"sheets": [{"name": "krea-realism", "prompt_set": "ordinary", "prompt_ids": ["o01", "o02"],
                 "seeds": [0], "blind": false,
                 "variants": [{"label": "baseline", "loras": []},
                              {"label": "Beauty 0.8", "note": "25 uses, 1.7k downloads", "loras": [{"path": "/x.safetensors", "scale": 0.8}]}]}]}

`seeds` are offsets added to each prompt's own seed, so [0, 1000] is two seeds. Images already on disk are kept, so a
re-run after an interruption only renders what is missing.
"""
import argparse
import hashlib
import html
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_gate  # noqa: E402  (shares the engine launch and the request shape with the pre-screen)


def prompts_for(sheet):
    """A sheet names prompts inline (`prompts`: id, text, seed) or picks ids from a prompt set file."""
    if sheet.get("prompts"):
        return sheet["prompts"]
    with open(os.path.join(HERE, "prompts", sheet["prompt_set"] + ".json")) as handle:
        entries = {entry["id"]: entry for entry in json.load(handle)["prompts"]}
    return [entries[prompt_id] for prompt_id in sheet["prompt_ids"]]


def image_name(prompt, offset, variant):
    digest = hashlib.sha256(json.dumps([variant["loras"], variant.get("prefix", "")], sort_keys=True).encode()).hexdigest()[:10]
    return f"{prompt['id']}-s{offset}-{digest}.png"


def render(sheet, context, directory):
    """Every image a sheet needs, written once. Returns the file name per (prompt id, offset, variant index)."""
    os.makedirs(directory, exist_ok=True)
    names = {}
    for prompt in prompts_for(sheet):
        for offset in sheet.get("seeds") or [0]:
            for index, variant in enumerate(sheet["variants"]):
                name = image_name(prompt, offset, variant)
                names[(prompt["id"], offset, index)] = name
                path = os.path.join(directory, name)
                if os.path.exists(path):
                    continue
                loras = variant["loras"]
                prompt_text = (variant.get("prefix", "") + " " + prompt["text"]).strip()
                png = run_gate.generate(
                    context["port"],
                    context["key"],
                    prompt_text,
                    dict(context, seed=int(prompt["seed"]) + offset),
                    [entry["path"] for entry in loras] or None,
                    [float(entry["scale"]) for entry in loras] or None,
                )
                with open(path, "wb") as handle:
                    handle.write(png)
                print(f"  {sheet['name']}/{name}", flush=True)
    return names


def write_index(sheet, names, directory):
    variants = sheet["variants"]
    blind = bool(sheet.get("blind"))
    if blind and len(variants) != 2:
        raise SystemExit(f"{sheet['name']}: a blind sheet compares exactly two variants")
    key, rows = {}, []
    for prompt in prompts_for(sheet):
        for offset in sheet.get("seeds") or [0]:
            order = [0, 1] if not blind else random.Random(f"{sheet['name']}/{prompt['id']}/{offset}").sample([0, 1], 2)
            cells = []
            for slot, variant_index in enumerate(order):
                label = "AB"[slot] if blind else variants[variant_index]["label"]
                note = "" if blind else variants[variant_index].get("note", "")
                src = names[(prompt["id"], offset, variant_index)]
                cells.append(
                    f'<td><img src="{html.escape(src)}" width="300"><br><b>{html.escape(label)}</b>'
                    f"<br><small>{html.escape(note)}</small></td>"
                )
            if blind:
                key[f"{prompt['id']}/s{offset}"] = {"A": variants[order[0]]["label"], "B": variants[order[1]]["label"]}
            rows.append(
                f"<tr><th>{html.escape(prompt['id'])}/s{offset}<br><small>{html.escape(prompt['text'])}</small></th>{''.join(cells)}</tr>"
            )
    page = f"<html><body><h2>{html.escape(sheet['name'])}</h2><table>{''.join(rows)}</table></body></html>"
    with open(os.path.join(directory, "index.html"), "w") as handle:
        handle.write(page)
    if blind:
        with open(os.path.join(directory, "key.json"), "w") as handle:
            json.dump(key, handle, indent=2, sort_keys=True)


def main(argv):
    parser = argparse.ArgumentParser(description="Render contact sheets for the curation run (plan U3).")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--engine", default=os.environ.get("MLXC_ENGINE_BIN"))
    parser.add_argument("--weights", required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--steps", type=int, default=4)
    parser.add_argument("--only", help="render just the sheet with this name")
    args = parser.parse_args(argv)
    if not args.engine:
        raise SystemExit("pass --engine or set MLXC_ENGINE_BIN")
    if os.path.abspath(args.scratch).startswith(run_gate.REPO + os.sep):
        raise SystemExit("--scratch must be outside the repo")
    with open(args.plan) as handle:
        sheets = [s for s in json.load(handle)["sheets"] if not args.only or s["name"] == args.only]
    os.makedirs(args.scratch, exist_ok=True)
    context = {"model_id": args.model_id, "size": args.size, "steps": args.steps}
    proc, log, port, key = run_gate.launch(args.engine, args.weights, args.scratch)
    context.update({"port": port, "key": key})
    try:
        run_gate.wait_healthy(port)
        for sheet in sheets:
            directory = os.path.join(args.scratch, "sheets", sheet["name"])
            write_index(sheet, render(sheet, context, directory), directory)
            print(f"sheet {sheet['name']}: {os.path.join(directory, 'index.html')}", flush=True)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
