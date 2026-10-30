#!/bin/sh
# Fails unless engine.lock records a contract-suite pass for the engine version it pins (KTD3, KTD8;
# docs/lld/engine-contract.md §6).
#
#   CI:      sh scripts/engine-contract/check_lock.sh engine.lock
#   Locally: the same, after scripts/engine-contract/run_contract.py --write-lock
#
# The check compares versions, not probe sets (§5): a recorded pass stops counting the moment the lock's `version`
# changes, and probes added later do not invalidate an older pass until the next bump forces a complete run.
set -eu

LOCK="${1:-engine.lock}"

if [ ! -f "$LOCK" ]; then
    echo "error: no lock file at $LOCK" >&2
    exit 1
fi

python3 - "$LOCK" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        lock = json.load(handle)
except (OSError, ValueError) as error:
    sys.exit(f"error: {path} is not readable JSON: {error}")
if not isinstance(lock, dict):
    sys.exit(f"error: {path} is not a JSON object")

version = lock.get("version")
suite = lock.get("contract_suite")
problems = []
if not isinstance(version, str) or not version:
    problems.append(f"the lock has no non-empty string 'version' (found {version!r})")
if not isinstance(suite, dict):
    problems.append("the lock has no contract_suite object")
else:
    if suite.get("result") != "pass":
        problems.append(f"contract_suite.result is {suite.get('result')!r}, not 'pass'")
    if suite.get("version") != version:
        problems.append(f"contract_suite.version is {suite.get('version')!r} but the lock pins version {version!r}")
if problems:
    print("error: no recorded engine contract-suite pass for this pin:", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    print("  Record one with scripts/engine-contract/run_contract.py --write-lock for this version.", file=sys.stderr)
    sys.exit(1)

print(f"engine lock ok: contract suite passed on {version} ({suite.get('probes')} probes, {suite.get('run_at')})")
PY
