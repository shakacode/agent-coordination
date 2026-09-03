# Observability and the Feedback Loop

Measurement machinery in this repo produces reports. Reports are not
improvements. This document defines the path from an emitted event to a
*verified* improvement, so that every accepted change is a hypothesis with a
named target metric and a recorded verdict.

The verdict record lives in the
[observability kaizen ledger](solutions/observability-kaizen-ledger.md). A
change that never lands a ledger row has not closed the loop.

For an operator investigating one issue or pull request, the immediate read
path is `agent-coord log OWNER/REPO#TARGET`. It combines live and archived
coordination events into a custody trail; run `agent-coord log --sync` before
`agent-coord gc --execute` to preserve that trail in the local mirror. See
[Reading the trail](../README.md#reading-the-trail-where-is-the-work-on-an-issue-or-pr)
for filters, output formats, completeness warnings, and retention details. The
telemetry pipeline below serves cross-batch measurement rather than this
per-work-item operational lookup.

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

`--type` itself is not a closed enum: any string is accepted, with no allowlist
and no length bound, and only the four above have enforced fields. **Use the
typed forms.** The enforced fields make severity, category, reason, and kind
reliably present in the event JSON, and since issue #112 those four fields and
the event type itself are retained in the telemetry ledger. The scorecard now
counts interventions, help requests, and escalations; error-category and
measured-cost clustering remain open — see the
[gap register](#gap-register-what-is-not-measured-yet). Typing is still the higher-leverage
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
[`0003_pricing_scorecards.sql`](../schema/telemetry-ledger/0003_pricing_scorecards.sql),
plus the operational views in
[`0005_operational_scorecards.sql`](../schema/telemetry-ledger/0005_operational_scorecards.sql).
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
| `operational_load.merged_prs` | exact, same-repository merged PR denominator used for normalized operational load |
| `operational_load.human_interventions.count` | `human_intervention` event count |
| `operational_load.human_interventions.per_10_merged_prs` | intervention count per 10 merged PRs; `UNKNOWN` when the denominator is zero |
| `operational_load.human_interventions.by_kind.<kind>` | intervention count for `takeover`, `supersede`, `manual-fix`, or `drain` |
| `operational_load.human_interventions.by_kind_per_10_merged_prs.<kind>` | per-kind intervention count per 10 merged PRs; `UNKNOWN` when the denominator is zero |
| `operational_load.help_requests.count` | `help_requested` event count |
| `operational_load.help_requests.per_10_merged_prs` | help-request count per 10 merged PRs; `UNKNOWN` when the denominator is zero |
| `operational_load.help_requests.by_reason.<reason>` | help-request count for `blocked-user-input`, `question`, or `permission` |
| `operational_load.help_requests.by_reason_per_10_merged_prs.<reason>` | per-reason help-request count per 10 merged PRs; `UNKNOWN` when the denominator is zero |
| `operational_load.escalations.count` | `escalation_requested` event count |
| `operational_load.escalations.per_10_merged_prs` | escalation count per 10 merged PRs; `UNKNOWN` when the denominator is zero |
| `operational_load.lane_durations.lanes` | lanes registered in the batch |
| `operational_load.lane_durations.computable_lanes` | lanes with an exact, unambiguous claim-to-terminal duration |
| `operational_load.lane_durations.telemetry_gap_lanes` | lanes whose duration is `UNKNOWN` because membership, endpoints, or timestamps are incomplete |
| `operational_load.lane_durations.by_lane_seconds.<lane_id>` | seconds from first exact `claim.acquired` to first later `claim.released` or `lane_closed` with terminal value `done`, `abandoned`, or `superseded`; otherwise `UNKNOWN` |
| `operational_load.lane_durations.seconds.<summary>` | minimum, median, or maximum of computable lane durations; `UNKNOWN` when none are computable |
| `operational_load.custody_rework.reclaims` | acquisitions immediately following a release or takeover for the same target within the batch |
| `operational_load.custody_rework.per_10_merged_prs` | custody reclaims per 10 merged PRs; `UNKNOWN` when the denominator is zero |
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

Do not write a hypothesis against any of the following. No scorecard field
measures them today, and a plan that assumes otherwise will produce a
permanently `inconclusive` ledger row. Where an entry records that part of a
gap has since been closed, that part is settled — do not re-report it, and read
the remaining scope as the live gap.

- **No error-category or measured-cost friction cluster rollup.** The underlying
  events now survive ingest — issue #112 fixed that — and issue #143 added
  scorecard counts for interventions, help requests, and escalations. Nothing
  yet groups `error` events by category or ranks the operational signals by
  measured cost. Scope the
  remaining gap precisely before writing a hypothesis against it:
  - *Fixed, do not re-report.* The `EVENT_TYPES` allowlist in
    `lib/agent_coordination/harvester.rb` had been fitted to the historical
    spellings catalogued in the archived 2026-07-18 baseline rather than to
    current CLI output, so it intersected what the CLI emits at exactly
    `lane_closed` and the other seven types were stored as SQL `NULL`. The
    allowlist now covers every type the CLI emits — the three auto-emitted
    lifecycle types, `lane_closed`, and the four typed operational signals —
    and a test derives that set from `bin/agent-coord` itself, both from its
    constants and by scanning its literal `type:` emission sites, so a newly
    emitted type fails the suite rather than silently disappearing. Migration
    `0004_event_type_retention.sql` added `severity`, `category`, `kind`, and
    `reason` to `events`, so the fields `record-event` validates at write time
    are now retained at ingest. A type outside the allowlist is no longer an
    invisible `NULL`: the raw string is kept in `event_type_raw` and the
    `event_type_drift` view counts it. That column is sanitized but never
    rejected -- it is `NULL` only when the source event carried no usable type,
    meaning absent or whitespace-only -- so an oversized, control-bearing, or
    literally `UNKNOWN` type stays countable rather than falling back out of
    sight. `category` is sanitized the same way, so an oversized `error`
    category is bounded rather than discarded.
  - *Fixed, do not re-report.* The operational scorecard counts
    `human_intervention` by `kind`, `help_requested` by `reason`, and
    `escalation_requested`, with totals and rates per 10 merged PRs.
  - *Still open.* No view or scorecard field groups `error` by `category`, and
    ranking error or operational-friction clusters by measured cost is still
    not a one-query answer from the scorecard.
  - Note none of this ever affected `batch-audit`, which reads raw coordination
    state rather than the ledger.
- **No retry or review-round counter.** Custody rework is now measurable as a
  reclaim immediately after release or takeover, but no scorecard field counts
  command retries or review rounds.
- **No `pack_sha`.** No code, schema, state contract, or batch manifest in this
  repo defines or emits it; the only occurrences are in this document and the
  kaizen ledger.
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
- `.agents/bin/validate` runs RuboCop and then `.agents/bin/docs`, which checks
  changed Markdown for unlabelled fences and broken tracked-file links and anchors
  when a base is available, or all tracked Markdown otherwise.
  Commonmarker parses rendered links and images; reference errors point to their
  use sites. Unused definitions do not fail validation, and undefined references
  are literal text rather than rendered links.

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
