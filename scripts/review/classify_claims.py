#!/usr/bin/env python3
"""Run every claim's reproduction against the review tree AND the pristine commit, and classify it
(docs/adversarial-review.md, "A pass, step by step", step 6). This is the mechanical half of
verification; no model is involved. The verifier agent reads this file's output and only then tries to
disprove the candidates.

Claims directory layout (one directory per claim, grouped by finder):

  <claims>/<finder>/<claim-id>/claim.json      {"id": "F3-07", "finder": "F3", "tier": 1,
                                                 "file": "pgpm_core/install.sql", "line": 4671,
                                                 "lens": "concurrency", "scenario": "one line",
                                                 "repro": "repro.sql",            # or repro.sh
                                                 "install": ["pgpm_core/install.sql"],   # default
                                                 "fixtures": false}               # fixtures/demo.sql
  <claims>/<finder>/<claim-id>/repro.sql | repro.sh

The reproduction contract. Each run gets a FRESH database in the harness container with the tree under
test installed (every file in "install", piped through psql, so the tree need not be mounted).
  repro.sql  is piped into `psql -v ON_ERROR_STOP=1`. The defect is PRESENT ("fails") when psql exits
             non-zero or any output line begins with `not ok` (pgTAP is fine; create the extension in
             the file).
  repro.sh   runs on the host with PSQL (a command prefix that connects to the fresh database), TREE
             (the tree under test), DB and CONTAINER in the environment. Non-zero exit means "fails".

Classification, from the two runs:
  seed_hit        fails on the review tree, not on the pristine commit: the finder found a seed. It is
                  attributed to the nearest seed in the same file (from the sealed record).
  candidate       fails on both: a real defect until the verifier disproves it.
  not_reproduced  fails on neither: dropped.
  inverted        fails on the pristine commit only. Should not happen; look at the reproduction.

Usage:
  classify_claims.py --claims <dir> --review-tree <dir> --pristine-tree <dir> --sealed <json>
                     --out <json> [--container pgpm_test-15] [--only <claim-id>] [--keep-dbs]
  classify_claims.py --selftest
"""
import argparse
import json
import os
import re
import subprocess
import sys

NOT_OK = re.compile(r"^not ok\b", re.M)


def load_claims(claims_dir, only=None):
    claims = []
    for finder in sorted(os.listdir(claims_dir)):
        fdir = os.path.join(claims_dir, finder)
        if not os.path.isdir(fdir):
            continue
        for cid in sorted(os.listdir(fdir)):
            cdir = os.path.join(fdir, cid)
            cj = os.path.join(cdir, "claim.json")
            if not os.path.isfile(cj):
                continue
            with open(cj) as fh:
                c = json.load(fh)
            c.setdefault("id", cid)
            c.setdefault("finder", finder)
            c.setdefault("install", ["pgpm_core/install.sql"])
            c.setdefault("fixtures", False)
            c["dir"] = cdir
            if only and c["id"] != only:
                continue
            repro = os.path.join(cdir, c.get("repro", ""))
            if not c.get("repro") or not os.path.isfile(repro):
                c["error"] = "no reproduction file; a claim without one is a hypothesis, not a finding"
            claims.append(c)
    return claims


class Harness:
    """Fresh database per run in a running harness container; files reach psql through stdin."""

    def __init__(self, container, keep=False):
        self.container = container
        self.keep = keep

    def psql(self, db, args, stdin=None, check=True):
        cmd = ["docker", "exec", "-i", self.container, "psql", "-U", "postgres", "-d", db,
               "-v", "ON_ERROR_STOP=1", *args]
        return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=check)

    def run(self, tree, claim, tag):
        db = re.sub(r"[^a-z0-9_]", "_", f"rv_{claim['id']}_{tag}".lower())
        self.psql("postgres", ["-qc", f'drop database if exists "{db}"'])
        self.psql("postgres", ["-qc", f'create database "{db}"'])
        try:
            for rel in claim["install"]:
                with open(os.path.join(tree, rel)) as fh:
                    self.psql(db, ["-q", "--single-transaction", "-f", "-"], stdin=fh.read())
            if claim["fixtures"]:
                with open(os.path.join(tree, "fixtures", "demo.sql")) as fh:
                    self.psql(db, ["-q", "-f", "-"], stdin=fh.read())
            repro = os.path.join(claim["dir"], claim["repro"])
            if repro.endswith(".sql"):
                with open(repro) as fh:
                    r = self.psql(db, ["-f", "-"], stdin=fh.read(), check=False)
                out = r.stdout + r.stderr
                fails = r.returncode != 0 or bool(NOT_OK.search(r.stdout))
            else:
                env = {**os.environ,
                       "PSQL": f"docker exec -i {self.container} psql -U postgres -d {db} -v ON_ERROR_STOP=1",
                       "TREE": tree, "DB": db, "CONTAINER": self.container}
                r = subprocess.run(["bash", repro], env=env, capture_output=True, text=True, cwd=claim["dir"])
                out = r.stdout + r.stderr
                fails = r.returncode != 0
            return {"fails": fails, "exit": r.returncode, "tail": out[-1500:]}
        finally:
            if not self.keep:
                self.psql("postgres", ["-qc", f'drop database if exists "{db}"'], check=False)


def classify(review, pristine):
    if review["fails"] and not pristine["fails"]:
        return "seed_hit"
    if review["fails"] and pristine["fails"]:
        return "candidate"
    if not review["fails"] and not pristine["fails"]:
        return "not_reproduced"
    return "inverted"


def attribute(claim, seeds, window=60):
    """The seed nearest to the claim's file:line, within `window` lines; None if no seed is near."""
    best, best_d = None, None
    for s in seeds:
        if s.get("file") != claim.get("file") or not s.get("lines"):
            continue
        d = min(abs(int(claim.get("line") or 0) - ln) for ln in s["lines"])
        if d <= window and (best_d is None or d < best_d):
            best, best_d = s["id"], d
    return best


def run_all(claims, review_tree, pristine_tree, seeds, runner):
    out = []
    for c in claims:
        rec = {k: c.get(k) for k in ("id", "finder", "tier", "file", "line", "lens", "scenario", "repro")}
        if c.get("error"):
            rec.update({"class": "hypothesis", "error": c["error"]})
            out.append(rec)
            continue
        rv = runner(review_tree, c, "r")
        pr = runner(pristine_tree, c, "p")
        cls = classify(rv, pr)
        rec.update({"review": rv, "pristine": pr, "class": cls})
        if cls == "seed_hit":
            rec["seed"] = attribute(c, seeds)
            if rec["seed"] is None:
                rec["note"] = "seed hit with no seed near this file:line; check the claim's location or the sealed record"
        out.append(rec)
    return out


def summary(results):
    counts = {}
    for r in results:
        counts[r["class"]] = counts.get(r["class"], 0) + 1
    lines = ["class           n", "--------------  --"]
    for k in ("candidate", "seed_hit", "not_reproduced", "inverted", "hypothesis"):
        if k in counts:
            lines.append(f"{k:<15} {counts[k]:>2}")
    for r in results:
        if r["class"] == "seed_hit":
            lines.append(f"  {r['id']}: seed {r.get('seed') or '?'}" + (f"  ({r['note']})" if r.get("note") else ""))
    return "\n".join(lines)


def selftest():
    # classification truth table
    F, P = {"fails": True}, {"fails": False}
    assert classify(F, P) == "seed_hit" and classify(F, F) == "candidate"
    assert classify(P, P) == "not_reproduced" and classify(P, F) == "inverted"
    # `not ok` in TAP output is a failure even when psql exits 0
    assert NOT_OK.search("ok 1\nnot ok 2 - x\n") and not NOT_OK.search("ok 1\n# not ok in a comment\n")
    # attribution picks the nearest seed in the SAME file, within the window
    seeds = [{"id": "S1", "file": "a.sql", "lines": [100]}, {"id": "S2", "file": "a.sql", "lines": [400]},
             {"id": "S3", "file": "b.sql", "lines": [100]}]
    assert attribute({"file": "a.sql", "line": 380}, seeds) == "S2"
    assert attribute({"file": "a.sql", "line": 250}, seeds) is None
    assert attribute({"file": "b.sql", "line": 101}, seeds) == "S3"
    # end to end with a fake runner: a seed hit is attributed, a candidate is not, a missing repro is a hypothesis
    claims = [
        {"id": "F1-01", "finder": "F1", "file": "a.sql", "line": 105, "repro": "r.sql", "dir": "."},
        {"id": "F1-02", "finder": "F1", "file": "a.sql", "line": 900, "repro": "r.sql", "dir": "."},
        {"id": "F1-03", "finder": "F1", "file": "a.sql", "line": 1, "error": "no reproduction file"},
    ]

    def fake(tree, c, tag):
        table = {("F1-01", "review"): True, ("F1-01", "pristine"): False,
                 ("F1-02", "review"): True, ("F1-02", "pristine"): True}
        return {"fails": table[(c["id"], tree)], "exit": 1, "tail": ""}
    res = run_all(claims, "review", "pristine", seeds, fake)
    assert [r["class"] for r in res] == ["seed_hit", "candidate", "hypothesis"], res
    assert res[0]["seed"] == "S1" and "seed" not in res[1]
    assert "candidate        1" in summary(res) and "seed_hit         1" in summary(res)
    print("classify_claims selftest: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--claims")
    ap.add_argument("--review-tree")
    ap.add_argument("--pristine-tree")
    ap.add_argument("--sealed")
    ap.add_argument("--out")
    ap.add_argument("--container", default="pgpm_test-15")
    ap.add_argument("--only")
    ap.add_argument("--keep-dbs", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not (a.claims and a.review_tree and a.pristine_tree and a.sealed and a.out):
        ap.error("--claims, --review-tree, --pristine-tree, --sealed and --out are required")
    with open(a.sealed) as fh:
        seeds = json.load(fh)["seeds"]
    claims = load_claims(a.claims, a.only)
    if not claims:
        print("classify_claims: no claims found", file=sys.stderr)
        return 1
    h = Harness(a.container, keep=a.keep_dbs)
    results = run_all(claims, os.path.abspath(a.review_tree), os.path.abspath(a.pristine_tree), seeds, h.run)
    with open(a.out, "w") as fh:
        json.dump({"claims": results}, fh, indent=2)
    print(summary(results))
    print(f"written: {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
