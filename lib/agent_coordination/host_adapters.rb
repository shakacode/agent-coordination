# frozen_string_literal: true

require "digest"
require "json"

module AgentCoord
  module Telemetry
    module HostAdapters
      # Shared with Harvester so host-session metadata and ledger metadata cannot
      # drift on what counts as a control character or surrounding whitespace.
      # Tab, LF, and CR are intentional layout noise only at the ends; every C0,
      # DEL, and C1 character is rejected when it remains in the value.
      INGEST_CONTROL_CHARACTERS = /[\u0000-\u001F\u007F-\u009F]/
      INGEST_SURROUNDING_WHITESPACE = /\A[\u0009\u000A\u000D\u0020]+|[\u0009\u000A\u000D\u0020]+\z/

      class Parser
        METADATA_TOKEN = %r{\A[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}\z}
        MODELS = %w[
          gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna
          claude-opus-4-6 claude-opus-4-7 claude-opus-4-8
        ].freeze
        EFFORTS = %w[low medium high xhigh max ultra].freeze
        PRICING_PROFILES = %w[standard].freeze
        MISSING = Object.new.freeze

        def initialize(host_family)
          @host_family = host_family
        end

        def parse(bytes, source_ref)
          @sessions = {}
          @errors = []
          @current_session_ref = nil
          bytes.each_line.with_index(1) { |line, ordinal| parse_line(line, ordinal, source_ref) }
          { "sessions" => @sessions.values, "errors" => @errors }
        end

        private

        def parse_line(line, ordinal, source_ref)
          record = JSON.parse(line)
          @host_family == "codex" ? parse_codex(record, ordinal, source_ref) : parse_claude(record, ordinal, source_ref)
        rescue JSON::ParserError, EncodingError
          @errors << { "record_ordinal" => ordinal, "reason" => "invalid_json" }
        end

        def parse_codex(record, ordinal, source_ref)
          return unless record.is_a?(Hash)

          payload = record["payload"]
          return unless payload.is_a?(Hash)

          case record["type"]
          when "session_meta"
            reference = session_ref(payload["id"] || "#{source_ref}:#{ordinal}")
            metadata = cwd_fields(present_value(payload, "cwd")).merge(
              "pricing_profile" => pricing_profile(present_value(payload, "pricing_profile"))
            )
            @current_session_ref = reference
            merge_known!(fetch_session(reference), metadata)
          when "turn_context"
            return unless @current_session_ref

            metadata = {
              "model" => model(present_value(payload, "model")),
              "effort" => effort(present_value(payload, "effort", "reasoning_effort")),
              "pricing_profile" => pricing_profile(present_value(payload, "pricing_profile"))
            }
            merge_known!(fetch_session(@current_session_ref), metadata)
          when "event_msg"
            return unless @current_session_ref && payload["type"] == "token_count"

            usage = payload.dig("info", "last_token_usage")
            return unless usage.is_a?(Hash)

            session = fetch_session(@current_session_ref)
            session.fetch("usage") << usage_row(
              usage, ordinal, session,
              cache_read_keys: %w[cached_input_tokens cached_input],
              cache_write_keys: %w[cache_write_input_tokens cache_write_input],
              reasoning_keys: %w[reasoning_output_tokens reasoning_output]
            )
          end
        end

        def parse_claude(record, ordinal, _source_ref)
          return unless record.is_a?(Hash) && record["type"] == "assistant"

          message = record["message"]
          return unless message.is_a?(Hash) && message["usage"].is_a?(Hash)

          reference = session_ref(record["sessionId"] || "claude-record-#{ordinal}")
          pricing_value = present_value(record, "pricing_profile")
          pricing_value = present_value(message.fetch("usage"), "pricing_profile") if pricing_value.equal?(MISSING)
          record_metadata = cwd_fields(present_value(record, "cwd")).merge(
            "model" => model(present_value(message, "model")),
            "effort" => effort(present_value(message, "effort")),
            "pricing_profile" => pricing_profile(pricing_value)
          )
          session = fetch_session(reference)
          merge_known!(session, record_metadata)
          session.fetch("usage") << usage_row(
            message.fetch("usage"), ordinal, session,
            cache_read_keys: %w[cache_read_input_tokens],
            cache_write_keys: %w[cache_creation_input_tokens],
            reasoning_keys: %w[reasoning_output_tokens]
          )
        end

        def fetch_session(reference)
          @sessions[reference] ||= {
            "host_family" => @host_family,
            "session_ref" => reference,
            "cwd_basename" => nil,
            "cwd_sha256" => nil,
            "model" => nil,
            "effort" => nil,
            "pricing_profile" => nil,
            "usage" => []
          }
        end

        # rubocop:disable Metrics/ParameterLists
        def usage_row(usage, ordinal, session, cache_read_keys:, cache_write_keys:, reasoning_keys:)
          row = {
            "record_ordinal" => ordinal,
            "model" => session["model"],
            "effort" => session["effort"],
            "pricing_profile" => session["pricing_profile"],
            "input_tokens" => counter(usage, %w[input_tokens]),
            "cache_read_tokens" => counter(usage, cache_read_keys),
            "cache_write_tokens" => counter(usage, cache_write_keys),
            "output_tokens" => counter(usage, %w[output_tokens]),
            "reasoning_output_tokens" => counter(usage, reasoning_keys),
            "total_tokens" => counter(usage, %w[total_tokens total])
          }
          row.merge("source_record_sha256" => Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h)))
        end
        # rubocop:enable Metrics/ParameterLists

        def counter(usage, keys)
          key = keys.find { |candidate| usage.key?(candidate) }
          value = usage[key] if key
          value if value.is_a?(Integer) && value >= 0
        end

        def cwd_fields(value)
          return {} if value.equal?(MISSING)

          value = known(value)
          return { "cwd_basename" => nil, "cwd_sha256" => nil } unless value

          basename = File.basename(value)
          {
            "cwd_basename" => metadata_token(basename),
            "cwd_sha256" => Digest::SHA256.hexdigest(value)
          }
        end

        def merge_known!(session, values)
          values.each { |key, value| session[key] = value unless value.equal?(MISSING) }
        end

        def session_ref(value)
          Digest::SHA256.hexdigest(value.to_s)[0, 32]
        end

        def known(value)
          return MISSING if value.equal?(MISSING)

          string = value.to_s
          raise Encoding::InvalidByteSequenceError, "invalid UTF-8 metadata" unless string.valid_encoding?

          string = string.gsub(INGEST_SURROUNDING_WHITESPACE, "")
          return if string.empty? || string.casecmp?("UNKNOWN")
          return if string.match?(INGEST_CONTROL_CHARACTERS)

          string
        end

        def metadata_token(value)
          string = known(value)
          string if string&.match?(METADATA_TOKEN)
        end

        def model(value)
          enum(value, MODELS)
        end

        def effort(value)
          enum(value, EFFORTS)
        end

        def pricing_profile(value)
          enum(value, PRICING_PROFILES)
        end

        def enum(value, allowed)
          string = known(value)
          return MISSING if string.equal?(MISSING)

          string if allowed.include?(string)
        end

        def present_value(record, *keys)
          key = keys.find { |candidate| record.key?(candidate) }
          key ? record[key] : MISSING
        end
      end
    end
  end
end
