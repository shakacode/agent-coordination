# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "time"

require_relative "ledger"

module AgentCoord
  module Telemetry
    class Error < StandardError; end

    class Harvester
      UNKNOWN = "UNKNOWN"
      TERMINAL_OUTCOMES = %w[abandoned done superseded].freeze
      BATCH_STATUSES = %w[active blocked cancelled completed done in_progress].freeze

      def initialize(ledger:, source_path:)
        @ledger = ledger
        @source_path = File.expand_path(source_path)
      end

      def harvest_batch(batch_id)
        source = read_source
        batches = Array(source["batches"]).select { |batch| batch.is_a?(Hash) && batch["batch_id"] == batch_id }
        raise Error, "named batch was not found" unless batches.one?

        batch = batches.first
        targets = target_rows(batch)
        @ledger.transaction do
          @ledger.upsert_batch(batch_row(batch))
          targets.each { |target| @ledger.upsert_target(target) }
        end
        { "batches" => 1, "targets" => targets.length, "usage" => 0 }
      end

      private

      def read_source
        parsed = JSON.parse(File.read(@source_path, encoding: "UTF-8"))
        raise Error, "coordination JSON must be an object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Error, "coordination JSON is invalid"
      rescue SystemCallError
        raise Error, "coordination JSON is unreadable"
      end

      def batch_row(batch)
        batch_id = known(batch["batch_id"])
        row = {
          "batch_id" => batch_id,
          "repo" => repo(batch["repo"]),
          "status" => enum(batch["status"], BATCH_STATUSES),
          "registered_at" => timestamp(batch["registered_at"]),
          "updated_at" => timestamp(batch["updated_at"]),
          "synthetic" => batch["synthetic"] == true ? 1 : 0,
          "source_kind" => "coordination",
          "source_ref" => @source_path,
          "source_record_id" => batch_id
        }
        row.merge("source_sha256" => allowlisted_digest(row))
      end

      def target_rows(batch)
        batch_id = known(batch["batch_id"])
        batch_repo = repo(batch["repo"])
        exploded = Array(batch["lanes"]).flat_map do |lane|
          next [] unless lane.is_a?(Hash)

          Array(lane["targets"] || lane["target"]).filter_map do |target|
            next if target.to_s.empty?

            { "target" => target.to_s, "lane" => known(lane["name"] || lane["id"]), "status" => lane["status"] }
          end
        end
        exploded.group_by { |row| row.fetch("target") }.map do |target, rows|
          target_row(batch_id, batch_repo, target, rows)
        end
      end

      def target_row(batch_id, batch_repo, target, rows)
        lanes = rows.map { |row| row.fetch("lane") }.uniq.sort
        outcomes = rows.filter_map { |row| TERMINAL_OUTCOMES.include?(row["status"]) ? row["status"] : nil }.uniq
        row = {
          "batch_id" => batch_id,
          "repo" => batch_repo,
          "target" => target,
          "lane_count" => lanes.length,
          "lanes_json" => JSON.generate(lanes),
          "outcome" => outcomes.one? ? outcomes.first : UNKNOWN,
          "source_kind" => "coordination",
          "source_ref" => @source_path,
          "source_record_id" => [batch_id, batch_repo, target].join("|")
        }
        row.merge("source_sha256" => allowlisted_digest(row))
      end

      def allowlisted_digest(row)
        Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
      end

      def known(value)
        string = value.to_s
        string.empty? ? UNKNOWN : string
      end

      def repo(value)
        value.to_s.match?(%r{\A[^/\s]+/[^/\s]+\z}) ? value : UNKNOWN
      end

      def enum(value, allowed)
        allowed.include?(value) ? value : UNKNOWN
      end

      def timestamp(value)
        Time.iso8601(value.to_s).utc.iso8601
      rescue ArgumentError
        UNKNOWN
      end
    end

    class CLI
      def self.run(argv, stdout: $stdout, stderr: $stderr)
        command = argv.shift
        raise Error, "usage: agent-coord-harvest harvest [options]" unless command == "harvest"

        options = {}
        OptionParser.new do |parser|
          parser.on("--ledger PATH") { |value| options[:ledger] = value }
          parser.on("--coordination-json PATH") { |value| options[:coordination_json] = value }
          parser.on("--batch-id ID") { |value| options[:batch_id] = value }
        end.parse!(argv)
        raise Error, "missing required option" if options.values_at(:ledger, :coordination_json, :batch_id).any?(&:nil?)
        raise Error, "unexpected argument" unless argv.empty?

        counts = Harvester.new(
          ledger: Ledger.new(options.fetch(:ledger)), source_path: options.fetch(:coordination_json)
        ).harvest_batch(options.fetch(:batch_id))
        stdout.puts "harvested batches=#{counts.fetch('batches')} targets=#{counts.fetch('targets')} " \
                    "usage=#{counts.fetch('usage')}"
        0
      rescue Error, OptionParser::ParseError => e
        stderr.puts "agent-coord-harvest: #{e.message}"
        2
      end
    end
  end
end
