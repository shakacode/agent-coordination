# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class GraveyardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GRAVEYARD = File.join(ROOT, "sim", "bin", "graveyard")

  def test_graveyard_replays_dry_run_execute_and_idempotence
    stdout, stderr, status = Open3.capture3("ruby", GRAVEYARD)

    assert status.success?, stderr
    assert_equal "GRAVEYARD_OK archive=4 hot_claims=1 replay_actions=0\n", stdout
  end
end
