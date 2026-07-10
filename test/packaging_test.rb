# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rubygems"
require "rubygems/package"
require "tmpdir"

class PackagingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GEMSPEC = File.join(ROOT, "agent-coordination.gemspec")
  PACKAGE_FILES = %w[
    CHANGELOG.md
    LICENSE
    README.md
    bin/agent-coord
    docs/protocol-curl.md
  ].freeze

  def build_gem(tmpdir)
    gem_file = File.join(tmpdir, "agent-coordination.gem")
    stdout, stderr, status = Open3.capture3("gem", "build", GEMSPEC, "--output", gem_file, chdir: ROOT)
    assert status.success?, "gem build failed:\n#{stdout}\n#{stderr}"
    gem_file
  end

  def unbundled_env
    ENV.each_key.filter_map do |name|
      [name, nil] if name.start_with?("BUNDLE", "BUNDLER") || %w[RUBYLIB RUBYOPT].include?(name)
    end.to_h
  end

  def install_gem(gem_file, tmpdir)
    gem_home = File.join(tmpdir, "gem-home")
    bin_dir = File.join(tmpdir, "bin")
    stdout, stderr, status = Open3.capture3(
      "gem", "install", "--local", gem_file, "--ignore-dependencies", "--no-document",
      "--env-shebang", "--install-dir", gem_home, "--bindir", bin_dir
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

  def test_built_gem_installs_agent_coord_executable
    Dir.mktmpdir("agent-coordination-package") do |tmpdir|
      gem_file = build_gem(tmpdir)
      gem_home, executable = install_gem(gem_file, tmpdir)
      assert File.executable?(executable), "installed gem did not provide agent-coord"

      gem_path = ([gem_home] + Gem.path).join(File::PATH_SEPARATOR)
      stdout, stderr, status = Open3.capture3(
        unbundled_env.merge(
          "GEM_HOME" => gem_home,
          "GEM_PATH" => gem_path,
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
    assert_includes readme, "has not been published"
    assert_includes readme, "[Changelog](CHANGELOG.md)"
    assert_includes readme, "[Worker state protocol with `curl`](docs/protocol-curl.md)"
  end

  def test_ruby_floor_is_enforced_by_lint_and_ci
    rubocop_config = File.read(File.join(ROOT, ".rubocop.yml"))
    ci_workflow = File.read(File.join(ROOT, ".github/workflows/ci.yml"))

    assert_match(/^  TargetRubyVersion: 3\.2$/, rubocop_config)
    assert_includes ci_workflow, 'ruby-version: ["3.2", ".ruby-version"]'
    assert_includes ci_workflow, 'ruby-version: ${{ matrix.ruby-version }}'
  end
end
