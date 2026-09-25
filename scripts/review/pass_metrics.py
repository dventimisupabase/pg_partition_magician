#!/usr/bin/env python3
"""Compute a review pass's metrics and write its record (docs/adversarial-review.md, "Metrics" and
"Pass record"). Recall and precision are computed and printed BEFORE the count of findings, and the
record puts them on the same line, so the count is never read alone.

Inputs:
  --sealed      plant_seeds.py's sealed record (the seeds, their lenses and tiers)
  --classified  classify_claims.py's output (every claim with its class and attributed seed)
  --verdicts    the verifier's verdicts, one per candidate:
                {"F3-07": {"verdict": "finding", "tier": 1, "root_cause": "session TimeZone grid"},
                 "F2-01": {"verdict": "fell", "reason": "documented; reference.md#retain"},
                 "F1-04": {"verdict": "known_open", "issue": 439}}
  --budget-units, --budget  a number (agent-hours or tokens) for cost per finding, and its text form

Definitions used here:
  recall     = seeds attributed to at least one claim / K
  precision  = (findings + seed hits) / claims that had a reproduction. A correctly reported seed is a
               true report, so it counts for the finder; a hypothesis (no reproduction) is not a claim.
  cost       = budget-units / findings, and / Tier 1 findings

Usage:
  pass_metrics.py --pass N --date YYYY-MM-DD --pinned <sha> --release <tag> --sealed s.json
                  --classified c.json --verdicts v.json --budget "8 finders x 2h, 6h wall" --budget-units 16
                  --lenses "fresh surface, concurrency" --previous-lenses "..." --out docs/reviews/YYYY-MM-DD.md
  pass_metrics.py --selftest
"""
import argparse
import json
import sys

TIERS = (1, 2, 3, 4, 5)


def compute(sealed, classified, verdicts, budget_units=None):
    seeds = sealed["seeds"]
    claims = [c for c in classified["claims"] if c.get("class") != "hypothesis"]
    hypotheses = [c for c in classified["claims"] if c.get("class") == "hypothesis"]
    seed_hits = [c for c in claims if c["class"] == "seed_hit"]
    candidates = [c for c in claims if c["class"] == "candidate"]
    hit_ids = {c.get("seed") for c in seed_hits if c.get("seed")}
    K = len(seeds)
    recall = (len([s for s in seeds if s["id"] in hit_ids]) / K) if K else None

    findings, fell, known = [], [], []
    for c in candidates:
        v = verdicts.get(c["id"], {"verdict": "unverified"})
        c = {**c, "verdict": v}
        {"finding": findings, "fell": fell, "known_open": known}.get(v["verdict"], fell).append(c)
    unverified = [c for c in candidates if c["id"] not in verdicts]

    by_tier = {t: 0 for t in TIERS}
    for f in findings:
        t = int(f["verdict"].get("tier") or f.get("tier") or 0)
        if t in by_tier:
            by_tier[t] += 1
    root_causes = {f["verdict"].get("root_cause") for f in findings if f["verdict"].get("root_cause")}

    n_claims = len(claims)
    precision = ((len(findings) + len(seed_hits)) / n_claims) if n_claims else None
    per_finder = {}
    for c in claims:
        d = per_finder.setdefault(c["finder"], {"claims": 0, "true": 0})
        d["claims"] += 1
        if c["class"] == "seed_hit" or any(f["id"] == c["id"] for f in findings):
            d["true"] += 1
    for d in per_finder.values():
        d["precision"] = d["true"] / d["claims"] if d["claims"] else None

    blind = [s for s in seeds if s["id"] not in hit_ids]
    cost = cost_t1 = None
    if budget_units:
        cost = budget_units / len(findings) if findings else None
        cost_t1 = budget_units / by_tier[1] if by_tier[1] else None

    return {
        "K": K, "recall": recall, "claims": n_claims, "hypotheses": len(hypotheses),
        "seed_hits": len(seed_hits), "candidates": len(candidates), "findings": len(findings),
        "precision": precision, "by_tier": by_tier, "root_causes": sorted(root_causes),
        "known_open": len(known), "fell": len(fell), "unverified": len(unverified),
        "cost_per_finding": cost, "cost_per_t1": cost_t1, "per_finder": per_finder,
        "blind_spots": [{"id": s["id"], "lens": s["lens"], "tier": s["tier"],
                         "what": s.get("mutation") or s.get("patch")} for s in blind],
        "finding_rows": [{"id": f["id"], "tier": int(f["verdict"].get("tier") or f.get("tier") or 0),
                          "scenario": f.get("scenario", ""), "issue": f["verdict"].get("issue")} for f in findings],
        "fell_rows": [{"id": f["id"], "reason": f["verdict"].get("reason", "")} for f in fell],
        "known_rows": [{"id": f["id"], "issue": f["verdict"].get("issue")} for f in known],
        "hypothesis_rows": [{"id": h["id"], "finder": h["finder"], "scenario": h.get("scenario", "")} for h in hypotheses],
    }


def stopping_status(m):
    """This pass's half of the stopping criteria (the other half is the previous pass)."""
    rows = [
        ("zero Tier 1 findings", m["by_tier"][1] == 0),
        ("seed recall >= 0.8", m["recall"] is not None and m["recall"] >= 0.8),
        ("precision >= 0.7", m["precision"] is not None and m["precision"] >= 0.7),
    ]
    return rows


def fmt(x, nd=2):
    return "n/a" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


def record(m, a):
    t = m["by_tier"]
    lines = [
        f"# Review pass {a.pass_n}: {a.date}", "",
        f"pinned: `{a.pinned}` ({a.release}) | budget: {a.budget}",
        f"lenses: {a.lenses} | previous pass lenses: {a.previous_lenses}",
        f"seeds K={m['K']}, recall {fmt(m['recall'])}; claims {m['claims']}; findings {m['findings']}; precision {fmt(m['precision'])}",
        f"findings by tier: T1 {t[1]} T2 {t[2]} T3 {t[3]} T4 {t[4]} T5 {t[5]}",
        f"cost per finding: {fmt(m['cost_per_finding'], 1)}; per Tier 1 finding: {fmt(m['cost_per_t1'], 1)}",
        f"root causes: {len(m['root_causes'])} distinct verifier root-cause statements behind the findings"
        + (f"; grouped into {a.root_cause_groups} classes below" if a.root_cause_groups else "")
        + "; closed as a class: to be filled after the fix phase",
        f"known and open (re-found, unfixed from earlier passes): {m['known_open']}",
        f"capture-recapture (T1): {a.capture_recapture}",
        "blind spots (seeds missed, by lens): " + (", ".join(f"{b['id']} {b['what']} ({b['lens']}, T{b['tier']})" for b in m["blind_spots"]) or "none"),
        "",
        f"Per finder (claims, precision): " + ", ".join(f"{k} ({v['claims']}, {fmt(v['precision'])})" for k, v in sorted(m["per_finder"].items())),
        f"Seed hits {m['seed_hits']}, candidates {m['candidates']}, fell {m['fell']}, unverified {m['unverified']}, hypotheses {m['hypotheses']}.",
        "", "## Findings", "", "| tier | finding | issue | fix PR |", "|---|---|---|---|",
    ]
    for f in sorted(m["finding_rows"], key=lambda r: (r["tier"], r["id"])):
        issue = f"#{f['issue']}" if f["issue"] else ""
        lines.append(f"| {f['tier']} | {f['id']}: {f['scenario']} | {issue} | |")
    lines += ["", "## Null results (by lens)", "", "(from the finders' null-results files)", "",
              "## Fell in verification", ""]
    lines += [f"- {r['id']}: {r['reason']}" for r in m["fell_rows"]] or ["none"]
    lines += ["", "## Known and open", ""]
    lines += [f"- {r['id']}: #{r['issue']}" for r in m["known_rows"]] or ["none"]
    lines += ["", "## Hypotheses (not counted)", ""]
    lines += [f"- {r['id']} ({r['finder']}): {r['scenario']}" for r in m["hypothesis_rows"]] or ["none"]
    lines += ["", "## Stopping criteria status", "", "This pass's half; the criteria need the previous pass as well.", ""]
    lines += [f"- {name}: {'met' if ok else 'NOT met'}" for name, ok in stopping_status(m)]
    if getattr(a, "root_causes_file", None):
        with open(a.root_causes_file) as fh:
            lines += ["", "## Root causes", "", fh.read().rstrip("\n")]
    if getattr(a, "notes_file", None):
        with open(a.notes_file) as fh:
            lines += ["", "## Coordinator notes", "", fh.read().rstrip("\n")]
    return "\n".join(lines) + "\n"


def selftest():
    sealed = {"seeds": [{"id": "S1", "lens": "time", "tier": 1, "mutation": "grid_session_timezone"},
                        {"id": "S2", "lens": "concurrency", "tier": 1, "mutation": "untransmute_no_recheck_under_lock"}]}
    classified = {"claims": [
        {"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1},
        {"id": "F1-02", "finder": "F1", "class": "candidate", "tier": 1, "scenario": "rows lost"},
        {"id": "F1-03", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "documented"},
        {"id": "F2-01", "finder": "F2", "class": "not_reproduced", "tier": 2},
        {"id": "F2-02", "finder": "F2", "class": "candidate", "tier": 2},
        {"id": "F2-03", "finder": "F2", "class": "hypothesis", "error": "no reproduction file"},
    ]}
    verdicts = {"F1-02": {"verdict": "finding", "tier": 1, "root_cause": "x", "issue": 500},
                "F1-03": {"verdict": "fell", "reason": "documented"},
                "F2-02": {"verdict": "known_open", "issue": 439}}
    m = compute(sealed, classified, verdicts, budget_units=16)
    assert m["K"] == 2 and m["recall"] == 0.5, m
    assert m["claims"] == 5 and m["hypotheses"] == 1
    assert m["findings"] == 1 and m["by_tier"][1] == 1
    assert abs(m["precision"] - 2 / 5) < 1e-9          # one finding + one seed hit over five claims
    assert m["known_open"] == 1 and m["fell"] == 1 and m["unverified"] == 0
    assert m["per_finder"]["F1"]["precision"] == 2 / 3 and m["per_finder"]["F2"]["precision"] == 0
    assert m["cost_per_finding"] == 16 and m["cost_per_t1"] == 16
    assert [b["id"] for b in m["blind_spots"]] == ["S2"]
    st = dict(stopping_status(m))
    assert st["zero Tier 1 findings"] is False and st["seed recall >= 0.8"] is False

    class A:
        pass_n, date, pinned, release = 2, "2026-10-01", "c5a60df", "0.6.0+"
        budget, lenses, previous_lenses, capture_recapture = "2 x 1h", "time", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = 1, None, None
    rec = record(m, A)
    assert "recall 0.50; claims 5; findings 1; precision 0.40" in rec, rec
    assert "| 1 | F1-02: rows lost | #500 | |" in rec
    assert "S2 untransmute_no_recheck_under_lock (concurrency, T1)" in rec
    assert "root causes: 1 distinct verifier root-cause statements behind the findings; grouped into 1 classes below" in rec
    assert "- F2-02: #439" in rec and "- F2-03 (F2):" in rec
    print("pass_metrics selftest: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sealed"); ap.add_argument("--classified"); ap.add_argument("--verdicts")
    ap.add_argument("--pass", dest="pass_n"); ap.add_argument("--date"); ap.add_argument("--pinned")
    ap.add_argument("--release", default=""); ap.add_argument("--budget", default="")
    ap.add_argument("--budget-units", type=float); ap.add_argument("--lenses", default="")
    ap.add_argument("--previous-lenses", default=""); ap.add_argument("--capture-recapture", default="not attempted")
    ap.add_argument("--root-causes", dest="root_causes_file", help="markdown file with the coordinator's root-cause grouping, appended as a section")
    ap.add_argument("--root-cause-groups", type=int, help="number of classes in that grouping, for the summary line")
    ap.add_argument("--notes", dest="notes_file", help="markdown file appended as 'Coordinator notes'")
    ap.add_argument("--out"); ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    for k in ("sealed", "classified", "verdicts", "pass_n", "date", "pinned", "out"):
        if not getattr(a, k):
            ap.error(f"--{k.replace('_n', '').replace('_', '-')} is required")
    with open(a.sealed) as fh:
        sealed = json.load(fh)
    with open(a.classified) as fh:
        classified = json.load(fh)
    with open(a.verdicts) as fh:
        verdicts = json.load(fh)
    m = compute(sealed, classified, verdicts, a.budget_units)
    print(f"seeds K={m['K']}  recall {fmt(m['recall'])}  precision {fmt(m['precision'])}   (read these first)")
    print(f"claims {m['claims']}  findings {m['findings']}  by tier {m['by_tier']}  unverified {m['unverified']}")
    if m["unverified"]:
        print("WARNING: candidates without a verdict are not findings; run the verifier on them first", file=sys.stderr)
    with open(a.out, "w") as fh:
        fh.write(record(m, a))
    print(f"record written: {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
