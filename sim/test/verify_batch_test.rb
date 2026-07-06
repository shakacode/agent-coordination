# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class VerifyBatchTest < Minitest::Test
  VERIFY = File.expand_path("../bin/verify-batch", __dir__)

  def write(state, path, data)
    full = File.join(state, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, JSON.pretty_generate(data))
  end

  def released_claim(target)
    {
      "schema_version" => 1,
      "repo" => "sim/verify",
      "target" => target,
      "agent_id" => "w-#{target}",
      "branch" => "sim/#{target}-w",
      "status" => "released",
      "claimed_at" => "2026-07-04T00:00:00Z",
      "updated_at" => "2026-07-04T00:10:00Z",
      "expires_at" => "2026-07-04T00:10:00Z"
    }
  end

  def test_all_released_claims_score_full
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end
      stdout, _stderr, status = Open3.capture3(
        { "AGENT_COORD_STATE_ROOT" => state }, VERIFY, "--repo-slug", "sim/verify"
      )
      assert_equal 0, status.exitstatus, stdout
      assert_includes stdout, "SCORE 3/3"
    end
  end

  def test_missing_claim_fails_that_row
    Dir.mktmpdir do |state|
      write(state, "claims/sim/verify/task_one.json", released_claim("task_one"))
      stdout, _stderr, status = Open3.capture3(
        { "AGENT_COORD_STATE_ROOT" => state }, VERIFY, "--repo-slug", "sim/verify"
      )
      assert_equal 1, status.exitstatus
      assert_includes stdout, "FAIL task_two"
      assert_includes stdout, "SCORE 1/3"
    end
  end

  def test_live_mode_queries_pr_by_claim_branch
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end

      with_fake_gh do |env, log|
        stdout, _stderr, status = Open3.capture3(
          env.merge("AGENT_COORD_STATE_ROOT" => state),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 0, status.exitstatus, stdout
        assert_includes stdout, "pr=https://example.test/sim/task_one-w ci=pass"
        assert_includes File.read(log), "pr list --repo sim/verify --state all --head sim/task_one-w"
      end
    end
  end

  def test_live_mode_fails_pending_checks
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end

      with_fake_gh(check_bucket: "pending") do |env, _log|
        stdout, _stderr, status = Open3.capture3(
          env.merge("AGENT_COORD_STATE_ROOT" => state),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 1, status.exitstatus
        assert_includes stdout, "CI not passing (pending)"
      end
    end
  end

  private

  def with_fake_gh(check_bucket: "pass")
    Dir.mktmpdir do |dir|
      log = File.join(dir, "gh.log")
      gh = File.join(dir, "gh")
      File.write(gh, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"

        File.open(ENV.fetch("GH_ARGS_LOG"), "a") { |file| file.puts ARGV.join(" ") }
        if ARGV[0, 2] == ["pr", "list"]
          head = ARGV[ARGV.index("--head") + 1]
          puts JSON.generate([{ "url" => "https://example.test/#{head}", "headRefName" => head, "number" => 42 }])
        elsif ARGV[0, 2] == ["pr", "checks"]
          bucket = ENV.fetch("GH_CHECK_BUCKET", "pass")
          puts JSON.generate([{ "bucket" => bucket }])
          exit(bucket == "pass" ? 0 : 8)
        else
          warn "unexpected gh args: #{ARGV.join(' ')}"
          exit 2
        end
      RUBY
      FileUtils.chmod(0o755, gh)
      env = {
        "PATH" => "#{dir}:#{ENV.fetch('PATH')}",
        "GH_ARGS_LOG" => log,
        "GH_CHECK_BUCKET" => check_bucket
      }
      yield env, log
    end
  end
end
