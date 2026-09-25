#!/usr/bin/env python3
"""Plant blind seeds in a review tree (docs/adversarial-review.md, "Seeding").

A seed is a known defect put back into the review tree before a pass so the pass's sensitivity can be
measured: a pass that reports none of them has not shown it could find anything. Seeds come from two
sources, both named in a PLAN file the coordinator writes:

  {"seeds": [
     {"mutation": "untransmute_no_recheck_under_lock", "lens": "concurrency", "tier": 1},
     {"patch": "seeds/novel_grid_off_by_one.patch",      "lens": "boundary",    "tier": 1,
      "file": "pgpm_core/install.sql", "why": "one-line description for the sealed record"}
  ]}

A "mutation" entry is applied with the PRISTINE checkout's bench/mutations/mutate.py (the review tree
has no catalogue), which refuses to write anything if its pattern has drifted. A "patch" entry is a
unified diff the coordinator wrote for this pass (a novel seed), applied with `git apply` inside the
tree. Every entry is recorded in the SEALED file the finders never see, together with the lines it
touched in the pristine tree, which is what classify_claims.py later uses to attribute a seed hit.

After planting, the tree's single commit is amended so it stays history-less.

Usage:
  plant_seeds.py --tree <review-tree> --pristine <checkout> --plan <plan.json> --sealed <out.json>
  plant_seeds.py --catalogue [--pristine <checkout>]      # every mutation, its file and track
  plant_seeds.py --selftest
"""
import argparse
import json
import os
import re
import subprocess
import sys


def load_mutate(pristine):
    sys.path.insert(0, os.path.join(pristine, "bench", "mutations"))
    import mutate  # noqa: E402  (the catalogue is code, not data, on purpose: see its docstring)
    return mutate


def catalogue(mutate):
    rows = []
    for name, (guard, why, _edits) in mutate.MUTATIONS.items():
        rows.append({
            "mutation": name,
            "guard": guard,
            "file": mutate.MUTATION_SRC.get(name, "pgpm_core/install.sql"),
            "track": mutate.MUTATION_TRACK.get(name, "perf"),
            "why": why,
        })
    return rows


def touched_lines(text, edits):
    """Line numbers in `text` where a mutation's find-patterns match (for seed attribution)."""
    lines = set()
    for find, _replace, _expected in edits:
        if hasattr(find, "finditer"):
            spans = [m.start() for m in find.finditer(text)]
        else:
            spans, i = [], text.find(find)
            while i != -1:
                spans.append(i)
                i = text.find(find, i + 1)
        for s in spans:
            lines.add(text.count("\n", 0, s) + 1)
    return sorted(lines)


def patch_lines(patch_text):
    """Files and pristine-side line numbers a unified diff touches: (file, [lines])."""
    out, cur = {}, None
    for line in patch_text.splitlines():
        if line.startswith("--- "):
            cur = line[4:].strip()
            cur = cur[2:] if cur.startswith("a/") else cur
            out.setdefault(cur, [])
        elif line.startswith("@@") and cur is not None:
            m = re.match(r"@@ -(\d+)(?:,(\d+))? ", line)
            if m:
                start = int(m.group(1))
                n = int(m.group(2) or 1)
                out[cur].extend(range(start, start + max(n, 1)))
    return out


def validate(plan):
    for i, entry in enumerate(plan.get("seeds", []), 1):
        if ("mutation" in entry) == ("patch" in entry):
            raise SystemExit(f"plant_seeds: entry {i} must name exactly one of 'mutation' or 'patch'")
        for k in ("lens", "tier"):
            if k not in entry:
                raise SystemExit(f"plant_seeds: entry {i} lacks {k!r}; the sealed record needs it")
    if not plan.get("seeds"):
        raise SystemExit("plant_seeds: the plan has no seeds; a pass without seeds cannot measure its recall")


def plant(tree, pristine, plan, sealed_path, run=subprocess.run):
    validate(plan)
    mutate = load_mutate(pristine)
    sealed = {"pinned": None, "seeds": []}
    head = run(["git", "-C", pristine, "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
    sealed["pinned"] = head.stdout.strip()

    for i, entry in enumerate(plan["seeds"], 1):
        if "mutation" in entry:
            name = entry["mutation"]
            if name not in mutate.MUTATIONS:
                raise SystemExit(f"plant_seeds: unknown mutation {name!r}; see --catalogue")
            rel = mutate.MUTATION_SRC.get(name, "pgpm_core/install.sql")
            target = os.path.join(tree, rel)
            with open(os.path.join(pristine, rel)) as fh:
                pristine_text = fh.read()
            _guard, why, edits = mutate.MUTATIONS[name]
            # mutate.py refuses (non-zero) when a pattern's count has drifted: never a silent no-op seed
            run([sys.executable, os.path.join(pristine, "bench", "mutations", "mutate.py"),
                 name, target, target], check=True)
            sealed["seeds"].append({
                "id": f"S{i}", "kind": "mutation", "mutation": name, "file": rel,
                "lens": entry["lens"], "tier": entry["tier"], "why": why,
                "lines": touched_lines(pristine_text, edits),
            })
        elif "patch" in entry:
            ppath = entry["patch"]
            with open(ppath) as fh:
                ptext = fh.read()
            run(["git", "-C", tree, "apply", "--index", os.path.abspath(ppath)], check=True)
            files = patch_lines(ptext)
            sealed["seeds"].append({
                "id": f"S{i}", "kind": "patch", "patch": os.path.basename(ppath),
                "file": entry.get("file") or (next(iter(files)) if files else None),
                "lens": entry["lens"], "tier": entry["tier"], "why": entry.get("why", ""),
                "lines": sorted({ln for lns in files.values() for ln in lns}),
            })

    # keep the tree history-less: one commit, amended
    run(["git", "-C", tree, "-c", "user.name=review", "-c", "user.email=review@localhost", "add", "-A"], check=True)
    run(["git", "-C", tree, "-c", "user.name=review", "-c", "user.email=review@localhost",
         "commit", "-q", "--amend", "--no-edit"], check=True,
        env={**os.environ, "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"})
    n = run(["git", "-C", tree, "rev-list", "--count", "HEAD"], capture_output=True, text=True, check=True)
    if n.stdout.strip() != "1":
        raise SystemExit("plant_seeds: the review tree has more than one commit; seeds would be readable as a diff")

    with open(sealed_path, "w") as fh:
        json.dump(sealed, fh, indent=2)
    return sealed


def selftest():
    # touched_lines: a literal pattern and a regex pattern, each at a known line
    text = "a\nb\nfoo(1)\nc\nfoo(2)\n"
    assert touched_lines(text, [("foo(", "", 2)]) == [3, 5]
    assert touched_lines(text, [(re.compile(r"foo\(2\)"), "", 1)]) == [5]
    # patch_lines: two hunks in one file, pristine-side numbering
    patch = "--- a/x.sql\n+++ b/x.sql\n@@ -10,3 +10,3 @@\n-old\n+new\n@@ -40 +40 @@\n-o\n+n\n"
    assert patch_lines(patch) == {"x.sql": [10, 11, 12, 40]}
    # the plan is validated before anything is touched: no source, both sources, missing lens/tier, empty
    for bad, word in (({"seeds": [{"lens": "x", "tier": 1}]}, "exactly one"),
                      ({"seeds": [{"mutation": "m", "patch": "p", "lens": "x", "tier": 1}]}, "exactly one"),
                      ({"seeds": [{"mutation": "m", "tier": 1}]}, "lens"),
                      ({"seeds": []}, "no seeds")):
        try:
            validate(bad)
        except SystemExit as e:
            assert word in str(e), (word, str(e))
        else:
            raise AssertionError(f"accepted a bad plan: {bad}")
    print("plant_seeds selftest: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tree")
    ap.add_argument("--pristine", default=os.path.join(os.path.dirname(__file__), "..", ".."))
    ap.add_argument("--plan")
    ap.add_argument("--sealed")
    ap.add_argument("--catalogue", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    pristine = os.path.abspath(a.pristine)
    if a.catalogue:
        for r in catalogue(load_mutate(pristine)):
            print(f"{r['mutation']}\t{r['file']}\t{r['track']}\t{r['guard']}")
        return 0
    if not (a.tree and a.plan and a.sealed):
        ap.error("--tree, --plan and --sealed are required to plant")
    with open(a.plan) as fh:
        plan = json.load(fh)
    sealed = plant(os.path.abspath(a.tree), pristine, plan, a.sealed)
    print(f"planted {len(sealed['seeds'])} seed(s) into {a.tree}; sealed record: {a.sealed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
