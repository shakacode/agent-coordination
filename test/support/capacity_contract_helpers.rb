# frozen_string_literal: true

module CapacityContractHelpers
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
    }
  end

  def capacity_procedural_fixture(filename)
    read_fixture(File.join(self.class::CAPACITY_FIXTURES_PATH, "procedural", filename))
  end
end
