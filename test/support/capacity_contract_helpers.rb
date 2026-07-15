# frozen_string_literal: true

module CapacityContractHelpers
  private

  def malformed_capacity_snapshots(replay)
    duplicate_holds = capacity_procedural_fixture("reservation-duplicate-lane-ref.json")
    batch_mismatch = capacity_procedural_fixture("reservation-batch-lane-mismatch.json")
    expiry_mismatch = capacity_procedural_fixture("reservation-expiry-mismatch.json")
    duplicate_active_lanes = capacity_procedural_fixture("reservations-duplicate-active-lane-ref.json")
    consumed_without_occupancy = replay.fetch("active_reservations").first.merge(
      "lane_holds" => [
        {
          "lane_ref" => "batch-capacity:lane-a",
          "state" => "consumed",
          "consumed_at" => replay.fetch("as_of")
        }
      ]
    )

    {
      "disabled profile" => replay.merge(
        "capacity_profile" => replay.fetch("capacity_profile").merge("status" => "disabled")
      ),
      "disabled inbox" => replay.merge(
        "inboxes" => replay.fetch("inboxes").map.with_index do |inbox, index|
          index.zero? ? inbox.merge("status" => "disabled") : inbox
        end
      ),
      "mismatched inbox profile" => replay.merge(
        "inboxes" => replay.fetch("inboxes").map.with_index do |inbox, index|
          index.zero? ? inbox.merge("capacity_profile_id" => "different-profile") : inbox
        end
      ),
      "missing lane occupancies" => replay.except("lane_occupancies"),
      "missing active reservations" => replay.except("active_reservations"),
      "invalid occupancy state" => replay.merge(
        "lane_occupancies" => [replay.fetch("lane_occupancies").first.merge("state" => "mystery")]
      ),
      "unknown reservation inbox" => replay.merge(
        "active_reservations" => [replay.fetch("active_reservations").first.merge("inbox_id" => "missing")]
      ),
      "duplicate lane holds" => replay.merge("active_reservations" => [duplicate_holds]),
      "batch lane mismatch" => replay.merge("active_reservations" => [batch_mismatch]),
      "expiry mismatch" => replay.merge("active_reservations" => [expiry_mismatch]),
      "duplicate active lanes" => replay.merge(
        "active_reservations" => duplicate_active_lanes.fetch("active_reservations")
      ),
      "consumed hold without occupancy" => replay.merge("active_reservations" => [consumed_without_occupancy])
    }.merge(malformed_duplicate_key_snapshots(replay))
  end

  def malformed_duplicate_key_snapshots(replay)
    inbox = replay.fetch("inboxes").first
    occupancy = replay.fetch("lane_occupancies").first
    reservation = replay.fetch("active_reservations").first
    changed_reservation = reservation.merge(
      "lane_holds" => [{ "lane_ref" => "batch-capacity:lane-z", "state" => "active" }]
    )

    {
      "duplicate inbox key" => replay.merge("inboxes" => [inbox, inbox.merge("status" => "disabled")]),
      "duplicate occupancy key" => replay.merge("lane_occupancies" => [occupancy, occupancy.dup]),
      "duplicate reservation key" => replay.merge("active_reservations" => [reservation, changed_reservation])
    }
  end

  def capacity_procedural_fixture(filename)
    read_fixture(File.join(self.class::CAPACITY_FIXTURES_PATH, "procedural", filename))
  end

  def capacity_schemas
    @capacity_schemas ||= self.class::CAPACITY_SCHEMA_PATHS.transform_values do |path|
      JSONSchemer.schema(JSON.parse(File.read(path)))
    end
  end

  def capacity_logical_keys_unique?(inboxes, occupancies, reservations)
    unique_capacity_keys?(inboxes, %w[workspace inbox_id]) &&
      unique_capacity_keys?(occupancies, %w[workspace lane_ref]) &&
      unique_capacity_keys?(reservations, %w[workspace reservation_id])
  end

  def unique_capacity_keys?(records, fields)
    keys = records.map { |record| fields.map { |field| record.fetch(field) } }
    keys.uniq.length == keys.length
  end
end
