# Historical Batch Outcome Baseline

This one-off study measures how completely retained coordination data can
reconstruct historical batch outcomes. It is an evidence-coverage baseline,
not a worker-quality or batch-success rate. A terminal `abandoned` outcome can
be fully reconstructable; a lane described as `done` can remain incomplete
evidence when the exact coordination join is absent.

The frozen source and generated results are:

- [sanitized source projection](data/2026-07-18-historical-batch-baseline-source.json)
- [machine-readable summary](data/2026-07-18-historical-batch-baseline-summary.json)
- [all 100 batch scores](data/2026-07-18-historical-batch-baseline-batches.tsv)
- [all 392 target-unit results](data/2026-07-18-historical-batch-baseline-targets.tsv)
- [one-off replay generator](data/2026-07-18-historical-batch-baseline.rb)

## Result

The retained snapshot scores **1,050 / 1,332 (78.8%)** for outcome-evidence
coverage. Of 392 target units, **227 are reconstructable**, **63 are observed
only**, and **102 are `UNKNOWN`**. `UNKNOWN` means no recognized terminal
outcome was directly recorded; it is not treated as failure, abandonment, or
unfinished work.

| Measure | Count | Denominator | Rate |
| --- | ---: | ---: | ---: |
| Complete `batch_id + repo + target` key | 351 | 392 | 89.5% |
| Exact claim or event match | 272 | 392 | 69.4% |
| Recognized terminal outcome observed | 290 | 392 | 74.0% |
| Same-repo GitHub PR resolved when `pr_url` is recorded | 137 | 156 | 87.8% |
| Reconstructable outcome | 227 | 392 | 57.9% |
| Observed terminal outcome, reconstruction incomplete | 63 | 392 | 16.1% |
| Terminal outcome `UNKNOWN` | 102 | 392 | 26.0% |

The four score numerators reconcile to `351 + 272 + 290 + 137 = 1,050`.
The denominator is three coordination gates for every target unit plus one
GitHub gate only for PR-bearing units: `(392 x 3) + 156 = 1,332`.

## Population

At `2026-07-19T05:22:04Z`, this command completed with exit 0 and
`degraded: []`:

```sh
bin/agent-coord status --json --include-archived
```

Its raw 1,987,195-byte response has SHA-256
`6a99cedbc64d88ba5b92c5021b7a022631aa81591684f1314299aaeda613dee0`.
The committed source is a minimized projection that removes batch objectives,
instructions, launch prompts, messages, handoff notes, actor/session identity,
and unrelated payload fields.

| Snapshot section | Rows |
| --- | ---: |
| Batches | 100 |
| Lanes | 421 |
| Exploded lane-target rows | 503 |
| Claims | 579 |
| Heartbeats | 551 |
| Events | 1,011 |
| Archive records | 0 |

All 100 retained batch manifests are in scope, including one record explicitly
marked synthetic. Exploding every `lanes[].targets[]` value produced 503 rows.
Aggregating lane roles at `batch_id + repo + target` produced 392 target units;
111 repeated lane-role rows were collapsed. Four batches omit top-level `repo`,
leaving 41 target units without a complete join key.

The hot snapshot is the population, not a claim about all batches ever run.
Although `--include-archived` was supplied, the response contained zero archive
records. Retention, overwritten target claims, deleted platform history, or
data produced before current fields existed cannot be recovered from this
snapshot and remains absent.

## Scoring Method

Each aggregated target unit receives one point for each applicable gate:

1. `batch_id`, batch `repo`, and target are all explicitly present.
2. At least one claim or event matches that exact triple.
3. A terminal value is explicitly observed in the target's contributing lane,
   exact claim, or exact event. Recognized status aliases come from the current
   `agent-coord config show --json` terminal vocabulary; unrecognized strings
   are not promoted to terminal outcomes.
4. When a lane records `pr_url`, every recorded URL is a resolvable GitHub pull
   request in the same repository as the target key. This gate is not
   applicable when no PR URL is recorded.

Classification is deterministic:

- `reconstructable`: all applicable gates pass.
- `observed_only`: a terminal outcome is directly observed but another gate
  fails.
- `UNKNOWN`: no recognized terminal outcome is directly observed.

The score deliberately does not infer an outcome from claim release, branch
names, lane names, missing events, GitHub issue state, or current CI. A released
claim describes ownership lifecycle, not work outcome.

## Batch Scores

The weighted overall score is 78.8%. The unweighted batch mean is 82.2%, the
median is 100.0%, and the range is 25.0%-100.0%. Larger incomplete batches pull
the weighted result below the median.

| Score band | Batches |
| --- | ---: |
| 100% | 52 |
| 90%-99.9% | 4 |
| 75%-89.9% | 18 |
| 50%-74.9% | 11 |
| Below 50% | 15 |

The lowest-scoring retained batches illustrate missing evidence rather than
known poor outcomes:

| Batch | Repo | Target units | Reconstructable / observed / `UNKNOWN` | Score |
| --- | --- | ---: | ---: | ---: |
| `batch-b` | `shakacode/react_on_rails` | 1 | 0 / 0 / 1 | 25.0% |
| `ror17-fleet-c-20260717` | missing | 7 | 0 / 6 / 1 | 25.0% |
| `tr-07-13-1344-plugin-split` | missing | 3 | 0 / 3 / 0 | 27.3% |
| `ror-17-0-0-rc10-demo-fleet-0713-1420-hst` | missing | 21 | 0 / 21 / 0 | 30.4% |
| `awr-b-0716-1535` | missing | 10 | 0 / 10 / 0 | 33.3% |

The complete batch table carries each numerator and denominator; no batch was
excluded for being synthetic, active, blocked, or incomplete.

## Join-Key Validation

`batch_id + repo + target` is necessary and is valid as a **target-level** join
after lane-role aggregation. It is not a unique lane identifier.

- Twenty `repo + target` keys occur in more than one batch. Joining without
  `batch_id` would mix distinct historical runs.
- Eighty-two full triples occur in multiple lane rows, accounting for 111
  collapsed rows. These are typically implementation, QA, audit, or closeout
  roles for the same batch target.
- Therefore the triple must first aggregate contributing lane roles. Consumers
  that need lane identity must add the explicit lane name; they must not assume
  the triple uniquely identifies a lane.

Representative rows validate both conclusions:

| Batch / repo / target | Lane roles | Claim / event matches | Direct outcome | Result |
| --- | --- | ---: | --- | --- |
| `ac-a-0712-0107` / `shakacode/agent-coordination` / `51` | `ac-a-i51` | 1 / 1 | `done`; PR 56 is currently merged | reconstructable, 4/4 |
| `ac-b-0712-0107` / `shakacode/agent-coordination` / `8` | `ac-b-i8` | 0 / 1 | `done`; PR 61 is currently merged | reconstructable, 4/4 |
| `acb` / `shakacode/agent-coordination` / `8` | `host-limits-contract` | 0 / 0 | legacy terminal label only | observed only, 2/3 |
| `ac-a-coord-cinder` / `shakacode/agent-coordination` / `54` | `ac-a-pr54`, `ac-a-qa` | 1 / 2 | `done` | reconstructable, 3/3 after aggregation |
| `awr-b-0716-1535` / missing / `151` | `b3` | 0 / 0 | `done` | observed only, 1/3 |

The two target-8 rows prove the practical value of `batch_id`: the older `acb`
row must not inherit the later batch's exact event or PR evidence.

## Reconstruction Gaps

Counts below are actual target units blocked for the named reconstruction. A
unit may have more than one gap, so rows are not additive.

| Rank | Gap | Blocked | Denominator | Score impact |
| ---: | --- | ---: | ---: | --- |
| 1 | Historical CI-at-event-time absent | 156 | 156 PR-bearing units | Excluded from outcome score |
| 2 | No exact claim/event match | 120 | 392 target units | Blocking |
| 3 | No recognized terminal outcome observed | 102 | 392 target units | Blocking |
| 4 | Missing `repo` join component | 41 | 392 target units | Blocking |
| 5 | Invalid or unresolved GitHub PR URL | 6 | 156 PR-bearing units | Blocking |
| 6 | GitHub PR repository differs from batch repo | 2 | 156 PR-bearing units | Blocking |

The coordination-match gap consists of 120 target units with neither an exact
claim nor an exact event. Claims match 238 target units, events match 208, and
174 have both. Heartbeats are not used to fill the gap: the snapshot exposes no
`repo` field on any of its 551 heartbeat rows. Some heartbeat targets embed
repo-like text, but parsing that into an absent join component would create an
inferred event association.

## GitHub Evidence

The snapshot contains 140 unique `pr_url` values. Of these, 135 have GitHub
pull-request URL syntax and 134 resolved in one bounded GraphQL metadata read at
`2026-07-19T05:27:48Z`. The one unresolved URL names pull request 3972 in
`shakacode/react_on_rails`; GitHub returned no such pull request.

Across the 134 resolved PRs, current metadata reports 107 `MERGED`, 11 `CLOSED`,
and 16 `OPEN`. Present-head check rollups report 109 `SUCCESS`, 4 `FAILURE`, 18
`PENDING`, and 3 `UNKNOWN`.

Those check rollups are explicitly **not historical CI evidence**. They describe
the PR's current head at query time, not necessarily the SHA or checks observed
when a coordination event was recorded or a PR merged. No retained event field
binds a check conclusion, check run, or CI timestamp to terminal closeout, so
historical CI remains `UNKNOWN` for all 156 PR-bearing target units.

Five other unique `pr_url` values are not GitHub pull-request URLs: three are
synthetic `example.test` fixture URLs and two are GitHub issue-comment evidence
URLs. They remain recorded evidence but do not pass the PR gate. Two target
units explicitly point to a GitHub PR in a repository different from the batch
repo; the explicit mismatch is preserved rather than repaired heuristically.

## Caveats And Confidence

Confidence is high in the frozen counts, joins, score arithmetic, and present
GitHub metadata. The replay generator asserts unique batch ids, source/derived
batch counts, classification totals, target totals, score denominators, and
exploded-row reconciliation before writing output.

Confidence is intentionally limited for historical outcome completeness:

- The included population is only the currently retained hot snapshot; archive
  coverage is empty.
- Claims are current records keyed at the target surface and may not preserve
  every earlier batch association.
- Legacy status labels predate structured terminal fields. Only labels in the
  current published terminal vocabulary are accepted.
- Lane manifests have a batch-level repo, not a per-lane repo. Multi-repository
  batches with missing or mismatched batch repo cannot be repaired from a PR URL
  without changing the join contract.
- Current GitHub state cannot prove state at coordination-event time.
- Absent events, checks, PRs, or terminal markers remain absent. This report
  does not treat absence as success, failure, cancellation, or no-PR evidence.

## Replay

The committed sanitized source is sufficient to replay every score and table
without network access:

```sh
tmp_dir=$(mktemp -d)
ruby docs/archive/reports/data/2026-07-18-historical-batch-baseline.rb \
  docs/archive/reports/data/2026-07-18-historical-batch-baseline-source.json \
  "$tmp_dir/summary.json" \
  "$tmp_dir/batches.tsv" \
  "$tmp_dir/targets.tsv"
cmp "$tmp_dir/summary.json" \
  docs/archive/reports/data/2026-07-18-historical-batch-baseline-summary.json
cmp "$tmp_dir/batches.tsv" \
  docs/archive/reports/data/2026-07-18-historical-batch-baseline-batches.tsv
cmp "$tmp_dir/targets.tsv" \
  docs/archive/reports/data/2026-07-18-historical-batch-baseline-targets.tsv
```

Headline reconciliation:

```sh
jq '.headline, .reconstruction_gap_ranking, .join_validation' \
  docs/archive/reports/data/2026-07-18-historical-batch-baseline-summary.json

awk -F '\t' 'NR > 1 {
  targets += $5; reconstructed += $6; observed += $7; unknown += $8;
  numerator += $9; denominator += $10
} END {
  print targets, reconstructed, observed, unknown, numerator, denominator
}' docs/archive/reports/data/2026-07-18-historical-batch-baseline-batches.tsv
```

Expected second-command output is `392 227 63 102 1050 1332`.

## QA Decision

Separate batch QA is not required. This change adds no production code or
runtime behavior; QA consists of deterministic artifact replay, table/summary
reconciliation, repository validation, and independent report review. A
`qa-evidence v1` `required: no` draft should be anchored to the final commit SHA
in the lane handoff rather than embedded here, because recording a commit's own
SHA inside that commit would be self-referential.
