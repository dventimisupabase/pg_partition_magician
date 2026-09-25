# scripts/review: tooling for an adversarial review pass

The mechanical parts of a review pass as defined in [`docs/adversarial-review.md`](../../docs/adversarial-review.md).
Everything here is a script; nothing here judges a claim. The `/review-pass` skill (`.claude/skills/review-pass/`)
walks a coordinator through them in order, and the `finder` and `verifier` agents (`.claude/agents/`) are
the two model roles.

| script | step | what it does |
|---|---|---|
| `build_review_tree.sh <sha> <dir>` | 4 | the pinned commit as ONE history-less commit in a fresh repo with no remote; `bench/mutations/` removed |
| `plant_seeds.py --tree --pristine --plan --sealed` | 4 | applies catalogue mutations and novel patches from a plan, writes the sealed record, keeps the tree at one commit |
| `classify_claims.py --claims --review-tree --pristine-tree --sealed --out` | 6 | runs every reproduction against both trees in a fresh database each; classifies seed hit, candidate, not reproduced, inverted, hypothesis |
| `pass_metrics.py --sealed --classified --verdicts ... --out` | 8, 10 | recall and precision before the count; writes the pass record under `docs/reviews/` |

Each Python script has a `--selftest` that CI runs (`.github/workflows/lint.yml`, "Review tooling self-test").

## Claim format

One directory per claim, grouped by finder. The finder writes it; nothing else does.

```text
<claims>/<finder>/<claim-id>/claim.json
<claims>/<finder>/<claim-id>/repro.sql        or repro.sh
```

```json
{"tier": 1, "file": "pgpm_core/install.sql", "line": 4671, "lens": "concurrency",
 "scenario": "one line: what happens and what should have happened",
 "repro": "repro.sql", "install": ["pgpm_core/install.sql"], "fixtures": false}
```

`install` lists the files to load into the fresh database before the reproduction (default: the core
install); `fixtures: true` also loads `fixtures/demo.sql`. A claim directory without a reproduction file
is recorded as a **hypothesis** and is never counted or filed.

## Reproduction contract

The reproduction runs twice, against the review tree and against the pristine commit, each time in a
fresh database in the harness container with the tree under test installed. It must **fail when the
defect is present** and pass when it is absent; that is what lets the same file later close the finding
against the fixed `main`.

- `repro.sql` is piped into `psql -v ON_ERROR_STOP=1`. Present means psql exited non-zero or a line
  began with `not ok`. pgTAP is fine: `create extension if not exists pgtap;` at the top.
- `repro.sh` runs on the host under `bash` with these in the environment: `PSQL` (a command prefix
  that connects to the fresh database, use it as `$PSQL -tAc "..."`), `TREE` (the tree under test),
  `DB`, `CONTAINER`. Non-zero exit means present. Use this for two-session probes, `docker exec`
  against a second connection, or anything a single psql stream cannot express.

A reproduction that needs the finder's own environment, a hand edit to pgpm, or a state pgpm refuses
to enter is not a reproduction; the verifier will record why it fell.

## Verdicts

The verifier writes one JSON object keyed by claim id, which `pass_metrics.py` reads:

```json
{"F3-07": {"verdict": "finding",    "tier": 1, "root_cause": "session TimeZone grid", "issue": 501},
 "F2-01": {"verdict": "fell",       "reason": "documented behaviour; reference.md#set_retain"},
 "F1-04": {"verdict": "known_open", "issue": 439}}
```

Only `candidate` claims need a verdict. A candidate without one is reported as unverified and is not a
finding.

## Metric definitions

- recall: seeds attributed to at least one claim, over `K`.
- precision: findings plus seed hits, over claims that had a reproduction. A correctly reported seed
  is a true report; a hypothesis is not a claim.
- cost: budget units over findings, and over Tier 1 findings.

## Smoke test

With `pgpm_test-15` running (`docker compose --profile pg15 up -d postgres15`):

```bash
scripts/review/build_review_tree.sh HEAD /tmp/rt
printf '{"seeds": [{"mutation": "grid_session_timezone", "lens": "time", "tier": 1}]}' > /tmp/plan.json
scripts/review/plant_seeds.py --tree /tmp/rt --plan /tmp/plan.json --sealed /tmp/sealed.json
# write a claim under /tmp/claims/F1/F1-01/ whose repro.sql sets a non-UTC TimeZone and checks _grid_next
scripts/review/classify_claims.py --claims /tmp/claims --review-tree /tmp/rt --pristine-tree . \
  --sealed /tmp/sealed.json --out /tmp/classified.json
```

The claim classifies as `seed_hit` attributed to `S1`.
