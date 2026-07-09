# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

CLI = File.expand_path("../bin/agent-coord", __dir__)
REPO = "shakacode/integration-#{Process.pid}".freeze

def cli(*)
  stdout, stderr, status = Open3.capture3("ruby", CLI, *)
  [status.exitstatus, stdout, stderr]
end

class HttpBackendIntegrationTest < Minitest::Test
  def test_full_claim_lifecycle_and_contention
    target = "100"
    code, out, err = cli("claim", "--agent-id", "w1", "--repo", REPO, "--target", target)
    assert_equal 0, code, "first claim failed: #{err}"
    assert_includes out, "claimed"

    # w1 heartbeats live -> w2 must be refused with exit 3
    code, = cli("heartbeat", "--agent-id", "w1", "--repo", REPO, "--target", target)
    assert_equal 0, code
    code, _, err = cli("claim", "--agent-id", "w2", "--repo", REPO, "--target", target)
    assert_equal 3, code
    assert_includes err, "CLAIM_REFUSED"

    # dead-holder takeover: a 1-second-TTL heartbeat is "dead" after 4 x ttl = 4s
    # (liveness rule: dead when now >= updated_at + 4*ttl). The claim itself is
    # still unexpired, so this exercises the heartbeat-dead takeover path, not
    # the claim-expiry fallback.
    code, = cli("heartbeat", "--agent-id", "w1", "--repo", REPO, "--target", target, "--ttl", "1")
    assert_equal 0, code
    sleep 8
    code, _, err = cli("claim", "--agent-id", "w2", "--repo", REPO, "--target", target)
    assert_equal 0, code, "dead-holder takeover failed: #{err}"

    # release parity check: a different worker can claim after the holder releases
    code, = cli("release", "--agent-id", "w2", "--repo", REPO, "--target", target)
    assert_equal 0, code
    code, = cli("claim", "--agent-id", "w3", "--repo", REPO, "--target", target)
    assert_equal 0, code

    code, out, = cli("status", "--repo", REPO, "--target", target, "--json")
    assert_equal 0, code
    payload = JSON.parse(out)
    assert_equal "w3", payload.fetch("claims").first.fetch("agent_id")
  end

  def test_concurrent_claims_have_exactly_one_winner
    target = "200"
    results = Array.new(4) { nil }
    threads = results.each_index.map do |i|
      Thread.new { results[i] = cli("claim", "--agent-id", "racer#{i}", "--repo", REPO, "--target", target).first }
    end
    threads.each(&:join)
    winners = results.count(0)
    assert_equal 1, winners, "expected exactly one winner, got exits #{results.inspect}"
    assert results.all? { |code| [0, 2, 3].include?(code) }, "unexpected exit in #{results.inspect}"
  end

  def test_batch_event_listing_escapes_like_wildcards
    batch = "batch_#{Process.pid}"
    neighbor = "batchX#{Process.pid}"

    code, = cli("record-event", "--batch-id", batch, "--type", "phase", "--lane", "docs")
    assert_equal 0, code
    code, = cli("record-event", "--batch-id", neighbor, "--type", "phase", "--lane", "docs")
    assert_equal 0, code

    code, out, err = cli("status", "--batch-id", batch, "--json")
    assert_equal 0, code, err
    events = JSON.parse(out).fetch("events")
    assert_equal([batch], events.map { |event| event.fetch("batch_id") })
  end
end
