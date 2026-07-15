# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"
require "digest"
require "time"

class StateContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "contracts", "state-schema-v2.json")
  FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v2", "lane_closed.json")
  ARCHIVE_SCHEMA_PATH = File.join(ROOT, "contracts", "archive-record-schema-v1.json")
  ARCHIVE_FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v1", "archive_record.json")
  COMPACTED_EVENTS_FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v1", "compacted_events.json")
  HOST_LIMIT_SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "host-limit.schema.json")
  HOST_LIMIT_FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "fixtures")
  CAPACITY_CONTRACT_PATH = File.join(ROOT, "schema", "state", "v1", "capacity-reservation")
  CAPACITY_FIXTURES_PATH = File.join(CAPACITY_CONTRACT_PATH, "fixtures")
  CAPACITY_SCHEMA_PATHS = {
    "capacity_profile" => File.join(CAPACITY_CONTRACT_PATH, "capacity-profile.schema.json"),
    "inbox" => File.join(CAPACITY_CONTRACT_PATH, "inbox.schema.json"),
    "lane_occupancy" => File.join(CAPACITY_CONTRACT_PATH, "lane-occupancy.schema.json"),
    "capacity_reservation" => File.join(CAPACITY_CONTRACT_PATH, "capacity-reservation.schema.json")
  }.freeze

  def test_lane_closed_fixture_conforms_to_published_v2_contract
    schema_document = JSON.parse(File.read(SCHEMA_PATH))
    fixture = JSON.parse(File.read(FIXTURE_PATH))
    schema = JSONSchemer.schema(schema_document)

    assert_equal 2, schema_document.fetch("x-contract-version")
    assert_equal "default", schema_document.fetch("$defs").fetch("workspace").fetch("default")
    assert_equal "lane_closed-0f5a0caebfed6139", fixture.fetch("event_id")
    expected = "lane_closed-#{Digest::SHA256.hexdigest(fixture.fetch('lane'))[0, 16]}"
    assert_equal expected, fixture.fetch("event_id")
    assert_match(/\Alane_closed-[0-9a-f]{16}\z/, fixture.fetch("event_id"))
    assert_empty schema.validate(fixture).to_a
  end

  def test_archive_fixture_conforms_to_published_v1_contract
    schema_document = JSON.parse(File.read(ARCHIVE_SCHEMA_PATH))
    schema = JSONSchemer.schema(schema_document)
    fixtures = [ARCHIVE_FIXTURE_PATH, COMPACTED_EVENTS_FIXTURE_PATH].map { |path| JSON.parse(File.read(path)) }

    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "archive", schema_document.fetch("x-record-family")
    fixtures.each { |fixture| assert_empty schema.validate(fixture).to_a }
    compacted = fixtures.fetch(1)
    assert_operator compacted.fetch("source_paths").length, :>, compacted.fetch("records").length
    lane_closed = compacted.fetch("records").find { |record| record["type"] == "lane_closed" }
    state_schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
    assert_empty state_schema.validate(lane_closed).to_a
  end

  def test_lane_closed_contract_rejects_missing_workspace_and_invalid_terminal
    schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
    fixture = JSON.parse(File.read(FIXTURE_PATH))
    fixture.delete("workspace")
    fixture["terminal"] = "finished"

    errors = schema.validate(fixture).to_a

    refute_empty errors
    error_pointers = errors.map { |error| error.fetch("data_pointer") }
    assert_includes error_pointers, ""
    assert_includes error_pointers, "/terminal"
  end

  def test_host_limit_positive_and_negative_fixtures_conform_to_v1_contract
    schema_document = JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH))
    schema = JSONSchemer.schema(schema_document)

    assert JSONSchemer.valid_schema?(schema_document)
    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "host_limit", schema_document.fetch("x-record-family")
    assert_equal %w[workspace machine quota_host scope], schema_document.fetch("x-logical-key")
    assert_equal "host_limits/{workspace}/{machine}/{quota_host}/{scope}.json",
                 schema_document.dig("x-storage-key", "template")
    assert_equal %w[workspace machine quota_host scope],
                 schema_document.dig("$defs", "status_projection", "properties", "host_limits", "x-unique-key")
    assert_equal "producer",
                 schema_document.dig(
                   "$defs", "status_projection", "properties", "host_limits", "x-unique-key-enforcement"
                 )
    assert_equal "default", schema_document.dig("$defs", "workspace", "default")

    fixture_files("valid").each do |path|
      assert_empty schema.validate(read_fixture(path)).to_a, "expected valid fixture #{path} to conform"
    end
    fixture_files("invalid").each do |path|
      refute_empty schema.validate(read_fixture(path)).to_a, "expected invalid fixture #{path} to be rejected"
    end
  end

  def test_host_limit_contract_rejects_invalid_key_and_state_variants
    schema = JSONSchemer.schema(JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH)))
    fixture = read_fixture(fixture_files("valid").first)

    variants = [
      fixture.except("workspace"),
      fixture.except("quota_host").merge("host" => "claude-code/conductor"),
      fixture.merge("schema_version" => 2),
      fixture.merge("status" => "expired"),
      fixture.merge("source" => "private-api"),
      fixture.merge("scope" => "Five Hour"),
      fixture.merge("unexpected" => true)
    ]

    variants.each { |variant| refute_empty schema.validate(variant).to_a }
  end

  def test_host_limit_source_vocabulary_and_canonical_quota_host_rules
    schema = JSONSchemer.schema(JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH)))
    fixture = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-active.json"))

    %w[manual host-message hook probe].each do |source|
      assert_empty schema.validate(fixture.merge("source" => source)).to_a
    end
    ["Quota-Host-A", " quota-host-a", "quota host a", "https://quota-host-a", "quota-host-a:443"].each do |host|
      refute_empty schema.validate(fixture.merge("quota_host" => host)).to_a
    end
  end

  def test_host_limit_date_time_formats_are_asserted
    schema = JSONSchemer.schema(JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH)))
    active = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-active.json"))
    cleared = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-cleared.json"))
    variants = [
      [active.merge("observed_at" => "not-a-date-time"), "/observed_at"],
      [active.merge("resets_at" => "not-a-date-time"), "/resets_at"],
      [cleared.merge("cleared_at" => "not-a-date-time"), "/cleared_at"]
    ]

    variants.each do |record, pointer|
      errors = schema.validate(record).to_a
      assert(errors.any? { |error| error["type"] == "format" && error["data_pointer"] == pointer },
             "expected an explicit date-time format error at #{pointer}")
    end
  end

  def test_two_lanes_replay_one_effective_host_limit_record
    schema_document = JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH))
    projection_schema = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    replay = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "replay", "two-lanes-one-host-limit.json"))
    records = replay.dig("status", "host_limits")

    assert_empty projection_schema.validate(replay.fetch("status")).to_a
    assert_equal %w[batches claims events heartbeats host_limits], replay.fetch("status").keys.sort
    assert(replay.fetch("lanes").all? { |lane| lane.fetch("host") != lane.fetch("quota_host") })
    assert_equal records.length, records.map { |record| logical_key(record) }.uniq.length

    effective = effective_host_limits(records, replay.fetch("as_of"))
    lane_statuses = replay.fetch("lanes").to_h do |lane|
      blocked = effective.any? do |record|
        %w[workspace machine quota_host].all? { |key| lane.fetch(key) == record.fetch(key) }
      end
      [lane.fetch("lane"), blocked ? "blocked-on-limit" : "available"]
    end

    assert_equal replay.dig("expected", "effective_record_count"), effective.length
    assert_equal replay.dig("expected", "lane_statuses"), lane_statuses
  end

  def test_status_projection_allows_omitted_or_empty_host_limits
    schema_document = JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH))
    projection_schema = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    replay = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "replay", "two-lanes-one-host-limit.json"))
    existing_status = replay.fetch("status").except("host_limits")

    assert_empty projection_schema.validate(existing_status).to_a
    assert_empty projection_schema.validate(existing_status.merge("host_limits" => [])).to_a
    refute_empty projection_schema.validate(existing_status.merge("host_limits" => nil)).to_a
  end

  def test_status_projection_excludes_cleared_and_elapsed_reset_records
    active = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-active.json"))
    cleared = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-cleared.json"))
    elapsed_reset = active.merge("scope" => "daily", "resets_at" => "2026-07-13T00:59:59Z")
    unknown_reset = active.merge("scope" => "weekly", "resets_at" => nil)

    assert_equal [unknown_reset], effective_host_limits(
      [active, elapsed_reset, cleared, unknown_reset],
      "2026-07-13T01:00:00Z"
    )
  end

  def test_status_projection_procedurally_rejects_duplicate_logical_keys
    schema_document = JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH))
    projection_schema = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    fixture = read_fixture(
      File.join(HOST_LIMIT_FIXTURES_PATH, "procedural", "host-limits-duplicate-logical-key.json")
    )

    assert_empty projection_schema.validate(fixture).to_a,
                 "JSON Schema validates the records but cannot enforce composite-key uniqueness"
    assert_equal(%w[active cleared], fixture.fetch("host_limits").map { |record| record.fetch("status") })
    assert_raises(ArgumentError) { enforce_unique_logical_keys!(fixture.fetch("host_limits")) }
  end

  def test_capacity_record_schemas_publish_authoritative_keys_and_refusal_contract
    schemas = CAPACITY_SCHEMA_PATHS.transform_values { |path| JSON.parse(File.read(path)) }

    schemas.each do |record_family, schema_document|
      assert JSONSchemer.valid_schema?(schema_document), "expected #{record_family} schema to be valid"
      assert_equal 1, schema_document.fetch("x-contract-version")
      assert_equal record_family, schema_document.fetch("x-record-family")
      assert_equal "default", schema_document.dig("$defs", "workspace", "default")
      assert_match(%r{\A(?:capacity_profiles|inboxes|lane_occupancy|capacity_reservations)/\{workspace\}/},
                   schema_document.dig("x-storage-key", "template"))
    end

    reservation = schemas.fetch("capacity_reservation")
    assert_equal(
      { "name" => "RESERVATION_REFUSED", "exit_code" => 4 },
      reservation.fetch("x-cli-refusal")
    )
    assert_equal %w[active consumed released expired],
                 reservation.dig("$defs", "lane_hold", "properties", "state", "enum")
    assert_equal ["lane_ref"], reservation.fetch("x-lane-hold-unique-key")
    assert_equal "producer",
                 reservation.fetch("x-batch-lane-ref-match")
  end

  def test_capacity_record_positive_and_negative_fixtures_conform
    valid_fixtures = {
      "capacity-profile-enabled.json" => "capacity_profile",
      "inbox-enabled.json" => "inbox",
      "lane-occupancy-blocked.json" => "lane_occupancy",
      "capacity-reservation-active.json" => "capacity_reservation",
      "capacity-reservation-partial-consume.json" => "capacity_reservation"
    }
    invalid_fixtures = {
      "capacity-profile-zero.json" => "capacity_profile",
      "inbox-unknown-status.json" => "inbox",
      "lane-occupancy-blocked-no-reason.json" => "lane_occupancy",
      "capacity-reservation-both-attempt-scopes.json" => "capacity_reservation",
      "capacity-reservation-ttl-too-low.json" => "capacity_reservation",
      "capacity-reservation-consumed-no-at.json" => "capacity_reservation"
    }

    valid_fixtures.each do |filename, record_family|
      schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch(record_family))))
      fixture = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "valid", filename))
      assert_empty schema.validate(fixture).to_a, "expected valid fixture #{filename} to conform"
    end

    invalid_fixtures.each do |filename, record_family|
      schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch(record_family))))
      fixture = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "invalid", filename))
      refute_empty schema.validate(fixture).to_a, "expected invalid fixture #{filename} to be rejected"
    end
  end

  def test_capacity_replay_allows_exactly_one_planner_to_take_the_final_slot
    replay = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "replay", "two-planners-one-slot.json"))
    schemas = CAPACITY_SCHEMA_PATHS.transform_values do |path|
      JSONSchemer.schema(JSON.parse(File.read(path)))
    end

    assert_empty schemas.fetch("capacity_profile").validate(replay.fetch("capacity_profile")).to_a
    replay.fetch("inboxes").each do |record|
      assert_empty schemas.fetch("inbox").validate(record).to_a
    end
    replay.fetch("lane_occupancies").each do |record|
      assert_empty schemas.fetch("lane_occupancy").validate(record).to_a
    end
    replay.fetch("active_reservations").each do |record|
      assert_empty schemas.fetch("capacity_reservation").validate(record).to_a
    end

    assert_equal replay.fetch("expected"), simulate_capacity_requests(replay)
  end

  def test_capacity_lifecycle_replay_enforces_owner_ttl_and_partial_release
    replay = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "replay", "ownership-ttl-partial-release.json"))
    reservation = replay.fetch("reservation")
    schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch("capacity_reservation"))))

    assert_empty schema.validate(reservation).to_a
    owner_tuple = %w[owner_machine owner_id instance_id].map { |field| reservation.fetch(field) }
    wrong_owner_tuple = %w[owner_machine owner_id instance_id].map do |field|
      replay.fetch("wrong_owner").fetch(field)
    end

    assert_capacity_lifecycle_timestamps(replay, reservation)
    assert_capacity_consume_lifecycle(replay, reservation, schema, owner_tuple, wrong_owner_tuple)
    assert_capacity_release_lifecycle(replay, reservation, schema, owner_tuple, wrong_owner_tuple)
    assert_capacity_expiry_lifecycle(replay, reservation, schema, owner_tuple)
  end

  def test_capacity_predicate_fails_closed_when_authoritative_inputs_are_unavailable
    replay = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "replay", "two-planners-one-slot.json"))
    duplicate_holds = read_fixture(
      File.join(CAPACITY_FIXTURES_PATH, "procedural", "reservation-duplicate-lane-ref.json")
    )
    batch_mismatch = read_fixture(
      File.join(CAPACITY_FIXTURES_PATH, "procedural", "reservation-batch-lane-mismatch.json")
    )
    duplicate_active_lanes = read_fixture(
      File.join(CAPACITY_FIXTURES_PATH, "procedural", "reservations-duplicate-active-lane-ref.json")
    )
    variants = [
      replay.merge("capacity_profile" => replay.fetch("capacity_profile").merge("status" => "disabled")),
      replay.merge(
        "inboxes" => replay.fetch("inboxes").map.with_index do |inbox, index|
          index.zero? ? inbox.merge("status" => "disabled") : inbox
        end
      ),
      replay.merge(
        "inboxes" => replay.fetch("inboxes").map.with_index do |inbox, index|
          index.zero? ? inbox.merge("capacity_profile_id" => "different-profile") : inbox
        end
      ),
      replay.except("lane_occupancies"),
      replay.except("active_reservations"),
      replay.merge(
        "lane_occupancies" => [replay.fetch("lane_occupancies").first.merge("state" => "mystery")]
      ),
      replay.merge(
        "active_reservations" => [replay.fetch("active_reservations").first.merge("inbox_id" => "missing")]
      ),
      replay.merge("active_reservations" => [duplicate_holds]),
      replay.merge("active_reservations" => [batch_mismatch]),
      replay.merge("active_reservations" => duplicate_active_lanes.fetch("active_reservations"))
    ]

    assert authoritative_capacity_inputs?(replay)
    variants.each.with_index do |variant, index|
      refute authoritative_capacity_inputs?(variant), "expected malformed variant #{index} to fail closed"
    end
  end

  def test_capacity_reservation_procedurally_rejects_duplicate_lane_refs
    fixture = read_fixture(
      File.join(CAPACITY_FIXTURES_PATH, "procedural", "reservation-duplicate-lane-ref.json")
    )
    schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch("capacity_reservation"))))

    assert_empty schema.validate(fixture).to_a,
                 "JSON Schema validates distinct hold objects but cannot enforce lane_ref uniqueness"
    assert_raises(ArgumentError) { enforce_unique_lane_hold_refs!(fixture.fetch("lane_holds")) }
  end

  def test_batch_scoped_reservation_procedurally_rejects_foreign_lane_refs
    fixture = read_fixture(
      File.join(CAPACITY_FIXTURES_PATH, "procedural", "reservation-batch-lane-mismatch.json")
    )
    schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch("capacity_reservation"))))

    assert_empty schema.validate(fixture).to_a,
                 "JSON Schema validates lane syntax but cannot compare each lane prefix to batch_id"
    assert_raises(ArgumentError) { enforce_batch_lane_refs!(fixture) }
  end

  def test_capacity_snapshot_procedurally_rejects_duplicate_active_lane_refs_across_reservations
    fixture = read_fixture(
      File.join(CAPACITY_FIXTURES_PATH, "procedural", "reservations-duplicate-active-lane-ref.json")
    )
    schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch("capacity_reservation"))))

    fixture.fetch("active_reservations").each { |reservation| assert_empty schema.validate(reservation).to_a }
    reservations = fixture.fetch("active_reservations")
    assert_raises(ArgumentError) { enforce_unique_active_lane_refs!(reservations, "2026-07-14T20:05:00Z") }
    enforce_unique_active_lane_refs!(reservations, "2026-07-14T20:16:00Z")
  end

  def test_capacity_replay_accepts_exact_fit_and_refuses_multi_lane_one_over_atomically
    replay = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "replay", "exact-fit-and-one-over.json"))
    capacity = replay.fetch("max_concurrency")
    occupied = replay.fetch("occupied_lane_refs").uniq
    available = capacity - occupied.length

    actual = replay.fetch("scenarios").to_h do |scenario|
      requested = scenario.fetch("requested_lane_refs")
      accepted = requested.uniq.length == requested.length &&
                 requested.none? { |lane_ref| occupied.include?(lane_ref) } &&
                 requested.length <= available
      used_after = accepted ? (occupied + requested).uniq : occupied
      [scenario.fetch("name"), { "outcome" => accepted ? "accepted" : "RESERVATION_REFUSED",
                                 "used_lane_refs_after" => used_after.sort }]
    end

    assert_equal replay.fetch("expected"), actual
  end

  def test_capacity_replay_serializes_release_and_new_reservation_without_revival
    replay = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "replay", "release-vs-new-reserve.json"))
    schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch("capacity_reservation"))))

    assert_empty schema.validate(replay.fetch("existing_reservation")).to_a
    enforce_batch_lane_refs!(replay.fetch("existing_reservation"))

    actual = replay.fetch("orderings").to_h do |ordering|
      [ordering.fetch("name"), replay_release_and_reserve_ordering(replay, ordering.fetch("operations"))]
    end

    assert_equal replay.fetch("expected"), actual
  end

  def test_capacity_replay_excludes_unchanged_active_holds_at_ttl_boundary
    replay = read_fixture(File.join(CAPACITY_FIXTURES_PATH, "replay", "ttl-capacity-boundary.json"))
    schema = JSONSchemer.schema(JSON.parse(File.read(CAPACITY_SCHEMA_PATHS.fetch("capacity_reservation"))))

    assert_empty schema.validate(replay.fetch("reservation")).to_a
    actual = replay.fetch("as_of").to_h do |boundary, as_of|
      [boundary, reservation_capacity_at(replay.fetch("reservation"), as_of, replay.fetch("max_concurrency"))]
    end

    assert_equal replay.fetch("expected"), actual
    assert_equal "active", replay.dig("reservation", "lane_holds", 0, "state")
  end

  private

  def fixture_files(kind)
    Dir[File.join(HOST_LIMIT_FIXTURES_PATH, kind, "*.json")]
  end

  def read_fixture(path)
    JSON.parse(File.read(path))
  end

  def logical_key(record)
    %w[workspace machine quota_host scope].map { |field| record.fetch(field) }
  end

  def enforce_unique_logical_keys!(records)
    duplicates = records.group_by { |record| logical_key(record) }.select { |_, matches| matches.length > 1 }
    raise ArgumentError, "duplicate host-limit logical key" unless duplicates.empty?
  end

  def effective_host_limits(records, as_of)
    projection_time = Time.iso8601(as_of)
    records.select do |record|
      next false unless record.fetch("status") == "active"

      resets_at = record.fetch("resets_at")
      resets_at.nil? || Time.iso8601(resets_at) > projection_time
    end
  end

  def simulate_capacity_requests(replay)
    as_of = Time.iso8601(replay.fetch("as_of"))
    occupied_refs = replay.fetch("lane_occupancies").filter_map do |record|
      record.fetch("lane_ref") if %w[occupied blocked].include?(record.fetch("state"))
    end
    reserved_refs = replay.fetch("active_reservations").flat_map do |reservation|
      active_lane_refs(reservation, as_of)
    end
    used_refs = (occupied_refs + reserved_refs).uniq
    capacity = replay.dig("capacity_profile", "max_concurrency")
    accepted_payloads = {}

    outcomes = replay.fetch("requests").to_h do |request|
      outcome = capacity_request_outcome(replay, request, accepted_payloads, used_refs, capacity)
      [request.fetch("attempt"), outcome]
    end

    {
      "outcomes" => outcomes,
      "effective_used_lane_refs" => used_refs.uniq.sort,
      "remaining_slots" => capacity - used_refs.uniq.length
    }
  end

  def release_active_lane_holds(reservation, released_at, owner_tuple)
    validate_reservation_owner!(reservation, owner_tuple)
    expired = Time.iso8601(released_at) >= Time.iso8601(reservation.fetch("expires_at"))

    reservation.merge(
      "lane_holds" => reservation.fetch("lane_holds").map do |hold|
        next hold unless hold.fetch("state") == "active"

        if expired
          hold.merge("state" => "expired", "expired_at" => reservation.fetch("expires_at"))
        else
          hold.merge("state" => "released", "released_at" => released_at)
        end
      end
    )
  end

  def consume_active_lane_hold(reservation, lane_ref, consumed_at, owner_tuple, lane_occupancies)
    validate_reservation_owner!(reservation, owner_tuple)
    hold = reservation.fetch("lane_holds").find { |candidate| candidate.fetch("lane_ref") == lane_ref }
    raise ArgumentError, "reservation lane hold missing" unless hold
    return reservation if hold.fetch("state") == "consumed"
    raise ArgumentError, "reservation lane hold terminal" unless hold.fetch("state") == "active"

    if Time.iso8601(consumed_at) >= Time.iso8601(reservation.fetch("expires_at"))
      raise ArgumentError, "reservation expired"
    end

    matching_occupancy = lane_occupancies.any? do |record|
      record.fetch("workspace") == reservation.fetch("workspace") &&
        record.fetch("capacity_profile_id") == reservation.fetch("capacity_profile_id") &&
        record.fetch("inbox_id") == reservation.fetch("inbox_id") &&
        record.fetch("lane_ref") == lane_ref && record.fetch("state") == "occupied"
    end
    raise ArgumentError, "matching occupied lane required" unless matching_occupancy

    reservation.merge(
      "lane_holds" => reservation.fetch("lane_holds").map do |hold|
        next hold unless hold.fetch("lane_ref") == lane_ref && hold.fetch("state") == "active"

        hold.merge("state" => "consumed", "consumed_at" => consumed_at)
      end
    )
  end

  def authoritative_capacity_inputs?(snapshot, requested_inbox_id = nil)
    profile = snapshot.fetch("capacity_profile")
    inboxes = snapshot.fetch("inboxes")
    occupancies = snapshot.fetch("lane_occupancies")
    reservations = snapshot.fetch("active_reservations")
    requested_inbox_id ||= snapshot.fetch("requests").first.fetch("inbox_id")
    return false unless capacity_records_conform?(profile, inboxes, occupancies, reservations, snapshot.fetch("as_of"))
    return false unless profile.fetch("status") == "enabled"

    requested_inbox = inboxes.find { |record| record.fetch("inbox_id") == requested_inbox_id }
    return false unless enabled_inbox_for_profile?(requested_inbox, profile)

    inbox_ids = inboxes.filter_map do |record|
      record.fetch("inbox_id") if record_matches_profile?(record, profile)
    end
    (occupancies + reservations).all? do |record|
      record_matches_profile?(record, profile) && inbox_ids.include?(record.fetch("inbox_id"))
    end
  rescue KeyError, NoMethodError
    false
  end

  def capacity_request_fits?(payload, used_refs, capacity)
    payload.uniq.length == payload.length &&
      payload.none? { |lane_ref| used_refs.include?(lane_ref) } &&
      payload.length <= capacity - used_refs.length
  end

  def validate_reservation_owner!(reservation, owner_tuple)
    actual_owner = %w[owner_machine owner_id instance_id].map { |field| reservation.fetch(field) }
    raise ArgumentError, "reservation owner mismatch" unless actual_owner == owner_tuple
  end

  def canonical_reservation_request(request)
    %w[
      capacity_profile_id inbox_id batch_id planning_attempt_id owner_machine owner_id instance_id ttl_seconds
    ].each_with_object({ "lane_refs" => request.fetch("lane_refs").sort }) do |field, payload|
      payload[field] = request[field] if request.key?(field)
    end
  end

  def enforce_unique_lane_hold_refs!(lane_holds)
    refs = lane_holds.map { |hold| hold.fetch("lane_ref") }
    raise ArgumentError, "duplicate reservation lane_ref" unless refs.uniq.length == refs.length
  end

  def enforce_batch_lane_refs!(reservation)
    return unless reservation.key?("batch_id")

    expected_batch = reservation.fetch("batch_id")
    matches = reservation.fetch("lane_holds").all? do |hold|
      hold.fetch("lane_ref").rpartition(":").first == expected_batch
    end
    raise ArgumentError, "reservation lane_ref must belong to batch_id" unless matches
  end

  def enforce_unique_active_lane_refs!(reservations, as_of)
    active_refs = reservations.flat_map do |reservation|
      active_lane_refs(reservation, as_of)
    end
    return if active_refs.uniq.length == active_refs.length

    raise ArgumentError, "active reservation lane_ref held more than once"
  end

  def replay_release_and_reserve_ordering(replay, operations)
    reservation = replay.fetch("existing_reservation")
    outcomes = []

    operations.each do |operation|
      case operation
      when "reserve"
        active_refs = active_lane_refs(reservation, replay.fetch("release_at"))
        outcome = active_refs.include?(replay.fetch("requested_lane_ref")) ? "RESERVATION_REFUSED" : "accepted"
        outcomes << outcome
      when "release"
        reservation = release_active_lane_holds(
          reservation,
          replay.fetch("release_at"),
          %w[owner_machine owner_id instance_id].map { |field| reservation.fetch(field) }
        )
        outcomes << "released"
      else
        raise ArgumentError, "unknown replay operation"
      end
    end

    {
      "outcomes" => outcomes,
      "existing_lane_state" => reservation.fetch("lane_holds").first.fetch("state")
    }
  end

  def reservation_capacity_at(reservation, as_of, max_concurrency)
    used_refs = active_lane_refs(reservation, as_of).uniq.sort

    { "used_lane_refs" => used_refs, "remaining_slots" => max_concurrency - used_refs.length }
  end

  def active_lane_refs(reservation, as_of)
    snapshot_time = as_of.is_a?(Time) ? as_of : Time.iso8601(as_of)
    return [] unless Time.iso8601(reservation.fetch("expires_at")) > snapshot_time

    reservation.fetch("lane_holds").filter_map do |hold|
      hold.fetch("lane_ref") if hold.fetch("state") == "active"
    end
  end

  def assert_capacity_lifecycle_timestamps(replay, reservation)
    expires_at = Time.iso8601(reservation.fetch("expires_at"))
    assert_equal reservation.fetch("ttl_seconds"), expires_at - Time.iso8601(reservation.fetch("created_at"))
    assert_operator expires_at, :>, Time.iso8601(replay.fetch("before_expiry"))
    assert_equal expires_at, Time.iso8601(replay.fetch("at_expiry"))
  end

  def assert_capacity_consume_lifecycle(replay, reservation, schema, owner_tuple, wrong_owner_tuple)
    lane_ref = "batch-capacity:lane-b"
    occupancies = replay.fetch("lane_occupancies")
    consumed = consume_active_lane_hold(reservation, lane_ref, replay.fetch("consume_at"), owner_tuple, occupancies)

    assert_equal replay.fetch("expected_after_consume"), consumed
    assert_empty schema.validate(consumed).to_a
    assert_equal consumed, consume_active_lane_hold(consumed, lane_ref, replay.fetch("consume_at"), owner_tuple,
                                                    occupancies)
    assert_raises(ArgumentError) do
      consume_active_lane_hold(reservation, lane_ref, replay.fetch("consume_at"), wrong_owner_tuple, occupancies)
    end
    assert_raises(ArgumentError) do
      consume_active_lane_hold(reservation, lane_ref, replay.fetch("consume_at"), owner_tuple, [])
    end
  end

  def assert_capacity_release_lifecycle(replay, reservation, schema, owner_tuple, wrong_owner_tuple)
    released = release_active_lane_holds(reservation, replay.fetch("release_at"), owner_tuple)

    assert_equal replay.fetch("expected_after_release"), released
    assert_empty schema.validate(released).to_a
    assert_equal released, release_active_lane_holds(released, replay.fetch("release_at"), owner_tuple)
    assert_raises(ArgumentError) do
      release_active_lane_holds(reservation, replay.fetch("release_at"), wrong_owner_tuple)
    end
  end

  def assert_capacity_expiry_lifecycle(replay, reservation, schema, owner_tuple)
    assert_raises(ArgumentError) do
      consume_active_lane_hold(reservation, "batch-capacity:lane-b", replay.fetch("at_expiry"), owner_tuple,
                               replay.fetch("lane_occupancies"))
    end
    expired = release_active_lane_holds(reservation, replay.fetch("at_expiry"), owner_tuple)

    assert_equal replay.fetch("expected_after_expiry"), expired
    assert_empty schema.validate(expired).to_a
    assert_equal expired, release_active_lane_holds(expired, replay.fetch("at_expiry"), owner_tuple)
  end

  def capacity_request_outcome(replay, request, accepted_payloads, used_refs, capacity)
    return "RESERVATION_REFUSED" unless authoritative_capacity_inputs?(replay, request.fetch("inbox_id"))

    request_id = request.fetch("reservation_id")
    canonical_payload = canonical_reservation_request(request)
    if accepted_payloads.key?(request_id)
      return accepted_payloads.fetch(request_id) == canonical_payload ? "idempotent" : "RESERVATION_CONFLICT"
    end
    return "RESERVATION_REFUSED" unless capacity_request_fits?(request.fetch("lane_refs"), used_refs, capacity)

    accepted_payloads[request_id] = canonical_payload
    used_refs.concat(request.fetch("lane_refs"))
    "accepted"
  end

  def capacity_records_conform?(profile, inboxes, occupancies, reservations, as_of)
    schemas = CAPACITY_SCHEMA_PATHS.transform_values do |path|
      JSONSchemer.schema(JSON.parse(File.read(path)))
    end
    schemas.fetch("capacity_profile").validate(profile).to_a.empty? &&
      inboxes.all? { |record| schemas.fetch("inbox").validate(record).to_a.empty? } &&
      occupancies.all? { |record| schemas.fetch("lane_occupancy").validate(record).to_a.empty? } &&
      reservations.all? { |record| schemas.fetch("capacity_reservation").validate(record).to_a.empty? } &&
      procedural_capacity_reservations_valid?(reservations, as_of)
  end

  def procedural_capacity_reservations_valid?(reservations, as_of)
    reservations.each do |reservation|
      enforce_unique_lane_hold_refs!(reservation.fetch("lane_holds"))
      enforce_batch_lane_refs!(reservation)
    end
    enforce_unique_active_lane_refs!(reservations, as_of)
    true
  rescue ArgumentError, KeyError
    false
  end

  def enabled_inbox_for_profile?(inbox, profile)
    inbox&.fetch("status") == "enabled" && record_matches_profile?(inbox, profile)
  end

  def record_matches_profile?(record, profile)
    record.fetch("workspace") == profile.fetch("workspace") &&
      record.fetch("capacity_profile_id") == profile.fetch("capacity_profile_id")
  end
end
