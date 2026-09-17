#!/usr/bin/env python3
"""Prove the capture contract's refusals discriminate (issue #392).

A refusal is a NEGATIVE assertion, and this repo's recurring defect is a negative satisfied by an
execution where nothing happened. So every refusal here is exercised TWICE: once with the check in
place, which must refuse, and once with that check alone bypassed, which must render. The second run
is the discrimination proof. Without it a refusal test passes when the loader dies of a parse error,
a missing file, or an empty array, and the named check is never what rejected anything.

The bypassed run uses checks=() rather than "every check except this one": damaging a capture to
trip one check often trips a second (bypassing "empty" still trips "strong" on this fixture, and
bypassing "drain" leaves dropped at -1, which trips "dropped"). The discrimination claim is already
carried by the first run, which asserts that Refused.check equals the check's own name; the bypassed
run only has to prove the damaged capture does not crash the loader for an unrelated reason such as a
parse error or an empty array.

The positive fixture is the liveness witness for the refusals themselves: without it, a loader that
refused everything would pass the other four cases.
"""
import json
import pathlib
import shutil
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from plot_lock_view import CHECKS, Refused, load_capture  # noqa: E402

GOLDEN = pathlib.Path(__file__).parent / "fixtures" / "lockview" / "golden"
fail = 0


def check(label, actual, expected):
    global fail
    if actual == expected:
        print(f"PASS  {label:<62} {actual}")
    else:
        print(f"FAIL  {label:<62} got {actual}, want {expected}")
        fail = 1


def mutate(tmp, fn):
    """Copy the golden capture and let fn damage it."""
    d = pathlib.Path(tmp) / "run"
    shutil.copytree(GOLDEN, d)
    recs = [json.loads(l) for l in (d / "events.jsonl").open() if l.strip()]
    recs = fn(recs)
    with (d / "events.jsonl").open("w") as fh:
        for r in recs:
            fh.write(json.dumps(r) + "\n")
    return d


def refuses(run_dir, checks):
    try:
        load_capture(run_dir, checks=checks)
        return ""
    except Refused as exc:
        return exc.check


# Asymmetric on purpose: three relations and two commits, never one and one, so a transposition
# cannot cancel the way a symmetric fixture lets it.
DAMAGE = {
    "dropped": lambda rs: [{"dropped": 5, "unmatched": 0} if "dropped" in r else r for r in rs],
    "drain":   lambda rs: [r for r in rs if "dropped" not in r],
    "empty":   lambda rs: [r for r in rs if "dropped" in r],
    "strong":  lambda rs: [r for r in rs if not (r.get("kind") == "lock" and r.get("mode") == 8)],
}

for name, damage in DAMAGE.items():
    with tempfile.TemporaryDirectory() as tmp:
        d = mutate(tmp, damage)
        check(f"{name}: refuses with the check in place", refuses(d, CHECKS), name)
        check(f"{name}: renders with checks bypassed entirely", refuses(d, ()), "")

check("a good capture loads", refuses(GOLDEN, CHECKS), "")

sys.exit(fail)
