# pg_partition_magician: project instructions

## Assertions that pass for the wrong reason

The recurring defect in this repo is not a failing test. It is a **passing** one that would
also pass against broken code. It has shipped six times. Almost every contract here is a
negative (does not block, does not scan, does not lose rows, no lock held), and every
negative is satisfied by an execution where nothing happened at all, so absence-of-defect
and absence-of-setup look identical unless you separate them deliberately.

- **Pair every negative or bounded assertion with a liveness witness.** If the claim is
  "X did not happen", also assert that the conditions for X were present. The guards in
  `bench/` do this (`the probe caught the validation scan in progress`, `the tick did the
  work that takes the lock`) and it is what caught a probe that had starved the very step
  it was measuring.
- **Prove the guard discriminates, and keep the proof.** Green on correct code is not
  evidence. Every guard in `bench/` has a mutation in `bench/mutations/` that puts its
  defect back, and `./test.sh discriminate` requires the guard to FAIL against it. Add a
  mutation with the guard, in the same commit; a guard without one is unverified.
- **Never prefix-match `pgpm.log.action`.** Non-success events are prefixed
  (`skip_drain`, `fail_retain_drop`), never suffixed, precisely so `drain%` cannot match a
  deferral. Keep it that way, and prefer exact values in assertions regardless.
- **Assert identity, not cardinality; keep fixtures asymmetric.** A row-count check is
  invariant under compensating errors: a lost INSERT and a resurrected DELETE cancelled
  and the test passed under a real data-loss bug. Say *which* rows, and build fixtures
  where the expected effects cannot cancel (2 in, 1 out, not 1 and 1).
- **A concurrency probe perturbs what it measures.** Two rules learned the hard way: give
  each observation its own transaction (locks are held to transaction end, and a `DO`
  block is one transaction, so a polling loop pins its lock and starves the code under
  test), and check your instrument's cost against the window's width before trusting it
  (~100 ms per `docker exec` sample cannot land inside a ~400 ms scan; poll server-side).
- **Counters flush at transaction end.** `pg_stat_all_tables` scan counters read 0 when
  sampled inside the transaction that produced them, so those assertions cannot live in
  pgTAP, which wraps each file in a transaction. They belong in a `bench/` shell harness.

## Lint Markdown before pushing docs

CI runs a `Markdown` job (`.github/workflows/lint.yml`,
`DavidAnson/markdownlint-cli2-action@v16`) over `**/*.md` using the rules in
`.markdownlint.json`. `main` is unprotected, so a red Markdown check does not block a
merge: it just sits there unnoticed. Lint locally before pushing any doc change and keep
the check green.

- **Match CI's linter version.** The action pins markdownlint **v0.34.0**. Run
  `markdownlint-cli2@0.13.0` locally (it bundles v0.34.0). A newer markdownlint enforces
  rules CI does not (e.g. MD060) and sends you chasing phantom errors.
- **Scope to the files CI lints.** CI checks out only committed files, so it never sees
  the gitignored `bench/results/` scratch or other untracked `.md`. Lint the tracked set
  and do NOT reformat gitignored scratch.
- **Check, then optionally fix:**

  ```bash
  npx -y markdownlint-cli2@0.13.0 "**/*.md" \
    "!postgresql_online_partition_migration_summary.md" "!bench/results/**"
  # add --fix to auto-correct the structural rules (MD022/MD032/MD012/MD004/MD009)
  ```

  (Pass globs, not bare filenames: positional filenames lint zero files. Add `!<path>`
  for any local untracked scratch present in your working tree.)
- **`-` or `+` at the start of a wrapped line** reads as a stray list item (MD004/MD032).
  Reword instead of introducing an em dash (house style: no em dashes anywhere).
