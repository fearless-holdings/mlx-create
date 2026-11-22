#!/usr/bin/python3
"""GUI smoke runner (D50, plan U3): run the UI tests against the real app and engine in a throwaway home.

    run_smoke.py --models DIR --model-id ORG/NAME [--agent-models DIR --agent-model-id ORG/NAME] [--out DIR] [--timeout SECONDS]
    run_smoke.py --self-test

`--models` is a directory holding model folders as `ORG/NAME` (the app's `Models/Weights` layout). The model is
symlinked into a throwaway home, never copied. The UI test runner is sandboxed, so this script owns everything that
touches the file system: preflight, the home, cleanup, restoring the real preferences and exporting screenshots
(`docs/lld/gui-smoke.md`).

Exit codes: 0 a test ran to completion and passed; 1 the run started and failed (build, hang, test, or the real library
or preferences changed); 2 NOT RUN (a refusal, or a test that skipped itself), never a pass.

Run it from an Eval cell; see README.md.
"""
import argparse
import datetime
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
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


class RunFailed(Exception):
    """The run started and then failed (a build, a hang, a test): exit 1, with the evidence on disk, never NOT RUN."""


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


def model_folder_for(models, model_id, flag):
    """The ORG/NAME folder under `models`, or NotRun with the reason."""
    if not re.fullmatch(r"[\w.\-]+/[\w.\-]+", model_id):
        raise NotRun(f"{flag} must look like ORG/NAME, got {model_id!r}")
    folder = os.path.join(os.path.abspath(models), *model_id.split("/"))
    if not os.path.isdir(folder):
        raise NotRun(f"model folder missing: {folder}")
    if not any(os.path.isfile(os.path.join(folder, name)) for name in MODEL_MARKERS):
        raise NotRun(f"{folder} has neither config.json nor model_index.json: not a model folder")
    return folder


def preflight(models, model_id, agent_models=None, agent_model_id=None, running=running_app_pids, developer_mode=developer_mode_enabled):
    """Returns (model folder, agent folder or None), or raises NotRun with the reason. Each refusal has its own message."""
    if not models or not model_id:
        raise NotRun("no model configured: pass --models DIR and --model-id ORG/NAME")
    folder = model_folder_for(models, model_id, "--model-id")
    agent_folder = None
    if agent_model_id:
        if not agent_models:
            raise NotRun("--agent-model-id needs --agent-models DIR, the directory holding the agent pack")
        agent_folder = model_folder_for(agent_models, agent_model_id, "--agent-model-id")
    pids = running()
    if pids:
        raise NotRun(f"mlx-create is running (pid {', '.join(map(str, pids))}); quit it first, a UI test launch would take over its window")
    if not developer_mode():
        raise NotRun("Developer Mode is off: run `sudo DevToolsSecurity -enable` once (it needs an admin password)")
    return folder, agent_folder


# --- throwaway home and cleanup ----------------------------------------------------------------------------------


def make_home(model_folder, model_id, agent_folder=None, agent_model_id=None):
    """A fresh home whose library holds only the model, as a symlink. Created here: the test runner cannot."""
    home = tempfile.mkdtemp(prefix=HOME_PREFIX, dir="/tmp")
    weights_root = os.path.join(home, "Library", "Application Support", "mlx-create", "Models", "Weights")
    weights = os.path.join(weights_root, *model_id.split("/")[:-1])
    os.makedirs(weights)
    os.symlink(model_folder, os.path.join(weights, model_id.split("/")[-1]))
    if agent_folder and agent_model_id:
        agent_parent = os.path.join(weights_root, *agent_model_id.split("/")[:-1])
        os.makedirs(agent_parent, exist_ok=True)
        os.symlink(agent_folder, os.path.join(agent_parent, agent_model_id.split("/")[-1]))
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


# --- the developer's real state ----------------------------------------------------------------------------------
# CFFIXED_USER_HOME redirects the library, models and engine, but not UserDefaults.standard, which cfprefsd keys to the real
# user (docs/lld/gui-smoke.md section 4). So the runner snapshots the real preferences and restores whatever the app wrote,
# and it fingerprints the real library to prove a run never touched it.

PREFS_DOMAIN = "com.fearless.mlx-create"
REAL_LIBRARY = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "mlx-create")
DEFAULTS_FLAGS = {str: "-string", bool: "-bool", int: "-int", float: "-float"}


def real_prefs(domain=PREFS_DOMAIN):
    result = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        return plistlib.loads(result.stdout)
    except Exception:
        return {}


def restore_prefs(before, domain=PREFS_DOMAIN):
    """Put every app-owned key back as `before` had it. AppKit's own `NS…` keys (window frames) are left alone.

    Returns (restored keys, keys it could not restore). Run it after the app is dead: a live app rewrites its keys."""
    after = real_prefs(domain)
    restored, stuck = [], []
    for key in sorted(set(before) | set(after)):
        if key.startswith("NS") or ((key in before) == (key in after) and before.get(key) == after.get(key)):
            continue
        if key not in before:
            command = ["defaults", "delete", domain, key]
        else:
            value = before[key]
            if isinstance(value, list) and all(isinstance(item, str) for item in value):
                command = ["defaults", "write", domain, key, "-array", *value]
            else:
                flag = DEFAULTS_FLAGS.get(type(value))
                if flag is None:
                    stuck.append(key)
                    continue
                text = ("TRUE" if value else "FALSE") if isinstance(value, bool) else str(value)
                command = ["defaults", "write", domain, key, flag, text]
        if subprocess.run(command, capture_output=True).returncode == 0:
            restored.append(key)
        else:
            stuck.append(key)
    return restored, stuck


def library_fingerprint(root=REAL_LIBRARY):
    """{relative path: (size, mtime_ns)} for everything under `root` except Engine/ (a stray engine logs there).

    lstat only: symlinks are never followed, and no file is opened."""
    entries = {}
    if not os.path.isdir(root):
        return entries
    for directory, dirs, files in os.walk(root):
        relative = os.path.relpath(directory, root)
        if relative == ".":
            dirs[:] = [name for name in dirs if name != "Engine"]
        for name in files + dirs:
            try:
                info = os.lstat(os.path.join(directory, name))
            except OSError:
                continue
            entries[os.path.normpath(os.path.join(relative, name))] = (info.st_size, info.st_mtime_ns)
    return entries


def changed_paths(before, after):
    return sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))


# --- window placement --------------------------------------------------------------------------------------------


def builtin_display_bounds():
    """(x, y, width, height) of the built-in display in the global top-left-origin space, or None when none is active.

    CoreGraphics through ctypes: an AppleScript or `system_profiler` answer would not say which display is built in."""
    import ctypes

    class CGRect(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]

    core = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    core.CGDisplayBounds.restype = CGRect
    core.CGDisplayBounds.argtypes = [ctypes.c_uint32]
    core.CGDisplayIsBuiltin.argtypes = [ctypes.c_uint32]
    ids = (ctypes.c_uint32 * 16)()
    count = ctypes.c_uint32(0)
    if core.CGGetActiveDisplayList(16, ids, ctypes.byref(count)) != 0:
        return None
    for display in list(ids)[: count.value]:
        if core.CGDisplayIsBuiltin(display):
            rect = core.CGDisplayBounds(display)
            return (rect.x, rect.y, rect.w, rect.h)
    return None


def move_window_script(pid, x, y):
    """AppleScript that moves window 1 of the process with this unix id, and prints `moved` once it did."""
    return (
        'tell application "System Events"\n'
        f"  set matches to (every process whose unix id is {pid})\n"
        '  if (count of matches) is 0 then return "no process"\n'
        "  tell item 1 of matches\n"
        '    if (count of windows) is 0 then return "no window"\n'
        f"    set position of window 1 to {{{int(x)}, {int(y)}}}\n"
        "  end tell\n"
        'end tell\n'
        'return "moved"'
    )


class WindowPinner(threading.Thread):
    """Moves the app's window onto the built-in display as soon as it exists.

    macOS opens the window on whichever display it likes, and a window on an external display made XCUITest's
    `window.screenshot()` fail. XCUITest cannot move a window (a title-bar drag leaves the frame unchanged), and the test runner
    is sandboxed, so this runs here, in the runner, through System Events. The app is found by the throwaway home in its command
    line and by its bundle path, never by name alone (the engine child carries the home too)."""

    def __init__(self, home, bounds):
        super().__init__(daemon=True)
        self.home, self.bounds = home, bounds
        self.stop_event = threading.Event()
        self.moved = False

    def run(self):
        x, y, _, _ = self.bounds
        while not self.stop_event.wait(0.4) and not self.moved:
            apps = [pid for pid, args in processes_mentioning(self.home) if ".app/Contents/MacOS/" in args]
            for pid in apps[:1]:
                done = subprocess.run(["osascript", "-e", move_window_script(pid, x + 60, y + 60)], capture_output=True, text=True)
                self.moved = done.stdout.strip() == "moved"

    def stop(self):
        self.stop_event.set()
        self.join(timeout=10)


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
            raise RunFailed(f"timed out after {timeout}s running {' '.join(command[:3])} …; see {log_path}") from None


def export_screenshots(result_bundle, out_dir):
    """Export the attachments from the .xcresult. Step screenshots (PNG) land in screenshots/, named by their step label;
    everything else (the screen recording, XCTest's own snapshots and hierarchy dumps) lands in attachments/.

    Returns the screenshot paths in time order, or [] when the bundle has nothing to export."""
    raw = os.path.join(out_dir, "raw")
    try:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result_bundle, "--output-path", raw],
                       capture_output=True, check=True)
        with open(os.path.join(raw, "manifest.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"could not export the evidence from {result_bundle}: {error}")
        return []
    items = [a for test in manifest for a in test.get("attachments", [])]
    items.sort(key=lambda a: a.get("timestamp", 0))
    shots = os.path.join(out_dir, "screenshots")
    extras = os.path.join(out_dir, "attachments")
    os.makedirs(shots, exist_ok=True)
    os.makedirs(extras, exist_ok=True)
    exported = []
    for index, item in enumerate(items, 1):
        ext = os.path.splitext(item["exportedFileName"])[1]
        stem = item["suggestedHumanReadableName"].removesuffix(ext)
        stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", stem).replace("/", "-")
        source = os.path.join(raw, item["exportedFileName"])
        if ext == ".png" and re.match(r"\d\d ", stem):
            target = os.path.join(shots, f"{stem}{ext}")
            exported.append(target)
        else:
            target = os.path.join(extras, f"{index:03d}-{stem}{ext}")
        shutil.move(source, target)
    shutil.rmtree(raw, ignore_errors=True)
    return exported


def test_summary(result_bundle):
    """The result bundle's test summary as a dict, or None when it cannot be read."""
    if not os.path.isdir(result_bundle):
        return None
    result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result_bundle],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def classify(status, summary):
    """(exit code, message). The exit status alone is not trusted: XCTest counts a skipped test as a pass, and the UI test
    skips itself when its TEST_RUNNER_ variables do not arrive. Only a test that ran to completion is a pass."""
    if status != 0:
        return EXIT_FAIL, f"xcodebuild exited {status}"
    if summary is None:
        return EXIT_FAIL, "xcodebuild exited 0 but its result bundle cannot be read, so no pass can be claimed"
    passed, failed, skipped = summary.get("passedTests", 0), summary.get("failedTests", 0), summary.get("skippedTests", 0)
    if failed:
        return EXIT_FAIL, f"{failed} test(s) failed"
    if skipped or passed < 1:
        return EXIT_NOT_RUN, f"no test ran to completion ({passed} passed, {skipped} skipped); the UI test skips itself when it is not started by this runner"
    return EXIT_PASS, f"{passed} test(s) passed"


def fmt_seconds(seconds):
    return f"{seconds:.0f}s"


def run(args):
    started = time.time()
    model_folder, agent_folder = preflight(
        args.models, args.model_id, agent_models=args.agent_models, agent_model_id=args.agent_model_id)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.abspath(args.out or os.path.join(REPO, "build", "gui-smoke", stamp))
    os.makedirs(out_dir, exist_ok=True)
    log_path = os.path.join(out_dir, "xcodebuild.log")
    result_bundle = os.path.join(out_dir, "result.xcresult")
    phases = {}
    prefs_before = real_prefs()
    library_before = library_fingerprint()
    bounds = builtin_display_bounds()
    if bounds is None:
        raise NotRun("no built-in display is active (lid closed?): the run is pinned to the laptop's own screen")
    home = make_home(model_folder, args.model_id, agent_folder, args.agent_model_id)
    code = EXIT_FAIL
    try:
        try:
            mark = time.time()
            if run_logged(["xcodegen", "generate"], log_path, timeout=300) != 0:
                raise RunFailed(f"xcodegen generate failed; see {log_path}")
            phases["generate"] = time.time() - mark

            mark = time.time()
            env = dict(os.environ, TEST_RUNNER_MLXC_SMOKE_HOME=home, TEST_RUNNER_MLXC_SMOKE_MODEL_ID=args.model_id)
            if args.agent_model_id:
                env["TEST_RUNNER_MLXC_SMOKE_AGENT_MODEL_ID"] = args.agent_model_id
            # Without --agent-model-id only the Canvas flow runs: the Chat test would skip itself, and a skipped test
            # counts as NOT RUN. With it the whole target runs — Canvas first, then the Chat flow.
            only = TEST_TARGET if args.agent_model_id else f"{TEST_TARGET}/SmokeTests/testGenerateThenRestore"
            pinner = WindowPinner(home, bounds)
            pinner.start()
            try:
                status = run_logged(
                    ["xcodebuild", "-project", "MLXCreate.xcodeproj", "-scheme", SCHEME, "-configuration", "Debug", "-derivedDataPath", "build",
                     "-destination", "platform=macOS", "-resultBundlePath", result_bundle, f"-only-testing:{only}", "test"],
                    log_path, env=env, timeout=args.timeout)
            finally:
                pinner.stop()
            phases["build+test"] = time.time() - mark

            mark = time.time()
            shots = export_screenshots(result_bundle, out_dir) if os.path.isdir(result_bundle) else []
            phases["export"] = time.time() - mark

            summary = test_summary(result_bundle)
            code, message = classify(status, summary)
            if code == EXIT_FAIL:
                report = (summary or {}).get("testFailures", [])
                if not report:
                    print(f"FAILED before any test result was recorded ({message}); see {log_path}")
                for failure in report:
                    print(f"FAILED {failure.get('testName', '?')}: {failure.get('failureText', '')}")
                if shots:
                    print(f"last screenshot: {shots[-1]}")
            print({EXIT_PASS: "PASSED", EXIT_FAIL: "FAILED", EXIT_NOT_RUN: "NOT RUN"}[code] + f": {message}; {len(shots)} screenshots in {os.path.join(out_dir, 'screenshots')}")
        except RunFailed as error:
            code = EXIT_FAIL
            print(f"FAILED: {error}")
    finally:
        mark = time.time()
        killed = kill_processes_mentioning(home)
        remove_home(home)
        phases["cleanup"] = time.time() - mark
        if killed:
            print(f"cleanup stopped {len(killed)} leftover process(es) that carried {home}")
        restored, stuck = restore_prefs(prefs_before)
        if restored:
            print(f"restored {len(restored)} preference key(s) the run changed in {PREFS_DOMAIN}: {', '.join(restored)}")
        if stuck:
            print(f"COULD NOT restore preference key(s) in {PREFS_DOMAIN}: {', '.join(stuck)}")
            code = EXIT_FAIL
        touched = changed_paths(library_before, library_fingerprint())
        if touched:
            print(f"FAILED: the real library changed during the run ({len(touched)} path(s), first: {', '.join(touched[:5])}); isolation did not hold")
            code = EXIT_FAIL
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

    def refusal(models, model_id, agent_models=None, agent_model_id=None, running=lambda: [], developer_mode=lambda: True):
        try:
            preflight(models, model_id, agent_models=agent_models, agent_model_id=agent_model_id,
                      running=running, developer_mode=developer_mode)
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
        check("--agent-model-id without --agent-models is refused", "--agent-models" in (refusal(scratch, "Org/Name", agent_model_id="Org/Agent") or ""))
        check("malformed agent id is refused", "ORG/NAME" in (refusal(scratch, "Org/Name", agent_models=scratch, agent_model_id="nope") or ""))
        check("missing agent folder is refused", "model folder missing" in (refusal(scratch, "Org/Name", agent_models=scratch, agent_model_id="Org/Absent") or ""))
        check("a valid agent setup passes preflight", refusal(scratch, "Org/Name", agent_models=scratch, agent_model_id="Org/Name") is None)

        home = make_home(folder, "Org/Name")
        link = os.path.join(home, "Library", "Application Support", "mlx-create", "Models", "Weights", "Org", "Name")
        check("home links the model, not copies it", os.path.islink(link) and os.path.realpath(link) == os.path.realpath(folder))

        agent_home = make_home(folder, "Org/Name", folder, "Org/Agent")
        agent_link = os.path.join(agent_home, "Library", "Application Support", "mlx-create", "Models", "Weights", "Org", "Agent")
        check("home links the agent pack too", os.path.islink(agent_link) and os.path.realpath(agent_link) == os.path.realpath(folder))
        remove_home(agent_home)

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

        summary = {"passedTests": 1, "failedTests": 0, "skippedTests": 0}
        check("a passed test is a pass", classify(0, summary)[0] == EXIT_PASS)
        check("a skipped-only run is NOT RUN, never a pass", classify(0, {"passedTests": 0, "failedTests": 0, "skippedTests": 1})[0] == EXIT_NOT_RUN)
        check("a run with no test is NOT RUN", classify(0, {"passedTests": 0, "failedTests": 0, "skippedTests": 0})[0] == EXIT_NOT_RUN)
        check("a failed test is a failure", classify(0, {"passedTests": 0, "failedTests": 1, "skippedTests": 0})[0] == EXIT_FAIL)
        check("a non-zero xcodebuild is a failure", classify(65, summary)[0] == EXIT_FAIL)
        check("an unreadable result bundle is never a pass", classify(0, None)[0] == EXIT_FAIL)

        fresh = os.path.join(scratch, "library")
        os.makedirs(os.path.join(fresh, "Images"))
        os.makedirs(os.path.join(fresh, "Engine"))
        with open(os.path.join(fresh, "Images", "a.png"), "wb") as handle:
            handle.write(b"a")
        snapshot = library_fingerprint(fresh)
        check("an untouched library fingerprints the same", changed_paths(snapshot, library_fingerprint(fresh)) == [])
        with open(os.path.join(fresh, "Engine", "log.txt"), "w", encoding="utf-8") as handle:
            handle.write("engine log")
        check("Engine/ is not fingerprinted", changed_paths(snapshot, library_fingerprint(fresh)) == [])
        with open(os.path.join(fresh, "Images", "b.png"), "wb") as handle:
            handle.write(b"b")
        check("a new library file is detected", changed_paths(snapshot, library_fingerprint(fresh)) == ["Images", "Images/b.png"])

        domain = f"com.fearless.mlxc-smoke-selftest-{os.getpid()}"
        try:
            subprocess.run(["defaults", "write", domain, "lastUsedModelID", "-string", "Org/Name"], check=True)
            subprocess.run(["defaults", "write", domain, "queuePaused", "-bool", "TRUE"], check=True)
            subprocess.run(["defaults", "write", domain, "dismissedQueueJobIDs", "-array", "id-1", "id-2"], check=True)
            prefs = real_prefs(domain)
            subprocess.run(["defaults", "write", domain, "lastUsedModelID", "-string", "Org/Other"], check=True)
            subprocess.run(["defaults", "delete", domain, "queuePaused"], check=True)
            subprocess.run(["defaults", "write", domain, "dismissedQueueJobIDs", "-array"], check=True)
            subprocess.run(["defaults", "write", domain, "currentCollectionID", "-string", "ABC"], check=True)
            subprocess.run(["defaults", "write", domain, "NSWindow Frame x", "-string", "1 2 3 4"], check=True)
            restored, stuck = restore_prefs(prefs, domain)
            now = real_prefs(domain)
            check("preferences the app changed or added are restored", now.get("lastUsedModelID") == "Org/Name" and now.get("queuePaused") is True
                  and "currentCollectionID" not in now and not stuck and len(restored) == 4)
            check("a string-array preference the app emptied is restored", now.get("dismissedQueueJobIDs") == ["id-1", "id-2"])
            check("AppKit's own NS keys are left alone", now.get("NSWindow Frame x") == "1 2 3 4")
        finally:
            subprocess.run(["defaults", "delete", domain], capture_output=True)

        refused = subprocess.run([sys.executable, os.path.abspath(__file__)], capture_output=True, text=True)
        check("the command exits 2 with NOT RUN when no model is configured", refused.returncode == EXIT_NOT_RUN and "NOT RUN" in refused.stdout)
    return 1 if failures_ else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--models", help="directory holding model folders as ORG/NAME")
    parser.add_argument("--model-id", help="ORG/NAME of the model to generate with")
    parser.add_argument("--agent-model-id", help="ORG/NAME of the agent LLM pack; enables the Chat flow")
    parser.add_argument("--agent-models", help="directory holding the agent pack, linked into Weights like --models")
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
