# Observability Kaizen Ledger

The committed record of accepted improvements and whether they actually worked.
One row per change, appended in date order. A row is amended only to advance it
through its own lifecycle: `date` when the change lands, and `pack_sha`,
`after`, and `verdict` when its checkpoint is reached. `evidence` is written at
landing — it must already name the checkpoint, per the `pending` verdict rule
below — and is appended to at the checkpoint to record how `after` was obtained.
Rewriting a row for any other reason — restating a `before` value, softening a
`refuted` verdict, reordering history — is prohibited.

This is the verification half of the loop described in
[Observability and the Feedback Loop](../observability-and-feedback-loop.md).
That document defines the improvement contract and the metric vocabulary; this
file records outcomes. A change with no row here has not closed the loop,
regardless of how good the reasoning was.

## Column contract

Every row carries all eight columns. `UNKNOWN` is a legal value; a blank,
a guess, or a plausible-looking placeholder is not.

| Column | Contents |
| --- | --- |
| `change` | the landed change, with its PR or issue reference |
| `date` | UTC date the change landed (`YYYY-MM-DD`), or `pending` if not yet landed |
| `pack_sha` | prompt-pack revision the after-measurement was taken under; `UNKNOWN` until batch manifests carry it |
| `metric` | dotted path into the scorecard metric vocabulary — nothing else is admissible |
| `before` | baseline value, with the command or committed artifact it came from |
| `after` | value at the checkpoint, same instrument as `before`; `pending` until the checkpoint is reached |
| `verdict` | `confirmed`, `refuted`, `inconclusive`, or `pending` |
| `evidence` | at landing: where `before` came from and the checkpoint this row is due at. At the checkpoint, appended with how `after` was obtained. Either way, anything that makes the comparison weaker than it looks belongs here |

### Verdicts

- **`confirmed`** — the metric moved in the hypothesised direction, measured with
  the same instrument as the baseline, and no taxonomy or instrument change
  spans the interval.
- **`refuted`** — the metric did not move, or moved the wrong way. Normally the
  change should be reverted; this row is the record of why. A refuted row is a
  successful use of this ledger, not a failure of it.
- **`inconclusive`** — the metric could not be compared: instrument changed,
  baseline was `UNKNOWN`, confounding change landed in the same interval, or too
  few batches ran before the checkpoint. Say which, in `evidence`.
- **`pending`** — landed, checkpoint not yet reached. Every `pending` row must
  name its checkpoint in `evidence`, or it will silently never be resolved.

### Rules

1. **Never fabricate a metric value.** If a real value cannot be obtained, the
   cell is `UNKNOWN` and `evidence` says why. This rule outranks having a
   complete-looking table.
2. **Same instrument on both sides.** A `before` from one measurement path and an
   `after` from another is `inconclusive`, not `confirmed`. This bites hardest
   for the archived one-off baseline below, which was produced by a bespoke
   reconstruction script rather than by `agent-coord-harvest`.
3. **Baseline before landing.** Record `before` when the improvement is accepted,
   not after the change ships. A baseline measured after the fact is not a
   baseline.
4. **Taxonomy re-fits get their own row.** They invalidate comparisons spanning
   them, so they must be visible in date order.
5. **A `pending` row past its checkpoint is a retro action item**, not a
   permanent state.

## Ledger

| change | date | pack_sha | metric | before | after | verdict | evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Emit structured severity-bearing review-finding metadata so review economics becomes computable (#116) | pending | UNKNOWN | `review_economics.cost_per_actionable_finding_microusd` | `UNKNOWN` (denominator `review_economics.actionable_findings` = 0) | pending | pending | Baseline is a structural zero, measured two ways. (1) Fixture run of the real scorecard path emits `"actionable_findings":0` and `"cost_per_actionable_finding_microusd":"UNKNOWN"` — reproduce with `agent-coord-harvest harvest`/`scorecard` over `test/fixtures/telemetry/` for `--batch-id batch-fixture`. (2) Over real batches, [the 2026-07-18 baseline](../archive/reports/2026-07-18-historical-batch-baseline.md) found no severity-bearing structured finding block on 134 of 134 resolved PRs, and recorded all severities as `UNKNOWN` with the explicit caveat that absence is not zero findings. Checkpoint: 5 batches after the emitting change lands. Weakness: (2) used a bespoke archived script, not `agent-coord-harvest`, so it establishes only that the input does not exist — the first harvester-measured baseline is still to be captured. |
| Gate batch closeout on `agent-coord batch-audit` exit 0 (#117) | pending | UNKNOWN | `outcomes.UNKNOWN` | `UNKNOWN` under the harvester — no scorecard-measured baseline exists yet | pending | pending | Two figures in [the 2026-07-18 baseline](../archive/reports/2026-07-18-historical-batch-baseline.md) bracket this metric, and a later reader should pick the right one. The **closer analogue** is that report's final-state distribution, where `UNKNOWN` is 57 of 392 target units (14.5%, report line 58) — that is a resolved-state count, like `outcomes.UNKNOWN`. The wider figure is 102 of 392 (26.0%, `no_terminal_outcome_observed`, report line 35), which counts *reconstruction* gaps and so overstates what `outcomes.UNKNOWN` would show; overall evidence coverage there was 1,050/1,332 = 78.8%. Neither is an `outcomes.UNKNOWN` reading: that report predates the telemetry ledger and used a bespoke reconstruction script, so per rule 2 neither can serve as the `before` side of a `confirmed` verdict. Action before this row can resolve: capture a real `outcomes.UNKNOWN` baseline from `agent-coord-harvest scorecard` over a window of real batches. Checkpoint: 5 batches after that baseline exists. |

Both seed rows are deliberately baseline-only. No `after` value exists yet
because no improvement has landed and been re-measured, and inventing one to
make the table look finished would defeat the file's only purpose.

## Provenance of the seed baselines

The fixture scorecard reading was produced from committed fixtures under
`test/fixtures/telemetry/` against
[`lib/agent_coordination/scorecards.rb`](../../lib/agent_coordination/scorecards.rb).
It demonstrates the metric's shape and that the actionable denominator is zero;
it is a fixture, not a fleet measurement, and must not be cited as one.

The 2026-07-18 report is a committed, replayable snapshot over 100 batches, 421
lane rows, and 392 target units, captured at `2026-07-19T05:27:48Z`. Its own
framing is that it is an evidence-coverage baseline, not a worker-quality or
batch-success rate. Read it that way when citing it.

One caveat the report's own framing does not surface: of those 100 batches, 99
are real and 1 is synthetic (`sim-task_one`, repo `sim/local`, recorded as
`synthetic_batches: 1` in the summary JSON). It is a rounding-level effect on the
percentages above, but a harvester-measured baseline should exclude synthetic
batches rather than inherit this framing.
