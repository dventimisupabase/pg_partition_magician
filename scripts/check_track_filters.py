#!/usr/bin/env python3
"""Every file a test.sh track runs must be in its workflow's path filter.

WHY THIS EXISTS. A GitHub Actions `paths:` filter is a hand-maintained list of what a workflow
watches, and it drifts behind what the track it runs actually invokes. The drift is invisible in the
worst way: the job does not fail, it does not run, and a PR that changed only the guard it was
supposed to gate merges with a green tick and no evidence that anything looked at it. Three
instances were found and fixed by hand in one afternoon, each a different gap behind the same
symptom:

  perf.yml      4 of the 13 guards run_perf runs were unlisted, including bench/upgrade_in_place.sh
                -- so the PR that rewrote that guard triggered no perf job of its own (#419).
  lockview.yml  the seven lock-view files were complete; docker-compose.yml and Dockerfile, which
                define and build the container the track runs IN, were not (#423).
  archive.yml   all four bench/archive_*.sh guards were unlisted. Their MUTATION side was still
                covered by perf.yml's discriminate step, which is exactly the half-coverage this
                repo keeps mistaking for coverage (#424).

Patching instances is not a fix for a class. This is the same lesson as #417 one level up: a
hand-maintained list of what to check needs something that checks the list.

WHAT IT CHECKS, per workflow that both carries a `paths:` filter and runs `./test.sh <track>`:

  1. Every repo file the track's body in test.sh actually names is matched by the filter.
  2. `push.paths` and `pull_request.paths` are identical. They are maintained as duplicate blocks,
     so an edit to one and not the other is a silent half-fix.
  3. `test.sh` is in the filter. The track's BODY lives there; lockview.yml's header records this
     exact omission as a real past bug, where a PR weakening run_lockview triggered nothing.
  4. The workflow names ITSELF. Without it, an edit to the filter does not run the job it gates,
     so the edit is never exercised.

The workflow-to-track mapping is DERIVED, from `run:` steps in the parsed YAML, never hardcoded: a
hardcoded map is the same kind of list this script exists to police, and deriving it is what turned
up observe.yml, which the by-hand sweep had missed entirely. Workflows with no `paths:` at all
(test.yml, timescale.yml) are skipped and counted: they always run, so they cannot drift.

COMMENT HANDLING, and why it is deliberately timid. Only FULL-LINE `#` comments are stripped from a
track body, never trailing ones. Over-stripping hides a real invocation and reports a clean run,
which is silent; under-stripping demands a filter entry for a path that only appears in prose, which
is loud and takes one line to resolve. Between a silent false negative and a loud false positive
this takes the loud one every time. All three known false positives (bench/lock_trace.sh and
bench/discriminate.sh, named in test.sh's own prose) are full-line comments, so timid is also
sufficient today.

Usage:
  scripts/check_track_filters.py            # check this repo
  scripts/check_track_filters.py --selftest # prove each check fails when its defect is present
"""

import fnmatch
import glob as globmod
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Paths in a track body that name a file this repo ships. Anything else a body mentions (a database
# name, a container, an S3 key) cannot need a filter entry.
REF_RE = re.compile(r"(?:bench|scripts|tests)/[A-Za-z0-9_./*-]+")

# The floor. A parser that has stopped matching test.sh or the workflow directory would otherwise
# report a clean sweep having examined nothing, which is the one result this script must never
# produce (same reasoning as bench/discriminate.sh's i=0 check).
MIN_CHECKED_WORKFLOWS = 4


def parse_tracks(test_sh):
    """{track name: body} for every `run_<track>() { ... }` in test.sh."""
    return {m.group(1): m.group(2)
            for m in re.finditer(r"^run_(\w+)\(\) \{(.*?)\n\}", test_sh, re.S | re.M)}


def strip_full_line_comments(body):
    return "\n".join("" if ln.lstrip().startswith("#") else ln for ln in body.split("\n"))


def refs_in(body):
    """Repo-relative paths a track body names, comments excluded. Unresolved: main() filters
    these against the filesystem, so a glob or a directory is still a candidate here."""
    return set(REF_RE.findall(strip_full_line_comments(body)))


def workflow_info(text):
    """(push paths or None, pull_request paths or None, [tracks it runs])."""
    doc = yaml.safe_load(text)
    on = doc.get(True, doc.get("on")) or {}
    def paths(ev):
        node = on.get(ev) if isinstance(on, dict) else None
        return node.get("paths") if isinstance(node, dict) else None
    tracks, templated = [], []
    for job in (doc.get("jobs") or {}).values():
        for step in (job.get("steps") or []):
            run = step.get("run")
            if run:
                tracks += re.findall(r"\./test\.sh\s+([a-z][a-z0-9_]*)", run)
                # `./test.sh ${{ matrix.track }}`: the track is decided at run time, so this parser
                # cannot see it and would file the workflow under "not a track workflow". That is how
                # the sharded perf.yml silently left the verified set while it was being written.
                templated += re.findall(r"\./test\.sh\s+\$\{\{[^}]*\}\}", run)
    return paths("push"), paths("pull_request"), tracks, templated


def matches(pattern, path):
    """GitHub path-filter globbing: ** crosses /, * and ? do not."""
    rx = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            rx += ".*"
            i += 2
        elif pattern[i] == "*":
            rx += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            rx += "[^/]"
            i += 1
        else:
            rx += re.escape(pattern[i])
            i += 1
    return re.fullmatch(rx, path) is not None


def check_workflow(name, text, tracks_by_name, exists):
    """Violations for one workflow. `exists` decides whether a candidate reference is a real file,
    so the pure checks below stay testable without a filesystem."""
    push, pr, tracks, templated = workflow_info(text)
    if push is None and pr is None:
        return [], False                       # always runs; cannot drift
    if templated:
        return [f"{name}: runs {templated[0]!r}, a track chosen by a matrix variable. This check "
                f"reads the track name out of the run step to know what the job covers, so a templated "
                f"track makes the whole workflow invisible to it (it would be reported as not a track "
                f"workflow). Write the track literally, one job per track, and put the variable in "
                f"the arguments instead."], True
    if not tracks:
        return [], False                       # not a track workflow; pages.yml, and none of this applies
    v = []

    # Only when BOTH triggers exist. A workflow deliberately scoped to one of them (a deploy that
    # runs on push and never on a PR) is not a half-finished edit.
    if push is not None and pr is not None and push != pr:
        only_push = [p for p in (push or []) if p not in (pr or [])]
        only_pr = [p for p in (pr or []) if p not in (push or [])]
        v.append(f"{name}: push.paths and pull_request.paths differ "
                 f"(push only: {only_push or 'none'}; pull_request only: {only_pr or 'none'}). "
                 f"They are duplicate blocks, so editing one and not the other is a silent half-fix.")

    filt = pr if pr is not None else push
    if not any(p == "test.sh" for p in filt):
        v.append(f"{name}: does not filter on test.sh, where the body of "
                 f"{'/'.join(tracks) or 'its track'} lives. A PR weakening the track itself would "
                 f"trigger no job.")
    selfpath = f".github/workflows/{name}"
    if not any(p == selfpath for p in filt):
        v.append(f"{name}: does not name itself ({selfpath}), so an edit to this filter does not "
                 f"run the job it gates and is never exercised.")

    for track in tracks:
        body = tracks_by_name.get(track)
        if body is None:
            v.append(f"{name}: runs `./test.sh {track}`, but test.sh has no run_{track}(). "
                     f"Either the track was renamed or this parser has stopped matching.")
            continue
        # The dependency a path regex cannot see. A track that brings up a compose service depends
        # on docker-compose.yml (which defines it) and Dockerfile (which builds its image), and
        # NAMES NEITHER: it says `$DC --profile x up`. This is exactly how #423 hid -- the first
        # cut of this script reproduced the other two historical gaps and stayed green on that one,
        # which is why it is checked by what the body DOES rather than by what it mentions.
        if re.search(r"\$DC\b|docker[- ]compose", strip_full_line_comments(body)):
            for req in ("docker-compose.yml", "Dockerfile"):
                if not any(p == req for p in filt):
                    v.append(f"{name}: run_{track}() brings up a compose service but the filter "
                             f"does not name {req}. The track never mentions it by path, so a "
                             f"change to the service or its image triggers this job not at all.")

        refs = sorted(r for r in refs_in(body) if exists(r))
        if not refs:
            v.append(f"{name}: run_{track}() names no repo file at all. A track body that "
                     f"references nothing means this parser is not reading it.")
            continue
        for ref in refs:
            if not any(matches(p, ref) for p in filt):
                v.append(f"{name}: run_{track}() runs {ref}, which no path in the filter matches. "
                         f"A PR changing only that file triggers this job not at all.")
    return v, True


def run(test_sh, workflows, exists):
    """workflows: {basename: text}. Returns (violations, number actually checked)."""
    tracks_by_name = parse_tracks(test_sh)
    if not tracks_by_name:
        return ["test.sh: found no run_<track>() definitions at all; this parser is broken"], 0
    out, checked = [], 0
    for name in sorted(workflows):
        v, did = check_workflow(name, workflows[name], tracks_by_name, exists)
        out += v
        checked += 1 if did else 0
    return out, checked


# ---------------------------------------------------------------------------------------------
# self-test

CLEAN_TEST_SH = '''#!/usr/bin/env bash
run_demo() {
  # a full-line comment naming bench/not_invoked.sh, which must NOT be demanded
  bash "$(dirname "$0")/bench/demo_guard.sh" "$c" db
  python3 scripts/demo_helper.py
}
'''

CLEAN_WF = """name: Demo
on:
  push:
    paths: ['bench/demo_guard.sh', 'scripts/demo_helper.py', 'test.sh', '.github/workflows/demo.yml']
  pull_request:
    paths: ['bench/demo_guard.sh', 'scripts/demo_helper.py', 'test.sh', '.github/workflows/demo.yml']
jobs:
  demo:
    steps:
      - run: ./test.sh demo
"""

FAKE_FILES = {"bench/demo_guard.sh", "scripts/demo_helper.py", "bench/not_invoked.sh"}


def selftest():
    exists = FAKE_FILES.__contains__
    failures = 0

    def case(label, test_sh, wf, want_in_violation):
        nonlocal failures
        v, checked = run(test_sh, {"demo.yml": wf}, exists)
        if want_in_violation is None:
            if v:
                print(f"SELFTEST FAIL  {label}\n        reported: {v}")
                failures += 1
            elif checked != 1:
                print(f"SELFTEST FAIL  {label}\n        checked {checked} workflows, expected 1")
                failures += 1
            else:
                print(f"SELFTEST PASS  {label}")
            return
        if not any(want_in_violation in x for x in v):
            print(f"SELFTEST FAIL  {label}\n        wanted a violation mentioning "
                  f"{want_in_violation!r}, got: {v}")
            failures += 1
        else:
            print(f"SELFTEST PASS  {label}")

    case("a complete filter is clean, and a full-line comment demands nothing",
         CLEAN_TEST_SH, CLEAN_WF, None)

    case("an invoked file missing from the filter is caught",
         CLEAN_TEST_SH, CLEAN_WF.replace("'bench/demo_guard.sh', ", "", 2), "bench/demo_guard.sh")

    case("push and pull_request filters drifting apart is caught",
         CLEAN_TEST_SH,
         CLEAN_WF.replace("'bench/demo_guard.sh', 'scripts/demo_helper.py', 'test.sh', "
                          "'.github/workflows/demo.yml']", "'bench/demo_guard.sh']", 1),
         "differ")

    case("a filter that forgets test.sh is caught",
         CLEAN_TEST_SH, CLEAN_WF.replace("'test.sh', ", "", 2), "does not filter on test.sh")

    case("a filter that does not name itself is caught",
         CLEAN_TEST_SH, CLEAN_WF.replace(", '.github/workflows/demo.yml'", "", 2), "name itself")

    # The real instance: perf.yml's first sharded draft ran `./test.sh ${{ matrix.track }}` and this
    # script verified one workflow fewer, saying nothing. A track it cannot read must be a violation,
    # not a silent exit from the checked set.
    case("a track chosen by a matrix variable is caught, not skipped",
         CLEAN_TEST_SH, CLEAN_WF.replace("run: ./test.sh demo", "run: ./test.sh ${{ matrix.track }} --shard=1/2"),
         "matrix variable")

    case("a workflow running a track test.sh does not define is caught",
         CLEAN_TEST_SH.replace("run_demo()", "run_other()"), CLEAN_WF, "no run_demo()")

    # The liveness floors: a parser that reads nothing must FAIL, never report clean.
    v, checked = run("nothing here at all\n", {"demo.yml": CLEAN_WF}, exists)
    if not any("no run_<track>() definitions" in x for x in v):
        print(f"SELFTEST FAIL  a test.sh this parser cannot read reports clean: {v}")
        failures += 1
    else:
        print("SELFTEST PASS  a test.sh this parser cannot read fails loudly")

    v, _ = run("run_demo() {\n  echo hi\n}\n", {"demo.yml": CLEAN_WF}, exists)
    if not any("names no repo file at all" in x for x in v):
        print(f"SELFTEST FAIL  a track body naming no file reports clean: {v}")
        failures += 1
    else:
        print("SELFTEST PASS  a track body naming no file fails loudly")

    # The #423 case, pinned. A track that brings up a compose service names neither the compose
    # file nor the Dockerfile, so nothing a path regex can see relates them.
    dc_test_sh = CLEAN_TEST_SH.replace('  bash "$(dirname "$0")/bench/demo_guard.sh" "$c" db',
                                       '  $DC --profile demo up -d --wait demo\n'
                                       '  bash "$(dirname "$0")/bench/demo_guard.sh" "$c" db')
    dc_wf = CLEAN_WF.replace("'test.sh',", "'test.sh', 'docker-compose.yml', 'Dockerfile',")
    case("a compose-using track needs docker-compose.yml and Dockerfile", dc_test_sh, dc_wf, None)
    case("a compose-using track missing docker-compose.yml is caught",
         dc_test_sh, dc_wf.replace(" 'docker-compose.yml',", "", 2), "docker-compose.yml")
    case("a compose-using track missing Dockerfile is caught",
         dc_test_sh, dc_wf.replace(" 'Dockerfile',", "", 2), "Dockerfile")

    # A path-filtered workflow that runs no track at all (pages.yml) is none of this check's
    # business. Caught by the real repo on the first run, when every rule below fired against it.
    v, checked = run(CLEAN_TEST_SH,
                     {"pages.yml": "name: P\non:\n  push:\n    paths: ['index.html']\njobs:\n"
                                   "  p:\n    steps:\n      - run: echo deploy\n"}, exists)
    if v or checked != 0:
        print(f"SELFTEST FAIL  a path-filtered workflow running no track was not skipped: "
              f"{v}, checked={checked}")
        failures += 1
    else:
        print("SELFTEST PASS  a path-filtered workflow that runs no track is skipped")

    # A track workflow deliberately scoped to push only must not be read as a half-finished edit.
    push_only = ("name: D\non:\n  push:\n    paths: ['bench/demo_guard.sh', 'scripts/demo_helper.py',"
                 " 'test.sh', '.github/workflows/demo.yml']\njobs:\n"
                 "  d:\n    steps:\n      - run: ./test.sh demo\n")
    v, checked = run(CLEAN_TEST_SH, {"demo.yml": push_only}, exists)
    if any("differ" in x for x in v):
        print(f"SELFTEST FAIL  a push-only track workflow was reported as drifted: {v}")
        failures += 1
    else:
        print("SELFTEST PASS  a push-only track workflow is not reported as drifted")

    # A workflow with no paths: always runs, cannot drift, and must not be counted as checked.
    v, checked = run(CLEAN_TEST_SH,
                     {"demo.yml": "name: D\non:\n  push: {branches: [main]}\njobs:\n"
                                  "  d:\n    steps:\n      - run: ./test.sh demo\n"}, exists)
    if v or checked != 0:
        print(f"SELFTEST FAIL  an unfiltered workflow was not skipped: {v}, checked={checked}")
        failures += 1
    else:
        print("SELFTEST PASS  an unfiltered workflow is skipped, and not counted as checked")

    for pat, path, want in [("bench/*.sh", "bench/a.sh", True),
                            ("bench/*.sh", "bench/sub/a.sh", False),
                            ("tests/archive/**", "tests/archive/db/x.sql", True),
                            ("scripts/verify_parquet*.py", "scripts/verify_parquet_range.py", True)]:
        if matches(pat, path) != want:
            print(f"SELFTEST FAIL  glob {pat!r} vs {path!r}: expected {want}")
            failures += 1
    else:
        print("SELFTEST PASS  ** crosses a slash and * does not")

    print()
    if failures:
        print(f"check_track_filters selftest: FAIL ({failures} failure(s))")
        return 1
    print("check_track_filters selftest: PASS")
    return 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        return selftest()
    if len(sys.argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2

    os.chdir(ROOT)
    workflows = {os.path.basename(p): open(p).read()
                 for p in sorted(globmod.glob(".github/workflows/*.yml"))}
    if not workflows:
        print("check_track_filters: no workflows found; this check examined nothing", file=sys.stderr)
        return 1

    def exists(ref):
        if any(c in ref for c in "*?"):
            return bool(globmod.glob(ref))
        return os.path.isfile(ref)

    # A glob in a track body stands for the files it matches, so each is checked on its own.
    def expand(ref):
        return globmod.glob(ref) if any(c in ref for c in "*?") else [ref]

    violations, checked = run(open("test.sh").read(), workflows, exists)

    # Re-check glob references file by file: `tests/archive/db/*.sql` covered as a whole says
    # nothing about a file the glob matches that the filter does not.
    tracks_by_name = parse_tracks(open("test.sh").read())
    for name, text in sorted(workflows.items()):
        push, pr, tracks, _templated = workflow_info(text)
        filt = pr if pr is not None else push
        if filt is None:
            continue
        for track in tracks:
            for ref in sorted(refs_in(tracks_by_name.get(track) or "")):
                for f in expand(ref):
                    if os.path.isfile(f) and not any(matches(p, f) for p in filt):
                        msg = (f"{name}: run_{track}() runs {f}, which no path in the filter "
                               f"matches. A PR changing only that file triggers this job not at all.")
                        if msg not in violations:
                            violations.append(msg)

    if checked < MIN_CHECKED_WORKFLOWS:
        violations.append(
            f"only {checked} path-filtered track workflow(s) were checked, expected at least "
            f"{MIN_CHECKED_WORKFLOWS}. A workflow that stopped being recognised is a filter nobody "
            f"is policing; fix the parser or lower the floor deliberately.")

    if violations:
        print("check_track_filters: FAIL")
        for x in violations:
            print("  " + x)
        return 1
    print(f"check_track_filters: PASS ({checked} path-filtered track workflow(s) verified)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
