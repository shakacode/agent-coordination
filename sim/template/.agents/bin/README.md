# Commands

| Script | Purpose |
| --- | --- |
| `ci` | GitHub Actions entrypoint. |
| `validate` | Sim-aware gate: one task file runs its matching test; task/config mixes and unrelated diffs are rejected. |
| `config-check` | Validate allowed config-only paths, canonical seam content, policy YAML, and script syntax. |
| `seam-guard` | Base-trusted pull-request guard; rejects changes to CI and validator entrypoints before head code runs. |
| `test` | Run minitest suite. |

`seam-guard` intentionally rejects changes to itself, CI workflows, and
validator entrypoints. A legitimate update to those protected files requires an
explicit bootstrap PR: review and validate the exact revision independently,
merge it with maintainer bootstrap authority, then confirm the new base-trusted
guard runs before accepting ordinary task or config PRs again. Hash pins in
`ci` and `config-check` are local drift diagnostics, not the root of trust.
