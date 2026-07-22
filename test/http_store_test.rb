# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "net/http"
require "stringio"
require "tmpdir"
require "webrick"

load File.expand_path("../bin/agent-coord", __dir__)

class HttpStoreStubServlet < WEBrick::HTTPServlet::AbstractServlet
  def initialize(server, handler)
    super(server)
    @handler = handler
  end

  def service(req, res)
    @handler.call(req, res)
  end
end

class HttpStoreStub
  attr_reader :requests

  def initialize(responses)
    @responses = responses
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    handler = proc do |req, res|
      @requests << { method: req.request_method, path: req.unparsed_uri,
                     auth: req["authorization"], if_match: req["if-match"],
                     if_none_match: req["if-none-match"] }
      status, body = @responses.shift || [500, { "error" => "unexpected" }]
      res.status = status
      if body.nil?
        res.body = nil
      elsif body.is_a?(String)
        res.content_type = "text/plain"
        res.body = body
      else
        res.content_type = "application/json"
        res.body = JSON.generate(body)
      end
    end
    @server.mount("/", HttpStoreStubServlet, handler)
    @thread = Thread.new { @server.start }
  end

  def base_url = "http://127.0.0.1:#{@server.config[:Port]}"
  def shutdown = @server.shutdown && @thread.join
end

class HttpStoreTestCase < Minitest::Test
  def with_stub(responses)
    stub = HttpStoreStub.new(responses)
    store = AgentCoord::HttpStore.new(base_url: stub.base_url, token: "tok")
    yield store, stub
  ensure
    store&.close
    stub.shutdown
  end

  def with_net_http_start_error(error)
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise error }
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end
end

class HttpStoreReadTest < HttpStoreTestCase
  def test_reuses_http_session_across_requests
    starts = 0
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
      starts += 1
      original_start.call(*args, **kwargs, &block)
    end

    responses = [
      [200, { "entries" => [] }],
      [
        200,
        { "path" => "claims/o/r/1.json", "data" => { "agent_id" => "a1" }, "version" => 7 }
      ],
      [200, { "status" => "ok" }]
    ]
    with_stub(responses) do |store, _|
      store.list_json("claims")
      store.read_json("claims/o/r/1.json")
      store.verify_layout!(AgentCoord::JSON_PREFIXES)
    end

    assert_equal 1, starts
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def test_read_json_retries_once_when_reused_get_session_is_stale
    starts = 0
    first_requests = 0
    response = Struct.new(:code, :body)
    original_start = Net::HTTP.method(:start)
    stale_http = Object.new
    stale_http.define_singleton_method(:active?) { true }
    stale_http.define_singleton_method(:finish) { nil }
    stale_http.define_singleton_method(:request) do |_request|
      first_requests += 1
      raise EOFError, "end of file reached" if first_requests > 1

      response.new("200", JSON.generate("entries" => []))
    end
    fresh_http = Object.new
    fresh_http.define_singleton_method(:active?) { true }
    fresh_http.define_singleton_method(:finish) { nil }
    fresh_http.define_singleton_method(:request) do |_request|
      response.new(
        "200",
        JSON.generate("path" => "claims/o/r/1.json", "data" => { "agent_id" => "a1" }, "version" => 7)
      )
    end
    Net::HTTP.define_singleton_method(:start) do |*|
      starts += 1
      starts == 1 ? stale_http : fresh_http
    end

    store = AgentCoord::HttpStore.new(base_url: "https://agent-coord.example", token: "tok")
    store.list_json("claims")
    entry = store.read_json("claims/o/r/1.json")

    assert_equal({ "agent_id" => "a1" }, entry.data)
    assert_equal 2, starts
  ensure
    store&.close
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def test_read_json_returns_stored_json_with_version_as_sha
    body = { "path" => "claims/o/r/1.json", "data" => { "agent_id" => "a1" }, "version" => 7 }
    with_stub([[200, body]]) do |store, stub|
      entry = store.read_json("claims/o/r/1.json")
      assert_equal({ "agent_id" => "a1" }, entry.data)
      assert_equal "7", entry.sha
      assert_equal "Bearer tok", stub.requests.first[:auth]
      assert_equal "/v1/state/claims%2Fo%2Fr%2F1.json", stub.requests.first[:path]
    end
  end

  def test_read_json_percent_encodes_spaces_in_state_path
    body = { "path" => "claims/o r/1.json", "data" => { "agent_id" => "a1" }, "version" => 7 }
    with_stub([[200, body]]) do |store, stub|
      store.read_json("claims/o r/1.json")
      assert_equal "/v1/state/claims%2Fo%20r%2F1.json", stub.requests.first[:path]
    end
  end

  def test_read_json_returns_nil_when_not_found
    with_stub([[404, { "error" => "not_found" }]]) do |store, _|
      assert_nil store.read_json("claims/o/r/1.json")
    end
  end

  def test_read_json_raises_operational_on_malformed_not_found
    with_stub([[404, "<html>wrong origin</html>"]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
      assert_includes error.message, "malformed JSON"
    end
  end

  def test_read_json_raises_operational_on_route_not_found
    with_stub([[404, { "error" => "route_not_found" }]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
      assert_includes error.message, "route_not_found"
    end
  end

  def test_read_json_raises_operational_on_server_error
    with_stub([[500, { "error" => "boom" }]]) do |store, _|
      assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
    end
  end

  def test_read_json_raises_operational_on_non_object_error_body
    with_stub([[500, []]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
      assert_includes error.message, "500 []"
    end
  end

  def test_read_json_raises_operational_on_malformed_success
    with_stub([[200, { "path" => "claims/o/r/1.json", "version" => 7 }]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
      assert_includes error.message, "malformed response"
    end
  end

  def test_read_json_raises_operational_on_non_object_success
    with_stub([[200, []]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
      assert_includes error.message, "expected object"
    end
  end

  def test_list_json_maps_entries
    body = { "entries" => [{ "path" => "heartbeats/a1.json", "data" => { "agent_id" => "a1" }, "version" => 2 }] }
    with_stub([[200, body]]) do |store, stub|
      entries = store.list_json("heartbeats")
      assert_equal 1, entries.length
      assert_equal "heartbeats/a1.json", entries.first.path
      assert_equal "2", entries.first.sha
      refute store.filtered_list?("heartbeats")
      assert_equal "/v1/state?prefix=heartbeats", stub.requests.first[:path]
    end
  end

  def test_list_json_tracks_filtered_responses_per_prefix
    responses = [
      [200, { "entries" => [], "filtered" => true }],
      [200, { "entries" => [] }]
    ]
    with_stub(responses) do |store, _|
      store.list_json("claims")
      assert store.filtered_list?("claims")

      store.list_json("claims")
      refute store.filtered_list?("claims")
    end
  end

  def test_verify_readable_uses_record_endpoint_for_exact_state_path
    body = { "path" => "heartbeats/m5-codex.json", "data" => { "agent_id" => "m5-codex" }, "version" => 2 }
    with_stub([[200, body]]) do |store, stub|
      store.verify_readable!("heartbeats/m5-codex.json")

      assert_equal "/v1/state/heartbeats%2Fm5-codex.json", stub.requests.first[:path]
    end
  end

  def test_verify_readable_keeps_json_named_claim_repo_as_list_prefix
    with_stub([[200, { "entries" => [] }]]) do |store, stub|
      store.verify_readable!("claims/shakacode/api.json")

      assert_equal "/v1/state?prefix=claims%2Fshakacode%2Fapi.json", stub.requests.first[:path]
    end
  end

  def test_list_json_follows_next_cursor_until_snapshot_complete
    responses = [
      [
        200,
        {
          "entries" => [
            { "path" => "heartbeats/a1.json", "data" => { "agent_id" => "a1" }, "version" => 2 }
          ],
          "next_cursor" => "heartbeats/a1.json"
        }
      ],
      [
        200,
        {
          "entries" => [
            { "path" => "heartbeats/a2.json", "data" => { "agent_id" => "a2" }, "version" => 3 }
          ]
        }
      ]
    ]

    with_stub(responses) do |store, stub|
      entries = store.list_json("heartbeats")
      assert_equal ["heartbeats/a1.json", "heartbeats/a2.json"], entries.map(&:path)
      request_paths = stub.requests.map { |request| request[:path] }
      assert_equal [
        "/v1/state?prefix=heartbeats",
        "/v1/state?prefix=heartbeats&cursor=heartbeats%2Fa1.json"
      ], request_paths
    end
  end

  def test_list_json_rejects_malformed_next_cursor
    with_stub([[200, { "entries" => [], "next_cursor" => [] }]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.list_json("heartbeats") }
      assert_includes error.message, "next_cursor is not a string"
    end
  end

  def test_list_json_raises_operational_when_entries_is_not_array
    with_stub([[200, { "entries" => "oops" }]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.list_json("heartbeats") }
      assert_includes error.message, "entries is not an array"
    end
  end

  def test_list_json_raises_operational_when_entry_is_not_object
    with_stub([[200, { "entries" => ["oops"] }]]) do |store, _|
      error = assert_raises(AgentCoord::OperationalError) { store.list_json("heartbeats") }
      assert_includes error.message, "entry is not an object"
    end
  end

  def test_list_json_wraps_socket_failures_as_operational
    store = AgentCoord::HttpStore.new(base_url: "https://agent-coord.example", token: "tok")
    with_net_http_start_error(SocketError.new("getaddrinfo failed")) do
      error = assert_raises(AgentCoord::OperationalError) { store.list_json("claims") }
      assert_includes error.message, "http backend unreachable"
      assert_includes error.message, "getaddrinfo failed"
    end
  end

  def test_list_json_wraps_tls_failures_as_operational
    store = AgentCoord::HttpStore.new(base_url: "https://agent-coord.example", token: "tok")
    with_net_http_start_error(OpenSSL::SSL::SSLError.new("certificate verify failed")) do
      error = assert_raises(AgentCoord::OperationalError) { store.list_json("claims") }
      assert_includes error.message, "http backend unreachable"
      assert_includes error.message, "certificate verify failed"
    end
  end

  def test_list_json_treats_no_body_error_as_operational
    store = AgentCoord::HttpStore.new(base_url: "http://127.0.0.1:9", token: "tok")
    response = Struct.new(:code, :body).new("204", nil)
    store.define_singleton_method(:request) { |*| response }

    error = assert_raises(AgentCoord::OperationalError) { store.list_json("claims") }
    assert_includes error.message, "http backend list claims failed: 204"
  end
end

class HttpStoreWriteTest < HttpStoreTestCase
  def test_http_session_disables_net_http_automatic_write_retries
    response = Struct.new(:code, :body)
    original_start = Net::HTTP.method(:start)
    fake_http = Class.new do
      attr_accessor :max_retries

      def initialize(response)
        @response = response
        @max_retries = 1
      end

      def active? = true
      def finish = nil
      def request(_request) = @response
    end.new(response.new("200", "{}"))
    Net::HTTP.define_singleton_method(:start) { |*| fake_http }

    store = AgentCoord::HttpStore.new(base_url: "https://agent-coord.example", token: "tok")
    store.write_json("claims/o/r/1.json", {}, message: "m", sha: "7")

    assert_equal 0, fake_http.max_retries
  ensure
    store&.close
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def test_write_does_not_retry_stale_connection_errors
    starts = 0
    original_start = Net::HTTP.method(:start)
    stale_http = Object.new
    stale_http.define_singleton_method(:active?) { true }
    stale_http.define_singleton_method(:finish) { nil }
    stale_http.define_singleton_method(:request) { |_request| raise EOFError, "end of file reached" }
    Net::HTTP.define_singleton_method(:start) do |*|
      starts += 1
      stale_http
    end

    store = AgentCoord::HttpStore.new(base_url: "https://agent-coord.example", token: "tok")
    error = assert_raises(AgentCoord::OperationalError) do
      store.write_json("claims/o/r/1.json", {}, message: "m", sha: "7")
    end

    assert_includes error.message, "http backend unreachable"
    assert_equal 1, starts
  ensure
    store&.close
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def test_create_sends_if_none_match_and_succeeds_on_created
    with_stub([[201, { "path" => "claims/o/r/1.json", "version" => 1 }]]) do |store, stub|
      store.write_json("claims/o/r/1.json", { "a" => 1 }, message: "m", create: true)
      assert_equal "*", stub.requests.first[:if_none_match]
    end
  end

  def test_create_conflict_raises_already_exists
    with_stub([[409, { "error" => "already_exists" }]]) do |store, _|
      error = assert_raises(AgentCoord::Conflict) do
        store.write_json("claims/o/r/1.json", {}, message: "m", create: true)
      end
      assert_equal "state already exists at claims/o/r/1.json", error.message
    end
  end

  def test_update_sends_if_match_and_conflict_raises_state_changed
    with_stub([[409, { "error" => "version_conflict" }]]) do |store, stub|
      error = assert_raises(AgentCoord::Conflict) do
        store.write_json("claims/o/r/1.json", {}, message: "m", sha: "7")
      end
      assert_equal "7", stub.requests.first[:if_match]
      assert_equal "state changed at claims/o/r/1.json", error.message
    end
  end

  def test_write_without_sha_or_create_is_usage_error
    with_stub([]) do |store, _|
      assert_raises(AgentCoord::Error) do
        store.write_json("claims/o/r/1.json", {}, message: "m")
      end
    end
  end

  def test_delete_sends_if_match_and_maps_version_conflict
    with_stub([[409, { "error" => "version_conflict" }]]) do |store, stub|
      error = assert_raises(AgentCoord::Conflict) do
        store.delete_json("claims/o/r/1.json", message: "gc", sha: "7")
      end

      assert_equal "DELETE", stub.requests.first[:method]
      assert_equal "7", stub.requests.first[:if_match]
      assert_equal "state changed at claims/o/r/1.json", error.message
    end
  end
end

class HttpEnvTestCase < Minitest::Test
  IDENTITY_ENV_KEYS = %w[AGENT_COORD_MACHINE_ID AGENT_COORD_SESSION_ID CODEX_THREAD_ID].freeze

  def with_env(pairs)
    pairs = IDENTITY_ENV_KEYS.to_h { |key| [key, nil] }.merge(pairs)
    saved = pairs.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

class HttpBackendSelectionTest < HttpEnvTestCase
  def run_cli(args, _env)
    stdout = StringIO.new
    stderr = StringIO.new
    code = begin
      AgentCoord::Runner.new(args, stdout: stdout, stderr: stderr).run
    rescue AgentCoord::Error => e
      stderr.puts e.message
      e.exit_code
    end
    [code, stdout.string, stderr.string]
  end

  def test_status_uses_http_backend_when_api_env_set
    responses = [
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }]
    ]
    stub = HttpStoreStub.new(responses)
    env = { "AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok" }
    with_env(env) do
      code, out, = run_cli(["status"], env)
      assert_equal 0, code
      assert_includes out, "claims"
      assert_includes out, "events"
    end
    assert_equal 4, stub.requests.length
  ensure
    stub.shutdown
  end

  def test_status_closes_http_store_after_command
    closes = 0
    original_close = AgentCoord::HttpStore.instance_method(:close)
    AgentCoord::HttpStore.define_method(:close) do
      closes += 1
      original_close.bind_call(self)
    end
    responses = [
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      code, = run_cli(["status"], {})
      assert_equal 0, code
    end

    assert_equal 1, closes
  ensure
    AgentCoord::HttpStore.define_method(:close, original_close) if original_close
    stub&.shutdown
  end

  def test_status_degrades_when_http_backend_does_not_support_events_yet
    responses = [
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [400, { "error" => "invalid_prefix" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      code, out, = run_cli(["status"], {})
      assert_equal 0, code
      assert_includes out, "event state not supported by backend"
    end
    assert_equal 4, stub.requests.length
  ensure
    stub.shutdown
  end

  def test_status_degrades_for_scoped_http_forbidden_sections
    responses = [
      [200, { "entries" => [], "filtered" => true }],
      [403, { "error" => "forbidden" }],
      [403, { "error" => "forbidden" }],
      [403, { "error" => "forbidden" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      code, out, = run_cli(["status", "--json"], {})
      payload = JSON.parse(out)

      assert_equal 0, code
      assert_includes payload.fetch("degraded"), "claims filtered by scoped token"
      assert_includes payload.fetch("degraded"), "heartbeats not readable by scoped token"
      assert_includes payload.fetch("degraded"), "batches not readable by scoped token"
      assert_includes payload.fetch("degraded"), "events not readable by scoped token"
    end
  ensure
    stub.shutdown
  end

  def test_batch_audit_unknown_when_event_trail_is_filtered_by_scoped_token
    responses = [
      [200, { "data" => { "schema_version" => 1, "batch_id" => "batch",
                          "lanes" => [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }] },
              "version" => 3 }],
      [200, { "entries" => [], "filtered" => true }]
    ]
    stub = HttpStoreStub.new(responses)
    env = {
      "AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok",
      "AGENT_COORD_STATE_ROOT" => nil, "AGENT_COORD_STATUS_STATE_ROOT" => nil
    }
    with_env(env) do
      code, out, = run_cli(["batch-audit", "--batch-id", "batch", "--json"], env)
      payload = JSON.parse(out)

      assert_equal 2, code
      assert_equal "unknown", payload.fetch("verdict")
      assert_includes payload.fetch("reason"), "filtered by a scoped token"
    end
    # A scoped read that only lists a visible subset must not be treated as the
    # complete trail: batch (record) read + events (filtered list) = 2 requests.
    assert_equal 2, stub.requests.length
  ensure
    stub.shutdown
  end

  def test_missing_token_is_operational_error
    with_env("AGENT_COORD_API_URL" => "http://127.0.0.1:9", "AGENT_COORD_API_TOKEN" => nil) do
      code, _, err = run_cli(["status"], {})
      assert_equal 2, code
      assert_includes err, "AGENT_COORD_API_TOKEN"
    end
  end

  def test_malformed_api_url_is_operational_error
    with_env("AGENT_COORD_API_URL" => "http://[bad", "AGENT_COORD_API_TOKEN" => "tok") do
      code, _, err = run_cli(["status"], {})
      assert_equal 2, code
      assert_includes err, "invalid HTTP backend URL"
    end
  end

  def test_empty_api_url_env_uses_implicit_xdg_local_default
    Dir.mktmpdir("agent-coord-empty-api") do |root|
      state_home = File.join(root, "state")
      with_env("AGENT_COORD_API_URL" => "",
               "AGENT_COORD_API_TOKEN" => nil,
               "AGENT_COORD_BACKEND" => nil,
               "AGENT_COORD_STATE_ROOT" => nil,
               "AGENT_COORD_STATUS_STATE_ROOT" => nil,
               "XDG_STATE_HOME" => state_home,
               "HOME" => File.join(root, "home"),
               "TMPDIR" => File.join(root, "tmp")) do
        code, out, err = run_cli(["status", "--json"], {})

        assert_equal 0, code
        assert_equal "all", JSON.parse(out).dig("scope", "kind")
        assert_includes err, "local mode — single-machine only"
        assert_includes err, File.join(state_home, "agent-coordination")
      end
    end
  end

  def test_token_only_http_env_is_rejected_before_implicit_local_fallback
    Dir.mktmpdir("agent-coord-token-only") do |root|
      state_home = File.join(root, "state")
      with_env("AGENT_COORD_API_TOKEN" => "token-without-url",
               "AGENT_COORD_BACKEND" => nil,
               "AGENT_COORD_STATE_ROOT" => nil,
               "AGENT_COORD_STATUS_STATE_ROOT" => nil,
               "XDG_STATE_HOME" => state_home,
               "HOME" => File.join(root, "home"),
               "TMPDIR" => File.join(root, "tmp")) do
        [nil, ""].each do |api_url|
          with_env("AGENT_COORD_API_URL" => api_url) do
            [
              ["status", "--json"],
              ["claim", "--agent-id", "worker-a", "--repo", "demo/example", "--target", "1"]
            ].each do |args|
              code, out, err = run_cli(args, {})

              assert_equal 2, code
              assert_empty out
              assert_includes err, "AGENT_COORD_API_TOKEN is set but AGENT_COORD_API_URL is missing or empty"
              refute_includes err, "local mode — single-machine only"
            end
          end
        end
      end
      refute_path_exists File.join(state_home, "agent-coordination")
    end
  end

  def test_api_url_with_empty_host_is_operational_error
    with_env("AGENT_COORD_API_URL" => "https://", "AGENT_COORD_API_TOKEN" => "tok") do
      code, _, err = run_cli(["status"], {})
      assert_equal 2, code
      assert_includes err, "expected http(s) URL with host"
    end
  end

  def test_non_loopback_http_api_url_is_operational_error
    with_env("AGENT_COORD_API_URL" => "http://agent-coord.example", "AGENT_COORD_API_TOKEN" => "tok") do
      code, _, err = run_cli(["status"], {})
      assert_equal 2, code
      assert_includes err, "must use https"
    end
  end

  def test_both_env_vars_warns_and_uses_http
    responses = [
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok",
             "AGENT_COORD_STATE_ROOT" => "/tmp/nonexistent-root") do
      code, _, err = run_cli(["status"], {})
      assert_equal 0, code
      assert_includes err, "both set"
    end
  ensure
    stub.shutdown
  end

  def test_api_url_flag_warning_names_flag_when_state_root_env_set
    responses = [
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_TOKEN" => "tok", "AGENT_COORD_STATE_ROOT" => "/tmp/nonexistent-root") do
      code, _, err = run_cli(["status", "--api-url", stub.base_url], {})
      assert_equal 0, code
      assert_includes err, "--api-url and AGENT_COORD_STATE_ROOT"
      refute_includes err, "AGENT_COORD_API_URL and AGENT_COORD_STATE_ROOT"
    end
  ensure
    stub.shutdown
  end

  def test_api_url_and_state_root_flags_warn_and_use_local
    Dir.mktmpdir do |root|
      with_env("AGENT_COORD_API_TOKEN" => nil) do
        code, out, err = run_cli(["status", "--api-url", "http://127.0.0.1:9", "--state-root", root], {})
        assert_equal 0, code
        assert_includes out, "claims"
        assert_includes err, "--api-url and --state-root"
      end
    end
  end

  def test_state_root_flag_warns_when_api_url_env_set_and_uses_local
    Dir.mktmpdir do |root|
      with_env("AGENT_COORD_API_URL" => "http://127.0.0.1:9", "AGENT_COORD_API_TOKEN" => nil) do
        code, out, err = run_cli(["status", "--state-root", root], {})
        assert_equal 0, code
        assert_includes out, "claims"
        assert_includes err, "AGENT_COORD_API_URL and --state-root"
      end
    end
  end

  def test_empty_state_root_env_uses_implicit_xdg_local_default
    Dir.mktmpdir("agent-coord-xdg-state") do |state_home|
      with_env("AGENT_COORD_API_TOKEN" => nil,
               "AGENT_COORD_API_URL" => nil,
               "AGENT_COORD_STATE_ROOT" => "",
               "XDG_STATE_HOME" => state_home) do
        stderr = StringIO.new
        options = AgentCoord::Runner.new([], stdout: StringIO.new, stderr: stderr)
                                    .send(:parse_options, "status", [])

        assert_equal File.join(state_home, "agent-coordination"), options[:state_root]
        assert_nil options[:api_url]
        assert_includes stderr.string, "local mode — single-machine only"
      end
    end
  end

  def test_status_warns_when_consumer_env_file_points_remote_but_cli_uses_local
    Dir.mktmpdir("agent-coord-xdg-config") do |config_home|
      env_file = File.join(config_home, "agent-coord", "env")
      FileUtils.mkdir_p(File.dirname(env_file))
      File.write(env_file, "AGENT_COORD_API_URL=https://agent-coord.example\nAGENT_COORD_API_TOKEN=secret\n")

      with_env("AGENT_COORD_API_URL" => nil,
               "AGENT_COORD_API_TOKEN" => nil,
               "AGENT_COORD_BACKEND" => nil,
               "AGENT_COORD_STATE_ROOT" => nil,
               "AGENT_COORD_STATUS_STATE_ROOT" => nil,
               "XDG_CONFIG_HOME" => config_home) do
        code, _, err = run_cli(["status", "--json"], {})

        assert_equal 0, code
        assert_includes err, "split-brain"
        assert_includes err, env_file
        assert_includes err, "CLI is using the local backend"
      end
    end
  end

  def test_status_ignores_consumer_env_file_with_invalid_encoding
    Dir.mktmpdir("agent-coord-xdg-config") do |config_home|
      env_file = File.join(config_home, "agent-coord", "env")
      FileUtils.mkdir_p(File.dirname(env_file))
      File.binwrite(env_file, "\xFFAGENT_COORD_API_URL=https://agent-coord.example\n".b)

      with_env("AGENT_COORD_API_URL" => nil,
               "AGENT_COORD_API_TOKEN" => nil,
               "AGENT_COORD_BACKEND" => nil,
               "AGENT_COORD_STATE_ROOT" => nil,
               "AGENT_COORD_STATUS_STATE_ROOT" => nil,
               "XDG_CONFIG_HOME" => config_home) do
        code, _, err = run_cli(["status", "--json"], {})

        assert_equal 0, code
        refute_includes err, "split-brain"
      end
    end
  end

  def test_missing_explicit_backend_defaults_to_labeled_xdg_local_store
    Dir.mktmpdir("agent-coord-xdg-state") do |state_home|
      with_env("AGENT_COORD_API_TOKEN" => nil,
               "AGENT_COORD_API_URL" => nil,
               "AGENT_COORD_BACKEND" => nil,
               "AGENT_COORD_STATE_ROOT" => nil,
               "AGENT_COORD_STATUS_STATE_ROOT" => nil,
               "XDG_STATE_HOME" => state_home) do
        code, out, err = run_cli(["status", "--json"], {})

        assert_equal 0, code
        assert_equal "all", JSON.parse(out).dig("scope", "kind")
        assert_includes err, "local mode — single-machine only"
        assert_includes err, File.join(state_home, "agent-coordination")
      end
    end
  end

  def test_empty_home_rejects_implicit_local_for_missing_empty_or_relative_xdg
    Dir.mktmpdir("agent-coord-empty-home") do |root|
      cwd = File.join(root, "cwd")
      FileUtils.mkdir_p(cwd)
      Dir.chdir(cwd) do
        [nil, "", "relative-state"].each do |xdg_state_home|
          with_env("AGENT_COORD_API_TOKEN" => nil,
                   "AGENT_COORD_API_URL" => nil,
                   "AGENT_COORD_BACKEND" => nil,
                   "AGENT_COORD_STATE_ROOT" => nil,
                   "AGENT_COORD_STATUS_STATE_ROOT" => nil,
                   "XDG_STATE_HOME" => xdg_state_home,
                   "HOME" => "",
                   "TMPDIR" => File.join(root, "tmp")) do
            [["status", "--json"], ["doctor"]].each do |args|
              code, out, err = run_cli(args, {})

              assert_equal 2, code
              assert_empty out
              assert_includes err, "set XDG_STATE_HOME or HOME to an absolute path, or pass --state-root"
              refute_includes err, "local mode — single-machine only"
            end
          end
        end
      end
      assert_equal ["cwd"], Dir.children(root).sort
    end
  end

  def test_unavailable_home_is_operational_but_absolute_xdg_does_not_consult_it
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, stderr: StringIO.new)
    runner.define_singleton_method(:home_directory) { raise ArgumentError, "home unavailable" }
    with_env("XDG_STATE_HOME" => nil, "HOME" => nil) do
      error = assert_raises(AgentCoord::OperationalError) { runner.send(:default_local_state_root) }
      assert_includes error.message, "set XDG_STATE_HOME or HOME to an absolute path, or pass --state-root"
      refute_includes error.message, "home unavailable"
    end

    Dir.mktmpdir("agent-coord-absolute-xdg") do |state_home|
      with_env("XDG_STATE_HOME" => state_home, "HOME" => nil) do
        assert_equal File.join(state_home, "agent-coordination"), runner.send(:default_local_state_root)
      end
    end
  end

  def test_doctor_json_omits_backend_url_when_state_root_wins
    Dir.mktmpdir do |root|
      with_env("AGENT_COORD_API_TOKEN" => nil) do
        code, out, err = run_cli(["doctor", "--api-url", "http://127.0.0.1:9", "--state-root", root, "--json"], {})
        payload = JSON.parse(out)
        assert_equal 0, code
        assert_equal "local", payload.fetch("backend")
        assert_nil payload["backend_url"]
        assert_includes err, "--api-url and --state-root"
      end
    end
  end

  def test_version_does_not_warn_about_backend_env_conflicts
    with_env("AGENT_COORD_API_URL" => "https://agent-coord.example",
             "AGENT_COORD_STATE_ROOT" => "/tmp/nonexistent-root") do
      code, out, err = run_cli(["version"], {})
      assert_equal 0, code
      assert_includes out, AgentCoord::VERSION
      assert_empty err
    end
  end
end

class HttpDoctorTest < HttpEnvTestCase
  def test_doctor_closes_http_store_when_readable_check_fails
    closes = 0
    original_close = AgentCoord::HttpStore.instance_method(:close)
    AgentCoord::HttpStore.define_method(:close) do
      closes += 1
      original_close.bind_call(self)
    end
    stub = HttpStoreStub.new([[500, { "error" => "boom" }]])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      assert_raises(AgentCoord::OperationalError) do
        AgentCoord::Runner.new(["doctor"], stdout: StringIO.new, stderr: StringIO.new).run
      end
    end

    assert_equal 1, closes
  ensure
    AgentCoord::HttpStore.define_method(:close, original_close) if original_close
    stub&.shutdown
  end

  def test_doctor_reports_http_backend
    responses = [
      [200, { "entries" => [] }],
      [200, { "status" => "ok" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(["doctor"], stdout: stdout, stderr: StringIO.new).run
      assert_equal 0, code
      assert_includes stdout.string, "backend: http"
      assert_includes stdout.string, stub.base_url
      assert_includes stdout.string, "doctor_prefix: claims"
    end
  ensure
    stub.shutdown
  end

  def test_doctor_uses_custom_http_readable_prefix
    responses = [
      [200, { "entries" => [] }],
      [200, { "status" => "ok" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--doctor-prefix", "events/batch"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      assert_equal 0, code
      assert_includes stdout.string, "doctor_prefix: events/batch"
      assert_equal "/v1/state?prefix=events%2Fbatch", stub.requests.first[:path]
    end
  ensure
    stub.shutdown
  end

  def test_doctor_json_includes_default_http_readable_prefix
    responses = [
      [200, { "entries" => [] }],
      [200, { "status" => "ok" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(["doctor", "--json"], stdout: stdout, stderr: StringIO.new).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal(
        {
          "version" => "0.1.0",
          "backend" => "http",
          "backend_repo" => nil,
          "backend_url" => stub.base_url,
          "state_root" => nil,
          "deep" => false,
          "status" => "ok",
          "doctor_prefix" => "claims"
        },
        payload
      )
    end
  ensure
    stub.shutdown
  end

  def test_doctor_json_includes_custom_http_readable_prefix
    responses = [
      [200, { "entries" => [] }],
      [200, { "status" => "ok" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--doctor-prefix", "events/batch", "--json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal(
        {
          "version" => "0.1.0",
          "backend" => "http",
          "backend_repo" => nil,
          "backend_url" => stub.base_url,
          "state_root" => nil,
          "deep" => false,
          "status" => "ok",
          "doctor_prefix" => "events/batch"
        },
        payload
      )
    end
  ensure
    stub.shutdown
  end

  def test_doctor_deep_skips_forbidden_unscoped_http_prefixes
    responses = [
      [200, { "status" => "ok" }],
      [200, { "entries" => [], "filtered" => true }],
      [403, { "error" => "forbidden" }],
      [403, { "error" => "forbidden" }],
      [403, { "error" => "forbidden" }],
      [403, { "error" => "forbidden" }],
      [200, { "machine" => "scoped", "read_prefixes" => ["claims/x/y"], "write_prefixes" => [] }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(["doctor", "--deep", "--json"], stdout: stdout, stderr: StringIO.new).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_deep_scoped_doctor(payload, stub)
    end
  ensure
    stub.shutdown
  end

  def test_doctor_deep_degrades_when_http_backend_does_not_support_events_yet
    responses = [
      [200, { "status" => "ok" }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [400, { "error" => "invalid_prefix" }],
      [400, { "error" => "invalid_prefix" }],
      [404, { "error" => "route_not_found" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(["doctor", "--deep", "--json"], stdout: stdout, stderr: StringIO.new).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal "ok", payload.fetch("status")
      assert_equal "unsupported", payload.fetch("resource_checks").fetch("events")
      assert_includes payload.fetch("degraded"), "event state not supported by backend"
      assert_equal "unsupported", payload.fetch("resource_checks").fetch("archive")
      assert_includes payload.fetch("degraded"), "archive state not supported by backend"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_unauthorized_names_resource_and_prints_recovery_command
    stub = HttpStoreStub.new([
                               [200, { "status" => "ok" }],
                               [401, { "error" => "unknown_token" }]
                             ])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "stale") do
      error = assert_raises(AgentCoord::OperationalError) do
        AgentCoord::Runner.new(["doctor", "--deep"], stdout: StringIO.new, stderr: StringIO.new).run
      end

      assert_includes error.message, "claims"
      assert_includes error.message,
                      "worker/bin/provision-token <machine-name> --local --database <database-name> --rotate " \
                      "<original-scope-flags>"
      assert_includes error.message, "do not infer them from the resource that returned 401"
      assert_includes error.message, "docs/runbooks/rotate-backend.md"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_tolerates_worker_without_whoami_route
    responses = [
      [200, { "status" => "ok" }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [404, { "error" => "route_not_found" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(["doctor", "--deep", "--json"], stdout: stdout, stderr: StringIO.new).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal "ok", payload.fetch("status")
      refute payload.key?("identity")
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_still_checks_custom_exact_path
    stub = HttpStoreStub.new([
                               [200, { "status" => "ok" }],
                               [403, { "error" => "forbidden" }],
                               [200, { "machine" => "scoped", "read_prefixes" => ["claims/m5"],
                                       "write_prefixes" => [] }]
                             ])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--deep", "--doctor-prefix", "heartbeats/m5.json", "--json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal "forbidden", payload.fetch("resource_checks").fetch("heartbeats/m5.json")
      assert_includes payload.fetch("degraded"), "heartbeats/m5.json not readable by scoped token"
      assert_equal "/v1/state/heartbeats%2Fm5.json", stub.requests[1][:path]
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_reports_missing_custom_exact_path
    stub = HttpStoreStub.new([
                               [200, { "status" => "ok" }],
                               [404, { "error" => "not_found" }],
                               [200, { "machine" => "m5", "read_prefixes" => ["heartbeats/m5.json"],
                                       "write_prefixes" => [] }]
                             ])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--deep", "--doctor-prefix", "heartbeats/m5.json", "--json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal "missing", payload.fetch("resource_checks").fetch("heartbeats/m5.json")
      assert_includes payload.fetch("degraded"), "heartbeats/m5.json does not exist"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_custom_scope_skips_unrelated_resource_probes
    responses = [
      [200, { "status" => "ok" }],
      [200, { "path" => "heartbeats/m5.json", "data" => {}, "version" => 1 }],
      [200, { "machine" => "m5", "read_prefixes" => ["heartbeats/m5.json"], "write_prefixes" => [] }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--deep", "--doctor-prefix", "heartbeats/m5.json", "--json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal({ "heartbeats/m5.json" => "ok" }, payload.fetch("resource_checks"))
      refute payload.key?("degraded")
      expected_paths = [
        "/v1/health",
        "/v1/state/heartbeats%2Fm5.json",
        "/v1/whoami"
      ]
      assert_equal(expected_paths, stub.requests.map { |request| request[:path] })
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_custom_scope_unauthorized_prints_recovery_command
    stub = HttpStoreStub.new([
                               [200, { "status" => "ok" }],
                               [401, { "error" => "unknown_token" }]
                             ])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "stale") do
      error = assert_raises(AgentCoord::OperationalError) do
        AgentCoord::Runner.new(
          ["doctor", "--deep", "--doctor-prefix", "heartbeats/m5.json"],
          stdout: StringIO.new,
          stderr: StringIO.new
        ).run
      end

      assert_includes error.message, "doctor resource heartbeats/m5.json failed authentication"
      assert_includes error.message, "worker/bin/provision-token"
      assert_includes error.message, "docs/runbooks/rotate-backend.md"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_custom_directory_preserves_filtered_status
    responses = [
      [200, { "status" => "ok" }],
      [200, { "entries" => [], "filtered" => true }],
      [200, { "machine" => "scoped", "read_prefixes" => ["claims/team/repo"], "write_prefixes" => [] }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--deep", "--doctor-prefix", "claims/team", "--json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal "filtered", payload.dig("resource_checks", "claims/team")
      assert_includes payload.fetch("degraded"), "claims/team filtered by scoped token"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_custom_directory_preserves_forbidden_status
    stub = HttpStoreStub.new([
                               [200, { "status" => "ok" }],
                               [403, { "error" => "forbidden" }],
                               [200, { "machine" => "scoped", "read_prefixes" => ["claims/m5"],
                                       "write_prefixes" => [] }]
                             ])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--deep", "--doctor-prefix", "heartbeats", "--json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal "forbidden", payload.fetch("resource_checks").fetch("heartbeats")
      assert_includes payload.fetch("degraded"), "heartbeats not readable by scoped token"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_custom_event_prefix_degrades_for_older_worker
    stub = HttpStoreStub.new([
                               [200, { "status" => "ok" }],
                               [400, { "error" => "invalid_prefix" }],
                               [404, { "error" => "route_not_found" }]
                             ])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--deep", "--doctor-prefix", "events/batch-1", "--json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      payload = JSON.parse(stdout.string)

      assert_equal 0, code
      assert_equal "unsupported", payload.fetch("resource_checks").fetch("events/batch-1")
      assert_includes payload.fetch("degraded"), "event state not supported by backend"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_deep_text_labels_all_state_scopes
    responses = [
      [200, { "status" => "ok" }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "entries" => [] }],
      [200, { "machine" => "operator", "read_prefixes" => [""], "write_prefixes" => [""] }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(["doctor", "--deep"], stdout: stdout, stderr: StringIO.new).run

      assert_equal 0, code
      assert_includes stdout.string, "read_prefixes: all-state"
      assert_includes stdout.string, "write_prefixes: all-state"
    end
  ensure
    stub&.shutdown
  end

  def test_doctor_uses_record_get_for_exact_http_readable_path
    responses = [
      [200, { "path" => "heartbeats/m5-codex.json", "data" => { "agent_id" => "m5-codex" }, "version" => 1 }],
      [200, { "status" => "ok" }]
    ]
    stub = HttpStoreStub.new(responses)
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok") do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(
        ["doctor", "--doctor-prefix", "heartbeats/m5-codex.json"],
        stdout: stdout,
        stderr: StringIO.new
      ).run
      assert_equal 0, code
      assert_includes stdout.string, "doctor_prefix: heartbeats/m5-codex.json"
      assert_equal "/v1/state/heartbeats%2Fm5-codex.json", stub.requests.first[:path]
    end
  ensure
    stub.shutdown
  end

  def assert_deep_scoped_doctor(payload, stub)
    expected_notes = [
      "claims filtered by scoped token",
      "heartbeats not readable by scoped token",
      "batches not readable by scoped token",
      "events not readable by scoped token",
      "archive not readable by scoped token"
    ]
    expected_notes.each { |note| assert_includes payload.fetch("degraded"), note }
    assert_equal expected_notes.first, payload.fetch("section_notes").fetch("claims")
    assert_equal({
                   "claims" => "filtered", "heartbeats" => "forbidden", "batches" => "forbidden",
                   "events" => "forbidden", "archive" => "forbidden"
                 }, payload.fetch("resource_checks"))
    assert_equal "scoped", payload.dig("identity", "machine")
    prefixes = %w[claims heartbeats batches events archive].map { |prefix| "/v1/state?prefix=#{prefix}" }
    assert_equal(["/v1/health", *prefixes, "/v1/whoami"], stub.requests.map { |request| request[:path] })
  end
end
