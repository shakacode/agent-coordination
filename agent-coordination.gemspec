# frozen_string_literal: true

version_source = File.read(File.expand_path("bin/agent-coord", __dir__))
version_match = version_source.match(/^\s*VERSION = "([^"]+)"$/)
raise "Could not find AgentCoord::VERSION in bin/agent-coord" unless version_match

Gem::Specification.new do |spec|
  spec.name = "agent-coordination"
  spec.version = version_match[1]
  spec.authors = ["ShakaCode"]
  spec.summary = "Coordinate concurrent agent work from the command line"
  spec.description = "The agent-coord CLI for local and HTTP-backed claims, heartbeats, batches, and events."
  spec.homepage = "https://github.com/shakacode/agent-coordination"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = %w[
    CHANGELOG.md
    LICENSE
    README.md
    bin/agent-coord
    contracts/state-schema-v2.json
    docs/adr/0007-host-limit-state-contract.md
    docs/adr/0008-capacity-reservation-state-contract.md
    docs/adr/0009-usage-record-state-contract.md
    docs/adr/0010-route-state-contract.md
    docs/adr/0011-merge-authority-state-contract.md
    docs/adr/0012-batch-completion-state-contract.md
    docs/adr/0013-batch-blocker-state-contract.md
    docs/protocol-curl.md
    schema/state/v1/batch-blocker/batch-blocker.schema.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-decision-not-string.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-empty-decision-string.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-empty-decisions.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-extra-field.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-message-empty.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-missing-blocker.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-missing-decisions.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-missing-message.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-missing-workspace.json
    schema/state/v1/batch-blocker/fixtures/invalid/blocker-null-recommended-reply.json
    schema/state/v1/batch-blocker/fixtures/replay/blocker-panel-render.json
    schema/state/v1/batch-blocker/fixtures/valid/blocker-full.json
    schema/state/v1/batch-blocker/fixtures/valid/blocker-no-recommended-reply.json
    schema/state/v1/batch-completion/batch-completion.schema.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-audit-version-field.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-bad-verdict.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-baseline-missing-path.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-empty-receipts.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-fabricated-tokens-string.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-missing-audit.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-missing-final-report.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-missing-state-live.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-missing-workspace.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-negative-duration.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-null-final-report.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-omitted-tokens-total.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-outcome-link-missing-href.json
    schema/state/v1/batch-completion/fixtures/invalid/completion-outcome-unknown-field.json
    schema/state/v1/batch-completion/fixtures/replay/completion-drawer-render.json
    schema/state/v1/batch-completion/fixtures/valid/completion-full.json
    schema/state/v1/batch-completion/fixtures/valid/completion-minimal-archive-ready.json
    schema/state/v1/batch-completion/fixtures/valid/completion-outcomes-plain-text.json
    schema/state/v1/batch-completion/fixtures/valid/completion-verdict-findings.json
    schema/state/v1/capacity-reservation/capacity-profile.schema.json
    schema/state/v1/capacity-reservation/capacity-reservation.schema.json
    schema/state/v1/capacity-reservation/fixtures/invalid/capacity-profile-zero.json
    schema/state/v1/capacity-reservation/fixtures/invalid/capacity-reservation-batch-id-too-long.json
    schema/state/v1/capacity-reservation/fixtures/invalid/capacity-reservation-batch-id-unrepresentable.json
    schema/state/v1/capacity-reservation/fixtures/invalid/capacity-reservation-both-attempt-scopes.json
    schema/state/v1/capacity-reservation/fixtures/invalid/capacity-reservation-consumed-no-at.json
    schema/state/v1/capacity-reservation/fixtures/invalid/capacity-reservation-ttl-too-low.json
    schema/state/v1/capacity-reservation/fixtures/invalid/inbox-unknown-status.json
    schema/state/v1/capacity-reservation/fixtures/invalid/lane-occupancy-blocked-no-reason.json
    schema/state/v1/capacity-reservation/fixtures/procedural/reservation-batch-lane-mismatch.json
    schema/state/v1/capacity-reservation/fixtures/procedural/reservation-duplicate-lane-ref.json
    schema/state/v1/capacity-reservation/fixtures/procedural/reservation-expiry-mismatch.json
    schema/state/v1/capacity-reservation/fixtures/procedural/reservations-duplicate-active-lane-ref.json
    schema/state/v1/capacity-reservation/fixtures/replay/exact-fit-and-one-over.json
    schema/state/v1/capacity-reservation/fixtures/replay/ownership-ttl-partial-release.json
    schema/state/v1/capacity-reservation/fixtures/replay/release-vs-new-reserve.json
    schema/state/v1/capacity-reservation/fixtures/replay/ttl-capacity-boundary.json
    schema/state/v1/capacity-reservation/fixtures/replay/two-planners-one-slot.json
    schema/state/v1/capacity-reservation/fixtures/valid/capacity-profile-enabled.json
    schema/state/v1/capacity-reservation/fixtures/valid/capacity-reservation-active.json
    schema/state/v1/capacity-reservation/fixtures/valid/capacity-reservation-partial-consume.json
    schema/state/v1/capacity-reservation/fixtures/valid/inbox-enabled.json
    schema/state/v1/capacity-reservation/fixtures/valid/lane-occupancy-blocked.json
    schema/state/v1/capacity-reservation/inbox.schema.json
    schema/state/v1/capacity-reservation/lane-occupancy.schema.json
    schema/state/v1/fixtures/invalid/host-limit-active-with-cleared-at.json
    schema/state/v1/fixtures/invalid/host-limit-cleared-without-cleared-at.json
    schema/state/v1/fixtures/invalid/host-limit-malformed-observed-at.json
    schema/state/v1/fixtures/invalid/host-limit-noncanonical-host.json
    schema/state/v1/fixtures/procedural/host-limits-duplicate-logical-key.json
    schema/state/v1/fixtures/replay/two-lanes-one-host-limit.json
    schema/state/v1/fixtures/valid/host-limit-active.json
    schema/state/v1/fixtures/valid/host-limit-cleared.json
    schema/state/v1/host-limit.schema.json
    schema/state/v1/merge-authority/fixtures/invalid/merge-authority-launch-verbose.json
    schema/state/v1/merge-authority/fixtures/invalid/merge-authority-null.json
    schema/state/v1/merge-authority/fixtures/invalid/merge-authority-unknown-value.json
    schema/state/v1/merge-authority/fixtures/invalid/merge-authority-uppercase.json
    schema/state/v1/merge-authority/fixtures/invalid/merge-authority-wrong-type.json
    schema/state/v1/merge-authority/fixtures/replay/merge-authority-drawer.json
    schema/state/v1/merge-authority/fixtures/valid/merge-authority-absent.json
    schema/state/v1/merge-authority/fixtures/valid/merge-authority-ask.json
    schema/state/v1/merge-authority/fixtures/valid/merge-authority-auto.json
    schema/state/v1/merge-authority/fixtures/valid/merge-authority-none.json
    schema/state/v1/merge-authority/merge-authority.schema.json
    schema/state/v1/route/fixtures/invalid/route-null.json
    schema/state/v1/route/fixtures/invalid/route-object-empty-model.json
    schema/state/v1/route/fixtures/invalid/route-object-extra-field.json
    schema/state/v1/route/fixtures/invalid/route-object-missing-both.json
    schema/state/v1/route/fixtures/invalid/route-object-missing-effort.json
    schema/state/v1/route/fixtures/invalid/route-string-empty-part.json
    schema/state/v1/route/fixtures/invalid/route-string-extra-slash.json
    schema/state/v1/route/fixtures/invalid/route-string-no-effort.json
    schema/state/v1/route/fixtures/invalid/route-wrong-type.json
    schema/state/v1/route/fixtures/replay/route-chip-rendering.json
    schema/state/v1/route/fixtures/valid/route-absent.json
    schema/state/v1/route/fixtures/valid/route-compact-string.json
    schema/state/v1/route/fixtures/valid/route-structured.json
    schema/state/v1/route/route.schema.json
    schema/state/v1/usage/fixtures/invalid/usage-fabricated-string-metric.json
    schema/state/v1/usage/fixtures/invalid/usage-missing-model.json
    schema/state/v1/usage/fixtures/invalid/usage-negative-cost.json
    schema/state/v1/usage/fixtures/invalid/usage-negative-tokens.json
    schema/state/v1/usage/fixtures/invalid/usage-noncanonical-repo.json
    schema/state/v1/usage/fixtures/invalid/usage-nonusd-currency.json
    schema/state/v1/usage/fixtures/invalid/usage-omitted-metric.json
    schema/state/v1/usage/fixtures/invalid/usage-unknown-field.json
    schema/state/v1/usage/fixtures/procedural/usage-duplicate-logical-key.json
    schema/state/v1/usage/fixtures/replay/usage-all-unknown-batch.json
    schema/state/v1/usage/fixtures/replay/usage-by-model-aggregation.json
    schema/state/v1/usage/fixtures/valid/usage-known.json
    schema/state/v1/usage/fixtures/valid/usage-unknown-metrics.json
    schema/state/v1/usage/usage-record.schema.json
  ]
  spec.bindir = "bin"
  spec.executables = ["agent-coord"]

  spec.add_dependency "base64", ">= 0.1.1", "< 1.0"
end
