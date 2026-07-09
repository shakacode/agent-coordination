# 0003. Publish a state-schema contract and keep the dashboard a separate consumer

Date: 2026-07-08
Status: proposed

## Context

The coordination stack spans three public code repositories — `agent-workflows`
(the portable workflow pack), this repository (`agent-coordination`, the protocol
plane: `agent-coord` CLI, Cloudflare Worker API, simulation harness), and
`agent-coordination-dashboard` (a standalone local operator dashboard) — plus
private runtime data (`agent-coordination-state`, `agent-coord-sim-*`).

The dashboard is a functional TypeScript/React + Express app, single-operator and
filesystem-coupled. It hand-mirrors this repository's coordination state contract
in `src/shared/types.ts`; the 2026-07 audit flagged the resulting drift risk (the
dashboard's types carry no operator field while the protocol plane may add one).

Dashboard issue `agent-coordination-dashboard#9` — its v2 — both switches the
dashboard from filesystem reads to an HTTP read mode against this repository's
Worker API, and adds operator/human attribution, a host dimension, and a per-PR
collaboration view (the "two developers on the same PR" use case).

An earlier draft of this ADR proposed merging the standalone dashboard into this
repository as `apps/dashboard/` before that v2 work. An engineering review with an
independent second model rejected that ordering. The dashboard's coupling is
isolated to one ~306-line reader (`readCoordinationState.ts`); that shows the seam
is cheap to extract, not that none exists. ADR
[0001](0001-worker-d1-backend.md) already establishes that the CLI/Worker API
contract is the seam for consumers, and issue #9 is precisely the dashboard
beginning to use that seam. Merging first would import a filesystem-coupled Express
app into the protocol plane just before that coupling is rewritten, and would
weaken the protocol plane's strongest proof: a real, separately-hosted consumer.

## Decision

Do not merge the repositories now. Instead:

1. Publish a versioned state-schema contract in this repository (JSON Schema or
   OpenAPI for the Worker's `/v1/state` surface) as part of the MIT protocol
   plane, with a conformance fixture/test that both the Ruby producer and any
   TypeScript consumer validate against. This is the single source of truth that
   replaces the dashboard's hand-mirrored `src/shared/types.ts`.
2. In issue `agent-coordination-dashboard#9`, switch the dashboard's reader to
   consume the Worker HTTP API against that published contract, with generated or
   contract-checked TypeScript types. This decouples the dashboard from filesystem
   internals.
3. Keep `shakacode/agent-coordination-dashboard` a separate repository — the
   reference external consumer that proves the protocol plane's API is usable
   without monorepo proximity.
4. Defer repository consolidation. Revisit only if a concrete need appears (for
   example, schema-iteration friction that versioning does not absorb). If it is
   ever done, it is a deliberate later step, not a prerequisite for #9.

This also resolves the two-dashboard question left open by ADR
[0002](0002-mit-protocol-plane-open-core-boundary.md): the standalone repository
remains the local operator view and consumes the Worker API via the published
contract. Whether a read-only view is additionally served from the Worker itself
(as 0002 anticipates) is a deploy-shape decision for #9, not settled here.

## Rationale

- ADR 0001 already names the CLI/Worker API contract as the seam for backend
  moves, and #9 makes the dashboard use it. Proving that seam with a real,
  separately-hosted consumer is stronger evidence of a durable protocol plane than
  co-location.
- Because the coupling is isolated to one reader, the contract is cheap to
  publish. A versioned contract plus a conformance test cures the type-drift the
  audit flagged without consolidation.
- Keeping the dashboard a separate, single-language repository makes it a
  low-friction, low-blast-radius surface for casual and AI-assisted ("vibe-coded")
  changes: `git clone` + `npm install` + `npm run dev`, with no need to understand
  the Ruby CLI, the Worker, or D1. Such changes cannot reach the load-bearing
  coordination primitive (ADR 0001: the coordination plane must be more reliable
  than the work it coordinates), and, made against the published contract, they
  double as live proof the API is consumable by an outside contributor. A polyglot
  monorepo would force one contribution bar and one CI gate across both the
  hackable view and the hardened primitive.
- Merge-first would absorb build, CI, history, and tooling churn before #9 proves
  the API shape, and would let the dashboard accrete protocol-repo assumptions
  that make the ADR-0001/0002 product-plane graduation harder — a weaker two-way
  door than the merge-first draft claimed.
- The pack (`agent-workflows`) stays separate for the reason it always has: it
  resolves any backend through repo-owned seams.

## Consequences

- New in the protocol plane: a versioned state-schema contract and conformance
  test. The dashboard's `src/shared/types.ts` is replaced by contract-derived
  types once #9 lands.
- The #9 schema changes (operator/human attribution, host dimension, per-PR view)
  evolve the published contract; the dashboard consumes the new version. This is
  normal versioned-API evolution across two repositories, not raw drift.
- To keep that low-friction contribution path real, the dashboard ships a
  first-class demo mode: a bundled sample-state fixture and a `dev:demo` script, so
  `git clone && npm install && npm run dev:demo` renders a populated dashboard with
  no backend to stand up. The existing filesystem read mode plus the simulation
  fixtures already cover most of this.
- Private runtime state and simulation fixtures stay separate private repositories
  (unchanged from 0002).
- If consolidation is ever revisited, this migration checklist must be resolved
  first: reconcile the identically named CI workflows (`ci.yml`,
  `claude-code-review.yml`, `claude.yml`) including branch-protection required
  check names, CodeQL/dependency scanning, cache keys, and Dependabot/Renovate/PR
  bot config; decide a Node policy (the dashboard needs Node >= 24, the Worker
  pins none) as repo-wide, subdirectory-scoped, or a CI matrix; and accept that
  `git subtree`/`git filter-repo` preserve commits but not PR discussions, issue
  references, tags, package provenance, CODEOWNERS, security alerts, or
  permalinks.
- Reversible in both directions: separate-with-contract can consolidate later, and
  a consolidated dashboard could still graduate out to the product plane per 0001
  and 0002.
