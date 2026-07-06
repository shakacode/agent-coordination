# AGENTS.md

Simulation repo for shakacode/agent-coordination batch testing. Content is
generated from `sim/template/`; do not hand-edit outside a simulation run.

## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`ci`, `validate`, `test`); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.
