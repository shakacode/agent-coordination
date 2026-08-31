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
  owner/session references, and recognized PR URLs. See
  [Events](#events) for the `events` column contract.
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

## Events

`events.event_type` is clamped to a closed vocabulary so grouping is over a
fixed set. That vocabulary covers every type `bin/agent-coord` emits — the
auto-emitted lifecycle types `claim.acquired`, `claim.released`, and
`phase.changed`; the terminal `lane_closed`; and the typed operational signals
`help_requested`, `escalation_requested`, `error`, and `human_intervention` —
plus nine historical spellings that appear only in the archived 2026-07-18
baseline. Those nine are retained so already-harvested rows keep their
classification; they do **not** make that archive broadly readable, since
re-harvesting it classifies 210 of 959 events and leaves 749 spread over 166
distinct spellings. What makes those 749 usable is `event_type_raw`, below.

The emitted set is derived from `bin/agent-coord` by a test rather than
restated, and derived two ways: from the CLI's constants, and by scanning its
source for literal `type:` emission sites. Both are needed — the four types the
CLI emits itself are bare literals at their call sites, so a new hardcoded
emission touches no constant and a constants-only check would miss it. A newly
emitted type therefore fails the suite until the harvester either ingests it or
names it an explicit exclusion, and the exclusion list cannot name every emitted
type. A type outside the vocabulary is
never silently dropped: the raw string is always stored in `event_type_raw`, so
an unrecognized value is a countable
`event_type IS NULL AND event_type_raw IS NOT NULL` row, exposed by the
`event_type_drift` view.

`event_type_raw` is sanitized but never rejected, which is what makes that
guarantee hold: **it is `NULL` if and only if the source event carried no usable
type — absent, or nothing but whitespace.** Control
characters are removed, because drift output is read in a terminal, and the
stored value is bounded to 256 bytes; the literal string `UNKNOWN` is kept
verbatim, since the column is explicitly the raw string and an absent type is
already `NULL`. A value that had to be truncated carries a short digest of the
original, so two distinct oversized types stay distinct rather than collapsing
into one drift row. Sanitizing never conceals a classified event, because every
allowlisted type is short and control-character free and so can never require it.

Values are normalized by trimming surrounding whitespace before any of that, so
two inputs differing only there are stored identically — they are the same type,
and reporting them as two drift rows would be worse output. Beyond that
normalization, distinct originals stay distinct. The digest suffix shape is
reserved, so a clean value that happens to equal another value's sanitized form
is itself digest-marked rather than stored as that form — the two paths' outputs
are disjoint, and a stored value ending in the marker shape is always one the
sanitizer produced. (A legitimate value ending in the marker plus twelve hex
characters is therefore marked too. Rare, harmless, and the right trade.) Beyond
that, two sanitized values collide only on a SHA-256 hex-prefix collision, which
is a cryptographic bound rather than an exact guarantee.

The set of trimmed characters is derived rather than chosen, because the trim
runs before control detection: any character that is both trimmable and a
control character would be silently removed, storing identically to a value that
never carried it. Ruby's `String#strip` overlaps on NUL, VT, and FF;
`[[:space:]]` overlaps on NEL (U+0085). So the trim set is exactly space plus
the three characters the CLI's own control definition deliberately omits — tab,
LF, and CR, which are formatting rather than terminal injection. Nothing the CLI
treats as terminal-unsafe is ever trimmable, which makes NUL, NEL, VT, FF, and
the whole C1 range structurally unable to launder: they take the digest-marked
control path. A value consisting only of control characters is therefore stored
as a bare digest rather than `NULL` — it carried something.

Tab, LF, and CR are trimmed at the ends (layout noise) but stripped and
digest-marked in the interior (content corruption).

The trim class and the control class are single definitions across the ingest
boundary, not per-column copies. `AgentCoord::HostAdapters` owns them because the
harvester loads that parser first; the harvester aliases the same objects for
its two sanitizers. `bounded_signal` strips and digest-marks free-form columns,
while both `known` implementations reject identity and enum columns. They may
disagree about what to do with a control character; they cannot disagree about
what one is.

That structural reuse matters because independent copies caused both defects.
Harvester#known once carried a C0-and-DEL-only pattern and missed the C1 range
including U+009B (CSI), while HostAdapters#known once applied no control check.
Both also used `String#strip`, so a trailing NUL was removed before an allowlist
comparison and a value such as `high<NUL>` was promoted to the allowlisted
`high` (issues #171 and #200).

Closing that promotion also made `known` self-consistent. It had rejected NUL,
VT, and FF in the interior of a value while accepting them at the ends, purely
because `strip` removes them; all three are control characters by the CLI's own
definition, so they are now rejected wherever they appear. This is the one
behavior change beyond the two defects — a value like `batch<VT>` was previously
accepted as `batch` and is now rejected.

What a rejection costs depends on the column, and it is not uniform. Three
callers treat a rejected value as a guard rather than merely storing `NULL`:

- **`batch_id`.** `harvest_batches` builds its selected-id set with
  `filter_map { known(...) }` and then skips any batch whose id is rejected, so
  the batch disappears along with everything under it — its lanes, target
  observations, claims, and events. Those rows never reach `join_status`, which
  is why `missing_batch` is in practice unreachable by this path: an event or
  claim whose own `batch_id` is rejected is filtered out of the selected set
  rather than landing with a partial join.
- **`repo`, `url`, and `state` on a pull request.** `insert_pull_request`
  returns early unless all of them survive, dropping that `pull_requests` row
  together with its review receipts and findings. Worth knowing that `repo()`
  and `github_url()` match with `[^/\s]+`, and `\s` does not cover C1 — so a
  C1-bearing repo segment or PR URL previously passed both regexes and landed in
  the ledger, to be rendered in terminal-facing scorecards.
- **`lane_id`.** `insert_lane` writes the `lanes` row only when the lane's name
  (or its `id`, whichever the document carries) survives, so a rejected one skips
  that row. This is a partial skip rather than
  a whole subtree: the lane's `target_observations` still land, carrying a `NULL`
  `lane_id`, so the targets stay visible even though the lane record does not.

Everywhere else rejection degrades the row rather than removing it, which is the
common case. A rejected `repo` or `target` on an event, claim, or target
observation still lands the row and reports `missing_repo` / `missing_target`
rather than `exact`. A rejected enum lands as `NULL` — and for `event_type` that
`NULL` is precisely what puts the row inside `event_type_drift`, which keys on
`event_type IS NULL`, so a control-bearing type is now counted by the view
rather than sitting outside it as a clean `event_type` beside a digest-marked
`event_type_raw`. The `event_ref`, `review_ref`, and `finding_ref` columns
degrade further still, falling back to a positional identifier rather than
`NULL`.

In practice a CLI-written *identifier* cannot contain whitespace or control
characters at all, since `AgentCoord.validate_segment!` constrains those at write
time. That is not true of every CLI-written value — `--category` is deliberately
free-form and unbounded, which is exactly why it goes through `bounded_signal`
rather than this guard. And the guard matters regardless, because ingest also
reads hand-written files, archived baselines, and the HTTP backend, none of which
pass through the CLI's write-time validation at all.

**Upgrade note.** A ledger populated before this change may already hold a batch
whose id is now rejected — only from one of those non-CLI sources, since
`validate_segment!` cannot produce such an id. A named `harvest --batch-id` will
not refresh or remove that batch: the id is matched against the raw document
string, so the batch is found, but it is rejected before it reaches the set of
ids the harvest replaces, so the command exits 0 reporting `batches=0` while the
stored row stays queryable and can still be emitted by `scorecard`. A date-range
harvest covering that batch does clear it — it removes the stale row rather than
refreshing it, since the id is still rejected and so cannot be re-ingested — and
that is the workaround. This is an upgrade hazard rather than new exposure: the
row is already in the ledger and already reachable today, and a re-harvest before
this change would have replaced it with the same control-bearing value. Tracked
in issue #204.

Note the `0004` migration's own comment still describes the promotion as an open
gap. Applied migrations are hash-pinned historical records and are not edited;
this document is the live description.

`category` gets the same sanitize-never-reject treatment, for the same reason:
it is required for `error` events but bounded nowhere at write time, so
rejecting an oversized value would destroy the friction classifier it carries.
It differs in one respect — a literal `UNKNOWN` category is stored as `NULL`,
because a category is a semantic classifier and this repo reads `UNKNOWN` as
"no value", whereas `event_type_raw` keeps it verbatim. `severity`, `kind`, and
`reason` need no sanitizing: they are closed enums, so a value outside the set
is correctly `NULL` whatever its length.

Typed signals keep the attributes the CLI validates at write time. `severity`,
`kind`, and `reason` are validated against mirrors of the CLI's own enums and
stored as `NULL` if they fall outside them; `category` is free-form at write
time, so it is sanitized and bounded rather than enum-checked (see above). `escalation_requested`'s
`from_route`, `to_route`, and `evidence` are deliberately **not** retained:
`evidence` is free prose that does not belong in an analysis column, and the
route strings are unbounded free text duplicating the route/model dimension
`host_sessions` already carries. Only the `escalation_requested` count is
needed, and `event_type` provides it.

## Joins and outcomes

`target_units` exists only for a complete `batch_id + repo + target` key.
Incomplete observations remain in `target_observations` with an explicit
`join_status`; `UNKNOWN` is not inserted into a primary key or numeric column.
Lane membership is normalized in `lane_memberships`.

Host sessions allocate cost only when their opaque session reference maps to
one exact lane membership. Unmatched or ambiguous sessions remain queryable but
are excluded from `allocated_costs`. Same-repository GitHub PR evidence may
classify an outcome only when no claim or event declares a protocol terminal
state. Protocol terminal state is authoritative over GitHub-derived state.
Cross-repository evidence is retained as `repo_mismatch` and cannot override
coordination state. Conflicting exact PR states or incompatible structured
statuses produce `conflicting-observations`. Missing outcomes stay SQL `NULL`
and render as literal `UNKNOWN` in scorecard output.

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
