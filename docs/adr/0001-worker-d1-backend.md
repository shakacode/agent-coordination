# 0001. Cloudflare Worker + D1 over a Rails app or Supabase

Date: 2026-07-04
Status: accepted

## Context

The v2 coordination backend (#7) needs an always-on HTTP store for claims,
heartbeats, batches, events, and reservations, replacing JSON files committed to
this repo via the GitHub Contents API. The load is tiny (~14k writes/day), the
schema is five small tables, and the operator is one person. ShakaCode is a Rails
shop, so "why isn't this a Rails app?" is the obvious future question — and
Supabase was a credible third option since gbrain already targets it. Full
comparison: [backend-design.md](../backend-design.md) → Options considered.

## Decision

Host the backend as a single Cloudflare Worker over a D1 (SQLite) database in the
shakacode Cloudflare account, with per-machine bearer tokens, the read-only
dashboard served from the same Worker behind Cloudflare Access, and every
mutual-exclusion decision expressed as a single conditional SQL statement.

## Rationale

- The coordination plane must be more reliable and lower-maintenance than the
  work it coordinates. A managed edge function is the smallest possible always-on
  operational surface; a Rails app (deploys, Postgres, patching, monitoring) is
  the largest, and its capabilities — full transactions, background jobs,
  ActionCable — go unused at 14k writes/day against five tables.
- One deployable covers API + dashboard + access control. Supabase covers only
  the database: CAS logic would move into SQL functions behind PostgREST,
  per-machine attribution fights the service-key model, and the dashboard still
  needs separate hosting. Its free tier also pauses inactive projects — an
  unacceptable failure mode for infrastructure — and its one genuinely superior
  feature (realtime push) is replaceable by 5-second polling at this scale.
- Cost is $0 at ~100× headroom on the free tier, in an account the org already
  operates with existing tooling.
- The decision is a two-way door: the `agent-coord` CLI contract is the seam, so
  a later migration re-implements ~10 endpoints without touching any skill,
  workflow, or consumer repo.

## Consequences

- A small TypeScript surface (~300 lines) enters a Ruby codebase; the behavioral
  contract stays in the Ruby CLI's tests, with a parity suite run against the
  Worker.
- D1's lack of interactive transactions constrains the design to single-statement
  conditional writes — accepted, and arguably a feature: it forces the
  check-then-act gaps found in the 2026-07-02 concurrency review to be closed in
  the WHERE clause rather than reintroduced in application code.
- Graduation criteria are recorded in the design doc: revisit Rails if this
  becomes a multi-user product with write-heavy UI and SSO needs; revisit
  Postgres/Supabase if realtime push becomes a must-have or CAS outgrows
  single-statement semantics.
- The named graduation path is a ShakaStack showcase app as the *product plane*
  (dashboard, orgs, batch planning) consuming this Worker's API — the protocol
  plane described here is deliberately not replaced by it, so the exclusion
  primitive never depends on a demo app's deploy cadence.
