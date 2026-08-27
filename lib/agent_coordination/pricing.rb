# frozen_string_literal: true

require "digest"
require "json"

module AgentCoord
  module Telemetry
    class PricingCatalog
      COMPONENT_FIELDS = {
        "input" => "input_tokens",
        "cache_read" => "cache_read_tokens",
        "cache_write" => "cache_write_tokens",
        "output" => "output_tokens",
        "reasoning_output" => "reasoning_output_tokens"
      }.freeze
      INPUT_COMPONENTS = %w[input cache_read cache_write].freeze

      attr_reader :snapshot_id

      def self.load(path)
        bytes = File.binread(path)
        document = JSON.parse(bytes)
        new(document, Digest::SHA256.hexdigest(bytes))
      rescue JSON::ParserError
        raise Error, "pricing JSON is invalid"
      rescue SystemCallError
        raise Error, "pricing JSON is unreadable"
      end

      def initialize(document, source_sha256)
        unless document.is_a?(Hash) && document["contract"] == "telemetry-pricing-v1" && document["version"] == 1
          raise Error, "pricing contract is invalid"
        end
        raise Error, "pricing currency is unsupported" unless document["currency"] == "USD"
        raise Error, "pricing unit is unsupported" unless document["unit"] == "microusd_per_million_tokens"

        @document = document
        @source_sha256 = source_sha256
        @snapshot_id = document.fetch("snapshot_id")
        @definitions = {}
        Array(document["rates"]).each do |rate|
          validate_rate!(rate)
          key = [rate.fetch("model"), rate.fetch("profile")]
          raise Error, "pricing model/profile is duplicated" if @definitions.key?(key)

          @definitions[key] = rate
        end
      end

      def persist(ledger) # rubocop:disable Metrics/MethodLength
        existing = ledger.first(
          "SELECT source_sha256 FROM pricing_snapshots WHERE snapshot_id = ?",
          [snapshot_id]
        )
        if existing && existing.fetch("source_sha256") != @source_sha256
          raise Error, "pricing snapshot source hash mismatch"
        end

        snapshot_values = [
          snapshot_id,
          @document.fetch("version"),
          @document.fetch("currency"),
          @document.fetch("published_at"),
          @source_sha256
        ]
        ledger.execute(
          <<~SQL, snapshot_values
            INSERT INTO pricing_snapshots (snapshot_id, version, currency, published_at, source_sha256)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(snapshot_id) DO UPDATE SET
              version = excluded.version,
              currency = excluded.currency,
              published_at = excluded.published_at,
              source_sha256 = excluded.source_sha256
          SQL
        )
        ledger.execute("DELETE FROM pricing_rates WHERE snapshot_id = ?", [snapshot_id])
        @definitions.each_value do |definition| # rubocop:disable Metrics/BlockLength
          long = definition.fetch("long_context", {})
          definition.fetch("components").each do |component, rate|
            rate_values = [
              snapshot_id,
              definition.fetch("provider"),
              definition.fetch("model"),
              definition.fetch("profile"),
              component,
              rate,
              long["threshold_input_tokens"],
              long.fetch("input_multiplier_numerator", 1),
              long.fetch("input_multiplier_denominator", 1),
              long.fetch("output_multiplier_numerator", 1),
              long.fetch("output_multiplier_denominator", 1)
            ]
            ledger.execute(
              <<~SQL, rate_values
                INSERT INTO pricing_rates (
                  snapshot_id, provider, model, profile, component,
                  rate_microusd_per_million_tokens, long_context_threshold_input_tokens,
                  input_multiplier_numerator, input_multiplier_denominator,
                  output_multiplier_numerator, output_multiplier_denominator
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              SQL
            )
          end
        end
      end

      def cost(usage)
        definition = @definitions[[usage["model"], usage["pricing_profile"]]]
        return unknown_cost unless definition

        components = definition.fetch("components")
        counters = components.to_h do |component, _rate|
          field = COMPONENT_FIELDS.fetch(component)
          [component, usage[field]]
        end
        return unknown_cost unless counters.values.all? { |value| value.is_a?(Integer) && value >= 0 }

        long_context = long_context?(definition, counters)
        priced_components = counters.map do |component, tokens|
          numerator, denominator = multiplier(definition, component, long_context)
          rate = components.fetch(component)
          cost = divide_round_half_up(tokens * rate * numerator, 1_000_000 * denominator)
          {
            "component" => component,
            "tokens" => tokens,
            "rate_microusd_per_million_tokens" => rate,
            "multiplier_numerator" => numerator,
            "multiplier_denominator" => denominator,
            "cost_microusd" => cost
          }
        end
        {
          "pricing_snapshot_id" => snapshot_id,
          "pricing_status" => "priced",
          "total_cost_microusd" => priced_components.sum { |component| component.fetch("cost_microusd") },
          "components" => priced_components
        }
      end

      private

      def validate_rate!(rate)
        unless rate.is_a?(Hash) && rate["components"].is_a?(Hash) &&
               rate.fetch("components").all? do |component, value|
                 COMPONENT_FIELDS.key?(component) && value.is_a?(Integer) && value >= 0
               end
          raise Error, "pricing rate is invalid"
        end
      end

      def long_context?(definition, counters)
        threshold = definition.dig("long_context", "threshold_input_tokens")
        threshold.is_a?(Integer) && INPUT_COMPONENTS.sum { |component| counters.fetch(component, 0) } > threshold
      end

      def multiplier(definition, component, long_context)
        return [1, 1] unless long_context

        prefix = INPUT_COMPONENTS.include?(component) ? "input" : "output"
        long = definition.fetch("long_context")
        [long.fetch("#{prefix}_multiplier_numerator"), long.fetch("#{prefix}_multiplier_denominator")]
      end

      def divide_round_half_up(numerator, denominator)
        (numerator + (denominator / 2)) / denominator
      end

      def unknown_cost
        {
          "pricing_snapshot_id" => snapshot_id,
          "pricing_status" => "unknown",
          "total_cost_microusd" => nil,
          "components" => []
        }
      end
    end
  end
end
