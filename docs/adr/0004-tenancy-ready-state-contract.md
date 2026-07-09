# 0004. Tenancy-ready state contract and product-plane seams

Date: 2026-07-08
Status: proposed

## Context

ADR [0001](0001-worker-d1-backend.md) and [0002](0002-mit-protocol-plane-open-core-boundary.md)
commit to a named graduation path: a future multi-tenant ShakaStack **product
plane** (hosted dashboards, org workflows, batch planning, billing) that
consumes this MIT protocol plane's Worker API rather than replacing it. ADR
[0003](0003-consolidate-standalone-dashboard.md) establishes a single documented
state schema, validated by a contract test, as part of merging the operator
dashboard into this repository.

The protocol plane today is single-tenant by construction.
`worker/migrations/0001_state.sql` keys coordination state on a flat global
`path` primary key, and issues per-machine bearer tokens from a `machines` table
with no tenant association. Every self-hosted deployment is its own isolated
backend, so a global namespace is correct for that use.

A hosted product plane is multi-tenant against one backend: many workspaces
share the Worker and D1, and their state must not collide or leak across the
tenant boundary. If the state contract 0003 is about to define carries no tenant
dimension, adding one after self-hosters and any hosted pilot hold live data is
a destructive re-key of the `state` primary key and a backfill of `machines` —
the most expensive kind of migration, on the one table that must never lose a
row. This is the same class of gap the 2026-07 audit caught with the missing
`operator` field, one scope dimension higher.

## Decision

Make the protocol plane tenancy-ready now, without building the product plane.
Three seams:

1. **Workspace scoping key in the state contract, from the outset.** The single
   documented state schema that ADR 0003 establishes MUST carry a `workspace`
   (tenant) identifier as a first-class part of the coordination key, defaulting
   to a single reserved value (`default`) for self-host. Concretely, the `state`
   primary key becomes `(workspace, path)` and `machines` gains a `workspace`
   column; a self-host deployment writes only `default` and behaves exactly as
   today. The contract test asserts the key is present and defaulted.

2. **Auth as a named seam.** The Worker's derivation of identity from
   `Authorization: Bearer <machine token>` stays behind one explicit function
   that maps a credential to a `(workspace, machine)` identity. The current
   per-machine-token table is its default implementation. A product plane
   substitutes accounts, API keys, or OAuth at this seam without touching route
   handlers.

3. **A wrappable Worker.** `worker/src/index.ts` exposes its route handlers so a
   product plane can compose them behind middleware (tenant routing, auth, rate
   limiting, billing checks), rather than fork a sealed `fetch()` entrypoint.

This ADR does not build, schedule, or scope the product plane. It only fixes the
protocol-plane seams so the graduation 0001 and 0002 already committed to is
non-breaking.

## Rationale

- The cost is asymmetric. Adding `workspace` while the contract is being written
  is one key convention and a default constant. Adding it after live data exists
  is a re-key of the coordination primary key plus a token backfill, coordinated
  across self-hosters you do not control.
- It is the boring, proven shape. Multi-tenant infrastructure carries a tenant
  key on every scoped row from day one; retrofitting tenancy is the canonical
  open-core migration people regret.
- It stays inside the open-core boundary of 0002. The tenant key and the auth
  seam are protocol primitives, MIT, and useful to self-host (a single `default`
  workspace) as much as to the product plane. No product-plane feature, license,
  or code enters this repository.
- It keeps the graduation a two-way door. If the product plane is never built,
  the standing cost is one column defaulted to `default` and one indirection in
  auth — negligible.

## Consequences

- The state schema and its contract test (ADR 0003) include `workspace` from the
  first commit; self-host uses `default` and sees no behavior change.
- `worker/migrations/` gains the `workspace` dimension on `state` and `machines`
  in the same change that introduces the documented schema, not a later
  migration against live data.
- Auth identity derivation becomes a named seam with the per-machine-token model
  as its default; no change to the bearer-token contract the CLI and
  self-hosters use today.
- The Worker exposes composable handlers; the self-host entrypoint is a thin
  default wrapper over them.
- Out of scope, unchanged from 0001/0002: the product plane's own repository,
  license, accounts, billing, and multi-tenant operations. This ADR only makes
  the protocol plane ready to be wrapped, not wrapped.
