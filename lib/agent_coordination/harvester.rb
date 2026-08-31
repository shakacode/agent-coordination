# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "optparse"
require "time"

require_relative "argv_encoding"
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
      # Event types `bin/agent-coord` writes, split the way the CLI defines them
      # so drift is mechanical to check (issue #112).
      #
      # Only four are emitted by the CLI itself, as bare `type:` literals at
      # their call sites: the three lifecycle types (from claim, release, and a
      # heartbeat that moves an already-set phase) and `lane_closed` (from the
      # terminal closeout path). The four typed signals are operator-supplied
      # via `record-event --type`; the CLI validates their required fields but
      # never originates them.
      #
      # Note `--type` is an OPEN vocabulary. `AgentCoord.validate_segment!`
      # constrains the character set but applies no allowlist and no length
      # bound, so an arbitrary -- and arbitrarily long -- type can reach ingest.
      # That is why `event_type_raw` has to sanitize rather than reject.
      CLI_LIFECYCLE_EVENT_TYPES = %w[claim.acquired claim.released phase.changed].freeze
      CLI_TERMINAL_EVENT_TYPES = %w[lane_closed].freeze
      CLI_TYPED_EVENT_TYPES = %w[help_requested escalation_requested error human_intervention].freeze
      CLI_EVENT_TYPES = (CLI_LIFECYCLE_EVENT_TYPES + CLI_TERMINAL_EVENT_TYPES + CLI_TYPED_EVENT_TYPES).freeze
      # CLI-emitted types ingest deliberately declines to classify. Empty today.
      # An exclusion must be named here rather than simply omitted, so the
      # source-of-truth drift test still fails on an *unlisted* new CLI type.
      EXCLUDED_CLI_EVENT_TYPES = [].freeze
      # Spellings that only ever appear in the archived 2026-07-18 baseline
      # (docs/archive/reports/2026-07-18-historical-batch-baseline*). No current
      # code path emits them. They are retained because dropping them would
      # reclassify already-harvested rows for no gain, NOT because they make that
      # archive readable: re-harvesting it classifies 210 of 959 events (21.9%),
      # leaving 749 spread over 166 distinct spellings, `handoff` alone
      # accounting for 263. What actually makes those 749 usable is
      # `event_type_raw`, which now records every one of them as a countable
      # drift row instead of an invisible NULL.
      #
      # Deliberately NOT extended to chase those 166 spellings: #112's scope is
      # the types the CLI emits today, and archive vocabulary coverage is a
      # separate, evidence-driven decision tracked on its own issue.
      HISTORICAL_EVENT_TYPES = %w[
        claim release dispatch-replaced replacement worker-replacement
        lane-takeover collision-blocked model-escalation MODEL_ESCALATION_REQUEST
      ].freeze
      EVENT_TYPES = (CLI_EVENT_TYPES - EXCLUDED_CLI_EVENT_TYPES + HISTORICAL_EVENT_TYPES).freeze
      # Mirrors of the CLI's write-time enums: AgentCoord::ERROR_SEVERITIES,
      # AgentCoord::HUMAN_INTERVENTION_KINDS, and
      # AgentCoord::HELP_REQUESTED_REASONS. Mirrored rather than imported so the
      # harvester never loads the CLI at runtime; the drift test pins that these
      # still match their source. `category` has no mirror because it is
      # free-form at write time; it goes through `bounded_signal` instead.
      EVENT_SEVERITIES = %w[P0 P1 P2 P3].freeze
      EVENT_KINDS = %w[takeover supersede manual-fix drain].freeze
      EVENT_REASONS = %w[blocked-user-input question permission].freeze
      # Bind order for the `events` INSERT; `source_record_sha256` is appended
      # separately because it digests the built row rather than reading from it.
      EVENT_COLUMNS = %w[
        event_ref batch_id repo target event_type event_type_raw observed_at terminal
        severity category kind reason join_status source_artifact_id
      ].freeze
      # The ingest boundary's definition of "control character", shared by
      # HostAdapters::Parser and both sanitizers in this file: `bounded_signal`,
      # which strips and digest-marks free-form signal columns, and `known`, which
      # rejects identity and enum columns. They disagree about what to *do* with a
      # control character; they must not disagree about what one *is*. Copies that
      # can silently drift were the bugs in issues #171 and #200.
      #
      # HostAdapters owns the definitions because Harvester loads that parser before
      # defining this class. These aliases preserve Harvester's public constants while
      # making all three sanitizers read the same objects. Do not replace them with
      # byte-equivalent private patterns: structural reuse is the drift prevention.
      #
      # Named for the boundary that owns it, deliberately parallel to
      # `AgentCoord::LOG_CONTROL_CHARACTERS` in bin/agent-coord: that one is the
      # log-rendering boundary's definition, this one is the ledger-ingest boundary's.
      # The prefix used to be SIGNAL_, which was accurate while `bounded_signal` was
      # the only caller and became misleading the moment `known` shared it.
      #
      # Control characters are the one thing that must never survive verbatim: this
      # output is read in a terminal, where an escape sequence recorded inside a value
      # could rewrite the report around it.
      #
      # C0, DEL, and C1. The C1 range matters as much as C0 -- U+009B is CSI, a single
      # character that opens an escape sequence on its own, with no preceding ESC --
      # and this deliberately agrees with the CLI's sanitizer, which covers the same
      # range. This one additionally covers tab/CR/LF, which that one handles
      # separately, because an ingested value is a single-line classifier or
      # identifier and never legitimately contains them.
      #
      # That relationship is containment, not equality, and it is enforced rather than
      # merely asserted here. See
      # test_ingest_control_characters_cover_the_cli_terminal_sanitizer, which
      # compares the two by codepoint: widening the CLI's set without widening this
      # one fails the suite. Harvester behaviour is pinned by
      # test_known_control_range_agrees_with_the_shared_ingest_definition; exact
      # HostAdapters reuse is pinned by the host-session control regression.
      INGEST_CONTROL_CHARACTERS = HostAdapters::INGEST_CONTROL_CHARACTERS
      # Characters trimmed from the ends of an ingested value by
      # HostAdapters::Parser#known, `bounded_signal`, and Harvester#known.
      #
      # The trim runs before control detection, so ANY character that is both
      # trimmable and control gets laundered: it is silently removed, and the value is
      # handled identically to one that never contained it. In `bounded_signal` that
      # means storing with no digest marker. In `known` it is worse -- the value is
      # promoted past a closed allowlist, so `enum("error<NUL>", EVENT_TYPES)`
      # returned the allowlisted "error" (issue #171).
      #
      # `String#strip` overlaps on NUL, VT, and FF; `[[:space:]]` overlaps on NEL
      # (U+0085). Picking another convenient class would just wait for the next
      # overlapping character, so this class is not chosen -- it is derived, as
      # exactly the complement of the CLI's own control definition:
      #
      #   INGEST_SURROUNDING_WHITESPACE == {space} + (INGEST_CONTROL_CHARACTERS -
      #                                               AgentCoord::LOG_CONTROL_CHARACTERS)
      #
      # `LOG_CONTROL_CHARACTERS` deliberately excludes tab, LF, and CR because they
      # are formatting rather than terminal injection; space is not a control
      # character anywhere. So the invariant that kills this bug class is that nothing
      # the CLI considers terminal-unsafe is ever trimmable, which makes NUL, NEL, VT,
      # FF, and the whole C1 range structurally unable to launder: they take the
      # digest-marked control path in `bounded_signal` and the reject path in `known`.
      # Pinned by test_trimmable_characters_never_overlap_the_cli_control_definition.
      #
      # Note the overlap with INGEST_CONTROL_CHARACTERS on exactly tab/LF/CR is
      # intended: trimmed at the ends (layout noise, the T3 decision), treated as
      # control in the interior (content corruption).
      INGEST_SURROUNDING_WHITESPACE = HostAdapters::INGEST_SURROUNDING_WHITESPACE
      SIGNAL_MAX_BYTES = 256
      SIGNAL_DIGEST_LENGTH = 12
      SIGNAL_TRUNCATION_MARKER = "~"
      SIGNAL_PREFIX_BYTES =
        SIGNAL_MAX_BYTES - SIGNAL_DIGEST_LENGTH - SIGNAL_TRUNCATION_MARKER.bytesize
      # The shape a sanitized value ends in. Reserved: an input already wearing
      # it is never returned unchanged, so a stored value ending in this shape is
      # always one the sanitizer produced. Without the reservation an operator
      # could supply the literal sanitized form of some other value -- say the
      # exact string a control-bearing category sanitizes to -- and the two would
      # store identically, collapsing two friction clusters into one.
      #
      # The cost is that a legitimate clean value that happens to end in the
      # marker plus twelve hex characters is also digest-marked. That is rare and
      # harmless, and it is the trade we want: an odd-looking stored value is
      # cheaper than a stored value that cannot be traced back to one input.
      #
      # Derived from the marker and digest-length constants so it cannot drift
      # from what the sanitizer actually emits; pinned by
      # test_sanitized_shape_matches_what_the_sanitizer_emits.
      SIGNAL_SANITIZED_SHAPE =
        /#{Regexp.escape(SIGNAL_TRUNCATION_MARKER)}[0-9a-f]{#{SIGNAL_DIGEST_LENGTH}}\z/
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
          replace_invalid_batch_errors(source.fetch("document"), coordination_artifact_id)
          reconciled_ids = date_range ? reconcile_date_range(coordination_artifact_id, date_range) : []
          refreshed_ids = (reconciled_ids + selected_ids).uniq
          preserved_pr_links = github ? [] : snapshot_target_pr_links(refreshed_ids)
          delete_coordination_rows(refreshed_ids)
          refreshed_ids.each { |batch_id| @ledger.delete_batch(batch_id) }
          observations.concat(insert_coordination_batches(batches, coordination_artifact_id))
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

      def insert_coordination_batches(batches, source_artifact_id)
        batches.flat_map do |batch|
          next insert_batch(batch, source_artifact_id) if known(batch["batch_id"])

          []
        end
      end

      def replace_invalid_batch_errors(document, source_artifact_id)
        clear_ingestion_errors(source_artifact_id, reason: "invalid_record")
        Array(document["batches"]).each_with_index do |batch, index|
          next unless batch.is_a?(Hash) && !known(batch["batch_id"])

          record_ingestion_error(source_artifact_id, index + 1, "invalid_record")
        end
      end

      def clear_ingestion_errors(source_artifact_id, reason: nil)
        sql = "DELETE FROM ingestion_errors WHERE source_artifact_id = ?"
        parameters = [source_artifact_id]
        if reason
          sql += " AND reason = ?"
          parameters << reason
        end
        @ledger.execute(sql, parameters)
      end

      def record_ingestion_error(source_artifact_id, record_ordinal, reason)
        @ledger.execute(
          "INSERT INTO ingestion_errors (source_artifact_id, record_ordinal, reason) VALUES (?, ?, ?)",
          [source_artifact_id, record_ordinal, reason]
        )
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
          clear_ingestion_errors(artifact_id)
          @ledger.execute("DELETE FROM host_sessions WHERE source_artifact_id = ?", [artifact_id])
          parsed = HostAdapters::Parser.new(host_family).parse(
            source.fetch("bytes"), source.fetch("source_ref")
          )
          parsed.fetch("errors").each do |error|
            record_ingestion_error(artifact_id, error.fetch("record_ordinal"), error.fetch("reason"))
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

        row = event_row(event, index, source_artifact_id)
        @ledger.execute(
          <<~SQL,
            INSERT INTO events (
              event_ref, batch_id, repo, target, event_type, event_type_raw, observed_at, terminal,
              severity, category, kind, reason,
              join_status, source_artifact_id, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          row.except("source_ordinal").values_at(*EVENT_COLUMNS) + [allowlisted_digest(row)]
        )
      end

      # `event_type` stays clamped to the closed EVENT_TYPES vocabulary so
      # grouping is safe, while `event_type_raw` retains the raw string for every
      # event that carried one -- sanitized but never dropped, see
      # `bounded_signal`. A type the allowlist rejects is therefore a
      # countable `event_type IS NULL AND event_type_raw IS NOT NULL` row (see
      # the `event_type_drift` view) rather than the silent NULL that produced
      # #112.
      #
      # That view used to have a gap, and this is the method where it lived: the view
      # filters on `event_type IS NULL`, and a control-bearing type whose trimmed
      # form was allowlisted did not have a NULL `event_type`. A NUL-suffixed "error"
      # classified as `error` while its raw column recorded the digest-marked form --
      # the mismatch visible in the row but absent from the view. Closed in issue
      # #171: `known` no longer trims NUL away ahead of the allowlist comparison, so
      # the type is rejected, `event_type` is NULL, and the row is counted. Pinned
      # end to end by test_nul_suffixed_allowlisted_type_is_counted_by_the_drift_view,
      # which asserts through the view rather than through `known`.
      #
      # Sanitizing never hides a classified row: every EVENT_TYPES member
      # is short and control-character free, so a value that needs sanitizing can
      # never also match the allowlist (asserted by the harvester tests).
      def event_row(event, index, source_artifact_id)
        batch_id = known(event["batch_id"])
        event_repo = repo(event["repo"])
        target = known(event["target"])
        {
          "event_ref" => opaque_value(event["id"]) || "record-#{index}",
          "batch_id" => batch_id,
          "repo" => event_repo,
          "target" => target,
          "event_type" => enum(event["type"], EVENT_TYPES),
          # unknown_is_value: this column is the raw type string, so a literal
          # "unknown" -- which the CLI writes for a type-less record -- is a real
          # observation to keep, not an absent value. Contrast `category` below.
          "event_type_raw" => bounded_signal(event["type"], unknown_is_value: true),
          "observed_at" => timestamp(event["at"] || event["timestamp"]),
          "terminal" => enum(event["terminal"], STRUCTURED_STATUSES),
          "join_status" => join_status(batch_id, event_repo, target),
          "source_artifact_id" => source_artifact_id,
          "source_ordinal" => index
        }.merge(event_signal_fields(event))
      end

      # Typed operational-signal attributes (#112, consumed by #143).
      # `severity`, `kind`, and `reason` are closed enums, validated against
      # mirrors of the CLI's own write-time enums. They need no sanitizing:
      # `enum` correctly nils anything outside the set whatever its length, and
      # no member of any of the three is a value `known()` would drop (pinned by
      # test). `category` is free-form at write time and unbounded there, so it
      # goes through `bounded_signal` instead. `from_route`, `to_route`, and `evidence` are
      # deliberately not ingested: `evidence` is free prose that does not belong
      # in a ledger analysis column, and the route strings are unbounded free
      # text duplicating the route/model dimension `host_sessions` already
      # carries -- #143 needs only `escalation_requested` counts, which
      # `event_type` alone provides.
      def event_signal_fields(event)
        {
          "severity" => enum(event["severity"], EVENT_SEVERITIES),
          # Sanitized, not rejected: `--category` is required for `error` events
          # but is bounded nowhere at write time (it is not a path segment, so
          # `validate_segment!` never sees it), and `known()` was silently
          # dropping oversized and control-character values -- destroying the
          # very classifier this column carries. `unknown_is_value: false`
          # because a category is a semantic classifier and this repo reads
          # UNKNOWN as "no value"; contrast `event_type_raw` above.
          "category" => bounded_signal(event["category"], unknown_is_value: false),
          "kind" => enum(event["kind"], EVENT_KINDS),
          "reason" => enum(event["reason"], EVENT_REASONS)
        }
      end

      def ingest_github(source)
        source_artifact_id = upsert_artifact(source)
        clear_ingestion_errors(source_artifact_id, reason: "invalid_record")
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
        unless pr_repo && number && state && url
          record_ingestion_error(source_artifact_id, index + 1, "invalid_record")
          return
        end

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
        bytes.force_encoding(Encoding::UTF_8)
        raise Error, "#{kind} JSON contains invalid UTF-8: #{path}" unless bytes.valid_encoding?

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

      # Shared sanitizer for the free-form signal columns: `event_type_raw` and
      # `category`. Deliberately NOT `known()`. `known()` guards identity fields,
      # where an out-of-bounds value must be rejected outright, so it returns nil
      # for an oversized string, one carrying control characters, and the literal
      # "UNKNOWN". Reusing it for these columns silently dropped exactly the
      # signals they exist to carry -- for `event_type_raw` the row landed with
      # both it and `event_type` NULL and vanished from `event_type_drift`, and
      # for `category` an `error` event lost its required classifier and with it
      # the friction clustering the column was added for. These columns have the
      # opposite requirement: record that a value was present, bounded, rather
      # than reject it.
      #
      # Invariant: NULL if and only if the source carried no usable value --
      # absent, or nothing but whitespace.
      #
      # NUL is deliberately not treated as whitespace. It is a control
      # character, so a NUL-bearing value takes the control path below and is
      # stripped and digest-marked like any other, instead of being quietly
      # trimmed into a value identical to its clean twin. `String#strip` does
      # remove NUL, which is exactly the laundering this avoids, so the trim
      # uses INGEST_SURROUNDING_WHITESPACE rather than `strip`. A value that is
      # nothing but control characters is therefore stored as a bare digest,
      # not NULL -- it carried something, and this column's job is to say so.
      #
      # `unknown_is_value:` is the one deliberate asymmetry between the callers,
      # and it is a difference in the columns' contracts, not an oversight:
      #   - `event_type_raw` passes true. That column's entire purpose is to
      #     capture the raw type string, an absent type is already NULL so there
      #     is no ambiguity, and the CLI itself writes the literal "unknown" for
      #     a type-less event record -- dropping it would hide an ordinary case.
      #   - `category` passes false. It is a semantic classifier, and this repo
      #     treats UNKNOWN as "no value", so it maps to NULL like any other
      #     absent classifier.
      #
      # A value that had to be changed to be stored carries a short digest of the
      # original, so modified values stay visibly modified *and* distinct from
      # one another. A bare "truncated" marker would collapse every oversized
      # value into one identical string and make the drift counts wrong, the same
      # class of failure these columns were added to fix.
      #
      # Scope of that distinctness claim, stated precisely:
      #
      #   - Values are first normalized by trimming surrounding whitespace, so
      #     two inputs differing only there store identically. Deliberate: they
      #     are the same value, and two rows would be worse output.
      #   - No clean value can store as some other value's sanitized form,
      #     because SIGNAL_SANITIZED_SHAPE is reserved -- an input already
      #     wearing that shape is routed through the sanitizer and gets its own
      #     digest. So the two paths' outputs are disjoint by construction, and
      #     a stored value ending in the shape is always sanitizer-produced.
      #   - Two sanitized values can only collide by colliding on a
      #     SIGNAL_DIGEST_LENGTH-character SHA-256 hex prefix. That is a
      #     cryptographic bound, not an exact guarantee -- worth knowing, but a
      #     different and far weaker class than the constructible collisions
      #     above, which are closed outright.
      #
      # CLI-written types cannot contain whitespace or control characters anyway:
      # `AgentCoord.validate_segment!` restricts `--type` to `[A-Za-z0-9_:-]` and
      # dot separators.
      def bounded_signal(value, unknown_is_value:)
        original = value.to_s.gsub(INGEST_SURROUNDING_WHITESPACE, "")
        return if original.empty?
        return if !unknown_is_value && original.casecmp?("UNKNOWN")
        return original if original.bytesize <= SIGNAL_MAX_BYTES &&
                           !original.match?(INGEST_CONTROL_CHARACTERS) &&
                           !original.match?(SIGNAL_SANITIZED_SHAPE)

        prefix = original.gsub(INGEST_CONTROL_CHARACTERS, "")
                         .byteslice(0, SIGNAL_PREFIX_BYTES).to_s.scrub("")
        digest = Digest::SHA256.hexdigest(original)[0, SIGNAL_DIGEST_LENGTH]
        "#{prefix}#{SIGNAL_TRUNCATION_MARKER}#{digest}"
      end

      # Guard for the identity and enum columns written from THIS file: `batch_id`,
      # `repo`, `target`, `lane_id`, `owner_ref`, `session_ref`, `status`,
      # `terminal`, `host_family`, the PR and review-finding fields, and the
      # `event["id"]` input to `opaque_value`.
      #
      # It also guards `model`, `effort`, and `pricing_profile` on review receipts.
      # Host-session copies of those columns are parsed by AgentCoord::HostAdapters,
      # whose `known` now shares the same trim and control definitions.
      #
      # Rejects rather than sanitizes -- the deliberate opposite of
      # `bounded_signal` -- because an out-of-bounds identity value has no useful
      # bounded form. A truncated `batch_id` is not a batch id, it is a different
      # and wrong one, so it must not be stored as though it were the original.
      #
      # Both the trim class and the control class are the shared INGEST_
      # constants rather than private literals, and that is the point: it makes
      # agreement with `bounded_signal` and with the CLI's own definition
      # structural instead of merely test-enforced. `known` previously used
      # `String#strip` and its own C0-and-DEL-only pattern, and both halves were
      # wrong (issue #171):
      #
      #   - `strip` removes NUL, VT, and FF as well as whitespace, and `enum`
      #     calls `known` BEFORE checking set membership. So a trailing control
      #     character was trimmed away and the remainder promoted past a closed
      #     allowlist: `enum("error<NUL>", EVENT_TYPES)` returned "error". The
      #     same character in the interior was rejected, so `known` was not even
      #     self-consistent about it.
      #   - The C0-and-DEL-only range let the entire C1 block through, including
      #     U+009B (CSI), which opens an ANSI escape sequence on its own with no
      #     preceding ESC. `known` was the only one of this repo's three
      #     sanitizers that missed it.
      #
      # What a rejection costs depends on the column, and it is NOT uniform.
      # Three callers treat a nil as a guard rather than merely storing NULL:
      #
      #   - `batch_id`. `harvest_batches` builds `selected_ids` with
      #     `filter_map { known(...) }` and then `next unless batch_id`, so a
      #     rejected batch id skips the batch AND everything under it -- its
      #     lanes, target observations, claims, and events. Those rows never
      #     reach `join_status` at all, which is why `missing_batch` is in
      #     practice unreachable by this path: an event or claim whose own
      #     `batch_id` is rejected is filtered out by `selected_ids.include?`
      #     rather than landing with a partial join.
      #   - `insert_pull_request`, whose `return unless pr_repo && number &&
      #     state && url` drops the `pull_requests` row along with its review
      #     receipts and findings. Note `repo()` and `github_url()` match with
      #     `[^/\s]+`, and `\s` does not cover C1, so a C1-bearing repo segment
      #     or PR URL used to pass those regexes and land in the ledger.
      #   - `insert_lane`, which writes the `lanes` row only `if lane_id`. A
      #     PARTIAL skip rather than a whole subtree: that lane's target
      #     observations still land, carrying a NULL `lane_id`, so the targets
      #     stay visible even though the lane record does not.
      #
      # Everywhere else rejection degrades the row rather than removing it, which
      # is the common case: a rejected `repo` or `target` on an event, claim, or
      # target observation still lands and reports `missing_repo` /
      # `missing_target` instead of `exact`, and a rejected enum lands as SQL
      # NULL -- and for `event_type` that NULL is precisely what makes the row
      # countable in the `event_type_drift` view, which keys on `event_type IS
      # NULL`. The `*_ref` columns degrade further still, falling back to a
      # positional identifier rather than NULL.
      #
      # Stated at this length because "stricter" invites the assumption that
      # nothing is lost, and for two of these columns something is.
      #
      # The 256-byte bound stays a literal rather than borrowing
      # SIGNAL_MAX_BYTES. The magnitudes coincide today, but the operations do
      # not -- `bounded_signal` truncates *to* that size, `known` rejects *above*
      # it -- and tying them would let a future widening of the signal columns
      # silently widen what counts as an acceptable identifier.
      def known(value)
        string = value.to_s.gsub(INGEST_SURROUNDING_WHITESPACE, "")
        return if string.empty? || string.casecmp?("UNKNOWN")
        return if string.bytesize > 256 || string.match?(INGEST_CONTROL_CHARACTERS)

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
      AMBIGUOUS_VALUE_OPTION = Object.new.freeze

      class OptionRegistry
        attr_reader :value_options, :path_options

        def initialize
          @parser = OptionParser.new
          @value_options = []
          @path_options = []
        end

        def on(*declarations, &)
          @parser.on(*declarations, &)
          long_declaration = declarations.find do |declaration|
            declaration.is_a?(String) && declaration.start_with?("--")
          end
          return unless long_declaration

          option_name, argument = long_declaration.split(/\s+/, 2)
          return unless argument

          @value_options << option_name
          # DECLARING A NEW PATH-VALUED OPTION: its placeholder must start with
          # PATH (`--archive-dir PATH`), because this match is on the placeholder
          # spelling, not on a type. `--archive-dir DIR`, `FILE`, `ROOT`, or
          # `[PATH]` is silently NOT exempted and its value is transcoded, which
          # changes which file it names. Nothing fails loudly if you get this
          # wrong, so match the spelling.
          @path_options << option_name if argument.start_with?("PATH")
        end

        def parse!(argv)
          @parser.parse!(argv)
        end
      end

      def self.run(argv, stdout: $stdout, stderr: $stderr)
        argv = normalized_argv(argv)
        command = argv.shift
        return run_scorecard(argv, stdout:) if command == "scorecard"
        raise Error, "usage: agent-coord-harvest harvest|scorecard [options]" unless command == "harvest"

        options = {}
        option_parser(command, options).parse!(argv)
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

      def self.normalized_argv(argv)
        raw = argv.map { |argument| argument.to_s.b }
        registry = option_parser(raw.first.to_s, {})
        ArgvEncoding.normalize_argv(argv, raw_indexes: path_argument_indexes(raw, registry))
      rescue ArgvEncoding::InvalidArgumentError => e
        raise Error, e.message
      end

      def self.path_argument_indexes(raw, registry)
        indexes = []
        awaiting = nil
        raw.each_with_index do |argument, index|
          if awaiting
            indexes << index if awaiting.equal?(AMBIGUOUS_VALUE_OPTION) || registry.path_options.include?(awaiting)
            awaiting = nil
            next
          end

          option_name, inline_value = argument.split("=", 2)
          option = resolve_value_option(option_name, registry.value_options)
          next unless option

          if inline_value
            indexes << index if option.equal?(AMBIGUOUS_VALUE_OPTION) || registry.path_options.include?(option)
          else
            awaiting = option
          end
        end
        indexes
      end

      def self.resolve_value_option(option_name, value_options)
        return unless option_name&.start_with?("--")
        return if option_name == "--"
        return option_name if value_options.include?(option_name)

        matches = value_options.select { |candidate| candidate.start_with?(option_name) }
        return matches.first if matches.one?

        AMBIGUOUS_VALUE_OPTION if matches.length > 1
      end

      def self.option_parser(command, options)
        registry = OptionRegistry.new
        case command
        when "harvest"
          registry.on("--ledger PATH") { |value| options[:ledger] = value }
          registry.on("--coordination-json PATH") { |value| options[:coordination_json] = value }
          registry.on("--github-json PATH") { |value| options[:github_json] = value }
          registry.on("--codex-root PATH") { |value| options[:codex_root] = value }
          registry.on("--claude-root PATH") { |value| options[:claude_root] = value }
          registry.on("--pricing PATH") { |value| options[:pricing] = value }
          registry.on("--batch-id ID") { |value| options[:batch_id] = value }
          registry.on("--from DATE") { |value| options[:from] = value }
          registry.on("--to DATE") { |value| options[:to] = value }
        when "scorecard"
          registry.on("--ledger PATH") { |value| options[:ledger] = value }
          registry.on("--batch-id ID") { |value| options[:batch_id] = value }
        end
        registry
      end

      def self.run_scorecard(argv, stdout:)
        options = {}
        option_parser("scorecard", options).parse!(argv)
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
