#!/usr/bin/python3
"""GUI smoke runner (D50, plan U3): run the UI tests against the real app and engine in a throwaway home.

    run_smoke.py --models DIR --model-id ORG/NAME [--out DIR] [--timeout SECONDS]
    run_smoke.py --self-test

`--models` is a directory holding model folders as `ORG/NAME` (the app's `Models/Weights` layout). The model is
symlinked into a throwaway home, never copied. The UI test runner is sandboxed, so this script owns everything that
touches the file system: preflight, the home, cleanup and exporting screenshots (`docs/lld/gui-smoke.md`).

Exit codes: 0 every step passed; 1 a step failed; 2 NOT RUN (a refusal, never a pass).

Run it from an Eval cell; see README.md.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCHEME = "MLXCreate"
TEST_TARGET = "MLXCreateUITests"
APP_EXECUTABLE = "mlx-create"
MODEL_MARKERS = ("config.json", "model_index.json")
DEFAULT_TIMEOUT = 1800
HOME_PREFIX = "mlxc-smoke-"
EXIT_PASS, EXIT_FAIL, EXIT_NOT_RUN = 0, 1, 2


class NotRun(Exception):
    """A refusal. The run did not happen, so it must never read as a pass."""


# --- preflight ---------------------------------------------------------------------------------------------------


def running_app_pids():
    """Pids of running mlx-create apps. Matched by executable name: this is a refusal check, never a kill."""
    output = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True).stdout
    pids = []
    for line in output.splitlines():
        pid, _, command = line.strip().partition(" ")
        if os.path.basename(command.strip()) == APP_EXECUTABLE:
            pids.append(int(pid))
    return pids


def developer_mode_enabled():
    tool = "/usr/sbin/DevToolsSecurity"
    if not os.path.exists(tool):
        return False
    result = subprocess.run([tool, "-status"], capture_output=True, text=True)
    return "enabled" in (result.stdout + result.stderr).lower()


def preflight(models, model_id, running=running_app_pids, developer_mode=developer_mode_enabled):
    """Returns the model folder, or raises NotRun with the reason. Each refusal has its own message."""
    if not models or not model_id:
        raise NotRun("no model configured: pass --models DIR and --model-id ORG/NAME")
    if not re.fullmatch(r"[\w.\-]+/[\w.\-]+", model_id):
        raise NotRun(f"--model-id must look like ORG/NAME, got {model_id!r}")
    folder = os.path.join(os.path.abspath(models), *model_id.split("/"))
    if not os.path.isdir(folder):
        raise NotRun(f"model folder missing: {folder}")
    if not any(os.path.isfile(os.path.join(folder, name)) for name in MODEL_MARKERS):
        raise NotRun(f"{folder} has neither config.json nor model_index.json: not a model folder")
    pids = running()
    if pids:
        raise NotRun(f"mlx-create is running (pid {', '.join(map(str, pids))}); quit it first, a UI test launch would take over its window")
    if not developer_mode():
        raise NotRun("Developer Mode is off: run `sudo DevToolsSecurity -enable` once (it needs an admin password)")
    return folder


# --- throwaway home and cleanup ----------------------------------------------------------------------------------


def make_home(model_folder, model_id):
    """A fresh home whose library holds only the model, as a symlink. Created here: the test runner cannot."""
    home = tempfile.mkdtemp(prefix=HOME_PREFIX, dir="/tmp")
    weights = os.path.join(home, "Library", "Application Support", "mlx-create", "Models", "Weights", *model_id.split("/")[:-1])
    os.makedirs(weights)
    os.symlink(model_folder, os.path.join(weights, model_id.split("/")[-1]))
    return home


def processes_mentioning(path):
    """(pid, args) of every process whose command line contains `path`, except this one and its ancestors."""
    skip = set()
    pid = os.getpid()
    ppids = {}
    listing = subprocess.run(["ps", "-axo", "pid=,ppid=,args="], capture_output=True, text=True, check=True).stdout
    entries = []
    for line in listing.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        entries.append((int(parts[0]), parts[2] if len(parts) > 2 else ""))
        ppids[int(parts[0])] = int(parts[1])
    while pid in ppids and pid not in skip:
        skip.add(pid)
        pid = ppids[pid]
    return [(p, args) for p, args in entries if p not in skip and path in args]


def kill_processes_mentioning(path, grace=5.0):
    """Cleanup (KTD9): by the home path in the command line, never by process name, so another task's mlx-serve lives."""
    found = processes_mentioning(path)
    for pid, _ in found:
        _signal(pid, signal.SIGTERM)
    deadline = time.time() + grace
    while time.time() < deadline and processes_mentioning(path):
        time.sleep(0.2)
    for pid, _ in processes_mentioning(path):
        _signal(pid, signal.SIGKILL)
    return [pid for pid, _ in found]


def _signal(pid, sig):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass


def remove_home(home):
    """rmtree unlinks the model symlink and never follows it. The prefix check keeps a bad path from deleting anything else."""
    if os.path.basename(home).startswith(HOME_PREFIX) and os.path.dirname(os.path.realpath(home)) in ("/tmp", "/private/tmp"):
        shutil.rmtree(home, ignore_errors=True)


# --- run ---------------------------------------------------------------------------------------------------------


def run_logged(command, log_path, env=None, timeout=None):
    """Run `command`, writing all output to `log_path`. A timeout kills the whole process group."""
    with open(log_path, "ab") as log:
        process = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise NotRun(f"timed out after {timeout}s: {' '.join(command[:3])} …; see {log_path}") from None


def export_screenshots(result_bundle, out_dir):
    """Export every attachment from the .xcresult as `NN-<step>.<ext>`. Returns the exported paths in step order."""
    raw = os.path.join(out_dir, "raw")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result_bundle, "--output-path", raw],
                   capture_output=True, check=True)
    with open(os.path.join(raw, "manifest.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    items = [a for test in manifest for a in test.get("attachments", [])]
    items.sort(key=lambda a: a.get("timestamp", 0))
    shots = os.path.join(out_dir, "screenshots")
    os.makedirs(shots, exist_ok=True)
    exported = []
    for index, item in enumerate(items, 1):
        ext = os.path.splitext(item["exportedFileName"])[1]
        stem = item["suggestedHumanReadableName"].removesuffix(ext)
        stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", stem).replace("/", "-")
        target = os.path.join(shots, f"{index:02d}-{stem}{ext}")
        shutil.move(os.path.join(raw, item["exportedFileName"]), target)
        exported.append(target)
    shutil.rmtree(raw, ignore_errors=True)
    return exported


def failures(result_bundle):
    """(test, text) for every failed test in the result bundle, or [] when it cannot be read."""
    result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result_bundle],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return []
    try:
        summary = json.loads(result.stdout)
    except ValueError:
        return []
    return [(f.get("testName", "?"), f.get("failureText", "")) for f in summary.get("testFailures", [])]


def fmt_seconds(seconds):
    return f"{seconds:.0f}s"


def run(args):
    started = time.time()
    model_folder = preflight(args.models, args.model_id)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.abspath(args.out or os.path.join(REPO, "build", "gui-smoke", stamp))
    os.makedirs(out_dir, exist_ok=True)
    log_path = os.path.join(out_dir, "xcodebuild.log")
    result_bundle = os.path.join(out_dir, "result.xcresult")
    phases = {}
    home = make_home(model_folder, args.model_id)
    code = EXIT_FAIL
    try:
        mark = time.time()
        if run_logged(["xcodegen", "generate"], log_path, timeout=300) != 0:
            raise NotRun(f"xcodegen generate failed; see {log_path}")
        phases["generate"] = time.time() - mark

        mark = time.time()
        env = dict(os.environ, TEST_RUNNER_MLXC_SMOKE_HOME=home, TEST_RUNNER_MLXC_SMOKE_MODEL_ID=args.model_id)
        status = run_logged(
            ["xcodebuild", "-project", "MLXCreate.xcodeproj", "-scheme", SCHEME, "-configuration", "Debug", "-derivedDataPath", "build",
             "-destination", "platform=macOS", "-resultBundlePath", result_bundle, f"-only-testing:{TEST_TARGET}", "test"],
            log_path, env=env, timeout=args.timeout)
        phases["build+test"] = time.time() - mark

        mark = time.time()
        shots = export_screenshots(result_bundle, out_dir) if os.path.isdir(result_bundle) else []
        phases["export"] = time.time() - mark

        code = EXIT_PASS if status == 0 else EXIT_FAIL
        if code == EXIT_FAIL:
            report = failures(result_bundle) if os.path.isdir(result_bundle) else []
            if not report:
                print(f"FAILED before any test result was recorded (xcodebuild exit {status}); see {log_path}")
            for test, text in report:
                print(f"FAILED {test}: {text}")
            if shots:
                print(f"last screenshot: {shots[-1]}")
        print(("PASSED" if code == EXIT_PASS else "FAILED") + f": {len(shots)} screenshots in {os.path.join(out_dir, 'screenshots')}")
    finally:
        mark = time.time()
        killed = kill_processes_mentioning(home)
        remove_home(home)
        phases["cleanup"] = time.time() - mark
        if killed:
            print(f"cleanup stopped {len(killed)} leftover process(es) that carried {home}")
        print("phases: " + ", ".join(f"{name} {fmt_seconds(value)}" for name, value in phases.items()) + f"; total {fmt_seconds(time.time() - started)}")
    return code


# --- self-test ---------------------------------------------------------------------------------------------------


def self_test():
    """The no-engine logic: refusals and cleanup. The live path is proven by the UI flows themselves."""
    failures_ = []

    def check(name, condition):
        print(("ok   " if condition else "FAIL ") + name)
        if not condition:
            failures_.append(name)

    def refusal(models, model_id, running=lambda: [], developer_mode=lambda: True):
        try:
            preflight(models, model_id, running=running, developer_mode=developer_mode)
        except NotRun as error:
            return str(error)
        return None

    with tempfile.TemporaryDirectory() as scratch:
        folder = os.path.join(scratch, "Org", "Name")
        os.makedirs(folder)
        check("no model configured is refused", "no model configured" in (refusal(None, None) or ""))
        check("malformed model id is refused", "ORG/NAME" in (refusal(scratch, "nope") or ""))
        check("missing model folder is refused", "model folder missing" in (refusal(scratch, "Org/Absent") or ""))
        check("folder without config.json or model_index.json is refused", "not a model folder" in (refusal(scratch, "Org/Name") or ""))
        with open(os.path.join(folder, "config.json"), "w", encoding="utf-8") as handle:
            handle.write("{}")
        check("running mlx-create is refused", "mlx-create is running" in (refusal(scratch, "Org/Name", running=lambda: [4242]) or ""))
        check("Developer Mode off is refused", "Developer Mode" in (refusal(scratch, "Org/Name", developer_mode=lambda: False) or ""))
        check("a valid setup passes preflight", refusal(scratch, "Org/Name") is None)

        home = make_home(folder, "Org/Name")
        link = os.path.join(home, "Library", "Application Support", "mlx-create", "Models", "Weights", "Org", "Name")
        check("home links the model, not copies it", os.path.islink(link) and os.path.realpath(link) == os.path.realpath(folder))

        sleeper = "import time; time.sleep(60)"
        ours = subprocess.Popen([sys.executable, "-c", sleeper, home])
        other = subprocess.Popen([sys.executable, "-c", sleeper, "/tmp/some-other-task-home"])
        try:
            time.sleep(0.5)
            found = {pid for pid, _ in processes_mentioning(home)}
            check("cleanup finds the process carrying the home path", ours.pid in found and other.pid not in found)
            kill_processes_mentioning(home, grace=2.0)
            time.sleep(0.3)
            check("cleanup stops the matched process", ours.poll() is not None)
            check("cleanup leaves an unrelated process alone", other.poll() is None)
        finally:
            for process in (ours, other):
                if process.poll() is None:
                    process.kill()
                process.wait()
        remove_home(home)
        check("home is removed", not os.path.exists(home))
        check("removing the home leaves the model in place", os.path.isfile(os.path.join(folder, "config.json")))
        check("remove_home ignores a path outside the throwaway prefix", (remove_home(scratch), os.path.isdir(scratch))[1])
    return 1 if failures_ else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--models", help="directory holding model folders as ORG/NAME")
    parser.add_argument("--model-id", help="ORG/NAME of the model to generate with")
    parser.add_argument("--out", help="evidence directory (default build/gui-smoke/<timestamp>)")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="seconds allowed for build and tests")
    parser.add_argument("--self-test", action="store_true", help="check the refusals and cleanup, no engine needed")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    try:
        return run(args)
    except NotRun as error:
        print(f"NOT RUN: {error}")
        return EXIT_NOT_RUN


if __name__ == "__main__":
    sys.exit(main())
