# 0003. Consolidate the standalone operator dashboard into the protocol-plane repo

Date: 2026-07-08
Status: proposed

## Context

The coordination stack currently spans three public code repositories —
`agent-workflows` (the portable workflow pack), this repository
(`agent-coordination`, the protocol plane: `agent-coord` CLI, Cloudflare Worker
API, simulation harness), and `agent-coordination-dashboard` (a standalone local
operator dashboard) — plus private runtime data (`agent-coordination-state`,
`agent-coord-sim-*`).

ADR [0002](0002-mit-protocol-plane-open-core-boundary.md) already licenses both
the in-repo Worker-served read-only dashboard and the standalone
`agent-coordination-dashboard` as one MIT protocol plane, and it names the
standalone repository transitional: protocol plane "while it remains a local
operator view of this protocol plane." This ADR decides whether and when to make
that transition concrete.

The standalone dashboard is a functional TypeScript/React + Express app, but it
is single-operator, agent-centric, and filesystem-coupled. It hand-mirrors this
repository's coordination state contract in `src/shared/types.ts`; the 2026-07
audit flagged the resulting drift risk (the dashboard's types carry no operator
field while the protocol plane may add one).

The dashboard's v2 (its issue `agent-coordination-dashboard#9`) couples the two
repositories on both axes at once:

- it adds an HTTP-backend read mode against this repository's Worker API, and
- it adds operator/human attribution, a host dimension, and a per-PR
  collaboration view ("two developers on the same PR") — all schema changes that
  originate in this protocol plane and must be consumed by the dashboard.

Phase 2 (relational schema, new claim verbs) will couple them again. Today each
such change is a coordinated two-repository pull-request sequence — an awkward
result for a coordination project — and the hand-mirrored types can drift from
the CLI's state contract.

The `agent-workflows` pack is deliberately excluded from this question. It is a
backend-agnostic consumer that resolves any coordination backend only through
repo-owned seams (its seam design and `CONTEXT.md`). That boundary is a designed
seam, not raw coupling, so the pack stays a separate repository.

## Decision

Merge `shakacode/agent-coordination-dashboard` into this repository as the local
operator dashboard of the MIT protocol plane, before starting that v2 work.

- Direction: the dashboard moves into `agent-coordination`; the Worker already
  deploys from here and does not move. Layout: `apps/dashboard/` alongside the
  `agent-coord` CLI, `worker/`, and the simulation harness.
- Establish a single documented state schema as the source of truth, validated by
  a contract test exercised against both the Ruby producer and the TypeScript
  consumer (the simulation harness is the home for that test). This replaces the
  hand-mirrored `src/shared/types.ts`.
- Preserve history with `git subtree` / `git filter-repo`; migrate
  `agent-coordination-dashboard#9` into this repository; path-filter CI so
  dashboard changes do not run the Ruby suite and vice versa.
- Out of the boundary, unchanged from 0002: private runtime state
  (`agent-coordination-state`) and disposable simulation fixtures
  (`agent-coord-sim-*`) remain separate private data repositories.
- Out of scope: the future multi-tenant ShakaStack product-plane dashboard
  remains its own repository and license per ADR
  [0001](0001-worker-d1-backend.md) and 0002. This decision concerns only the
  local operator view.

## Rationale

- It executes a transition 0002 already anticipated rather than introducing a new
  boundary: both dashboards are already the MIT protocol plane, and the standalone
  repository is already documented as a transitional local operator view.
- Merge where there is no seam; split where one was built. The dashboard↔backend
  boundary is raw shared-schema coupling (direct state reads plus hand-mirrored
  types), so co-locate it. The pack↔backend boundary is a designed seam, so keep
  it separate.
- Timing: that v2 work straddles both repositories. Merging first turns it from
  cross-repository choreography into one atomic change and removes the type-drift
  class of bug the audit flagged.
- Single source of truth: one schema plus one contract test beats two
  hand-maintained copies in two repositories. The honest limit is that Ruby and
  TypeScript types are not auto-shared — the win is one documented, contract-
  tested schema in one place, not free code generation.

## Consequences

- One issue tracker, CI, and board for the protocol plane and its operator
  dashboard; the v2 work and Phase 2 land atomically.
- A polyglot repository (Ruby CLI, TypeScript Worker, TypeScript dashboard) —
  already partly true, since the Worker is TypeScript in a Ruby codebase.
  Path-filtered CI keeps the suites independent.
- The standalone `agent-coordination-dashboard` repository is archived with a
  pointer to its new location; external links and any stars redirect there.
- The state contract gains a contract test; `src/shared/types.ts` is removed in
  favor of the shared schema.
- Two-way door: if the operator dashboard later graduates into the ShakaStack
  product plane, it moves out again to the product-plane repository and license
  per 0001 and 0002.
- `agent-workflows` is untouched: the public, adopt-me pack keeps its own
  repository, changelog, and landing page.
