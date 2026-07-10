# 0004. Tenancy-ready state contract and product-plane seams

Date: 2026-07-08
Status: proposed

## Context

ADR [0001](0001-worker-d1-backend.md) and
[0002](0002-mit-protocol-plane-open-core-boundary.md) commit to a named
graduation path: a future multi-tenant ShakaStack **product plane** (hosted
dashboards, org workflows, batch planning, billing) that consumes this MIT
protocol plane's Worker API rather than replacing it. ADR
[0003](0003-decouple-dashboard-via-state-contract.md) decides to publish a
versioned state-schema contract (JSON Schema or OpenAPI for the Worker's
`/v1/state` surface), with a conformance test, as the single source of truth the
separate dashboard consumes over HTTP. It does not merge the dashboard in.

The protocol plane today is single-tenant by construction.
`worker/migrations/0001_state.sql` keys coordination state on a flat global
`path` primary key. Migration `0002_machine_scopes_and_writer_attribution.sql`
has since added writer attribution (`state.updated_by`) and per-machine
path-prefix authorization (`machines.read_prefixes` / `write_prefixes`), so
attribution and prefix-scoped access now exist — but there is still no tenant
boundary. Every self-hosted deployment is one isolated backend, so a global
namespace is correct for that use.

A hosted product plane is multi-tenant against one backend: many workspaces
share the Worker and D1, and their state must not collide or leak across the
tenant boundary. If the versioned contract 0003 is about to publish carries no
tenant dimension, adding one after self-hosters and any hosted pilot hold live
data is a destructive re-key of `state` plus a breaking bump of the published
contract — the most expensive kind of migration, on the one table that must
never lose a row. Attribution (`updated_by`) landing in migration 0002 is the
same class of scoping field one dimension down; tenancy is the dimension still
missing, and it is the expensive one to retrofit.

## Decision

Make the protocol plane tenancy-ready now, without building the product plane.
Three seams:

1. **A workspace scoping dimension in the published contract, from v1.** The
   versioned state-schema contract ADR 0003 publishes MUST treat a `workspace`
   (tenant) identifier as a first-class part of the coordination key, defaulting
   to a single reserved value (`default`) for self-host. Two storage mechanisms
   satisfy this and the choice is left to the contract work: reserve a workspace
   path-prefix as the leading segment of `path` (reusing the `read_prefixes` /
   `write_prefixes` scoping from migration 0002), or add an explicit `workspace`
   column to `state` and `machines`. What matters is that `workspace` is named in
   the v1 contract and defaulted, so self-host writes only `default` and behaves
   exactly as today while the product plane already has a real boundary.

2. **Auth as a named seam.** The Worker's derivation of identity from
   `Authorization: Bearer <machine token>` stays behind one explicit function
   that maps a credential to a `(workspace, machine)` identity; the per-machine
   token table and its prefix scopes are its default implementation. A product
   plane substitutes accounts, API keys, or OAuth at this seam without touching
   route handlers.

3. **A wrappable Worker.** `worker/src/index.ts` exposes its route handlers so a
   product plane can compose them behind middleware (tenant routing, auth, rate
   limiting, billing checks), rather than fork a sealed `fetch()` entrypoint.

This ADR does not build, schedule, or scope the product plane. It only fixes the
protocol-plane seams so the graduation 0001 and 0002 already committed to is
non-breaking.

## Rationale

- The cost is asymmetric. Naming `workspace` in the contract now is one key
  convention and a default constant. Adding it after live data exists is a re-key
  of the coordination primary key plus a breaking contract version, coordinated
  across self-hosters you do not control.
- It reuses machinery that already landed. Migration 0002's per-machine
  `read_prefixes` / `write_prefixes` already express path-scoped access; a
  reserved workspace prefix is a small, boring extension of that model rather than
  a new subsystem.
- It stays inside the open-core boundary of 0002. The workspace dimension and the
  auth seam are protocol primitives, MIT, and useful to self-host (a single
  `default` workspace) as much as to the product plane. No product-plane feature,
  license, or code enters this repository.
- It keeps the graduation a two-way door. If the product plane is never built,
  the standing cost is one defaulted key and one indirection in auth — negligible.

## Consequences

- The versioned state-schema contract and its conformance test (ADR 0003) name
  `workspace` from v1; self-host uses `default` and sees no behavior change.
- Whichever storage mechanism is chosen (reserved prefix or explicit column)
  lands with the contract, not as a later migration against live data.
- Auth identity derivation becomes a named seam with the per-machine-token and
  prefix-scope model as its default; no change to the bearer-token contract the
  CLI and self-hosters use today.
- The Worker exposes composable handlers; the self-host entrypoint is a thin
  default wrapper over them.
- Out of scope, unchanged from 0001/0002: the product plane's own repository,
  license, accounts, billing, and multi-tenant operations. This ADR only makes
  the protocol plane ready to be wrapped, not wrapped.
