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
    docs/protocol-curl.md
    schema/state/v1/fixtures/invalid/host-limit-active-with-cleared-at.json
    schema/state/v1/fixtures/invalid/host-limit-cleared-without-cleared-at.json
    schema/state/v1/fixtures/invalid/host-limit-noncanonical-host.json
    schema/state/v1/fixtures/procedural/host-limits-duplicate-logical-key.json
    schema/state/v1/fixtures/replay/two-lanes-one-host-limit.json
    schema/state/v1/fixtures/valid/host-limit-active.json
    schema/state/v1/fixtures/valid/host-limit-cleared.json
    schema/state/v1/host-limit.schema.json
  ]
  spec.bindir = "bin"
  spec.executables = ["agent-coord"]

  spec.add_dependency "base64", ">= 0.1.1", "< 1.0"
end
