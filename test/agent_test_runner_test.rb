# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class AgentTestRunnerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNNER = File.join(ROOT, ".agents/bin/test")

  def test_runner_discards_backend_credentials_and_uses_ephemeral_local_state
    Dir.mktmpdir("agent-test-runner") do |tmpdir|
      fake_bin = File.join(tmpdir, "bin")
      capture_path = File.join(tmpdir, "state-roots")
      caller_state_root = File.join(tmpdir, "caller-state")
      FileUtils.mkdir_p([fake_bin, caller_state_root])
      install_fake_bundle(fake_bin)

      env = {
        "PATH" => [fake_bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "BASH_ENV" => File::NULL,
        "ENV" => File::NULL,
        "AGENT_COORD_API_URL" => "https://backend.invalid",
        "AGENT_COORD_API_TOKEN" => "not-a-real-token",
        "AGENT_COORD_STATE_ROOT" => caller_state_root,
        "AGENT_TEST_RUNNER_CALLER_STATE_ROOT" => caller_state_root,
        "AGENT_TEST_RUNNER_CAPTURE" => capture_path
      }

      stdout, stderr, status = Open3.capture3(env, RUNNER, chdir: ROOT)
      assert status.success?, "runner failed:\n#{stdout}\n#{stderr}"

      state_roots = File.readlines(capture_path, chomp: true)
      refute_empty state_roots
      assert_equal 1, state_roots.uniq.length
      refute_equal caller_state_root, state_roots.first
      refute Dir.exist?(state_roots.first), "runner left its temporary state root behind"
    end
  end

  private

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
      if [ ! -d "${AGENT_COORD_STATE_ROOT:-}" ]; then
        echo "AGENT_COORD_STATE_ROOT is not an isolated directory" >&2
        exit 73
      fi
      if [ "$AGENT_COORD_STATE_ROOT" = "$AGENT_TEST_RUNNER_CALLER_STATE_ROOT" ]; then
        echo "caller AGENT_COORD_STATE_ROOT leaked into a test command" >&2
        exit 74
      fi

      printf '%s\n' "$AGENT_COORD_STATE_ROOT" >> "$AGENT_TEST_RUNNER_CAPTURE"
    SH
    FileUtils.chmod(0o755, bundle)
  end
end
