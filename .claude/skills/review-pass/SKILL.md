---
name: review-pass
description: Run an adversarial review pass of pgpm end to end under docs/adversarial-review.md, as its coordinator. Pins a commit, plants blind seeds, fans out finders, verifies every candidate independently, and writes the pass record with recall and precision before the count.
argument-hint: "[pinned-sha] [K] [lens, lens, ...]"
disable-model-invocation: true
allowed-tools: Bash Read Write Agent
---

You are the **coordinator** of review pass N of pg_partition_magician. You do not review code for
defects and you do not fix anything. Read `docs/adversarial-review.md` in full before step 1, and
`scripts/review/README.md` for the file formats. Arguments: `$ARGUMENTS` (pinned sha, K, lenses; ask
for any that is missing, and for the budget).

Work in a scratch directory outside the repository (the session scratchpad). Refer to it as `$WORK`.

## 1. Pin and budget

- `pinned=$(git rev-parse <sha>)`; record the release it corresponds to (`git describe --tags`).
- Record the budget: number of finders, a per-finder token or turn cap, a wall-clock limit. Fixed now.
- Record this pass's lenses and the previous pass's (from the latest `docs/reviews/*.md`). At least
  half must differ. **Fresh surface is always included**: list the PRs merged since the previous pinned
  commit and the files and hunks they touched (`git log --oneline <prev>..<pinned>`, `git diff --stat`).

## 2. Seeds (sealed)

- `scripts/review/plant_seeds.py --catalogue` lists every catalogue mutation with its file and track.
- Write `$WORK/plan.json` with K seeds spanning the lenses and tiers 1 to 3, at least a third of them
  **novel patches** you write for this pass in the catalogue's style (a quiet defect: a dropped
  re-check, an off-by-one at a boundary, a `%I` over a `_q` fragment). Save novel patches under
  `$WORK/seeds/`.
- `scripts/review/build_review_tree.sh $pinned $WORK/tree`
- `scripts/review/plant_seeds.py --tree $WORK/tree --pristine . --plan $WORK/plan.json --sealed $WORK/sealed.json`
- Never show `$WORK/sealed.json`, `$WORK/plan.json` or `$WORK/seeds/` to a finder, and never mention
  which functions were seeded.

## 3. Slices

Divide the review tree into as many slices as finders: by module and function group, so every
`pgpm_core/install.sql` function, `pgpm_archive/install.sql`, `bench/`, `tests/` and `docs/` belong to
exactly one slice. The fresh-surface hunks go to a dedicated slice in addition to their home slice.

## 4. Hunt

Start `pgpm_test-15` from the pristine checkout (`docker compose --profile pg15 up -d postgres15`).
Spawn one **`finder`** agent per slice (the `finder` type from `.claude/agents/`), all in one message so
they run in parallel. Each prompt contains: the review tree path, the slice, the lenses, the claims
directory `$WORK/claims`, its finder id (`F1`, `F2`, ...), the budget, the container name, and the text
of `scripts/review/README.md`'s "Claim format" and "Reproduction contract" sections. Say nothing about
seeds.

**Model-tier split** (the methodology's way of choosing models with data): give two slices to a second
finder each, run with a different `model` on the Agent call, same prompt. Record which finder id ran on
which model; per-finder recall and precision are computed later.

If the user has opted into multi-agent orchestration ("use a workflow"), the fan-out and per-claim
verification below fit the Workflow tool's pipeline shape; otherwise use the Agent tool directly.

## 5. Classify (mechanical)

```bash
scripts/review/classify_claims.py --claims $WORK/claims --review-tree $WORK/tree --pristine-tree . \
  --sealed $WORK/sealed.json --out $WORK/classified.json
```

Read the summary. `inverted` or an unattributed `seed_hit` means a claim's location or the sealed
record is wrong; look before going on.

## 6. Verify (one verifier per candidate)

Export the open-issue list: `gh issue list --state open --label bug --limit 200 --json number,title,body > $WORK/open.json`.
For every `candidate` in `$WORK/classified.json`, spawn one **`verifier`** agent with: the claim's
directory, the two tree paths, its classifier record, `$WORK/open.json`, the container, and the verdict
path `$WORK/verdicts/<id>.json`. Give it nothing from the finder's transcript. Then
`jq -s 'add' $WORK/verdicts/*.json > $WORK/verdicts.json`.

## 7. Metrics and record

```bash
scripts/review/pass_metrics.py --pass N --date $(date +%F) --pinned $pinned --release <tag> \
  --sealed $WORK/sealed.json --classified $WORK/classified.json --verdicts $WORK/verdicts.json \
  --budget "<text>" --budget-units <n> --lenses "<list>" --previous-lenses "<list>" \
  --out docs/reviews/$(date +%F).md
```

**Report recall and precision before the count of findings, always.** Then the findings by tier, the
blind spots (seeds missed, by lens), and the per-finder table including the model-tier split. If any
candidate is unverified, say so and do not call it a finding.

## 8. File, fix, close

- One issue per finding or root-cause group, labelled `bug`, with the reproduction attached. Fill the
  issue numbers into the record.
- Fixes are separate work under `CLAUDE.md`'s rules (guard plus mutation per fix), one PR each, merged
  in order with a rebase and fresh CI per PR. A finding closes when its own reproduction passes on the
  fixed `main`; the verifier's `classify_claims.py --only <id>` against the new `main` is that check.
- Add each fixed defect's mutation to the catalogue if the fix PR did not, and the novel seeds from
  `$WORK/seeds/` now that the pass is over.
- Open the PR that adds `docs/reviews/<date>.md` and updates the "Pass history" table in
  `docs/adversarial-review.md`.

## Do not

- Report a finding count before recall and precision.
- Let a finder see seeds, the catalogue, the pristine tree, another finder's claims, or the open-issue
  list.
- Let a verifier see a finder's reasoning.
- Count a hypothesis, an unverified candidate, or a known-and-open re-find as a finding.
