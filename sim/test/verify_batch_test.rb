# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/local_coordination_env"

class VerifyBatchTest < Minitest::Test
  VERIFY = File.expand_path("../bin/verify-batch", __dir__)
  ROOT = File.expand_path("../..", __dir__)
  HARVEST = File.join(ROOT, "bin", "agent-coord-harvest")
  TELEMETRY_FIXTURE = File.join(ROOT, "test", "fixtures", "telemetry", "coordination.json")

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
        local_coordination_env(state), VERIFY, "--repo-slug", "sim/verify"
      )
      assert_equal 0, status.exitstatus, stdout
      assert_includes stdout, "SCORE 3/3"
    end
  end

  # Open3 tags a capture with Encoding.default_external, so under LC_ALL=C the
  # UTF-8 JSON agent-coord writes came back labelled US-ASCII. One non-ASCII byte
  # anywhere in the batch -- an accented agent id, an em dash in a branch name --
  # then crashed this verifier's JSON.parse with
  # Encoding::InvalidByteSequenceError before it could score a single row, so a
  # green batch was indistinguishable from a broken one.
  def test_non_ascii_claim_fields_score_under_an_ascii_locale
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end
      write(
        state, "claims/sim/verify/task_two.json",
        released_claim("task_two").merge("agent_id" => "w-café", "branch" => "sim/task_two—w")
      )
      stdout, stderr, status = Open3.capture3(
        local_coordination_env(state).merge("LC_ALL" => "C", "LANG" => "C"),
        VERIFY, "--repo-slug", "sim/verify"
      )
      assert_equal 0, status.exitstatus, stderr
      refute_includes stderr, "Encoding::InvalidByteSequenceError"
      assert_includes stdout, "SCORE 3/3"
      assert_includes stdout.dup.force_encoding(Encoding::UTF_8), "branch=sim/task_two—w"
    end
  end

  def test_non_ascii_manifest_fields_score_under_ascii_and_utf8_locales
    issues = %w[task_one task_two task_three].map do |key|
      { "key" => key, "title" => "#{key} — café" }
    end

    with_verify_manifest(issues) do |verify|
      Dir.mktmpdir do |state|
        issues.each do |issue|
          target = issue.fetch("key")
          write(state, "claims/sim/verify/#{target}.json", released_claim(target))
        end

        %w[C C.UTF-8].each do |locale|
          stdout, stderr, status = Open3.capture3(
            local_coordination_env(state).merge("LC_ALL" => locale, "LANG" => locale),
            verify, "--repo-slug", "sim/verify"
          )
          assert_equal 0, status.exitstatus, "#{locale}:\n#{stdout}\n#{stderr}"
          refute_includes stderr, "Encoding::InvalidByteSequenceError", locale
          assert_includes stdout, "SCORE 3/3", locale
        end
      end
    end
  end

  def test_invalid_utf8_manifest_still_fails_closed
    invalid_manifest = "{\"issues\":[{\"key\":\"task_\xFF\",\"title\":\"bad key\"}]}".b

    with_verify_manifest([], manifest_bytes: invalid_manifest) do |verify|
      Dir.mktmpdir do |state|
        write(state, "claims/sim/verify/task_one.json", released_claim("task_one"))
        stdout, stderr, status = Open3.capture3(
          local_coordination_env(state).merge("LC_ALL" => "C", "LANG" => "C"),
          verify, "--repo-slug", "sim/verify"
        )
        assert_equal 1, status.exitstatus
        assert_includes stderr, "simulation issue manifest is not valid UTF-8"
        refute_includes stdout, "PASS"
        refute_includes stdout, "SCORE"
      end
    end
  end

  def test_valid_rows_do_not_hide_invalid_utf8_in_an_unused_title
    invalid_manifest = <<~JSON.b
      {"issues":[{"key":"task_one","title":"valid"},{"key":"task_unused","title":"bad \xFF"}]}
    JSON

    with_verify_manifest([], manifest_bytes: invalid_manifest) do |verify|
      Dir.mktmpdir do |state|
        %w[task_one task_unused].each do |target|
          write(state, "claims/sim/verify/#{target}.json", released_claim(target))
        end
        stdout, stderr, status = Open3.capture3(
          local_coordination_env(state).merge("LC_ALL" => "C", "LANG" => "C"),
          verify, "--repo-slug", "sim/verify"
        )
        assert_equal 1, status.exitstatus
        assert_includes stderr, "simulation issue manifest is not valid UTF-8"
        refute_includes stdout, "PASS"
        refute_includes stdout, "SCORE"
      end
    end
  end

  def test_missing_claim_fails_that_row
    Dir.mktmpdir do |state|
      write(state, "claims/sim/verify/task_one.json", released_claim("task_one"))
      stdout, _stderr, status = Open3.capture3(
        local_coordination_env(state), VERIFY, "--repo-slug", "sim/verify"
      )
      assert_equal 1, status.exitstatus
      assert_includes stdout, "FAIL task_two"
      assert_includes stdout, "SCORE 1/3"
    end
  end

  def test_optional_telemetry_ledger_prints_aggregate_batch_scorecard
    Dir.mktmpdir do |dir|
      state = File.join(dir, "state")
      ledger = File.join(dir, "telemetry.sqlite3")
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end
      harvest_out, harvest_err, harvest_status = Open3.capture3(
        HARVEST, "harvest", "--ledger", ledger,
        "--coordination-json", TELEMETRY_FIXTURE, "--batch-id", "batch-fixture"
      )
      assert harvest_status.success?, "harvest failed:\n#{harvest_out}\n#{harvest_err}"

      stdout, stderr, status = Open3.capture3(
        local_coordination_env(state),
        VERIFY, "--repo-slug", "sim/verify",
        "--telemetry-ledger", ledger, "--batch-id", "batch-fixture"
      )
      assert_equal 0, status.exitstatus, stderr
      assert_includes stdout,
                      "TELEMETRY batch=batch-fixture target_units=2 cost_microusd=0 unknown_cost_sessions=0"
      assert_includes stdout, "SCORE 3/3"
    end
  end

  def test_live_mode_queries_pr_by_claim_branch
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end

      with_fake_gh do |env, log|
        stdout, _stderr, status = Open3.capture3(
          local_coordination_env(state).merge(env),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 0, status.exitstatus, stdout
        assert_includes stdout, "pr=https://example.test/sim/task_one-w ci=pass"
        assert_includes File.read(log), "pr list --repo sim/verify --state open --head sim/task_one-w"
      end
    end
  end

  def test_live_mode_fails_pending_checks
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end

      with_fake_gh(check_buckets: ["pending"]) do |env, _log|
        stdout, _stderr, status = Open3.capture3(
          local_coordination_env(state).merge(env),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 1, status.exitstatus
        assert_includes stdout, "CI not passing (pending)"
      end
    end
  end

  def test_live_mode_fails_cancelled_or_empty_checks
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end

      with_fake_gh(check_buckets: ["cancel"]) do |env, _log|
        stdout, _stderr, status = Open3.capture3(
          local_coordination_env(state).merge(env),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 1, status.exitstatus
        assert_includes stdout, "CI not passing (cancel)"
      end

      with_fake_gh(check_buckets: []) do |env, _log|
        stdout, _stderr, status = Open3.capture3(
          local_coordination_env(state).merge(env),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 1, status.exitstatus
        assert_includes stdout, "CI not passing (none)"
      end
    end
  end

  def test_live_mode_handles_non_json_check_output
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end

      with_fake_gh(checks_stdout: "not json", checks_exit: 8) do |env, _log|
        stdout, _stderr, status = Open3.capture3(
          local_coordination_env(state).merge(env),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 1, status.exitstatus
        assert_includes stdout, "gh pr checks failed: invalid JSON"
        assert_includes stdout, "SCORE 0/3"
      end
    end
  end

  def test_live_mode_falls_back_to_latest_pr_when_no_open_pr_exists
    Dir.mktmpdir do |state|
      %w[task_one task_two task_three].each do |target|
        write(state, "claims/sim/verify/#{target}.json", released_claim(target))
      end

      with_fake_gh(open_empty: true, multi_prs: true) do |env, _log|
        stdout, _stderr, status = Open3.capture3(
          local_coordination_env(state).merge(env),
          VERIFY, "--repo-slug", "sim/verify", "--live"
        )
        assert_equal 0, status.exitstatus, stdout
        assert_includes stdout, "pr=https://example.test/new/sim/task_one-w ci=pass"
      end
    end
  end

  # Six of these tests hand Dir.mktmpdir's own root in as the state root, so a
  # config home derived from the state root's parent landed in the shared OS
  # temp root instead of inside the tree the test owns.
  def test_local_coordination_env_confines_the_config_home_to_the_test_tmp_tree
    Dir.mktmpdir do |root|
      nested = File.join(root, "state")
      FileUtils.mkdir_p(nested)

      [root, nested].each do |state|
        config_home = local_coordination_env(state).fetch("XDG_CONFIG_HOME")

        assert_operator config_home, :start_with?, "#{root}#{File::SEPARATOR}",
                        "config home escaped the test tmp root for state root #{state}"
        refute_equal File.dirname(root), File.dirname(config_home),
                     "config home landed in the shared OS temp root for state root #{state}"
      end
    end
  end

  private

  # XDG_CONFIG_HOME has to point at a directory this test owns so an ambient
  # developer config cannot reach the CLI. Deriving it from the state root's
  # *parent* only worked when the caller nested the state root: most callers
  # pass the Dir.mktmpdir root itself, so the config home landed in the shared
  # OS temp root instead of inside the test tree. Derive it from the state root
  # itself, which every caller owns by construction. The leaf is never created
  # (agent-coord only reads config) and is outside every coordination state
  # prefix, so it cannot be mistaken for state.
  def local_coordination_env(state)
    LocalCoordinationEnv::SCRUBBED_VARIABLES.merge(
      "AGENT_COORD_STATE_ROOT" => state,
      "XDG_CONFIG_HOME" => config_home_for(state),
      "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
    )
  end

  def config_home_for(state)
    File.join(state, ".xdg-config")
  end

  def with_verify_manifest(issues, manifest_bytes: nil)
    Dir.mktmpdir do |root|
      sim_root = File.join(root, "sim")
      verify = File.join(sim_root, "bin", "verify-batch")
      cli = File.join(root, "bin", "agent-coord")
      FileUtils.mkdir_p(File.dirname(verify))
      FileUtils.mkdir_p(File.dirname(cli))
      FileUtils.cp(VERIFY, verify)
      File.binwrite(
        File.join(sim_root, "issues.json"),
        manifest_bytes || JSON.generate("issues" => issues)
      )
      File.write(cli, <<~RUBY)
        #!/usr/bin/env ruby
        require "rbconfig"
        exec RbConfig.ruby, #{File.join(ROOT, 'bin', 'agent-coord').dump}, *ARGV
      RUBY
      FileUtils.chmod(0o755, verify)
      FileUtils.chmod(0o755, cli)
      yield verify
    end
  end

  def with_fake_gh(check_buckets: ["pass"], checks_stdout: nil, checks_exit: nil, open_empty: false, multi_prs: false)
    Dir.mktmpdir do |dir|
      log = File.join(dir, "gh.log")
      gh = File.join(dir, "gh")
      File.write(gh, fake_gh_script)
      FileUtils.chmod(0o755, gh)
      env = {
        "PATH" => [dir, File.dirname(RbConfig.ruby), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "GH_ARGS_LOG" => log,
        "GH_CHECK_BUCKETS" => check_buckets.join(","),
        "GH_OPEN_EMPTY" => open_empty ? "1" : "0",
        "GH_MULTI_PRS" => multi_prs ? "1" : "0"
      }
      env["GH_CHECKS_STDOUT"] = checks_stdout if checks_stdout
      env["GH_CHECKS_EXIT"] = checks_exit.to_s if checks_exit
      yield env, log
    end
  end

  def fake_gh_script
    <<~'RUBY'
      #!/usr/bin/env ruby
      require "json"

      File.open(ENV.fetch("GH_ARGS_LOG"), "a") { |file| file.puts ARGV.join(" ") }
      if ARGV[0, 2] == ["pr", "list"]
        head = ARGV[ARGV.index("--head") + 1]
        state = ARGV[ARGV.index("--state") + 1]
        if state == "open" && ENV.fetch("GH_OPEN_EMPTY", "0") == "1"
          puts JSON.generate([])
        elsif ENV.fetch("GH_MULTI_PRS", "0") == "1"
          puts JSON.generate([
            { "url" => "https://example.test/old/#{head}", "headRefName" => head, "number" => 10 },
            { "url" => "https://example.test/new/#{head}", "headRefName" => head, "number" => 43 }
          ])
        else
          puts JSON.generate([{ "url" => "https://example.test/#{head}", "headRefName" => head, "number" => 42 }])
        end
      elsif ARGV[0, 2] == ["pr", "checks"]
        if ENV["GH_CHECKS_STDOUT"]
          puts ENV.fetch("GH_CHECKS_STDOUT")
          exit ENV.fetch("GH_CHECKS_EXIT", "8").to_i
        end
        buckets = ENV.fetch("GH_CHECK_BUCKETS", "pass").split(",")
        puts JSON.generate(buckets.map { |bucket| { "bucket" => bucket } })
        exit(buckets == ["pass"] ? 0 : 8)
      else
        warn "unexpected gh args: #{ARGV.join(' ')}"
        exit 2
      end
    RUBY
  end
end
