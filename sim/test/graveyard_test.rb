# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/local_coordination_env"

class GraveyardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GRAVEYARD = File.join(ROOT, "sim", "bin", "graveyard")

  def test_graveyard_replays_dry_run_execute_and_idempotence
    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(local_coordination_env(dir), "ruby", GRAVEYARD)

      assert status.success?, stderr
      assert_equal "GRAVEYARD_OK archive=4 hot_claims=1 replay_actions=0\n", stdout
    end
  end

  # agent-coord loads its canonical user config on every invocation, so an
  # ambient config the developer happens to have installed must not reach the
  # gc subprocesses of a purely --state-root-scoped replay.
  def test_graveyard_ignores_an_ambient_user_configuration
    Dir.mktmpdir do |dir|
      config_home = File.join(dir, "ambient-config")
      env_file = File.join(config_home, "agent-coord", "env")
      FileUtils.mkdir_p(File.dirname(env_file))
      File.write(env_file, "AGENT_COORD_POLICY=required\n")
      # Group-readable: agent-coord refuses to load this and exits 2.
      File.chmod(0o644, env_file)

      env = local_coordination_env(dir).merge("XDG_CONFIG_HOME" => config_home)
      stdout, stderr, status = Open3.capture3(env, "ruby", GRAVEYARD)

      assert status.success?, stderr
      assert_equal "GRAVEYARD_OK archive=4 hot_claims=1 replay_actions=0\n", stdout
    end
  end

  private

  def local_coordination_env(dir)
    LocalCoordinationEnv::SCRUBBED_VARIABLES.merge(
      "XDG_CONFIG_HOME" => File.join(dir, "xdg-config"),
      "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
    )
  end
end
