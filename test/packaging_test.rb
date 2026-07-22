# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "rubygems"
require "rubygems/package"
require "tmpdir"
require "yaml"

class PackagingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GEMSPEC = File.join(ROOT, "agent-coordination.gemspec")
  PACKAGE_FILES = %w[
    CHANGELOG.md
    LICENSE
    README.md
    bin/agent-coord
    contracts/state-schema-v2.json
    docs/adr/0007-host-limit-state-contract.md
    docs/adr/0008-capacity-reservation-state-contract.md
    docs/adr/0009-usage-record-state-contract.md
    docs/protocol-curl.md
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
    schema/state/v1/usage/fixtures/invalid/usage-fabricated-string-metric.json
    schema/state/v1/usage/fixtures/invalid/usage-missing-model.json
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
  ].freeze

  def gem_command
    executable = Gem.win_platform? ? "gem.cmd" : "gem"
    File.join(File.dirname(RbConfig.ruby), executable)
  end

  def build_gem(tmpdir)
    gem_file = File.join(tmpdir, "agent-coordination.gem")
    build_gem_home = File.join(tmpdir, "build-gem-home")
    stdout, stderr, status = Open3.capture3(
      isolated_gem_env(build_gem_home, tmpdir),
      gem_command, "build", "--norc", GEMSPEC, "--output", gem_file, chdir: ROOT
    )
    assert status.success?, "gem build failed:\n#{stdout}\n#{stderr}"
    gem_file
  end

  def unbundled_env
    ENV.each_key.filter_map do |name|
      [name, nil] if name.start_with?("BUNDLE", "BUNDLER") || %w[RUBYLIB RUBYOPT].include?(name)
    end.to_h
  end

  def isolated_gem_env(gem_home, tmpdir)
    unbundled_env.merge(
      "GEM_HOME" => gem_home,
      "GEM_PATH" => [gem_home, Gem.default_dir].join(File::PATH_SEPARATOR),
      "HOME" => File.join(tmpdir, "home"),
      "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR),
      "XDG_CONFIG_HOME" => File.join(tmpdir, "xdg-config"),
      "RUBYGEMS_GEMDEPS" => nil
    )
  end

  def install_gem(gem_file, tmpdir)
    gem_home = File.join(tmpdir, "gem-home")
    bin_dir = File.join(tmpdir, "bin")
    stdout, stderr, status = Open3.capture3(
      isolated_gem_env(gem_home, tmpdir),
      gem_command, "install", "--norc", "--local", gem_file, "--no-document",
      "--env-shebang", "--bindir", bin_dir
    )
    assert status.success?, "gem install failed:\n#{stdout}\n#{stderr}"
    [gem_home, File.join(bin_dir, "agent-coord")]
  end

  def test_gemspec_declares_cli_package_contract
    spec = Gem::Specification.load(GEMSPEC)

    refute_nil spec
    assert_equal "agent-coordination", spec.name
    assert_equal Gem::Version.new("0.1.0"), spec.version
    assert_equal "MIT", spec.license
    assert_equal Gem::Requirement.new(">= 3.2"), spec.required_ruby_version
    assert_equal ["base64"], spec.runtime_dependencies.map(&:name)
  end

  def test_gem_command_uses_the_selected_ruby_runtime
    Dir.mktmpdir("agent-coordination-gem-runtime") do |tmpdir|
      gem_home = File.join(tmpdir, "gem-home")
      stdout, stderr, status = Open3.capture3(
        isolated_gem_env(gem_home, tmpdir), gem_command, "environment"
      )

      assert status.success?, "gem environment failed:\n#{stdout}\n#{stderr}"
      assert_match(/RUBY EXECUTABLE:\s+#{Regexp.escape(RbConfig.ruby)}/, stdout)
    end
  end

  def test_base64_requirement_supports_the_ruby_3_2_default_gem
    dependency = Gem::Specification.load(GEMSPEC).runtime_dependencies.find { |candidate| candidate.name == "base64" }

    assert dependency.requirement.satisfied_by?(Gem::Version.new("0.1.1")),
           "base64 requirement must accept the version bundled with Ruby 3.2"
  end

  def test_development_dependencies_keep_parallel_compatible_with_the_ruby_floor
    gemfile = File.read(File.join(ROOT, "Gemfile"))
    lockfile = File.read(File.join(ROOT, "Gemfile.lock"))

    assert_match(/^gem "parallel", "< 2", require: false$/, gemfile)
    locked_version = lockfile[/^    parallel \(([^)]+)\)$/, 1]
    refute_nil locked_version
    assert_operator Gem::Version.new(locked_version), :<, Gem::Version.new("2")
    assert_match(/^  parallel \(< 2\)$/, lockfile)
  end

  def test_built_gem_installs_agent_coord_executable
    Dir.mktmpdir("agent-coordination-package") do |tmpdir|
      gem_file = build_gem(tmpdir)
      gem_home, executable = install_gem(gem_file, tmpdir)
      assert File.executable?(executable), "installed gem did not provide agent-coord"

      stdout, stderr, status = Open3.capture3(
        isolated_gem_env(gem_home, tmpdir).merge(
          "AGENT_COORD_API_URL" => nil,
          "AGENT_COORD_API_TOKEN" => nil,
          "AGENT_COORD_BACKEND" => nil,
          "AGENT_COORD_STATE_ROOT" => nil,
          "AGENT_COORD_STATUS_STATE_ROOT" => nil
        ),
        executable, "version", "--json"
      )
      assert status.success?, "installed agent-coord failed:\n#{stdout}\n#{stderr}"
      assert_includes stdout, '"version": "0.1.0"'
      assert_empty stderr
    end
  end

  def test_changelog_has_only_an_unreleased_release_heading
    changelog_path = File.join(ROOT, "CHANGELOG.md")
    flunk "CHANGELOG.md is missing" unless File.file?(changelog_path)

    release_headings = File.read(changelog_path).scan(/^## \[(.+)\]$/).flatten
    assert_equal ["Unreleased"], release_headings
  end

  def test_unreleased_changelog_documents_zero_config_local_mode_and_demo
    changelog = File.read(File.join(ROOT, "CHANGELOG.md")).gsub(/\s+/, " ")

    assert_match(/zero-config local-store default.*single-machine/i, changelog)
    assert_match(/shared or multi-machine coordination.*explicit HTTP configuration/i, changelog)
    assert_match(/deterministic `agent-coord demo` walkthrough/i, changelog)
    assert_match(/demo.*does not write remote state/i, changelog)
  end

  def test_unreleased_added_changelog_documents_terminal_closeout_and_launch_prompt
    changelog = File.read(File.join(ROOT, "CHANGELOG.md"))
    added = changelog[/^## \[Unreleased\].*?^### Added\n\n(.*?)(?=^### |\z)/m, 1]

    refute_nil added
    added = added.gsub(/\s+/, " ")
    assert_match(/ordinary records remain v1.*`lane_closed`.*v2/i, added)
    assert_match(/`release --terminal`.*claim reconciliation.*batch completion/i, added)
    assert_match(/`register-batch --launch-prompt PATH\|-`.*files or stdin/i, added)
    assert_match(/launch prompt.*invalid input.*no state write/i, added)
  end

  def test_protocol_curl_walkthrough_uses_placeholders_and_worker_preconditions
    docs_path = File.join(ROOT, "docs/protocol-curl.md")
    flunk "docs/protocol-curl.md is missing" unless File.file?(docs_path)

    docs = File.read(docs_path)
    assert_includes docs, "https://<worker-host>"
    assert_includes docs, "<machine-token>"
    assert_includes docs, "/v1/health"
    assert_includes docs, "/v1/state"
    assert_includes docs, "Authorization: Bearer $AGENT_COORD_API_TOKEN"
    assert_includes docs, "If-None-Match: *"
    assert_includes docs, "If-Match: $STATE_VERSION"
    refute_match(%r{https://[A-Za-z0-9-]+\.[A-Za-z0-9.-]+}, docs)
  end

  def test_protocol_curl_walkthrough_creates_before_reading_and_updating
    docs = File.read(File.join(ROOT, "docs/protocol-curl.md"))
    create_position = docs.index("Create a record only")
    read_position = docs.index("Read one exact record")
    update_position = docs.index("Update an existing record")

    refute_nil create_position
    refute_nil read_position
    refute_nil update_position
    assert_operator create_position, :<, read_position
    assert_operator read_position, :<, update_position
  end

  def test_built_gem_contains_only_the_public_cli_distribution
    Dir.mktmpdir("agent-coordination-archive") do |tmpdir|
      package = Gem::Package.new(build_gem(tmpdir))

      assert_equal PACKAGE_FILES, package.contents.sort
      assert_equal PACKAGE_FILES, package.spec.files.sort
      assert_equal "https://github.com/shakacode/agent-coordination", package.spec.metadata.fetch("source_code_uri")
      assert_equal "https://github.com/shakacode/agent-coordination/blob/main/CHANGELOG.md",
                   package.spec.metadata.fetch("changelog_uri")
    end
  end

  def test_readme_documents_local_package_verification_without_publishing
    readme = File.read(File.join(ROOT, "README.md"))

    assert_includes readme, "Ruby 3.2 or newer"
    assert_includes readme, "gem build agent-coordination.gemspec"
    assert_includes readme, "gem install --local"
    assert_includes readme, "agent-coordination-VERSION.gem"
    assert_includes readme, "Replace `VERSION` with the version in the filename printed by `gem build`."
    refute_includes readme, "agent-coordination-0.1.0.gem"
    assert_includes readme, "has not been published"
    assert_includes readme, "[Changelog](CHANGELOG.md)"
    assert_includes readme, "[Worker state protocol with `curl`](docs/protocol-curl.md)"
  end

  def test_generated_gem_archives_are_ignored
    ignore_rules = File.readlines(File.join(ROOT, ".gitignore"), chomp: true)

    assert_includes ignore_rules, "*.gem"
  end

  def test_ruby_floor_is_enforced_by_lint_and_ci
    rubocop_config = File.read(File.join(ROOT, ".rubocop.yml"))
    ci_jobs = YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml"), aliases: true).fetch("jobs")
    canonical_job = ci_jobs.fetch("test")

    assert_match(/^  TargetRubyVersion: 3\.2$/, rubocop_config)
    refute canonical_job.key?("strategy"), "the canonical test check must keep its original job identity"
    canonical_setup = canonical_job.fetch("steps").find { |step| step.fetch("name", "") == "Set up Ruby" }
    assert_equal ".ruby-version", canonical_setup.fetch("with").fetch("ruby-version")

    floor_job = ci_jobs.fetch("test-ruby-floor")
    floor_setup = floor_job.fetch("steps").find { |step| step.fetch("name", "") == "Set up Ruby" }
    assert_equal "3.2", floor_setup.fetch("with").fetch("ruby-version")
    canonical_tests = canonical_job.fetch("steps").find { |step| step.fetch("name", "") == "Run tests" }
    floor_tests = floor_job.fetch("steps").find { |step| step.fetch("name", "") == "Run tests" }
    assert_equal canonical_tests.fetch("run"), floor_tests.fetch("run")
  end
end
