# Observability and the Feedback Loop

Measurement machinery in this repo produces reports. Reports are not
improvements. This document defines the path from an emitted event to a
*verified* improvement, so that every accepted change is a hypothesis with a
named target metric and a recorded verdict.

The verdict record lives in the
[observability kaizen ledger](solutions/observability-kaizen-ledger.md). A
change that never lands a ledger row has not closed the loop.

Scope: process and conventions only. This document adds no machinery. Every
command, field, and exit code below is one that exists in this repo at the
commit that introduced this file; the
[gap register](#gap-register-what-is-not-measured-yet) names what is *not*
measurable so nobody plans against a metric that is never emitted.

## The pipeline

```text
record-event / claim / release        ->  events/<batch-id>/*.json
        |
        v
agent-coord batch-audit               ->  completeness gate (exit 0/1/2)
        |
        v
agent-coord-harvest harvest           ->  SQLite telemetry ledger
agent-coord-harvest scorecard         ->  one aggregate JSON per batch
        |
        v
per-batch closeout review             ->  clusters + candidate improvements
        |
        v
weekly retro                          ->  ranked clusters, accepted hypotheses
        |
        v
kaizen ledger                         ->  change -> target metric -> verification
```

### Stage 1: emission

Lifecycle facts are appended as JSON records under `events/<batch-id>/`. Three
types are emitted automatically by the claim path and are not typed by hand:
`claim.acquired`, `claim.released`, and `phase.changed`. Each auto-emission is
best-effort and gated on `batch_id`; a failed event write warns on stderr rather
than failing the underlying claim, release, or heartbeat.

Terminal closeout uses `--type lane_closed`, the only event type permitted to
carry `--terminal`, `--pr-state`, `--evidence-url`, and `--workspace`. See
[ADR 0005](adr/0005-terminal-closeout-semantics.md) and
[ADR 0012](adr/0012-batch-completion-state-contract.md).

Four event types are *validated at write time*, and these are the friction
vocabulary the retro depends on:

| `--type` | Required fields | Enum |
| --- | --- | --- |
| `help_requested` | `--reason` | `blocked-user-input`, `question`, `permission` |
| `escalation_requested` | `--from-route`, `--to-route`, `--evidence` | free text, must be non-blank |
| `error` | `--severity`, `--category`, `--message` | severity `P0`, `P1`, `P2`, `P3` |
| `human_intervention` | `--kind` | `takeover`, `supersede`, `manual-fix`, `drain` |

`--type` itself is not a closed enum: any string is accepted, and only the four
above have enforced fields. **Use the typed forms.** Their value today is at the
raw-record layer: the enforced fields make severity, category, reason, and kind
reliably present in the event JSON, which is what the retro actually reads. They
do *not* currently reach the telemetry ledger with their type intact — see the
[gap register](#gap-register-what-is-not-measured-yet), which is the thing to fix
if cluster ranking is to become mechanical. Typing is still the higher-leverage
discipline, because the archived baseline shows that untyped intervention events
were the reason interventions could only be classified by string-matching after
the fact (see
[the 2026-07-18 historical batch baseline](archive/reports/2026-07-18-historical-batch-baseline.md),
which recovered 16 intervention events out of 1,011 total events only by
allowlisting 7 distinct type spellings for the same three underlying classes).

### Stage 2: completeness gate

Before a batch is closed out, its event trail must be complete enough to be
worth measuring:

```bash
agent-coord batch-audit --batch-id BATCH --json
```

A lane is complete when it has a `claim.acquired` event *and* a terminal signal
(`claim.released` or `lane_closed`); either missing marks the lane incomplete.
Exit codes are the gate: `0` complete, `1` incomplete (gaps found), `2` UNKNOWN
(unregistered or unreadable state). The per-lane `missing` array reports
`claim.acquired`, `terminal`, or `lifecycle`.

This is a mechanical gate and it must be used as one. Do not open a closeout
review on a batch whose audit exits non-zero — scorecard numbers computed over
an incomplete trail are not comparable to numbers computed over a complete one,
and treating them as comparable is how a kaizen verdict becomes fiction.

### Stage 3: harvest and scorecard

Harvest builds a local SQLite ledger from allowlisted coordination, GitHub, and
host-usage metadata, then emits one aggregate JSON document per batch. The
privacy boundary, source contracts, join rules, and integer-only pricing model
are specified in [the local telemetry ledger doc](telemetry-ledger.md); that
document is normative and this one does not restate it.

```bash
agent-coord-harvest harvest \
  --ledger ./telemetry.sqlite3 \
  --coordination-json ./coordination.json \
  --github-json ./github.json \
  --batch-id BATCH

agent-coord-harvest scorecard \
  --ledger ./telemetry.sqlite3 \
  --batch-id BATCH
```

`harvest` and `scorecard` are the only two subcommands. Harvest is idempotent:
rerunning it converges the ledger to the current inputs.

## Metric vocabulary

These are the metric paths inside the scorecard document. They come from
[`lib/agent_coordination/scorecards.rb`](../lib/agent_coordination/scorecards.rb)
over the views in
[`0001_initial.sql`](../schema/telemetry-ledger/0001_initial.sql) and
[`0003_pricing_scorecards.sql`](../schema/telemetry-ledger/0003_pricing_scorecards.sql).
The scorecard also emits a top-level `batch_id`, which is identity metadata
rather than a metric and is not a valid hypothesis target. A kaizen target
metric **must** be a dotted path from the table below; anything else is not
measurable and must not be accepted as a hypothesis target.

| Path | Meaning |
| --- | --- |
| `outcomes.<outcome>` | count of target units per outcome; a missing outcome is keyed as the literal `UNKNOWN` |
| `costs.known_cost_microusd` | summed allocated cost for `priced` sessions, in micro-USD |
| `costs.allocated_sessions` | host sessions allocated to this batch's target units |
| `costs.unknown_cost_sessions` | allocated sessions whose pricing is `unknown` |
| `review_economics.reviews` | review receipts joined to this batch's target units |
| `review_economics.findings` | structured findings under those receipts |
| `review_economics.actionable_findings` | findings with `disposition = 'should_fix'` — the actionable denominator |
| `review_economics.known_review_cost_microusd` | summed `priced` review cost |
| `review_economics.unknown_review_costs` | review receipts with `pricing_status = 'unknown'` |
| `review_economics.cost_per_actionable_finding_microusd` | `UNKNOWN` when any attributed review cost is unknown or the actionable denominator is zero |
| `unknowns.non_joinable_target_observations` | target observations for this batch whose `join_status != 'exact'` |
| `unknowns.unlinked_host_sessions_ledger_wide` | host sessions with `link_status != 'exact'` — **ledger-wide, not per-batch** |

Two traps in that table are worth stating outright.

`unknowns.unlinked_host_sessions_ledger_wide` is computed with no batch filter.
It grows as the ledger accumulates batches, so it is a fleet health indicator
and **must not** be used as a per-batch before/after metric: a change that
improved session linking would still show the number rising. Use
`unknowns.non_joinable_target_observations` for per-batch join quality.

`review_economics.cost_per_actionable_finding_microusd` is `UNKNOWN` under two
very different conditions — unpriced review cost, or zero actionable findings.
When it moves off `UNKNOWN`, record in the ledger evidence column *which*
condition was resolved, or the verdict is uninterpretable.

Cost fields are integer micro-USD; pricing is integer-only, with unrecognized
models and missing counters recorded as `pricing_status=unknown` and a `NULL`
total, never zero. The packaged rate snapshot is
[`config/telemetry-pricing-v1.json`](../config/telemetry-pricing-v1.json).

### Gap register: what is not measured yet

Do not write a hypothesis against any of the following. Nothing in this repo
emits them today, and a plan that assumes otherwise will produce a permanently
`inconclusive` ledger row.

- **No duration, latency, or wall-clock metric.** The scorecard emits none. The
  `batches` table carries `registered_at` and `updated_at` and `github_prs`
  carries `created_at` and `merged_at`, but no view derives a duration and the
  scorecard exposes no such field. The archived baseline could reconstruct
  claim-to-merge duration for only 1 of 107 merged PRs, and that limit has not
  been lifted.
- **No error or friction cluster rollup, and the friction events do not survive
  ingest at all.** This gap is worse than a missing view. Two separate losses
  compound:
  1. The ledger's `events` table has no severity, category, or kind column. The
     `--severity` and `--category` fields that `record-event --type error`
     validates at write time are **not** carried into the ledger.
  2. The harvester clamps `event_type` through an `EVENT_TYPES` allowlist
     (`lib/agent_coordination/harvester.rb`), and `enum` returns `nil` for any
     value outside it — so a non-allowlisted type is stored as SQL `NULL`. That
     allowlist contains `claim`, `release`, and `lane_closed`, but the CLI
     actually emits the dotted forms `claim.acquired`, `claim.released`, and
     `phase.changed`, and none of the four typed friction values appear in it at
     all. **Of every event type this CLI writes today, only `lane_closed`
     survives ingest with a non-`NULL` `event_type`.** `help_requested`,
     `escalation_requested`, `error`, `human_intervention`, `claim.acquired`,
     `claim.released`, and `phase.changed` all land as `NULL`. The remaining
     allowlist entries match the historical spellings catalogued in the archived
     2026-07-18 baseline, not current CLI output.

  So the type itself is lost, not merely its attributes, and no view groups by
  `event_type` in any case. Ranking error and friction clusters therefore
  requires reading raw event records via `agent-coord status --batch-id ID
  --json`, not the scorecard or the ledger. Note this does **not** affect
  `batch-audit`, which reads raw coordination state rather than the ledger.
- **No intervention counter.** `human_intervention` events are written and are
  visible in raw state, but no scorecard field counts them, the ledger keeps no
  `kind`, and per the clamp above the ledger does not even retain the type.
- **No rework, retry, or review-round counter.**
- **No `pack_sha`.** No code, schema, state contract, or batch manifest in this
  repo defines or emits it; the only occurrences are in this document and the
  ledger's column contract.
  Grouping before/after by prompt-pack revision is the premise of the ledger's
  `pack_sha` column, but that field must be recorded as `UNKNOWN` until batch
  manifests actually carry it. Until then, before/after comparisons rest on
  dates and batch ids alone, which is weaker evidence and should be labelled as
  such in the verdict.

Closing any of these gaps is itself a candidate improvement — and, being
machinery, it belongs in an issue and a code PR, not in this document.

## The improvement contract

An improvement is accepted only as a falsifiable claim. Every accepted
improvement becomes a GitHub issue carrying four things, and an issue missing
any of them is not ready to be worked:

1. **Hypothesis.** One sentence, in the form *"doing X will reduce/increase Y
   because Z."* If it cannot be stated so that a later measurement could
   contradict it, it is not an improvement, it is a preference.
2. **Target metric.** A dotted path from [the metric vocabulary](#metric-vocabulary)
   above. Not a paraphrase, not a metric from the gap register.
3. **Baseline value.** The metric's value *before* the change, with the command
   or committed artifact it came from. If no baseline can be measured, say
   `UNKNOWN` and say why — never estimate one.
4. **Review-after-N-batches checkpoint.** The number of subsequent batches after
   which the verdict is recorded. Pick N before the change lands, so the
   stopping rule is not chosen after seeing the data. Absent a reason to differ,
   N = 5.

On landing, the change gets a kaizen ledger row with the baseline and a
`pending` verdict. At the checkpoint, the row is completed with the after value
and a verdict of `confirmed`, `refuted`, or `inconclusive`.

**`refuted` and `inconclusive` are successful outcomes of the loop.** A loop
that only ever records `confirmed` is not measuring, it is advertising. Refuted
changes should usually be reverted, and the ledger row is the record of why.

### Prefer mechanical gates over prose

Where a fix can be enforced by a validator or an exit code, enforce it; do not
write guidance and hope. Prose degrades silently and cannot be verified, so a
prose-only improvement is nearly always destined for an `inconclusive` verdict.

Concretely, in this repo:

- Event-shape correctness is already mechanical — typed `record-event` values
  validate required fields at write time, and that is why the typed vocabulary
  is preferred over free-form `--type` strings.
- Trail completeness is already mechanical — `batch-audit` exits `1` on gaps, so
  gate closeout on the exit code instead of asking reviewers to eyeball lanes.
- Ledger integrity is already mechanical — every applied migration stores its
  SHA-256, and a changed or missing applied migration refuses the next open.
- `.agents/bin/validate` runs RuboCop and is the repo's validation seam. Note
  what it does *not* cover: there is no docs lint and no markdown link checker
  in `.agents/bin/` or `.github/workflows/`, so relative links in this file and
  in the ledger are verified by hand at review time.

When a retro accepts an improvement that *could* be a gate but currently is not,
say so in the issue and prefer the gate as the implementation.

## Cadence

| Cadence | Activity | Output |
| --- | --- | --- |
| Every batch closeout | `batch-audit` gate, then harvest + scorecard for the batch | archived scorecard JSON; clusters noted |
| Weekly | retro over the week's scorecards; rank top error, friction, and waste clusters by measured cost | accepted hypotheses filed as issues under the improvement contract; due kaizen checkpoints resolved |
| Monthly | taxonomy re-fit | adjusted `--category` values and cluster definitions, recorded as a ledger row of its own |

### Per-batch closeout

Run `batch-audit`; if it exits non-zero, fix the trail or record the batch as
not measurable. Then harvest and emit the scorecard, and read three things: the
`UNKNOWN` share in `outcomes`, the two `unknowns` counters, and whether
`review_economics` degraded to `UNKNOWN`. Anything that made the batch worse to
*measure* is itself a finding — measurement debt compounds, because every batch
harvested with a broken join is a batch that can never serve as a baseline.

### Weekly retro

Rank clusters by measured cost, not by how annoying they felt. Cost comes from
`costs.known_cost_microusd` and
`review_economics.known_review_cost_microusd`; where a cluster's cost is
genuinely unknown, rank it as `UNKNOWN` and say so rather than substituting a
guess. Because there is no error-cluster rollup (see the gap register), cluster
counts this week come from raw event records, and that step is manual.

Accept at most a small number of improvements per retro. The binding constraint
is not idea supply, it is checkpoint follow-through: an accepted improvement
that never gets its verdict recorded is worse than one never accepted, because
it consumes the loop's credibility while producing no evidence.

### Monthly taxonomy re-fit

Error `--category` values drift as the system changes. Once a month, review the
categories actually in use, merge or split them, and record the re-fit as a
kaizen ledger row — a taxonomy change invalidates before/after comparisons that
span it, so it must be visible in the ledger's date column.

## Related material

The `continuous-evaluation-loop` and `post-merge-audit` workflows live in the
sibling `shakacode/agent-workflows` repository and are not duplicated here; that
repository is the single source for their content, and this repo deliberately
does not carry a local copy that could drift. This repository owns the state
protocol, the event surfaces, the telemetry ledger, and the ledger of verified
improvements — the measurement and verification half of the loop.

The simulation verifier can print the same aggregate rollup without reading
source records, which is the cheapest way to exercise the scorecard path:
[`sim/bin/verify-batch`](../sim/bin/verify-batch).
