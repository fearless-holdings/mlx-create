#!/usr/bin/python3
"""Engine contract runner (plan U7; KTD3, KTD8): run the contract suite and record its result in engine.lock.

The suite in Tests/MCEngineContractTests writes a result file only for a complete run: every declared probe ran and
none failed (`docs/lld/engine-contract.md` §2.4). Swift Testing counts a skipped test as passing, so this runner never
trusts the exit code alone; it reads the result file and applies three more checks -- the probe count matches, the
failure list is empty, and the tested engine is the version engine.lock pins -- before `contract_suite` changes.

    run_contract.py --models DIR --loras DIR [--repo DIR] [--lock PATH] [--write-lock] [--timeout SECONDS]

Without --write-lock the run is a dry run that reports only. The suite needs real models, so it is not part of
`swift test` and not part of CI (D49); CI checks the recorded result with scripts/engine-contract/check_lock.sh.

Run it from an Eval cell; see README.md.
"""
import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SUITE = "MCEngineContractTests"
SUITE_KEYS = ("result", "run_at", "version", "probes")
ENGINE = "mlx-serve"
# The deadline is generous: the full probe set drives every family through several generations plus seed repeats.
DEFAULT_TIMEOUT = 7200
# Left-overs AGENTS.md names after a hung or killed `swift test`.
STRAGGLER_PATTERNS = ("swiftpm-testing-helper", "swift-test")


# --- lock file --------------------------------------------------------------------------------------------------


def read_lock(path):
    """The lock's text and parsed object. The text is what `render_lock` rewrites, so formatting survives."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    try:
        lock = json.loads(text)
    except ValueError as error:
        raise SystemExit(f"{path} is not valid JSON: {error}") from error
    if not isinstance(lock, dict) or not isinstance(lock.get("version"), str) or not lock["version"]:
        raise SystemExit(f"{path} has no non-empty string 'version'")
    return text, lock


def _value_span(text, key):
    """Offsets of the JSON value that follows `key` in `text`, or None when the key is absent.

    A text scan, not a parse-and-redump, so every other field keeps its exact bytes (key order, line wrapping,
    the one-line `contract_suite` style). Strings are skipped so a brace inside them cannot end the value.
    """
    match = re.search(r'"%s"\s*:\s*' % re.escape(key), text)
    if not match:
        return None
    start = match.end()
    depth = 0
    in_string = False
    escaped = False
    index = start
    while index < len(text):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "{[":
            depth += 1
        elif char in "}]":
            if depth == 0:
                return start, _trim_end(text, start, index)
            depth -= 1
            if depth == 0:
                return start, index + 1
        elif char == "," and depth == 0:
            return start, _trim_end(text, start, index)
        index += 1
    raise ValueError(f"engine.lock has no closing brace after '{key}'")


def _trim_end(text, start, end):
    while end > start and text[end - 1].isspace():
        end -= 1
    return end


def render_suite(suite):
    """The `contract_suite` object on one line, matching the lock's existing style."""
    missing = [key for key in SUITE_KEYS if key not in suite]
    if missing:
        raise ValueError(f"contract_suite is missing {', '.join(missing)}")
    return "{ " + ", ".join(f'"{key}": {json.dumps(suite[key])}' for key in SUITE_KEYS) + " }"


def render_lock(lock_text, suite):
    """`lock_text` with `contract_suite` replaced by `suite` and every other field byte-identical."""
    rendered = render_suite(suite)
    span = _value_span(lock_text, "contract_suite")
    if span is not None:
        return lock_text[: span[0]] + rendered + lock_text[span[1] :]
    closing = lock_text.rstrip().rfind("}")
    if closing < 0:
        raise ValueError("engine.lock has no closing brace")
    head = lock_text[:closing].rstrip()
    return f'{head},\n  "contract_suite": {rendered}\n' + lock_text[closing:]


def write_lock(path, lock_text, lock, suite):
    """Records `suite` in `path`, after proving the rewrite changed nothing else."""
    updated = render_lock(lock_text, suite)
    try:
        data = json.loads(updated)
    except ValueError as error:
        raise SystemExit(f"internal error: the rewritten lock is not valid JSON: {error}") from error
    expected = dict(lock)
    expected["contract_suite"] = suite
    if data != expected or list(data) != list(lock):
        raise SystemExit("internal error: the rewrite changed more than contract_suite; engine.lock untouched")
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(updated)
    os.replace(temporary, path)
    return updated


# --- KTD3 checks (pure) -----------------------------------------------------------------------------------------


def validate_result(result, lock_version):
    """Problems with a parsed result file; an empty list means a complete passing run of the pinned engine."""
    if not isinstance(result, dict):
        return ["the result file is not a JSON object"]
    problems = []
    expected = result.get("probes_expected")
    ran = result.get("probes_run")
    counts = (expected, ran)
    if not all(isinstance(value, int) and not isinstance(value, bool) for value in counts):
        problems.append(f"probe counts are not integers (probes_expected={expected!r}, probes_run={ran!r})")
    elif ran != expected:
        problems.append(f"{ran} of {expected} declared probes ran")
    elif expected <= 0:
        problems.append("the run recorded no probes")
    failures = result.get("failures")
    if not isinstance(failures, list):
        problems.append(f"failures is not a list ({failures!r})")
    elif failures:
        problems.append(f"{len(failures)} probe(s) failed: " + "; ".join(str(item) for item in failures))
    version = result.get("engine_version")
    if version != lock_version:
        problems.append(f"the run tested engine {version!r} but engine.lock pins {lock_version!r}")
    return problems


# --- reporting --------------------------------------------------------------------------------------------------


def progress_report(result_path):
    """Lines naming the probes the interrupted run never reached, from `<result>.progress`."""
    path = result_path + ".progress"
    if not os.path.exists(path):
        return [f"no progress file at {path}: the suite stopped before it recorded a probe"]
    try:
        with open(path, encoding="utf-8") as handle:
            progress = json.load(handle)
    except (OSError, ValueError) as error:
        return [f"{path} could not be read: {error}"]
    if not isinstance(progress, dict):
        return [f"{path} is not a JSON object"]
    expected = progress.get("expected") or []
    passed = progress.get("passed") or []
    lines = [f"progress: {len(passed)} of {len(expected)} declared probes passed ({path})"]
    for key in ("missing", "failures"):
        values = progress.get(key) or []
        if values:
            lines.append(f"{key}: " + ", ".join(str(value) for value in values))
    if progress.get("inconclusive"):
        lines.append(f"inconclusive: {progress['inconclusive']}")
    return lines


def log_tail(path, count=20):
    try:
        with open(path, errors="replace", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return [f"no log at {path}"]
    return lines[-count:]


def report_incomplete(problems, result_path, log_path):
    print("\nthe run is not a complete pass; engine.lock is untouched:", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    for line in progress_report(result_path):
        print(f"  {line}", file=sys.stderr)
    print(f"  full log: {log_path}", file=sys.stderr)
    for line in log_tail(log_path):
        print(f"  log | {line}", file=sys.stderr)


# --- processes --------------------------------------------------------------------------------------------------


def extract_engine(repo, lock, scratch):
    """Extracts the pinned engine with the build script. Returns (binary, payload root)."""
    script = os.path.join(repo, "scripts", "embed-engine.sh")
    if not os.path.exists(script):
        raise SystemExit(f"no engine build script at {script}")
    destination = os.path.join(scratch, "engine")
    os.makedirs(destination, exist_ok=True)
    done = subprocess.run(["/bin/bash", script, "--extract", destination], cwd=repo, capture_output=True, text=True)
    if done.returncode != 0:
        detail = (done.stderr or done.stdout).strip()
        raise SystemExit(f"embed-engine.sh --extract failed (exit {done.returncode}):\n{detail}")
    printed = [line.strip() for line in (done.stdout or "").splitlines() if line.strip()]
    payload = printed[-1] if printed else os.path.join(destination, lock.get("root") or "")
    binary = os.path.join(payload, lock.get("executable") or ENGINE)
    if not os.access(binary, os.X_OK):
        raise SystemExit(f"the extracted engine is missing or not executable: {binary}")
    return binary, payload


def engine_version(binary):
    """The engine's own `--version` line, printed for the log; the result file's version is the one that counts."""
    try:
        done = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unknown ({error})"
    lines = (done.stdout or done.stderr).strip().splitlines()
    return lines[0].strip() if lines else "unknown"


def run_suite(repo, environment, log_path, timeout):
    """Runs the contract target with its own log file and deadline. Returns (exit status, timed out)."""
    command = ["swift", "test", "--no-parallel", "--filter", SUITE]
    with open(log_path, "w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command, cwd=repo, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
        )
        try:
            return process.wait(timeout=timeout), False
        except subprocess.TimeoutExpired:
            stop_process_group(process)
            return process.wait(), True


def stop_process_group(process, grace=10):
    """SIGTERM the suite's process group, then SIGKILL it."""
    for signal_number, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 5)):
        try:
            os.killpg(os.getpgid(process.pid), signal_number)
        except (ProcessLookupError, PermissionError):
            return
        try:
            process.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


def processes_matching(needles):
    """(pid, command) for every live process whose command line contains one of `needles`."""
    done = subprocess.run(["ps", "-Aww", "-o", "pid=,command="], capture_output=True, text=True)
    found = []
    for line in (done.stdout or "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        pid, command = int(parts[0]), parts[1]
        if pid == os.getpid():
            continue
        if any(needle in command for needle in needles):
            found.append((pid, command))
    return found


def pid_alive(pid):
    return subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode == 0


def wait_until_gone(pid, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.2)
    return not pid_alive(pid)


def stop_pids(pids, grace=10):
    """SIGTERM each pid, SIGKILL the ones still alive after `grace`. Returns every pid it had to handle."""
    for pid in pids:
        stop_one(pid, grace)
    return pids


def stop_one(pid, grace):
    for signal_number, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 5)):
        try:
            os.kill(pid, signal_number)
        except (ProcessLookupError, PermissionError):
            return
        if wait_until_gone(pid, wait):
            return


def stop_stragglers(payload):
    """The AGENTS.md cleanup, then any engine this run started. Returns the engine pids it had to stop."""
    for pattern in STRAGGLER_PATTERNS:
        subprocess.run(["pkill", "-f", pattern], capture_output=True)
    strays = [pid for pid, command in processes_matching([payload]) if ENGINE in command]
    return stop_pids(strays)


# --- self-test --------------------------------------------------------------------------------------------------


SELF_TEST_VERSION = "26.10.3-pre-release.1"
SELF_TEST_LOCK = """{
  "schema": 1,
  "version": "26.10.3-pre-release.1",
  "tag": "v26.10.3-pre-release.1",
  "frameworks": [
    "lib/libmlx.dylib", "lib/mlx.metallib"
  ],
  "notices": ["LICENSE", "NOTICE"],
  "contract_suite": { "result": "smoke-only", "run_at": "2026-10-21" }
}
"""
SELF_TEST_RESULT = {
    "engine_version": "26.10.3-pre-release.1",
    "probes_expected": 46,
    "probes_run": 46,
    "failures": [],
}


def _outside(text):
    """The lock's text before and after the `contract_suite` value: what a rewrite must not touch."""
    start, end = _value_span(text, "contract_suite")
    return text[:start], text[end:]


def self_test():
    """Offline: the KTD3 checks and the byte-identical lock rewrite, on in-memory fixtures."""
    accepted = validate_result(SELF_TEST_RESULT, SELF_TEST_VERSION)
    assert accepted == [], f"a complete matching run must be accepted: {accepted}"

    mismatch = validate_result(dict(SELF_TEST_RESULT, engine_version="26.10.3"), SELF_TEST_VERSION)
    assert mismatch and "pins" in mismatch[0], f"a version mismatch must be refused: {mismatch}"

    fewer = validate_result(dict(SELF_TEST_RESULT, probes_run=44), SELF_TEST_VERSION)
    assert fewer and "44 of 46" in fewer[0], f"a partial run must be refused: {fewer}"

    failed = validate_result(
        dict(SELF_TEST_RESULT, failures=["image.dimensions.krea-2-turbo: 512 != 1024"]), SELF_TEST_VERSION
    )
    assert failed and "image.dimensions.krea-2-turbo" in failed[0], f"a failing probe must be refused: {failed}"

    empty = validate_result({}, SELF_TEST_VERSION)
    assert empty, "a result file with no fields must be refused"

    suite = {"result": "pass", "run_at": "2026-10-29", "version": SELF_TEST_VERSION, "probes": 46}
    updated = render_lock(SELF_TEST_LOCK, suite)
    before, after = json.loads(SELF_TEST_LOCK), json.loads(updated)
    assert list(after) == list(before), f"key order changed: {list(after)}"
    assert after["contract_suite"] == suite, after["contract_suite"]
    assert _outside(updated) == _outside(SELF_TEST_LOCK), "a field other than contract_suite changed"
    assert render_lock(updated, suite) == updated, "a second rewrite must be a no-op"

    bare = SELF_TEST_LOCK.replace(',\n  "contract_suite": { "result": "smoke-only", "run_at": "2026-10-21" }', "")
    assert "contract_suite" not in bare, bare
    added = render_lock(bare, suite)
    assert json.loads(added)["contract_suite"] == suite, "a lock with no contract_suite must gain one"
    assert json.loads(added)["schema"] == 1, json.loads(added)
    prefix = bare[: bare.rstrip().rfind("}")].rstrip()
    assert added.startswith(prefix), "appending the field changed text before it"

    try:
        render_lock('{\n  "version": "26.10.3"\n', suite)
    except ValueError:
        pass
    else:
        raise AssertionError("a lock with no closing brace must be refused")


# --- entry point ------------------------------------------------------------------------------------------------


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Run the engine contract suite and record its result in engine.lock.")
    parser.add_argument("--models", required=True, help="directory of real model folders (MLXC_CONTRACT_MODEL_DIR)")
    parser.add_argument(
        "--loras", required=True, help="LoRA directory, <family id>/*.safetensors (MLXC_CONTRACT_LORA_DIR)"
    )
    parser.add_argument("--repo", default=REPO, help="repository root (default: the repo this script sits in)")
    parser.add_argument("--lock", help="engine.lock to read and record into (default: <repo>/engine.lock)")
    parser.add_argument("--write-lock", action="store_true", help="record a complete pass (default: report only)")
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"deadline for swift test in seconds (default {DEFAULT_TIMEOUT})",
    )
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    if sys.platform != "darwin":
        raise SystemExit("the pinned engine is a macOS arm64 build; run this on the Mac that holds the models")
    args.repo = os.path.abspath(args.repo)
    for name, path in (("--models", args.models), ("--loras", args.loras)):
        if not os.path.isdir(path):
            raise SystemExit(f"{name} is not a directory: {path}")

    lock_path = args.lock or os.path.join(args.repo, "engine.lock")
    lock_text, lock = read_lock(lock_path)
    version = lock["version"]

    scratch = tempfile.mkdtemp(prefix="mlx-create-contract-")
    result_path = os.path.join(scratch, "result.json")
    log_path = os.path.join(scratch, "swift-test.log")
    for path in (result_path, result_path + ".progress"):
        if os.path.exists(path):
            raise SystemExit(f"refusing to start: {path} already exists")
    print(f"engine.lock {lock_path} pins {version}", flush=True)
    print(f"scratch {scratch}", flush=True)

    binary, payload = extract_engine(args.repo, lock, scratch)
    print(f"engine binary {binary}", flush=True)
    print(f"engine reports {engine_version(binary)}", flush=True)

    environment = dict(os.environ)
    environment.update(
        {
            "MLXC_ENGINE_BIN": binary,
            "MLXC_CONTRACT_MODEL_DIR": os.path.abspath(args.models),
            "MLXC_CONTRACT_LORA_DIR": os.path.abspath(args.loras),
            "MLXC_CONTRACT_RESULT": result_path,
        }
    )
    print(f"running swift test --no-parallel --filter {SUITE} (log {log_path}, deadline {args.timeout}s)", flush=True)
    status, timed_out = run_suite(args.repo, environment, log_path, args.timeout)
    strays = stop_stragglers(payload)

    problems = []
    if timed_out:
        problems.append(f"the suite hit the {args.timeout}s deadline and was killed")
    if status != 0:
        problems.append(f"swift test exited {status}")
    if strays:
        problems.append("engines outlived the run (stopped): " + ", ".join(str(pid) for pid in strays))
    result = None
    if os.path.exists(result_path):
        try:
            with open(result_path, encoding="utf-8") as handle:
                result = json.load(handle)
        except (OSError, ValueError) as error:
            problems.append(f"{result_path} could not be read: {error}")
    else:
        problems.append(f"no result file: {result_path}")
    if result is not None:
        problems.extend(validate_result(result, version))

    if problems:
        report_incomplete(problems, result_path, log_path)
        return 1

    suite = {
        "result": "pass",
        "run_at": datetime.date.today().isoformat(),
        "version": version,
        "probes": result["probes_run"],
    }
    if not args.write_lock:
        print(f"all checks passed: {result['probes_run']} probes on engine {result['engine_version']}", flush=True)
        print(f"dry run: engine.lock untouched. --write-lock would record {render_suite(suite)}", flush=True)
        return 0
    write_lock(lock_path, lock_text, lock, suite)
    print(f"recorded in {lock_path}: {render_suite(suite)}", flush=True)
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        try:
            self_test()
        except AssertionError as error:
            print(f"self-test failed: {error}", file=sys.stderr)
            sys.exit(1)
        print("self-test ok")
    else:
        sys.exit(main(sys.argv[1:]))
