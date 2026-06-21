# pg_partition_magician: project instructions

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
