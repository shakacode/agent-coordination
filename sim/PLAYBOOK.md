# Simulation Playbook

Prereqs: HTTP backend env set (`AGENT_COORD_API_URL` plus
`AGENT_COORD_API_TOKEN`), `gh` authed, `codex` and/or `claude` CLIs installed,
sim repos seeded (`sim/bin/seed <repo> --reset`).

## Scenario A -- split batch, one host per repo

1. `sim/bin/seed shakacode/agent-coord-sim-alpha --reset`
2. For each seeded issue N in alpha: `sim/bin/llm-worker codex shakacode/agent-coord-sim-alpha N sim-$(date +%s)`
3. Same on beta with `claude`.
4. Score: `sim/bin/verify-batch --repo-slug shakacode/agent-coord-sim-alpha --live` (and beta).
   Expect `SCORE 3/3` on both.

## Scenario B -- contention: both hosts, same issue

1. Reseed alpha.
2. In two terminals, launch simultaneously:
   `sim/bin/llm-worker codex  shakacode/agent-coord-sim-alpha 1 race-test`
   `sim/bin/llm-worker claude shakacode/agent-coord-sim-alpha 1 race-test`
3. Expect exactly one PR; the loser's transcript reports CLAIM_REFUSED with
   the holder. If both produced PRs, the claim gate failed -- file it.

## Scenario C -- lost session recovery

1. Launch a worker on issue 2; kill the process after the `implementing`
   heartbeat (watch `agent-coord status --json`).
2. Wait for heartbeat death (4 x TTL), then relaunch with the other host.
3. Expect takeover, one final PR, and `verify-batch --live` passing for that
   issue. This is the "work can get lost" use case exercised end to end.

Teardown: `sim/bin/seed <repo> --reset` after every scenario; sim repos never
hold real work.
