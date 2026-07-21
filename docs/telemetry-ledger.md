# Local Telemetry Ledger

`agent-coord-harvest` builds a local SQLite ledger from allowlisted coordination,
GitHub, and host-usage metadata. It is intended for outcome, cost, and review-
economics analysis. The ledger is not a transcript archive and must not collect
prompts, responses, source patches, comment bodies, review bodies, credentials,
or customer data.

## Harvest a batch

Select exactly one named batch:

```bash
agent-coord-harvest harvest \
  --ledger ./telemetry.sqlite3 \
  --coordination-json ./coordination.json \
  --github-json ./github.json \
  --codex-root ./codex-fixture \
  --claude-root ./claude-fixture \
  --batch-id batch-example
```

Or select an inclusive UTC registration-date range:

```bash
agent-coord-harvest harvest \
  --ledger ./telemetry.sqlite3 \
  --coordination-json ./coordination.json \
  --from 2026-07-18 \
  --to 2026-07-18
```

`--github-json`, `--codex-root`, and `--claude-root` are optional. The packaged
`config/telemetry-pricing-v1.json` is used unless `--pricing` names another
versioned `telemetry-pricing-v1` snapshot.

Rerunning the same harvest is idempotent. Selected batches, GitHub rows, host
sessions, usage calls, exact links, and derived scorecards converge to the
current inputs; rows removed from a supplied source are removed from the active
ledger projection. Every applied SQL migration stores its SHA-256 hash. A
changed or missing applied migration stops the next open.

## Source contracts and privacy

Only bounded metadata is retained:

- Coordination: batch identity/status/time, normalized lane membership,
  repo/target join components, structured claim/event classifications, opaque
  owner/session references, and recognized PR URLs.
- GitHub: repository, PR number/state/timestamps, review provenance counters,
  and finding severity/disposition/verification status. Bodies, titles,
  comments, inline text, and recommendations are ignored.
- Codex: `session_meta`, `turn_context`, and `event_msg` token-count records.
  Each token-count record uses only `last_token_usage`; cumulative
  `total_token_usage` is never aggregated.
- Claude: only top-level `type=assistant` records and `message.usage` counters.
  User, tool, and progress records are ignored.

Host file paths are never stored. `source_artifacts.source_ref` is an opaque,
bounded identifier; sessions retain only a worktree basename and a SHA-256 of
the original `cwd`. Malformed JSONL records store source-artifact identity,
one-based ordinal, and a closed reason code—never the line or an excerpt. CLI
output is aggregate-only.

Native counters stay separate: input, cache read, cache write, output,
reasoning output, and host-reported total. An absent or literal `UNKNOWN`
counter becomes SQL `NULL`; the harvester never recomputes a missing host total.

## Joins and outcomes

`target_units` exists only for a complete `batch_id + repo + target` key.
Incomplete observations remain in `target_observations` with an explicit
`join_status`; `UNKNOWN` is not inserted into a primary key or numeric column.
Lane membership is normalized in `lane_memberships`.

Host sessions allocate cost only when their opaque session reference maps to
one exact lane membership. Unmatched or ambiguous sessions remain queryable but
are excluded from `allocated_costs`. Same-repository GitHub PR evidence may
classify an outcome; cross-repository evidence is retained as `repo_mismatch`
and cannot override coordination state. Conflicting exact PR states or
incompatible structured statuses produce `conflicting-observations`. Missing
outcomes stay SQL `NULL` and render as literal `UNKNOWN` in scorecard output.

## Costs and scorecards

Pricing is integer-only: rates are micro-USD per one million tokens, component
costs use rational multipliers and round half up, and stored currency is `USD`.
The packaged snapshot includes explicit standard profiles for the listed
OpenAI and Anthropic models. OpenAI requests above 272,000 input-side tokens use
the snapshot's long-context input/output multipliers. Unrecognized models,
`fast` or data-residency profiles, and missing required counters are
`pricing_status=unknown` with a `NULL` total—not zero. Anthropic cache-write
pricing in the standard profile is the five-minute write rate; another TTL
requires a separately versioned explicit profile.

SQLite exposes `outcome_scorecard`, `cost_scorecard`, and
`review_economics_scorecard`. Emit one aggregate JSON document with:

```bash
agent-coord-harvest scorecard \
  --ledger ./telemetry.sqlite3 \
  --batch-id batch-example
```

Review economics counts only structured finding metadata. `should_fix` is the
actionable denominator. If any attributed review cost is unknown, or the
actionable denominator is zero, cost per actionable finding renders as
`UNKNOWN`.

The simulation verifier can print the same aggregate rollup without reading
source records:

```bash
sim/bin/verify-batch \
  --repo-slug sim/example \
  --telemetry-ledger ./telemetry.sqlite3 \
  --batch-id batch-example
```
