# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities through GitHub's private vulnerability
reporting, not through a public issue, pull request, or discussion. Private
reporting keeps details out of public view until a fix is available.

1. Go to the [advisory form](https://github.com/shakacode/agent-coordination/security/advisories/new).
2. Or, from the repository: **Security** tab → **Report a vulnerability**.

Do not email a report. This project does not publish a security contact
address; the private advisory form is the only supported channel.

## Scope

In scope:

- The `agent-coord` CLI and its gem packaging.
- The Cloudflare Worker under `worker/`.
- The coordination HTTP backend, including its authentication and state
  handling.
- This repository's GitHub Actions workflows.

Out of scope:

- Findings that require an already-compromised machine or an
  already-trusted operator credential.
- Issues in third-party services themselves (GitHub, Cloudflare, RubyGems,
  and similar).

This project ingests untrusted public GitHub content by design (issue and
PR text, comments, and similar), so reports about that ingestion path are
especially welcome.

## Supported versions

There are no released versions yet: no tagged release and no published
gem. Only the latest `main` branch is supported. This section will be
updated with a version table once releases begin, per the versioning
policy in [CHANGELOG.md](CHANGELOG.md).

## Response expectations

This is a small maintainer team, so timelines are modest:

- Acknowledgement: within 3 business days of a report.
- Status update: at least every 7 business days until the report is
  resolved or closed.

These are response timeframes, not a fix commitment; a timeline for any
fix depends on severity and complexity.
