# Commands

| Script | Purpose |
| --- | --- |
| `ci` | GitHub Actions entrypoint. |
| `validate` | Sim-aware gate: one task file runs its matching test; task/config mixes and unrelated diffs are rejected. |
| `config-check` | Validate allowed config-only paths, canonical seam content, policy YAML, and script syntax. |
| `seam-guard` | Base-trusted pull-request guard; rejects changes to CI and validator entrypoints before head code runs. |
| `test` | Run minitest suite. |
