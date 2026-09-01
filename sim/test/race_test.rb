# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

SIM_ROOT = File.expand_path("..", __dir__) unless defined?(SIM_ROOT)
WORKER = File.join(SIM_ROOT, "bin", "scripted-worker") unless defined?(WORKER)

class RaceTest < Minitest::Test
  LOCAL_COORDINATION_ENV = {
    "AGENT_COORD_API_URL" => nil,
    "AGENT_COORD_API_TOKEN" => nil,
    "AGENT_COORD_BACKEND" => nil,
    "AGENT_COORD_ENV_FILE" => nil,
    "AGENT_COORD_LOCAL" => nil,
    "AGENT_COORD_MACHINE_ID" => nil,
    "AGENT_COORD_POLICY" => nil,
    "AGENT_COORD_REF" => nil,
    "AGENT_COORD_SESSION_ID" => nil,
    "AGENT_COORD_STATE_ROOT" => nil,
    "AGENT_COORD_STATUS_STATE_ROOT" => nil,
    "CODEX_THREAD_ID" => nil
  }.freeze

  # Every simulator-local environment must scrub both backend selectors and
  # ambient identity. Otherwise a developer's Codex task ID becomes the
  # simulator's session ID and makes supposedly deterministic records vary.
  def test_every_local_coordination_env_scrubs_backend_and_identity
    %w[AGENT_COORD_API_URL AGENT_COORD_STATE_ROOT AGENT_COORD_BACKEND].each do |key|
      assert LOCAL_COORDINATION_ENV.key?(key), "#{key} is not neutralized"
      assert_nil LOCAL_COORDINATION_ENV.fetch(key)
    end

    files = %w[
      bin/graveyard
      test/graveyard_test.rb
      test/race_test.rb
      test/scripted_worker_test.rb
      test/verify_batch_test.rb
    ]
    required = %w[
      AGENT_COORD_MACHINE_ID
      AGENT_COORD_SESSION_ID
      CODEX_THREAD_ID
    ]

    files.each do |relative_path|
      source = File.read(File.join(SIM_ROOT, relative_path))
      table = source[/LOCAL_COORDINATION_ENV = \{.*?\}\.freeze/m]
      refute_nil table, "#{relative_path} has no LOCAL_COORDINATION_ENV table"
      required.each do |key|
        assert_includes table, %("#{key}" => nil), "#{relative_path} does not neutralize #{key}"
      end
    end
  end

  def test_concurrent_workers_one_winner
    with_seeded_origin do |dir, state, origin|
      env = LOCAL_COORDINATION_ENV.merge(
        "AGENT_COORD_STATE_ROOT" => state,
        "XDG_CONFIG_HOME" => File.join(dir, "xdg-config"),
        "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
      )
      results = Array.new(3)
      threads = results.each_index.map do |i|
        Thread.new do
          _stdout, _stderr, status = Open3.capture3(
            env, WORKER, "--agent-id", "racer#{i}", "--repo-slug", "sim/race",
            "--clone-url", origin, "--issue-key", "task_two",
            "--workdir", File.join(dir, "work#{i}")
          )
          results[i] = status.exitstatus
        end
      end
      threads.each(&:join)

      assert_equal 1, results.count(0), "exactly one winner expected, got #{results.inspect}"
      assert results.all? { |code| [0, 2, 3].include?(code) }, "unexpected exits: #{results.inspect}"
      branches = `git --git-dir=#{origin} branch --list`.lines.map(&:strip).grep(%r{^sim/})
      assert_equal 1, branches.length, "exactly one sim branch expected, got #{branches.inspect}"
    end
  end

  private

  def with_seeded_origin
    Dir.mktmpdir do |dir|
      state = File.join(dir, "state").tap { |path| Dir.mkdir(path) }
      origin = File.join(dir, "origin.git")
      system("git", "init", "-q", "--bare", origin, exception: true)
      seed_origin(dir, origin)
      yield dir, state, origin
    end
  end

  def seed_origin(dir, origin)
    seed = File.join(dir, "seed")
    FileUtils.cp_r(File.join(SIM_ROOT, "template", "."), seed)
    Dir.chdir(seed) do
      system("git init -q -b main && " \
             "git config user.name 'agent-coord sim test' && " \
             "git config user.email 'agent-coord-sim@example.invalid' && " \
             "git add -A && git commit -qm seed && " \
             "git remote add origin #{origin} && git push -q origin main", exception: true)
    end
  end
end
