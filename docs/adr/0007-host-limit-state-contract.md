# 0007. Host-limit state contract foundation

Date: 2026-07-12
Status: accepted

## Context

One usage limit can pause every coordination lane using the same quota host on
one machine. Lane-local heartbeat failures cannot express that shared cause, and
persisting `blocked-on-limit` independently on each lane would duplicate state
and invite drift. Provider message formats, hook and probe coverage, reset-time
precision, and provider quota-pool aliases are currently `UNKNOWN`.

ADR [0003](0003-decouple-dashboard-via-state-contract.md) makes this repository
the producer of versioned state contracts while the dashboard remains a separate
consumer. ADR [0004](0004-tenancy-ready-state-contract.md) requires `workspace`
as a first-class key dimension, with `default` reserved for self-hosting.

## Decision

Publish the versioned JSON Schema at
[`schema/state/v1/host-limit.schema.json`](../../schema/state/v1/host-limit.schema.json).
A host-limit record's logical key is exactly `(workspace, machine, host, scope)`:

- `workspace` is required. Self-hosted producers use `default`.
- `machine` is the stable coordination-machine identifier.
- `host` is a canonical, provider-neutral quota-pool identifier. Producers trim
  and lowercase it and may use only lowercase ASCII letters, digits, `.`, `_`,
  and `-`. It contains no scheme, port, path, account identifier, or credential.
  Equality after that normalization is exact. Provider alias mapping is not
  guessed by this contract.
- `scope` is a canonical provider-neutral quota window or limit class. Multiple
  scopes may coexist for the same workspace, machine, and host.

The workspace-aware storage key reserved for a later runtime implementation is
`host_limits/<workspace-segment>/<machine-segment>/<host>/<scope>.json`. The
workspace and machine segments encode their UTF-8 bytes by leaving only ASCII
letters, digits, `_`, and `-` literal and percent-encoding every other byte with
uppercase hexadecimal. Thus `default` remains `default`, `/` becomes `%2F`, and
`%` becomes `%25`. Host and scope already use a path-safe canonical alphabet.
This reversible encoding prevents separators or traversal components from
changing key identity and encodes each logical key component exactly once. This
ADR does not add that path to the CLI or Worker.

Records have `status: active | cleared`, an immutable observation time in
`observed_at`, a nullable `resets_at`, and
`source: manual | host-message | hook | probe`. An explicit clear changes the
status to `cleared` and requires `cleared_at`; active records cannot carry
`cleared_at`. Ordering constraints such as `cleared_at >= observed_at` are
producer requirements because JSON Schema cannot compare timestamps.

Consumers determine whether a record is effective at projection time:

1. A cleared record is not effective.
2. An active record with `resets_at: null` remains effective until explicitly
   cleared.
3. An active record with `resets_at` later than projection time is effective.
4. An active record whose `resets_at` is at or before projection time is not
   effective. A later runtime may clear or remove it, but projection never needs
   that write to stop blocking lanes.

Status producers may add a top-level `host_limits` array containing at most one
record per logical key. A consumer derives `blocked-on-limit` for a lane when at
least one effective record exactly matches the lane's `(workspace, machine,
host)`. Scope describes the shared limiting window; it is not copied into every
lane. This addition is optional and additive to the existing `/v1/state` and CLI
status contracts.

## Consequences

- Positive, negative, and replay fixtures live beside the schema. The replay
  proves two lanes on one machine and host derive one shared effective record.
- Breaking changes to key or field semantics require `schema/state/v2`; additive
  optional fields may extend v1.
- This foundation does not add reporting commands, persistence routes, provider
  message parsing, private quota APIs, or dashboard behavior.
- Account identifiers, account rotation or pooling, and mechanisms intended to
  evade vendor caps are forbidden by the contract boundary.
- Runtime work must verify the currently `UNKNOWN` provider facts before
  implementing host-message, hook, or probe producers.
