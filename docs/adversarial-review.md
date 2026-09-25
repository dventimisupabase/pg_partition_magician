# pg_partition_magician: adversarial review methodology

How pgpm is subjected to a deliberate, antagonistic search for defects, and when to stop. This is the
process document for a **review pass**: a bounded, adversarial-but-friendly hunt over a pinned commit,
with an independent check on every claim, a measured sensitivity, and a written record. For the
day-to-day testing discipline see the root `CLAUDE.md`; for the guards and their mutations see `bench/`
and `bench/mutations/`.

## Contents

- [Premise](#premise)
- [Definitions](#definitions)
- [Roles and separation](#roles-and-separation)
- [A pass, step by step](#a-pass-step-by-step)
- [Seeding](#seeding)
- [Metrics](#metrics)
- [Stopping criteria](#stopping-criteria)
- [Between passes](#between-passes)
- [Lenses](#lenses)
- [Pass record](#pass-record)
- [Pass history](#pass-history)

## Premise

Three things are taken as given.

1. **The floor is not zero.** Each successful pass should lower the number and the severity of what the
   next one finds, but testing shows the presence of defects, never their absence. The goal of a pass is
   not to reach zero; it is to lower the expected cost of the defects that remain, and to know when the
   deep-hunt mode has stopped paying.
2. **A method's blind spots are stable.** A second pass with the same method finds fewer defects partly
   because the code improved and partly because the method could never see the rest. A falling yield is
   therefore only evidence about the code when the pass has also shown it could still find defects
   (see [Seeding](#seeding)). Passes rotate their [lenses](#lenses) for the same reason.
3. **A reviewer pushed to find defects will find some that are not there.** This applies to people and
   to models alike, and it gets worse as the real yield falls. The remedy is structural, not
   exhortation: a claim counts only when an executable reproduction survives an independent attempt to
   knock it down, and the reviewer's precision is measured and watched.

These are the same principles the repository already applies to its own tests. A guard must be paired
with a liveness witness that proves the conditions for the defect were present; a pass must be paired
with seeds that prove the conditions for a discovery were present. `./test.sh discriminate` proves a
guard fails against its mutation; the [verifier](#roles-and-separation) proves a finding fails against
the pinned commit and not against a fixed one.

## Definitions

- **Pinned commit.** The `main` SHA a pass reviews. Everything in the pass is stated against it.
- **Claim.** A defect as first reported by a finder. Every claim carries a one-line scenario, the file
  and line it points at, a severity tier, and a reproduction.
- **Reproduction.** An executable script (SQL file, shell script, or pgTAP file) that FAILS against the
  review tree and would PASS once the defect is fixed. A claim without one is a **hypothesis**, kept in
  the record but never counted as a finding and never filed as an issue.
- **Finding.** A claim whose reproduction the verifier has run, confirmed against the pinned commit, and
  failed to explain away. Only findings are filed and counted.
- **Seed.** A known defect the coordinator plants in the review tree before the pass, unknown to the
  finders. Seeds measure the pass's sensitivity; they are never real findings.
- **Review tree.** The pinned commit plus the seeds, delivered to finders as a single commit with no
  history, so that the seeds cannot be read off a diff.
- **Lens.** A named way of looking (concurrency, upgrade paths, time zones, ...). A pass declares its
  lenses up front; the next pass changes them.
- **Tier.** Severity, decided by a rubric before anything is counted:
  - **Tier 1**: data loss, or a silently wrong result (rows dropped, routed to the wrong partition,
    archived incompletely, reported as migrated when they were not).
  - **Tier 2**: a wedge or outage (a table that can no longer be maintained, a lock held for the length
    of a scan, a procedure that cannot make progress).
  - **Tier 3**: acts when it should refuse, or a documented contract not kept, without loss.
  - **Tier 4**: documentation that changes what an operator types, and is wrong.
  - **Tier 5**: a test or guard that passes for the wrong reason.

## Roles and separation

Four roles, and the separations between them are the substance of the method.

| role | does | may not |
|---|---|---|
| coordinator | pins the commit, picks lenses, plants seeds, sets the budget, assembles the record | review code for defects, fix anything |
| finder | reviews one slice of the review tree under the declared lenses, writes claims with reproductions, records what it probed and found sound | edit any file under review beyond adding instrumentation; read `bench/mutations/`, the upstream repository, or any diff of the review tree; see another finder's claims |
| verifier | re-runs every reproduction against the review tree AND the pristine pinned commit, classifies each claim, and tries to disprove the survivors | see the finder's reasoning, only the claim and its reproduction; fix anything |
| fixer | fixes a filed finding in its own PR with a guard and a mutation, per `CLAUDE.md` | be the finder or verifier of that finding |

A finder who needs to change pgpm to make a reproduction fail has not found a pgpm defect. A verifier
who cannot make the reproduction fail on the pristine commit has found a seed, a test artifact, or
nothing; none of the three is filed.

## A pass, step by step

1. **Pin.** Record the `main` SHA, the release it corresponds to, and the date.
2. **Set the budget.** Agent-hours or tokens per finder, number of finders, and a wall-clock limit. The
   budget is fixed before the pass so cost per finding is comparable across passes.
3. **Declare lenses.** Choose from the [catalog](#lenses), at least half of them different from the
   previous pass. The freshly merged surface since the last pass is always one lens: hand-resolved
   merge regions and interactions between recent fixes are where new defects concentrate.
4. **Seed.** Plant `K` seeds (see [Seeding](#seeding)); record which, where and their tiers in a sealed
   file the finders cannot read. Build the review tree as one history-less commit.
5. **Hunt.** Finders work their slices in parallel, in isolated worktrees on the review tree. Each
   produces a claims file and a null-results file (what was probed, how, and found sound).
6. **Verify.** For every claim the verifier runs the reproduction twice:
   - fails on the review tree, passes on the pristine commit: a **seed hit**;
   - fails on both: a **candidate**; the verifier then tries to disprove it (is the behaviour
     documented and intended, is the reproduction exercising a test artifact, does it need a state pgpm
     refuses to enter) and either confirms it as a finding or records why it fell;
   - fails on neither, or needs the finder's environment: **not reproduced**, dropped;
   - fails on both and matches an issue still open from an earlier pass: **known and open**, recorded
     against that issue and not counted as a new finding. The verifier alone holds the open-issue list
     (see [Between passes](#between-passes)).
7. **Triage.** Tier every finding by the rubric. Group findings that share a root cause and a fix.
8. **Measure.** Fill in the [metrics](#metrics). Compute precision and seed recall before anyone looks at
   the count of findings, so the count is read in light of them.
9. **File and fix.** One issue per finding or group; one PR per issue, each with a guard and a mutation,
   merged in a dependency-aware order with a rebase and a fresh CI run before each merge.
10. **Record.** Commit the [pass record](#pass-record). The raw claims and reproductions can stay in a
    local `notes/` file; the record is what the next pass reads first.

## Seeding

Seeds make a quiet pass meaningful. Without them, "found nothing" and "could not have found anything"
look the same.

- **Source.** Start from `bench/mutations/mutate.py`, which already holds one exact, reviewed defect per
  guard. Because finders may have seen that file in earlier sessions, at least a third of the seeds in
  every pass are **novel**: written for the pass, in the style of the catalogue, and added to it only
  after the pass so the next one cannot reuse them.
- **Placement.** Seeds cover the declared lenses and span tiers 1 to 3. A seed should be as quiet as the
  real defects the pass is hunting: a dropped re-check under a lock, an off-by-one at a grid boundary, a
  `%I` where a `_q` fragment is spliced. Loud seeds (a raise in a hot path) measure nothing.
- **Count.** `K` between 6 and 10 for a pass of six to eight finders. Fewer gives recall too coarse to
  read; more starts to shape what finders look at.
- **Blindness.** Finders never see the seed list, `bench/mutations/`, or any diff. The review tree has one
  commit and no remote. Novel seeds are kept in a sealed file the coordinator alone reads until the pass
  closes.
- **After the pass.** Every seed that no finder reported is a blind spot. Record it against the lens
  that should have caught it, and carry that lens into the next pass.

## Metrics

Recorded per pass, in this order, so the count of findings is never read alone.

| metric | definition |
|---|---|
| budget | finders, agent-hours or tokens per finder, wall-clock |
| seeds `K`, recall | seeds planted; fraction reported by at least one finder |
| claims | total claims across finders |
| findings | claims that survived verification |
| per finder | claims and precision for each finder, with the model it ran on when the pass split model tiers |
| precision | (findings + seed hits) / claims that had a reproduction; a correctly reported seed is a true report, and a hypothesis is not a claim |
| findings by tier | Tier 1 through Tier 5 |
| root causes | distinct root causes behind the findings, and how many the fix phase closed as a class rather than an instance |
| known and open | re-found findings from earlier passes still unfixed |
| cost per finding | budget / findings, and budget / Tier 1 findings |
| null results | slices probed and found sound, by lens |
| capture-recapture estimate | when two independent hunts run on the same commit: `n1 * n2 / overlap` for Tier 1, minus what was found |
| blind spots | seeds missed, by lens |

The curve the metrics are meant to draw across passes: findings and Tier 1 findings falling, cost per
finding rising, recall staying high, precision staying high. Precision falling while yield falls is the
signature of a reviewer reaching; it means change the method, not push harder.

## Stopping criteria

The deep-hunt mode ends when ALL of the following hold, judged on the two most recent passes:

1. **Zero Tier 1 findings** in each of two consecutive passes, and
2. **seed recall of at least 0.8** in each of those passes (so the zero was earned), and
3. **precision of at least 0.7** in each (so the passes were not reaching), and
4. **the capture-recapture estimate for Tier 1 rounds to zero**, when two independent hunts were run, or
   the estimate was not attempted and criteria 1 to 3 hold for three passes instead of two.

Stopping does not mean no scrutiny. It means the standing mode changes to:

- **per-PR adversarial verification**: every PR touching `pgpm_core/install.sql` or `pgpm_archive/`
  gets a verifier pass on its claims (the CHANGELOG bullet, the guard, the mutation) with the same
  fail-then-pass rule;
- **a full pass after any release, and after any merge batch of more than five PRs**, since a batch of
  fixes is new surface with new interactions.

A pass is also **abandoned early**, and the method revised, if precision drops below 0.5 mid-pass.

## Between passes

A pass has a counterpart, the fix phase, and the next pass stands on it. A pass whose findings were
not fixed re-finds them, its yield does not fall because nothing changed, and the curve the metrics are
meant to draw says nothing. The rules that keep the loop honest:

- **Pin on the fixes.** Pass N+1 pins a commit that contains the fixes for every Tier 1 and Tier 2
  finding of pass N. Lower tiers may be deferred, but each deferred finding stays open as an issue.
- **Known and open is a class, not a finding.** The verifier, and only the verifier, holds the list of
  issues still open from earlier passes. A re-found one is classified **known and open** and recorded
  against its issue. Finders never see the list, so it cannot steer what they look at.
- **A fix is a guard and a mutation, or it is a patch.** Per `CLAUDE.md`, every fix PR carries a guard
  that would fail with the defect present and a mutation in `bench/mutations/` that puts the defect
  back, proven by `./test.sh discriminate`. The guard keeps the fix honest now; the mutation keeps a
  later refactor from quietly undoing it. Without both, the floor can sink back and the next pass
  cannot tell a new defect from a resurrected one.
- **The reproduction is the acceptance test.** A finding is closed when its original reproduction
  passes against the fixed `main`. That is the verifier's last act for each finding, and it makes the
  reproduction a regression test rather than a one-off.
- **Fixed defects become seeds.** Every real defect this codebase produced is the best possible seed
  for a later pass, because it is quiet in exactly the way its siblings are. After the fix phase, add
  each fixed defect's mutation to the catalogue if the fix PR did not already.
- **Judge the fix phase on classes.** Pass 1's 25 issues came from about seven root causes. A fix that
  removes the cause removes a class; one that patches the symptom leaves siblings for the next pass to
  find. Record root causes closed alongside findings fixed.
- **Fixes are new surface.** A batch of fix PRs, and the hand-resolved merge regions between them, is
  where the next pass's defects concentrate. The floor rises as a ratchet with a small backlash, not
  monotonically, which is why the fresh-surface lens is mandatory and why a full pass follows any large
  merge batch. Finding a defect that a fix introduced is the process working.

The loop, in full: pin, hunt, verify, file, fix with guard and mutation, close each finding by its own
reproduction, merge the batch with a rebase and a fresh CI run per PR, pin again.

## Lenses

The catalogue to rotate through. Each pass names the ones it uses and states, in the record, which were
used last time.

- **Fresh surface** (always): regions merged since the last pass, hand-resolved conflict hunks first,
  then interactions between the recent fixes.
- **Concurrency and locks**: check-then-act across a lock, what a second session sees between commits,
  triggers under `session_replication_role`, advisory-lock reaping.
- **Time and zones**: session `TimeZone`, DST, `now()` versus data frontier, naive versus aware types,
  clock skew.
- **Boundary arithmetic and types**: grid floors and steps at partition edges, integer versus numeric
  division, `name` truncation, text collation versus bytewise order, `uuid` and `text_time` encodings.
- **Upgrade and install paths**: every released version to `main`, stale overloads, backfilled columns,
  `uninstall.sql` residue, bundles versus `install.sql`.
- **Identity and names**: `search_path`, same-named relations, oid anchors versus rendered names.
- **Operator error**: negative or zero knobs, wrong-type arguments, re-running a step, hand edits to
  `pgpm.config`.
- **Failure injection**: a crash or cancel between a procedure's commits, a failed archive upload, an
  archive_fn that lies about `covered_hi`.
- **Contracts versus documentation**: what the reference promises against what the code does, and what
  the runbook tells an operator to type.
- **Tests that pass for the wrong reason**: `count = count` assertions, `throws_ok(NULL)`, probes that
  starve what they measure, guards without a discriminating mutation.
- **Resource cliffs**: memory in the encoders, unbounded loops, statement timeouts that accumulate
  across internal commits.

## Pass record

One file per pass, committed under `docs/reviews/` as `YYYY-MM-DD.md`, in this shape:

```markdown
# Review pass N: YYYY-MM-DD

pinned: <sha> (<release>) | budget: <finders> x <hours or tokens>, <wall-clock>
lenses: <list> | previous pass lenses: <list>
seeds K=<n>, recall <r>; claims <c>; findings <f>; precision <p>
findings by tier: T1 <n> T2 <n> T3 <n> T4 <n> T5 <n>
cost per finding: <x>; per Tier 1 finding: <y>
root causes: <n> behind the findings, <m> closed as a class by the fix phase
known and open (re-found, unfixed from earlier passes): <n>
capture-recapture (T1): <estimate or "not attempted">
blind spots (seeds missed, by lens): <list>

## Findings
| tier | finding | issue | fix PR |

## Null results (by lens)

## Hypotheses (not counted)

## Stopping criteria status
```

## Pass history

| pass | date | pinned | findings (T1) | claims | precision | seeds / recall | notes |
|---|---|---|---|---|---|---|---|
| 1 | 2026-09-24 | `a72c5bf` (0.6.0) | 76 (25 filed as T1: #441 to #465) | ~106 | not measured | none | eight finders plus a coordinator; no independent verifier; the 76 each had a reproduction but at least one premise (#441's version range) was later corrected, so precision is unknown. Fixed by #466 to #490, merged 2026-09-25. Baseline only. |

Pass 1 predates this document and is recorded as the baseline it is: a high yield with no measured
sensitivity or precision. Pass 2 is the first to run under the method above.
