# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "net/http"
require "webrick"

load File.expand_path("../bin/agent-coord", __dir__)

class HttpStoreStub
  attr_reader :requests

  def initialize(responses)
    @responses = responses
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    @server.mount_proc("/") do |req, res|
      @requests << { method: req.request_method, path: req.unparsed_uri,
                     auth: req["authorization"], if_match: req["if-match"],
                     if_none_match: req["if-none-match"] }
      status, body = @responses.shift || [500, { "error" => "unexpected" }]
      res.status = status
      res.content_type = "application/json"
      res.body = JSON.generate(body)
    end
    @thread = Thread.new { @server.start }
  end

  def base_url = "http://127.0.0.1:#{@server.config[:Port]}"
  def shutdown = @server.shutdown && @thread.join
end

class HttpStoreTestCase < Minitest::Test
  def with_stub(responses)
    stub = HttpStoreStub.new(responses)
    yield AgentCoord::HttpStore.new(base_url: stub.base_url, token: "tok"), stub
  ensure
    stub.shutdown
  end
end

class HttpStoreReadTest < HttpStoreTestCase
  def test_read_json_returns_stored_json_with_version_as_sha
    body = { "path" => "claims/o/r/1.json", "data" => { "agent_id" => "a1" }, "version" => 7 }
    with_stub([[200, body]]) do |store, stub|
      entry = store.read_json("claims/o/r/1.json")
      assert_equal({ "agent_id" => "a1" }, entry.data)
      assert_equal "7", entry.sha
      assert_equal "Bearer tok", stub.requests.first[:auth]
    end
  end

  def test_read_json_returns_nil_when_not_found
    with_stub([[404, { "error" => "not_found" }]]) do |store, _|
      assert_nil store.read_json("claims/o/r/1.json")
    end
  end

  def test_read_json_raises_operational_on_server_error
    with_stub([[500, { "error" => "boom" }]]) do |store, _|
      assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
    end
  end

  def test_list_json_maps_entries
    body = { "entries" => [{ "path" => "heartbeats/a1.json", "data" => { "agent_id" => "a1" }, "version" => 2 }] }
    with_stub([[200, body]]) do |store, _|
      entries = store.list_json("heartbeats")
      assert_equal 1, entries.length
      assert_equal "heartbeats/a1.json", entries.first.path
      assert_equal "2", entries.first.sha
    end
  end

  def test_list_json_wraps_dns_failures_as_operational
    store = AgentCoord::HttpStore.new(base_url: "http://nonexistent.invalid", token: "tok")
    error = assert_raises(AgentCoord::OperationalError) { store.list_json("claims") }
    assert_includes error.message, "http backend unreachable"
  end
end

class HttpStoreWriteTest < HttpStoreTestCase
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
end
