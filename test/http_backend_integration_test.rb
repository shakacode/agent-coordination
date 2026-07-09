# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "net/http"
require "open3"
require "uri"

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

  def test_scoped_machine_token_enforces_path_prefix_and_records_writer
    scoped_token = ENV.fetch("SCOPED_AGENT_COORD_API_TOKEN")
    allowed_prefix = ENV.fetch("SCOPED_CLAIM_PREFIX")
    allowed_path = "#{allowed_prefix}/300.json"
    denied_path = "claims/shakacode/outside/300.json"

    code, body = http_json(
      "PUT",
      state_path(allowed_path),
      token: scoped_token,
      headers: { "If-None-Match" => "*" },
      body: { "data" => { "schema_version" => 1, "agent_id" => "scoped-worker" } }
    )
    assert_equal 201, code
    assert_equal "scoped", body.fetch("updated_by")

    code, body = http_json("GET", state_path(allowed_path), token: scoped_token)
    assert_equal 200, code
    assert_equal "scoped", body.fetch("updated_by")

    code, body = http_json("GET", "/v1/state?#{URI.encode_www_form('prefix' => allowed_prefix)}", token: scoped_token)
    assert_equal 200, code
    entry = body.fetch("entries").find { |candidate| candidate.fetch("path") == allowed_path }
    assert_equal "scoped", entry.fetch("updated_by")

    code, body = http_json("GET", "/v1/state?prefix=claims", token: scoped_token)
    assert_equal 403, code
    assert_equal "forbidden", body.fetch("error")

    code, body = http_json("GET", state_path(denied_path), token: scoped_token)
    assert_equal 403, code
    assert_equal "forbidden", body.fetch("error")

    code, body = http_json(
      "PUT",
      state_path(denied_path),
      token: scoped_token,
      headers: { "If-None-Match" => "*" },
      body: { "data" => { "schema_version" => 1, "agent_id" => "scoped-worker" } }
    )
    assert_equal 403, code
    assert_equal "forbidden", body.fetch("error")
  end

  private

  def state_path(path)
    "/v1/state/#{URI.encode_www_form_component(path)}"
  end

  def http_json(method, path, token:, headers: {}, body: nil)
    uri = URI("#{ENV.fetch('AGENT_COORD_API_URL')}#{path}")
    request_class = {
      "GET" => Net::HTTP::Get,
      "PUT" => Net::HTTP::Put
    }.fetch(method)
    request = request_class.new(uri)
    request["Authorization"] = "Bearer #{token}"
    headers.each { |key, value| request[key] = value }
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end

    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
      http.request(request)
    end
    [response.code.to_i, JSON.parse(response.body)]
  end
end
