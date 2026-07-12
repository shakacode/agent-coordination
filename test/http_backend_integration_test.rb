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
    case_neighbor = "Batch_#{Process.pid}"

    code, = cli("record-event", "--batch-id", batch, "--type", "phase", "--lane", "docs")
    assert_equal 0, code
    code, = cli("record-event", "--batch-id", neighbor, "--type", "phase", "--lane", "docs")
    assert_equal 0, code
    code, = cli("record-event", "--batch-id", case_neighbor, "--type", "phase", "--lane", "docs")
    assert_equal 0, code

    code, out, err = cli("status", "--batch-id", batch, "--json")
    assert_equal 0, code, err
    events = JSON.parse(out).fetch("events")
    assert_equal([batch], events.map { |event| event.fetch("batch_id") })
  end

  def test_gc_has_local_equivalent_archive_and_purge_semantics_over_http
    token = ENV.fetch("AGENT_COORD_API_TOKEN")
    target = "gc-#{Process.pid}"
    source_path = "claims/shakacode/integration-#{Process.pid}/#{target}.json"
    archive_path = "archive/#{source_path}"
    code, body = http_json(
      "PUT", state_path(source_path), token: token, headers: { "If-None-Match" => "*" },
                                      body: {
                                        "data" => {
                                          "schema_version" => 1,
                                          "repo" => REPO,
                                          "target" => target,
                                          "agent_id" => "gc-worker",
                                          "status" => "released",
                                          "terminal" => "done",
                                          "updated_at" => "2000-01-01T00:00:00Z"
                                        }
                                      }
    )
    assert_equal 201, code, body.inspect

    cli_code, output, error = cli("gc", "--execute", "--json")
    assert_equal 0, cli_code, error
    assert(JSON.parse(output).fetch("actions").any? { |action| action["archive_path"] == archive_path })
    code, body = http_json("GET", state_path(source_path), token: token)
    assert_equal 404, code
    assert_equal "not_found", body.fetch("error")
    code, body = http_json("GET", state_path(archive_path), token: token)
    assert_equal 200, code
    archived = body.fetch("data")
    assert_equal "archived_record", archived.fetch("record_family")

    archived["delete_after"] = "2000-01-02T00:00:00Z"
    code, = http_json(
      "PUT", state_path(archive_path), token: token, headers: { "If-Match" => body.fetch("version").to_s },
                                       body: { "data" => archived }
    )
    assert_equal 200, code
    cli_code, = cli("gc", "--execute", "--json")
    assert_equal 0, cli_code
    code, body = http_json("GET", state_path(archive_path), token: token)
    assert_equal 404, code
    assert_equal "not_found", body.fetch("error")
  end

  def test_gc_can_archive_a_max_sized_active_record_over_http
    token = ENV.fetch("AGENT_COORD_API_TOKEN")
    target = "gc-large-#{Process.pid}"
    source_path = "claims/shakacode/integration-#{Process.pid}/#{target}.json"
    archive_path = "archive/#{source_path}"
    data = {
      "schema_version" => 1, "repo" => REPO, "target" => target, "agent_id" => "gc-worker",
      "status" => "released", "terminal" => "done", "updated_at" => "2000-01-01T00:00:00Z",
      "padding" => "x" * 261_930
    }
    assert_operator JSON.generate(data).bytesize, :<=, 256 * 1024
    assert_operator JSON.generate({ "data" => data }).bytesize, :>, 262_125

    code, body = http_json(
      "PUT", state_path(source_path), token: token, headers: { "If-None-Match" => "*" }, body: { "data" => data }
    )
    assert_equal 201, code, body.inspect

    cli_code, output, error = cli("gc", "--execute", "--json")
    assert_equal 0, cli_code, error
    assert(JSON.parse(output).fetch("actions").any? { |action| action["archive_path"] == archive_path })
    code, body = http_json("GET", state_path(archive_path), token: token)
    assert_equal 200, code
    assert_equal data, body.fetch("data").fetch("data")
  end

  def test_scoped_machine_token_enforces_path_prefix_and_records_writer
    scoped_token = ENV.fetch("SCOPED_AGENT_COORD_API_TOKEN")
    full_token = ENV.fetch("AGENT_COORD_API_TOKEN")
    allowed_prefix = ENV.fetch("SCOPED_CLAIM_PREFIX")
    secondary_prefix = ENV.fetch("SCOPED_SECONDARY_CLAIM_PREFIX")
    allowed_path = "#{allowed_prefix}/300.json"
    secondary_path = "#{secondary_prefix}/301.json"
    hidden_path = "claims/shakacode/hidden/301.json"
    mixed_case_hidden_path = "claims/ShakaCode/api.json/302.json"
    denied_path = "claims/shakacode/outside/300.json"

    assert_scoped_write(scoped_token, allowed_path)

    seed_full_token_claims(full_token, secondary_path, hidden_path, mixed_case_hidden_path)

    code, body = http_json("GET", state_path(allowed_path), token: scoped_token)
    assert_equal 200, code
    assert_equal "scoped", body.fetch("updated_by")

    code, body = http_json("GET", "/v1/state?#{URI.encode_www_form('prefix' => allowed_prefix)}", token: scoped_token)
    assert_equal 200, code
    entry = body.fetch("entries").find { |candidate| candidate.fetch("path") == allowed_path }
    assert_equal "scoped", entry.fetch("updated_by")

    code, body = http_json("GET", "/v1/state?prefix=claims", token: scoped_token)
    assert_equal 200, code
    assert_filtered_listed_paths body, allowed_path, secondary_path

    assert_scoped_doctor_ok(scoped_token)

    assert_scoped_identity(scoped_token, allowed_prefix, secondary_prefix)

    code, body = http_json("GET", state_path("#{allowed_prefix}/300/extra.json"), token: scoped_token)
    assert_equal 400, code
    assert_equal "invalid_path", body.fetch("error")

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

  def test_delete_requires_archive_coverage_for_active_paths
    full_token = ENV.fetch("AGENT_COORD_API_TOKEN")
    active_token = ENV.fetch("SCOPED_AGENT_COORD_API_TOKEN")
    archive_token = ENV.fetch("ARCHIVE_AGENT_COORD_API_TOKEN")
    mirrored_token = ENV.fetch("MIRRORED_AGENT_COORD_API_TOKEN")
    active_path = "#{ENV.fetch('SCOPED_CLAIM_PREFIX')}/delete-active-only.json"
    archive_path = "archive/claims/shakacode/archive-only/delete.json"
    archive_denied_active_path = "claims/shakacode/archive-only/delete.json"
    mirrored_path = "#{ENV.fetch('MIRRORED_CLAIM_PREFIX')}/delete.json"

    assert_http_create(active_token, active_path)
    code, body = http_json(
      "DELETE", state_path(active_path), token: active_token, headers: { "If-Match" => "1" }
    )
    assert_equal 403, code
    assert_equal "forbidden", body.fetch("error")

    assert_http_create(full_token, archive_path)
    assert_http_create(full_token, archive_denied_active_path)
    code, = http_json(
      "DELETE", state_path(archive_denied_active_path), token: archive_token, headers: { "If-Match" => "1" }
    )
    assert_equal 403, code
    code, body = http_json(
      "DELETE", state_path(archive_path), token: archive_token, headers: { "If-Match" => "1" }
    )
    assert_equal 200, code
    assert_equal true, body.fetch("deleted")

    assert_http_create(mirrored_token, mirrored_path)
    code, body = http_json(
      "DELETE", state_path(mirrored_path), token: mirrored_token, headers: { "If-Match" => "1" }
    )
    assert_equal 200, code
    assert_equal true, body.fetch("deleted")

    assert_http_delete(full_token, active_path)
    assert_http_delete(full_token, archive_denied_active_path)
  end

  def test_maximum_active_path_has_a_valid_archive_mirror
    token = ENV.fetch("AGENT_COORD_API_TOKEN")
    active_path = "claims/o/r/#{'x' * 496}.json"
    archive_path = "archive/#{active_path}"
    too_long_active = "claims/o/r/#{'x' * 497}.json"
    too_long_archive = "archive/#{too_long_active}"
    assert_equal 512, active_path.bytesize
    assert_equal 520, archive_path.bytesize

    assert_http_create(token, active_path)
    assert_http_create(token, archive_path)
    [too_long_active, too_long_archive].each do |path|
      code, body = http_json(
        "PUT", state_path(path), token: token, headers: { "If-None-Match" => "*" },
                                 body: { "data" => { "schema_version" => 1 } }
      )
      assert_equal 400, code
      assert_equal "invalid_path", body.fetch("error")
    end

    assert_http_delete(token, active_path)
    assert_http_delete(token, archive_path)
  end

  def test_scoped_gc_prefix_processes_claims_without_other_hot_family_reads
    token = ENV.fetch("MIRRORED_AGENT_COORD_API_TOKEN")
    source_path = "#{ENV.fetch('MIRRORED_CLAIM_PREFIX')}/gc-prefix.json"
    archive_path = "archive/#{source_path}"
    data = {
      "schema_version" => 1, "repo" => "shakacode/mirrored-delete", "target" => "gc-prefix",
      "agent_id" => "gc-prefix", "status" => "released", "updated_at" => "2000-01-01T00:00:00Z"
    }
    code, body = http_json(
      "PUT",
      state_path(source_path),
      token: token,
      headers: { "If-None-Match" => "*" },
      body: { "data" => data }
    )
    assert_equal 201, code, body.inspect

    stdout, stderr, status = Open3.capture3(
      { "AGENT_COORD_API_TOKEN" => token }, "ruby", CLI, "gc", "--prefix", "claims", "--execute", "--json"
    )
    assert status.success?, stderr
    assert_equal ["claims"], JSON.parse(stdout).fetch("prefixes")
    code, = http_json("GET", state_path(source_path), token: token)
    assert_equal 404, code
    code, body = http_json("GET", state_path(archive_path), token: token)
    assert_equal 200, code
    assert_equal source_path, body.fetch("data").fetch("source_path")
  end

  def test_unknown_token_returns_machine_safe_auth_hint
    code, body = http_json("GET", "/v1/state?prefix=claims", token: "stale-token")

    assert_equal 401, code
    assert_equal "unknown_token", body.fetch("error")
  end

  def test_missing_token_remains_unauthorized
    code, body = http_json("GET", "/v1/state?prefix=claims", token: "")

    assert_equal 401, code
    assert_equal "unauthorized", body.fetch("error")
  end

  private

  def assert_http_create(token, path)
    code, body = http_json(
      "PUT", state_path(path), token: token, headers: { "If-None-Match" => "*" },
                               body: { "data" => { "schema_version" => 1, "agent_id" => "delete-test" } }
    )
    assert_equal 201, code, body.inspect
  end

  def assert_http_delete(token, path)
    code, body = http_json(
      "DELETE", state_path(path), token: token, headers: { "If-Match" => "1" }
    )
    assert_equal 200, code, body.inspect
    assert_equal true, body.fetch("deleted")
  end

  def assert_scoped_write(scoped_token, allowed_path)
    code, body = http_json(
      "PUT",
      state_path(allowed_path),
      token: scoped_token,
      headers: { "If-None-Match" => "*" },
      body: { "data" => { "schema_version" => 1, "agent_id" => "scoped-worker" } }
    )
    assert_equal 201, code
    assert_equal "scoped", body.fetch("updated_by")
  end

  def assert_scoped_identity(scoped_token, allowed_prefix, secondary_prefix)
    code, body = http_json("GET", "/v1/whoami", token: scoped_token)
    assert_equal 200, code
    assert_equal "scoped", body.fetch("machine")
    assert_equal [allowed_prefix, secondary_prefix], body.fetch("read_prefixes")
  end

  def seed_full_token_claims(full_token, *paths)
    paths.each do |path|
      code, = http_json(
        "PUT",
        state_path(path),
        token: full_token,
        headers: { "If-None-Match" => "*" },
        body: { "data" => { "schema_version" => 1, "agent_id" => "full-worker" } }
      )
      assert_equal 201, code
    end
  end

  def assert_listed_paths(body, *paths)
    listed_paths = body.fetch("entries").map { |entry| entry.fetch("path") }
    assert_equal paths, listed_paths
  end

  def assert_filtered_listed_paths(body, *paths)
    assert_equal true, body.fetch("filtered")
    assert_listed_paths body, *paths
  end

  def assert_scoped_doctor_ok(scoped_token)
    doctor_out, doctor_err, doctor_status = Open3.capture3(
      { "AGENT_COORD_API_TOKEN" => scoped_token },
      "ruby",
      CLI,
      "doctor",
      "--deep",
      "--json"
    )
    assert doctor_status.success?, doctor_err
    payload = JSON.parse(doctor_out)
    assert_equal "ok", payload.fetch("status")
    assert_equal "scoped", payload.dig("identity", "machine")
    assert_equal "filtered", payload.dig("resource_checks", "claims")
    assert_equal "forbidden", payload.dig("resource_checks", "heartbeats")
  end

  def state_path(path)
    "/v1/state/#{URI.encode_www_form_component(path)}"
  end

  def http_json(method, path, token:, headers: {}, body: nil)
    uri = URI("#{ENV.fetch('AGENT_COORD_API_URL')}#{path}")
    request_class = {
      "GET" => Net::HTTP::Get,
      "PUT" => Net::HTTP::Put,
      "DELETE" => Net::HTTP::Delete
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
