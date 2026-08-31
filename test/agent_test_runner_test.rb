# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class AgentTestRunnerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNNER = File.join(ROOT, ".agents/bin/test")

  def test_runner_discards_backend_credentials_and_uses_ephemeral_local_state
    Dir.mktmpdir("agent-test-runner") do |tmpdir|
      fixture = prepare_runner(tmpdir)
      stdout, stderr, status = Open3.capture3(fixture.fetch(:env), RUNNER, chdir: ROOT)
      assert status.success?, "runner failed:\n#{stdout}\n#{stderr}"
      assert_isolated_state(fixture)
    end
  end

  def test_runner_removes_ephemeral_state_after_test_failure
    Dir.mktmpdir("agent-test-runner") do |tmpdir|
      fixture = prepare_runner(tmpdir)
      fixture.fetch(:env)["AGENT_TEST_RUNNER_FAIL"] = "1"

      _stdout, _stderr, status = Open3.capture3(fixture.fetch(:env), RUNNER, chdir: ROOT)
      assert_equal 76, status.exitstatus
      assert_isolated_state(fixture)
    end
  end

  def test_ci_ruby_jobs_use_the_hermetic_test_runner
    workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml"), aliases: true)

    %w[test test-ruby-floor].each do |job_name|
      job = workflow.fetch("jobs").fetch(job_name)
      test_step = job.fetch("steps").find { |step| step.fetch("name", "") == "Run tests" }

      assert_equal ".agents/bin/test", test_step.fetch("run").strip, "#{job_name} bypasses the shared test seam"
    end
  end

  private

  def prepare_runner(tmpdir)
    fake_bin = File.join(tmpdir, "bin")
    capture_path = File.join(tmpdir, "state-roots")
    caller_state_root = File.join(tmpdir, "caller-state")
    FileUtils.mkdir_p([fake_bin, caller_state_root])
    install_fake_bundle(fake_bin)

    {
      capture_path: capture_path,
      caller_state_root: caller_state_root,
      env: {
        "PATH" => [fake_bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "BASH_ENV" => File::NULL,
        "ENV" => File::NULL,
        "AGENT_COORD_API_URL" => "https://backend.invalid",
        "AGENT_COORD_API_TOKEN" => "not-a-real-token",
        "AGENT_COORD_BACKEND" => "shared/legacy-backend",
        "AGENT_COORD_STATE_ROOT" => caller_state_root,
        "AGENT_COORD_STATUS_STATE_ROOT" => caller_state_root,
        "AGENT_TEST_RUNNER_CALLER_STATE_ROOT" => caller_state_root,
        "AGENT_TEST_RUNNER_CAPTURE" => capture_path
      }
    }
  end

  def assert_isolated_state(fixture)
    state_roots = File.readlines(fixture.fetch(:capture_path), chomp: true)
    refute_empty state_roots
    assert_equal 1, state_roots.uniq.length
    refute_equal fixture.fetch(:caller_state_root), state_roots.first
    refute Dir.exist?(state_roots.first), "runner left its temporary state root behind"
  end

  def install_fake_bundle(fake_bin)
    bundle = File.join(fake_bin, "bundle")
    File.write(bundle, <<~SH)
      #!/bin/sh
      set -eu

      if [ "${AGENT_COORD_API_URL+x}" = x ]; then
        echo "AGENT_COORD_API_URL leaked into a test command" >&2
        exit 71
      fi
      if [ "${AGENT_COORD_API_TOKEN+x}" = x ]; then
        echo "AGENT_COORD_API_TOKEN leaked into a test command" >&2
        exit 72
      fi
      if [ "${AGENT_COORD_BACKEND+x}" = x ]; then
        echo "AGENT_COORD_BACKEND leaked into a test command" >&2
        exit 77
      fi
      if [ "${AGENT_COORD_STATUS_STATE_ROOT+x}" = x ]; then
        echo "AGENT_COORD_STATUS_STATE_ROOT leaked into a test command" >&2
        exit 75
      fi
      if [ ! -d "${AGENT_COORD_STATE_ROOT:-}" ]; then
        echo "AGENT_COORD_STATE_ROOT is not an isolated directory" >&2
        exit 73
      fi
      if [ "$AGENT_COORD_STATE_ROOT" = "$AGENT_TEST_RUNNER_CALLER_STATE_ROOT" ]; then
        echo "caller AGENT_COORD_STATE_ROOT leaked into a test command" >&2
        exit 74
      fi

      printf '%s\n' "$AGENT_COORD_STATE_ROOT" >> "$AGENT_TEST_RUNNER_CAPTURE"
      if [ "${AGENT_TEST_RUNNER_FAIL:-}" = 1 ]; then
        exit 76
      fi
    SH
    FileUtils.chmod(0o755, bundle)
  end
end
