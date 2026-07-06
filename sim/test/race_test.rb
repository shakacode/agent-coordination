# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SIM_ROOT = File.expand_path("..", __dir__) unless defined?(SIM_ROOT)
WORKER = File.join(SIM_ROOT, "bin", "scripted-worker") unless defined?(WORKER)

class RaceTest < Minitest::Test
  def test_concurrent_workers_one_winner
    with_seeded_origin do |dir, state, origin|
      env = { "AGENT_COORD_STATE_ROOT" => state }
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
