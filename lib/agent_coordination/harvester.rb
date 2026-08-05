# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "optparse"
require "time"

require_relative "ledger"
require_relative "host_adapters"
require_relative "pricing"
require_relative "scorecards"

module AgentCoord
  module Telemetry
    class Error < StandardError; end

    class Harvester # rubocop:disable Metrics/ClassLength
      DEFAULT_PRICING = File.expand_path("../../config/telemetry-pricing-v1.json", __dir__)
      BATCH_STATUSES = %w[active blocked cancelled completed done in_progress].freeze
      HOST_FAMILIES = %w[codex claude].freeze
      PR_STATES = %w[open closed merged].freeze
      EVENT_TYPES = %w[
        claim release lane_closed dispatch-replaced replacement worker-replacement
        lane-takeover collision-blocked model-escalation MODEL_ESCALATION_REQUEST
      ].freeze
      REVIEW_DISPOSITIONS = %w[
        should_fix discuss optional skipped resolved accepted-waiver accepted-deferral not-applicable
      ].freeze
      VERIFICATION_STATUSES = %w[verified unverified current stale].freeze
      MODELS = %w[
        gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna
        claude-opus-4-6 claude-opus-4-7 claude-opus-4-8
      ].freeze
      EFFORTS = %w[low medium high xhigh max ultra].freeze
      PRICING_PROFILES = %w[standard].freeze
      EXCEPTIONAL_OUTCOMES = %w[blocked-user-input no-pr-evidence failed abandoned superseded].freeze
      STATUS_OUTCOMES = {
        "blocked" => "blocked",
        "blocked-user-input" => "blocked-user-input",
        "completed" => "done",
        "done" => "done",
        "failed" => "failed",
        "abandoned" => "abandoned",
        "superseded" => "superseded",
        "in_progress" => "in-progress",
        "implementing" => "in-progress",
        "open" => "in-progress",
        "ready" => "ready",
        "waiting" => "waiting",
        "no-pr-evidence" => "no-pr-evidence",
        "merged" => "merged"
      }.freeze
      STRUCTURED_STATUSES = (
        STATUS_OUTCOMES.keys + BATCH_STATUSES + %w[claimed released active]
      ).uniq.freeze

      # rubocop:disable Metrics/ParameterLists
      def initialize(ledger:, source_path:, github_path: nil, codex_root: nil, claude_root: nil,
                     pricing_path: DEFAULT_PRICING)
        @ledger = ledger
        @source_path = File.expand_path(source_path)
        @github_path = File.expand_path(github_path) if github_path
        @codex_root = File.expand_path(codex_root) if codex_root
        @claude_root = File.expand_path(claude_root) if claude_root
        @pricing = PricingCatalog.load(File.expand_path(pricing_path))
      end
      # rubocop:enable Metrics/ParameterLists

      def harvest_batch(batch_id)
        source = read_json(@source_path, "coordination")
        batches = Array(source.fetch("document")["batches"]).select do |batch|
          batch.is_a?(Hash) && batch["batch_id"] == batch_id
        end
        raise Error, "named batch was not found" unless batches.one?

        harvest_batches(source, batches)
      end

      def harvest_range(from_date, to_date)
        from = Date.iso8601(from_date)
        to = Date.iso8601(to_date)
        raise Error, "date range is reversed" if from > to

        source = read_json(@source_path, "coordination")
        batches = Array(source.fetch("document")["batches"]).select do |batch|
          batch.is_a?(Hash) && timestamp_date(batch["registered_at"])&.between?(from, to)
        end
        harvest_batches(source, batches, date_range: [from.iso8601, to.iso8601])
      rescue Date::Error
        raise Error, "date range must use YYYY-MM-DD"
      end

      private

      def harvest_batches(source, batches, date_range: nil)
        selected_ids = batches.filter_map { |batch| known(batch["batch_id"]) }
        observations = []
        github = @github_path ? read_json(@github_path, "github") : nil
        usage_count = 0
        @ledger.transaction do
          @pricing.persist(@ledger)
          coordination_artifact_id = upsert_artifact(source)
          reconciled_ids = date_range ? reconcile_date_range(coordination_artifact_id, date_range) : []
          refreshed_ids = (reconciled_ids + selected_ids).uniq
          preserved_pr_links = github ? [] : snapshot_target_pr_links(refreshed_ids)
          delete_coordination_rows(refreshed_ids)
          refreshed_ids.each { |batch_id| @ledger.delete_batch(batch_id) }
          batches.each do |batch|
            batch_id = known(batch["batch_id"])
            next unless batch_id

            observations.concat(insert_batch(batch, coordination_artifact_id))
          end
          insert_coordination_rows(source.fetch("document"), coordination_artifact_id, selected_ids)
          create_target_units(observations)
          restore_target_pr_links(preserved_pr_links)
          ingest_github(github) if github
          usage_count = ingest_host_roots
          relink_host_sessions
          outcome_batch_ids = if github
                                @ledger.rows("SELECT batch_id FROM batches").map { |row| row.fetch("batch_id") }
                              else
                                selected_ids
                              end
          outcome_batch_ids.each { |batch_id| recompute_outcomes(batch_id) }
        end
        {
          "batches" => selected_ids.length,
          "targets" => observations.filter_map { |row| exact_key(row) }.uniq.length,
          "usage" => usage_count
        }
      end

      def reconcile_date_range(source_artifact_id, date_range)
        from_date, to_date = date_range
        @ledger.rows(
          <<~SQL, [source_artifact_id, from_date, to_date]
            SELECT batch_id
            FROM batches
            WHERE source_artifact_id = ?
              AND date(registered_at) BETWEEN ? AND ?
          SQL
        ).map { |row| row.fetch("batch_id") }
      end

      def delete_coordination_rows(batch_ids)
        return if batch_ids.empty?

        placeholders = (["?"] * batch_ids.length).join(", ")
        @ledger.execute("DELETE FROM claims WHERE batch_id IN (#{placeholders})", batch_ids)
        @ledger.execute("DELETE FROM events WHERE batch_id IN (#{placeholders})", batch_ids)
      end

      def snapshot_target_pr_links(batch_ids)
        return [] if batch_ids.empty?

        placeholders = (["?"] * batch_ids.length).join(", ")
        @ledger.rows(
          <<~SQL, batch_ids
            SELECT target_units.batch_id, target_units.repo, target_units.target,
                   target_pr_links.github_pr_id, target_pr_links.link_status,
                   target_pr_links.source_record_sha256
            FROM target_units
            JOIN target_pr_links ON target_pr_links.target_unit_id = target_units.id
            WHERE target_units.batch_id IN (#{placeholders})
          SQL
        )
      end

      def restore_target_pr_links(links)
        restored = links.filter_map do |link|
          target = @ledger.first(
            "SELECT id FROM target_units WHERE batch_id = ? AND repo = ? AND target = ?",
            link.values_at("batch_id", "repo", "target")
          )
          next unless target

          target_unit_id = target.fetch("id")
          @ledger.execute(
            <<~SQL, [target_unit_id, *link.values_at("github_pr_id", "link_status", "source_record_sha256")]
              INSERT INTO target_pr_links (
                target_unit_id, github_pr_id, link_status, source_record_sha256
              ) VALUES (?, ?, ?, ?)
            SQL
          )
          [link.fetch("github_pr_id"), target_unit_id, link.fetch("link_status")]
        end
        restored.map(&:first).uniq.each do |github_pr_id|
          exact_target_ids = @ledger.rows(
            "SELECT target_unit_id FROM target_pr_links WHERE github_pr_id = ? AND link_status = 'exact'",
            [github_pr_id]
          ).map { |row| row.fetch("target_unit_id") }.uniq
          target_unit_id = exact_target_ids.one? ? exact_target_ids.first : nil
          @ledger.execute(
            "UPDATE review_receipts SET target_unit_id = ? WHERE github_pr_id = ?",
            [target_unit_id, github_pr_id]
          )
        end
      end

      def ingest_host_roots
        [
          ["codex", @codex_root],
          ["claude", @claude_root]
        ].sum do |host_family, root|
          root ? ingest_host_root(host_family, root) : 0
        end
      end

      def ingest_host_root(host_family, root)
        paths = host_log_paths(host_family, root)
        sources = paths.map { |path| read_host_source(path, root, host_family) }
        delete_stale_host_artifacts(host_family, sources.map { |source| source.fetch("source_key") })
        sources.sum do |source|
          artifact_id = upsert_artifact(source)
          @ledger.execute("DELETE FROM ingestion_errors WHERE source_artifact_id = ?", [artifact_id])
          @ledger.execute("DELETE FROM host_sessions WHERE source_artifact_id = ?", [artifact_id])
          parsed = HostAdapters::Parser.new(host_family).parse(
            source.fetch("bytes"), source.fetch("source_ref")
          )
          parsed.fetch("errors").each do |error|
            @ledger.execute(
              "INSERT INTO ingestion_errors (source_artifact_id, record_ordinal, reason) VALUES (?, ?, ?)",
              [artifact_id, error.fetch("record_ordinal"), error.fetch("reason")]
            )
          end
          parsed.fetch("sessions").sum do |session|
            insert_host_session(session, artifact_id)
          end
        end
      end

      def relink_host_sessions
        @ledger.execute("DELETE FROM allocated_costs")
        @ledger.execute("DELETE FROM session_lane_links")
        @ledger.rows(
          <<~SQL
            SELECT host_sessions.id, host_sessions.session_ref, host_sessions.host_family
            FROM host_sessions
          SQL
        ).each do |session|
          host_session_id = session.fetch("id")
          link_host_session(host_session_id, session)
          allocate_session_cost(host_session_id)
        end
      end

      def host_log_paths(host_family, root)
        prefix = host_family == "codex" ? "sessions" : "projects"
        Dir.glob(File.join(root, prefix, "**", "*.jsonl"))
      end

      def read_host_source(path, root, host_family)
        bytes = File.binread(path)
        relative = path.delete_prefix("#{root}/")
        relative_ref = Digest::SHA256.hexdigest(relative)
        {
          "bytes" => bytes,
          "source_kind" => host_family,
          "source_key" => "#{host_family}:#{relative_ref}",
          "source_ref" => "#{host_family}:#{relative_ref[0, 16]}",
          "source_sha256" => Digest::SHA256.hexdigest(bytes)
        }
      rescue SystemCallError
        raise Error, "#{host_family} logs are unreadable"
      end

      def delete_stale_host_artifacts(host_family, source_keys)
        if source_keys.empty?
          @ledger.execute("DELETE FROM source_artifacts WHERE source_kind = ?", [host_family])
        else
          placeholders = (["?"] * source_keys.length).join(", ")
          @ledger.execute(
            "DELETE FROM source_artifacts WHERE source_kind = ? AND source_key NOT IN (#{placeholders})",
            [host_family, *source_keys]
          )
        end
      end

      def insert_host_session(session, artifact_id) # rubocop:disable Metrics/MethodLength
        row = session.except("usage").merge("source_artifact_id" => artifact_id, "link_status" => "unmatched")
        source_digest = allowlisted_digest(row)
        @ledger.execute(
          <<~SQL,
            INSERT INTO host_sessions (
              host_family, session_ref, cwd_basename, cwd_sha256, model, effort,
              pricing_profile, link_status, source_artifact_id, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          row.values_at(
            "host_family", "session_ref", "cwd_basename", "cwd_sha256", "model", "effort",
            "pricing_profile", "link_status", "source_artifact_id"
          ) + [source_digest]
        )
        host_session_id = @ledger.first(
          "SELECT id FROM host_sessions WHERE source_artifact_id = ? AND session_ref = ?",
          [artifact_id, session.fetch("session_ref")]
        ).fetch("id")
        link_host_session(host_session_id, session)
        session.fetch("usage").each do |usage| # rubocop:disable Metrics/BlockLength
          cost = @pricing.cost(usage)
          @ledger.execute(
            <<~SQL,
              INSERT INTO usage_calls (
                host_session_id, source_artifact_id, record_ordinal, model, effort, pricing_profile,
                input_tokens, cache_read_tokens, cache_write_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, source_record_sha256,
                pricing_snapshot_id, pricing_status, total_cost_microusd
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            SQL
            [host_session_id, artifact_id] + usage.values_at(
              "record_ordinal", "model", "effort", "pricing_profile", "input_tokens",
              "cache_read_tokens", "cache_write_tokens", "output_tokens",
              "reasoning_output_tokens", "total_tokens", "source_record_sha256"
            ) + cost.values_at("pricing_snapshot_id", "pricing_status", "total_cost_microusd")
          )
          usage_call_id = @ledger.first(
            "SELECT id FROM usage_calls WHERE source_artifact_id = ? AND record_ordinal = ?",
            [artifact_id, usage.fetch("record_ordinal")]
          ).fetch("id")
          cost.fetch("components").each do |component|
            component_values = [usage_call_id] + component.values_at(
              "component", "tokens", "rate_microusd_per_million_tokens",
              "multiplier_numerator", "multiplier_denominator", "cost_microusd"
            )
            @ledger.execute(
              <<~SQL, component_values
                INSERT INTO usage_cost_components (
                  usage_call_id, component, tokens, rate_microusd_per_million_tokens,
                  multiplier_numerator, multiplier_denominator, cost_microusd
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
              SQL
            )
          end
        end
        allocate_session_cost(host_session_id)
        session.fetch("usage").length
      end

      def allocate_session_cost(host_session_id)
        link = @ledger.first(
          "SELECT target_unit_id FROM session_lane_links WHERE host_session_id = ?", [host_session_id]
        )
        return unless link

        calls = @ledger.rows(
          "SELECT pricing_snapshot_id, pricing_status, total_cost_microusd " \
          "FROM usage_calls WHERE host_session_id = ?",
          [host_session_id]
        )
        snapshot_ids = calls.filter_map { |call| call["pricing_snapshot_id"] }.uniq
        priced = calls.any? && snapshot_ids.one? && calls.all? { |call| call["pricing_status"] == "priced" }
        allocated_values = [
          link.fetch("target_unit_id"),
          host_session_id,
          snapshot_ids.one? ? snapshot_ids.first : nil,
          priced ? "priced" : "unknown",
          priced ? calls.sum { |call| call.fetch("total_cost_microusd") } : nil
        ]
        @ledger.execute(
          <<~SQL, allocated_values
            INSERT INTO allocated_costs (
              target_unit_id, host_session_id, pricing_snapshot_id, pricing_status, cost_microusd
            ) VALUES (?, ?, ?, ?, ?)
          SQL
        )
      end

      def link_host_session(host_session_id, session)
        candidates = @ledger.rows(
          <<~SQL, [session.fetch("session_ref"), session.fetch("host_family")]
            SELECT target_units.id AS target_unit_id, lanes.lane_id
            FROM lanes
            JOIN target_units ON target_units.batch_id = lanes.batch_id
            JOIN lane_memberships
              ON lane_memberships.target_unit_id = target_units.id
             AND lane_memberships.lane_id = lanes.lane_id
            WHERE lanes.session_ref = ?
              AND (lanes.host_family = ? OR lanes.host_family IS NULL)
          SQL
        )
        status = if candidates.one?
                   "exact"
                 elsif candidates.empty?
                   "unmatched"
                 else
                   "ambiguous"
                 end
        @ledger.execute("UPDATE host_sessions SET link_status = ? WHERE id = ?", [status, host_session_id])
        return unless candidates.one?

        candidate = candidates.first
        @ledger.execute(
          <<~SQL, [host_session_id, candidate.fetch("target_unit_id"), candidate.fetch("lane_id")]
            INSERT INTO session_lane_links (host_session_id, target_unit_id, lane_id, link_status)
            VALUES (?, ?, ?, 'exact')
          SQL
        )
      end

      def insert_batch(batch, source_artifact_id)
        batch_id = known(batch["batch_id"])
        batch_repo = repo(batch["repo"])
        row = {
          "batch_id" => batch_id,
          "repo" => batch_repo,
          "join_status" => batch_repo ? "exact" : "missing_repo",
          "status" => enum(batch["status"], BATCH_STATUSES),
          "registered_at" => timestamp(batch["registered_at"]),
          "updated_at" => timestamp(batch["updated_at"]),
          "synthetic" => batch["synthetic"] == true ? 1 : 0,
          "source_kind" => "coordination",
          "source_artifact_id" => source_artifact_id
        }
        @ledger.insert_batch(row.merge("source_record_sha256" => allowlisted_digest(row)))
        Array(batch["lanes"]).each_with_index.flat_map do |lane, lane_index|
          insert_lane(batch_id, batch_repo, lane, lane_index)
        end
      end

      def insert_lane(batch_id, batch_repo, lane, lane_index)
        return [] unless lane.is_a?(Hash)

        lane_id = known(lane["name"] || lane["id"])
        lane_row = {
          "batch_id" => batch_id,
          "lane_id" => lane_id,
          "owner_ref" => opaque_value(lane["owner"]),
          "status" => enum(lane["status"], STRUCTURED_STATUSES),
          "host_family" => enum(lane["host"], HOST_FAMILIES),
          "session_ref" => opaque_value(lane["session_id"])
        }
        @ledger.upsert_lane(lane_row.merge("source_record_sha256" => allowlisted_digest(lane_row))) if lane_id

        targets = lane.key?("targets") ? Array(lane["targets"]) : [lane["target"]]
        targets = [nil] if targets.empty?
        targets.map.with_index do |target_value, target_index|
          observation = {
            "batch_id" => batch_id,
            "lane_id" => lane_id,
            "repo" => repo(lane["repo"]) || batch_repo,
            "target" => known(target_value),
            "status" => enum(lane["status"], STRUCTURED_STATUSES),
            "pr_url" => github_url(lane["pr_url"]),
            "join_status" => join_status(batch_id, repo(lane["repo"]) || batch_repo, known(target_value)),
            "source_ordinal" => [lane_index, target_index]
          }
          stored = observation.except("source_ordinal")
          @ledger.insert_target_observation(
            stored.merge("source_record_sha256" => allowlisted_digest(observation))
          )
          stored
        end
      end

      def create_target_units(observations)
        observations.group_by { |row| exact_key(row) }.each do |key, rows|
          next unless key

          batch_id, target_repo, target = key
          unit_id = @ledger.insert_target_unit(
            "batch_id" => batch_id,
            "repo" => target_repo,
            "target" => target,
            "pr_join_status" => rows.any? { |row| row["pr_url"] } ? "unresolved" : "none"
          )
          rows.filter_map { |row| row["lane_id"] }.uniq.sort.each do |lane_id|
            @ledger.insert_lane_membership(unit_id, lane_id)
          end
        end
      end

      def insert_coordination_rows(document, source_artifact_id, selected_ids)
        Array(document["claims"]).each_with_index do |claim, index|
          insert_claim(claim, index, source_artifact_id) if selected_ids.include?(known(claim["batch_id"]))
        end
        Array(document["events"]).each_with_index do |event, index|
          insert_event(event, index, source_artifact_id) if selected_ids.include?(known(event["batch_id"]))
        end
      end

      def insert_claim(claim, index, source_artifact_id)
        return unless claim.is_a?(Hash)

        row = {
          "batch_id" => known(claim["batch_id"]),
          "repo" => repo(claim["repo"]),
          "target" => known(claim["target"]),
          "status" => enum(claim["status"], STRUCTURED_STATUSES),
          "terminal" => enum(claim["terminal"], STRUCTURED_STATUSES),
          "pr_url" => github_url(claim["pr_url"]),
          "join_status" => join_status(known(claim["batch_id"]), repo(claim["repo"]), known(claim["target"])),
          "source_artifact_id" => source_artifact_id,
          "source_ordinal" => index
        }
        @ledger.execute(
          <<~SQL,
            INSERT INTO claims (
              batch_id, repo, target, status, terminal, pr_url, join_status,
              source_artifact_id, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          row.except("source_ordinal").values_at(
            "batch_id", "repo", "target", "status", "terminal", "pr_url", "join_status", "source_artifact_id"
          ) + [allowlisted_digest(row)]
        )
      end

      def insert_event(event, index, source_artifact_id)
        return unless event.is_a?(Hash)

        row = {
          "event_ref" => opaque_value(event["id"]) || "record-#{index}",
          "batch_id" => known(event["batch_id"]),
          "repo" => repo(event["repo"]),
          "target" => known(event["target"]),
          "event_type" => enum(event["type"], EVENT_TYPES),
          "observed_at" => timestamp(event["at"] || event["timestamp"]),
          "terminal" => enum(event["terminal"], STRUCTURED_STATUSES),
          "join_status" => join_status(known(event["batch_id"]), repo(event["repo"]), known(event["target"])),
          "source_artifact_id" => source_artifact_id,
          "source_ordinal" => index
        }
        @ledger.execute(
          <<~SQL,
            INSERT INTO events (
              event_ref, batch_id, repo, target, event_type, observed_at, terminal,
              join_status, source_artifact_id, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          row.except("source_ordinal").values_at(
            "event_ref", "batch_id", "repo", "target", "event_type", "observed_at", "terminal",
            "join_status", "source_artifact_id"
          ) + [allowlisted_digest(row)]
        )
      end

      def ingest_github(source)
        source_artifact_id = upsert_artifact(source)
        @ledger.delete_github_prs(source_artifact_id)
        Array(source.fetch("document")["pull_requests"]).each_with_index do |pull_request, index|
          insert_pull_request(pull_request, index, source_artifact_id) if pull_request.is_a?(Hash)
        end
      end

      def insert_pull_request(pull_request, index, source_artifact_id) # rubocop:disable Metrics/MethodLength
        pr_repo = repo(pull_request["repo"])
        number = positive_integer(pull_request["number"])
        state = enum(pull_request["state"], PR_STATES)
        url = github_url(pull_request["url"])
        return unless pr_repo && number && state && url

        row = {
          "repo" => pr_repo,
          "number" => number,
          "url" => url,
          "state" => state,
          "created_at" => timestamp(pull_request["created_at"]),
          "merged_at" => timestamp(pull_request["merged_at"]),
          "source_artifact_id" => source_artifact_id,
          "source_ordinal" => index
        }
        github_pr_id = @ledger.insert_github_pr(
          row.except("source_ordinal").merge("source_record_sha256" => allowlisted_digest(row))
        )
        explicit = @ledger.rows(
          "SELECT id, repo FROM target_units WHERE batch_id = ? AND target = ?",
          [known(pull_request["batch_id"]), known(pull_request["target"])]
        )
        candidates = explicit +
                     @ledger.rows(
                       <<~SQL, [url]
                         SELECT DISTINCT target_units.id, target_units.repo
                         FROM target_units
                         JOIN target_observations
                           ON target_observations.batch_id = target_units.batch_id
                          AND target_observations.repo = target_units.repo
                          AND target_observations.target = target_units.target
                         WHERE target_observations.pr_url = ?
                       SQL
                     )
        links = candidates.each_with_object({}) do |candidate, result|
          target_unit_id = candidate.fetch("id")
          status = candidate.fetch("repo") == pr_repo ? "exact" : "repo_mismatch"
          result[target_unit_id] = status if result[target_unit_id] != "exact"
        end
        links.each do |target_unit_id, link_status|
          @ledger.execute(
            <<~SQL, [target_unit_id, github_pr_id, link_status, allowlisted_digest(row)]
              INSERT OR IGNORE INTO target_pr_links (
                target_unit_id, github_pr_id, link_status, source_record_sha256
              ) VALUES (?, ?, ?, ?)
            SQL
          )
        end
        exact_linked_ids = links.filter_map { |target_unit_id, status| target_unit_id if status == "exact" }
        insert_reviews(pull_request, github_pr_id, exact_linked_ids, row)
      end

      def insert_reviews(pull_request, github_pr_id, linked_ids, pull_request_row) # rubocop:disable Metrics/MethodLength
        Array(pull_request["reviews"]).each_with_index do |review, review_index| # rubocop:disable Metrics/BlockLength
          next unless review.is_a?(Hash)

          provenance = review["provenance"]
          usage = provenance["usage"] if provenance.is_a?(Hash)
          provenance ||= {}
          usage = {} unless usage.is_a?(Hash)
          receipt_usage = {
            "model" => enum(provenance["model"], MODELS),
            "effort" => enum(provenance["effort"], EFFORTS),
            "pricing_profile" => enum(provenance["pricing_profile"], PRICING_PROFILES),
            "input_tokens" => nonnegative_integer(usage["input_tokens"]),
            "cache_read_tokens" => nonnegative_integer(usage["cache_read_tokens"]),
            "cache_write_tokens" => nonnegative_integer(usage["cache_write_tokens"]),
            "output_tokens" => nonnegative_integer(usage["output_tokens"]),
            "reasoning_output_tokens" => nonnegative_integer(usage["reasoning_output_tokens"]),
            "total_tokens" => nonnegative_integer(usage["total_tokens"])
          }
          cost = @pricing.cost(receipt_usage)
          review_ref = opaque_value(review["id"]) || "#{github_pr_id}:#{review_index}"
          target_unit_id = linked_ids.one? ? linked_ids.first : nil
          receipt_row = {
            "github_pr_id" => github_pr_id,
            "target_unit_id" => target_unit_id,
            "review_ref" => review_ref,
            "model" => receipt_usage["model"],
            "effort" => receipt_usage["effort"],
            "pricing_profile" => receipt_usage["pricing_profile"],
            "input_tokens" => receipt_usage["input_tokens"],
            "cache_read_tokens" => receipt_usage["cache_read_tokens"],
            "cache_write_tokens" => receipt_usage["cache_write_tokens"],
            "output_tokens" => receipt_usage["output_tokens"],
            "reasoning_output_tokens" => receipt_usage["reasoning_output_tokens"],
            "total_tokens" => receipt_usage["total_tokens"],
            "pricing_snapshot_id" => cost["pricing_snapshot_id"],
            "pricing_status" => cost["pricing_status"],
            "cost_microusd" => cost["total_cost_microusd"],
            "source_ordinal" => [pull_request_row.fetch("source_ordinal"), review_index]
          }
          @ledger.execute(
            <<~SQL,
              INSERT INTO review_receipts (
                github_pr_id, target_unit_id, review_ref, model, effort, pricing_profile,
                input_tokens, cache_read_tokens, cache_write_tokens, output_tokens,
                reasoning_output_tokens, total_tokens,
                pricing_snapshot_id, pricing_status, cost_microusd, source_record_sha256
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            SQL
            receipt_row.except("source_ordinal").values_at(
              "github_pr_id", "target_unit_id", "review_ref", "model", "effort", "pricing_profile",
              "input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens",
              "reasoning_output_tokens", "total_tokens",
              "pricing_snapshot_id", "pricing_status", "cost_microusd"
            ) + [allowlisted_digest(receipt_row)]
          )
          review_receipt_id = @ledger.first(
            "SELECT id FROM review_receipts WHERE github_pr_id = ? AND review_ref = ?",
            [github_pr_id, review_ref]
          ).fetch("id")
          insert_findings(review, review_receipt_id, receipt_row)
        end
      end

      def insert_findings(review, review_receipt_id, receipt_row)
        Array(review["findings"]).each_with_index do |finding, finding_index|
          next unless finding.is_a?(Hash)

          finding_row = {
            "review_receipt_id" => review_receipt_id,
            "finding_ref" => opaque_value(finding["id"]) || "#{review_receipt_id}:#{finding_index}",
            "severity" => enum(finding["severity"], %w[P0 P1 P2 P3]),
            "disposition" => enum(finding["disposition"], REVIEW_DISPOSITIONS),
            "verification_status" => enum(finding["verification_status"], VERIFICATION_STATUSES),
            "source_ordinal" => [receipt_row.fetch("source_ordinal"), finding_index]
          }
          @ledger.execute(
            <<~SQL,
              INSERT INTO review_findings (
                review_receipt_id, finding_ref, severity, disposition,
                verification_status, source_record_sha256
              ) VALUES (?, ?, ?, ?, ?, ?)
            SQL
            finding_row.except("source_ordinal").values_at(
              "review_receipt_id", "finding_ref", "severity", "disposition", "verification_status"
            ) + [allowlisted_digest(finding_row)]
          )
        end
      end

      def recompute_outcomes(batch_id)
        @ledger.rows("SELECT * FROM target_units WHERE batch_id = ?", [batch_id]).each do |unit| # rubocop:disable Metrics/BlockLength
          target_key = unit.values_at("batch_id", "repo", "target")
          statuses = @ledger.rows(
            "SELECT status FROM target_observations WHERE batch_id = ? AND repo = ? AND target = ?",
            target_key
          ).filter_map { |row| STATUS_OUTCOMES[row["status"]] }.uniq
          coordination_statuses, terminal_statuses = coordination_statuses_for(target_key)
          statuses.concat(coordination_statuses)
          statuses.uniq!
          pr_links = @ledger.rows(
            <<~SQL, [unit.fetch("id")]
              SELECT github_prs.state, target_pr_links.link_status
              FROM target_pr_links
              JOIN github_prs ON github_prs.id = target_pr_links.github_pr_id
              WHERE target_pr_links.target_unit_id = ?
            SQL
          )
          pr_states = pr_links.filter_map do |row|
            row.fetch("state") if row.fetch("link_status") == "exact"
          end.uniq
          repo_mismatch = pr_links.any? { |row| row.fetch("link_status") == "repo_mismatch" }
          outcome, evidence_status = outcome_for(statuses, pr_states, terminal_statuses)
          pr_join_status = if pr_states.empty?
                             repo_mismatch ? "repo_mismatch" : unit.fetch("pr_join_status")
                           elsif pr_states.length == 1
                             "exact"
                           else
                             "multiple"
                           end
          @ledger.execute(
            <<~SQL, [outcome, evidence_status, pr_join_status, unit.fetch("id")]
              UPDATE target_units
              SET outcome = ?, outcome_evidence_status = ?, pr_join_status = ?
              WHERE id = ?
            SQL
          )
        end
      end

      def coordination_statuses_for(target_key)
        claims = @ledger.rows(
          "SELECT status, terminal FROM claims WHERE batch_id = ? AND repo = ? AND target = ?", target_key
        )
        terminal_statuses = claims.filter_map { |row| STATUS_OUTCOMES[row["terminal"]] }
        claim_statuses = claims.filter_map { |row| STATUS_OUTCOMES[row["status"]] }
        terminal_statuses.concat(
          @ledger.rows(
            "SELECT terminal FROM events WHERE batch_id = ? AND repo = ? AND target = ?", target_key
          ).filter_map { |row| STATUS_OUTCOMES[row["terminal"]] }
        )
        [claim_statuses + terminal_statuses, terminal_statuses]
      end

      def outcome_for(statuses, pr_states, terminal_statuses)
        terminal = terminal_statuses.uniq
        terminal = ["merged"] if (terminal - %w[done merged]).empty? && terminal.include?("merged")
        return [terminal.first, "exact"] if terminal.one?
        return %w[conflicting-observations conflicting] if terminal.length > 1

        exceptional = statuses & EXCEPTIONAL_OUTCOMES
        return [exceptional.first, "exact"] if exceptional.one?
        return %w[conflicting-observations conflicting] if exceptional.length > 1
        return %w[merged exact] if pr_states.include?("merged")
        return %w[conflicting-observations conflicting] if pr_states.length > 1
        return %w[open-pr exact] if pr_states == ["open"]
        return %w[closed-unmerged exact] if pr_states == ["closed"]

        normalized = statuses.uniq
        normalized = ["merged"] if (normalized - %w[done merged]).empty? && normalized.include?("merged")
        return [normalized.first, "exact"] if normalized.one?
        return [nil, "unknown"] if normalized.empty?

        %w[conflicting-observations conflicting]
      end

      def read_json(path, kind)
        bytes = File.binread(path)
        parsed = JSON.parse(bytes)
        raise Error, "#{kind} JSON must be an object" unless parsed.is_a?(Hash)

        {
          "document" => parsed,
          "source_kind" => kind,
          "source_key" => "#{kind}:#{Digest::SHA256.hexdigest(File.basename(path))[0, 24]}",
          "source_ref" => "#{kind}:#{Digest::SHA256.hexdigest(File.basename(path))[0, 16]}",
          "source_sha256" => Digest::SHA256.hexdigest(bytes)
        }
      rescue JSON::ParserError
        raise Error, "#{kind} JSON is invalid"
      rescue SystemCallError
        raise Error, "#{kind} JSON is unreadable"
      end

      def upsert_artifact(source)
        @ledger.upsert_source_artifact(source.except("document", "bytes"))
      end

      def exact_key(row)
        return unless row["join_status"] == "exact"

        row.values_at("batch_id", "repo", "target")
      end

      def join_status(batch_id, target_repo, target)
        missing = []
        missing << "batch" unless batch_id
        missing << "repo" unless target_repo
        missing << "target" unless target
        missing.empty? ? "exact" : missing.map { |component| "missing_#{component}" }.join(",")
      end

      def allowlisted_digest(row)
        Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
      end

      def opaque_value(value)
        value = known(value)
        value && Digest::SHA256.hexdigest(value)[0, 32]
      end

      def known(value)
        string = value.to_s.strip
        return if string.empty? || string.casecmp?("UNKNOWN")
        return if string.bytesize > 256 || string.match?(/[\u0000-\u001F\u007F]/)

        string
      end

      def repo(value)
        value = known(value)
        value if value&.match?(%r{\A[^/\s]+/[^/\s]+\z})
      end

      def github_url(value)
        value = known(value)
        value if value&.match?(%r{\Ahttps://github\.com/[^/\s]+/[^/\s]+/pull/[1-9][0-9]*\z})
      end

      def enum(value, allowed)
        value = known(value)
        value if allowed.include?(value)
      end

      def positive_integer(value)
        integer = Integer(value, exception: false)
        integer if integer&.positive?
      end

      def nonnegative_integer(value)
        integer = Integer(value, exception: false)
        integer if integer && integer >= 0
      end

      def timestamp_date(value)
        Time.iso8601(value.to_s).utc.to_date
      rescue ArgumentError
        nil
      end

      def timestamp(value)
        Time.iso8601(value.to_s).utc.iso8601
      rescue ArgumentError
        nil
      end
    end

    class CLI
      def self.run(argv, stdout: $stdout, stderr: $stderr) # rubocop:disable Metrics/AbcSize
        command = argv.shift
        return run_scorecard(argv, stdout:) if command == "scorecard"
        raise Error, "usage: agent-coord-harvest harvest|scorecard [options]" unless command == "harvest"

        options = {}
        OptionParser.new do |parser|
          parser.on("--ledger PATH") { |value| options[:ledger] = value }
          parser.on("--coordination-json PATH") { |value| options[:coordination_json] = value }
          parser.on("--github-json PATH") { |value| options[:github_json] = value }
          parser.on("--codex-root PATH") { |value| options[:codex_root] = value }
          parser.on("--claude-root PATH") { |value| options[:claude_root] = value }
          parser.on("--pricing PATH") { |value| options[:pricing] = value }
          parser.on("--batch-id ID") { |value| options[:batch_id] = value }
          parser.on("--from DATE") { |value| options[:from] = value }
          parser.on("--to DATE") { |value| options[:to] = value }
        end.parse!(argv)
        raise Error, "missing required option" if options.values_at(:ledger, :coordination_json).any?(&:nil?)
        raise Error, "unexpected argument" unless argv.empty?

        named = !options[:batch_id].nil?
        ranged = !options[:from].nil? || !options[:to].nil?
        raise Error, "select either --batch-id or --from/--to" if named == ranged
        raise Error, "both --from and --to are required" if ranged && options.values_at(:from, :to).any?(&:nil?)

        harvester = Harvester.new(
          ledger: Ledger.new(options.fetch(:ledger)),
          source_path: options.fetch(:coordination_json),
          github_path: options[:github_json],
          codex_root: options[:codex_root],
          claude_root: options[:claude_root],
          pricing_path: options.fetch(:pricing, Harvester::DEFAULT_PRICING)
        )
        counts = if named
                   harvester.harvest_batch(options.fetch(:batch_id))
                 else
                   harvester.harvest_range(options.fetch(:from), options.fetch(:to))
                 end
        stdout.puts "harvested batches=#{counts.fetch('batches')} targets=#{counts.fetch('targets')} " \
                    "usage=#{counts.fetch('usage')}"
        0
      rescue Error, Ledger::MigrationError, OptionParser::ParseError => e
        stderr.puts "agent-coord-harvest: #{e.message}"
        2
      end

      def self.run_scorecard(argv, stdout:)
        options = {}
        OptionParser.new do |parser|
          parser.on("--ledger PATH") { |value| options[:ledger] = value }
          parser.on("--batch-id ID") { |value| options[:batch_id] = value }
        end.parse!(argv)
        raise Error, "missing required option" if options.values_at(:ledger, :batch_id).any?(&:nil?)
        raise Error, "unexpected argument" unless argv.empty?

        scorecard = Scorecards.new(Ledger.new(options.fetch(:ledger))).batch(options.fetch(:batch_id))
        raise Error, "named batch was not found" unless scorecard

        stdout.puts JSON.generate(scorecard)
        0
      end
    end
  end
end
