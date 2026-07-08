# 0002. MIT protocol plane and open-core boundary

Date: 2026-07-08
Status: accepted

## Context

The coordination stack is split into this public code repository and private
runtime state. This repository contains the protocol implementation: the
`agent-coord` CLI, Cloudflare Worker API, Worker-served read-only dashboard,
simulation harness, tests, and documentation. Live claims, heartbeats, batches,
machine tokens, customer data, and operational exports are private runtime data,
not source code for the protocol.

The project also has a named graduation path: a future ShakaStack multi-tenant
product plane can provide hosted dashboards, org workflows, batch planning,
billing, saved views, or other customer-facing product features on top of the
protocol plane.

## Decision

License the protocol plane in this repository under the MIT License.

Protocol plane means:

- CLI, library code, and workflow-facing command contracts.
- Cloudflare Worker API code and D1 schema/migrations.
- Dashboard code that ships in this repository as a Worker-served read-only
  view of coordination state.
- The standalone `shakacode/agent-coordination-dashboard` local/protocol
  dashboard repository while it remains a local operator view of this protocol
  plane.
- Simulation harnesses, tests, documentation, ADRs, and examples.

Runtime state remains private data. It is not product source, is not licensed by
this repository, and must not be committed here. That includes live `claims/`,
`heartbeats/`, `batches/`, `*.json.lock`, machine tokens, credentials, customer
data, and source-code patches.

Future monetized or hosted ShakaStack product-plane code may use a different
license, repository, and commercial boundary. Product-plane code consumes the
protocol-plane API; it does not relicense or privatize the protocol primitives
that are MIT here.

## Rationale

- The coordination protocol is infrastructure glue. A permissive license makes
  it easy for public workflow docs, customer repos, and agent tools to depend on
  the same primitives without license friction.
- The open-core boundary is by layer, not by feature maturity: exclusion,
  liveness, state contracts, and the minimal read-only dashboard stay
  permissive; hosted product workflows can remain separate.
- Keeping runtime state outside the license boundary avoids implying that
  private operational data, credentials, or customer information are open-source
  artifacts.
- Dashboard licensing is explicit: the transitional Worker-served read-only
  dashboard belongs to the MIT protocol plane, while a future multi-tenant
  product dashboard belongs to the product plane.

## Consequences

- Contributors can treat all source files in this repository as MIT unless a
  file declares a more specific third-party license notice.
- Public docs should describe this repository as the MIT protocol plane and keep
  runtime state examples illustrative rather than live.
- Any future product-plane repository should document its own license and state
  that it consumes, rather than replaces, this MIT protocol plane.
- Pull requests must continue to keep runtime state and lock files out of this
  repository.
