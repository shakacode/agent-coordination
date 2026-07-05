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
end
