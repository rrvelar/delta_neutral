class HedgeVenueMigrationRouteMatrix
  VENUES = %w[extended ethereal nado].freeze
  MODES = %w[full stepwise].freeze
  SEQUENCES = %w[target_first source_first].freeze
  SUPPORTED_PREVIEW_ROUTES = [
    [ "extended", "ethereal" ],
    [ "ethereal", "extended" ]
  ].freeze
  ROUTE_ORDER = [
    [ "extended", "ethereal" ],
    [ "ethereal", "extended" ],
    [ "extended", "nado" ],
    [ "nado", "extended" ],
    [ "ethereal", "nado" ],
    [ "nado", "ethereal" ]
  ].freeze
  PROOF_RECEIPT_DIR = Rails.root.join("storage/hedge_migration_route_proofs")

  def initialize(position:, snapshot: nil, modes: MODES, sequences: SEQUENCES, venues: VENUES, now: -> { Time.current }, receipt_dir: PROOF_RECEIPT_DIR)
    @position = position
    @snapshot = snapshot || position&.position_dashboard_snapshot
    @modes = modes
    @sequences = sequences
    @venues = venues
    @now = now
    @receipt_dir = Pathname(receipt_dir)
  end

  def report
    {
      position_id: position&.id,
      source_snapshot_id: snapshot&.id,
      source_snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      generated_at: now.call.utc.iso8601,
      routes: route_pairs.map { |from, to| route_report(from, to) },
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def prove_routes!
    rows = []
    route_pairs.each do |from, to|
      modes.each do |mode|
        sequences.each do |sequence|
          rows << proof_receipt(from: from, to: to, mode: mode, sequence: sequence)
        end
      end
    end
    paths = rows.map { |row| receipt_writer.write(row) }.compact.map(&:to_s).uniq

    {
      action: "migration_route_proof_summary",
      position_id: position&.id,
      source_snapshot_id: snapshot&.id,
      routes_count: route_pairs.size,
      receipts_written: rows.size,
      receipt_paths: paths,
      routes: report.fetch(:routes),
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :position, :snapshot, :modes, :sequences, :venues, :now, :receipt_dir

  def route_pairs
    ROUTE_ORDER.select { |from, to| venues.include?(from) && venues.include?(to) }
  end

  def route_report(from, to)
    proof = preview_proof(from: from, to: to, mode: "full", sequence: HedgeVenueMigrationPlanner::DEFAULT_SEQUENCE)
    last_proof = last_proof_for(from, to)
    {
      from_venue: from,
      to_venue: to,
      supported: proof.fetch(:supported),
      preview_available: proof.fetch(:preview_available),
      live_available: false,
      readiness_status: proof.fetch(:readiness_status),
      route_status: proof.fetch(:route_status),
      blockers: proof.fetch(:blockers),
      warnings: proof.fetch(:warnings),
      missing_capabilities: proof.fetch(:missing_capabilities),
      required_gates: proof.fetch(:required_gates),
      supported_modes: proof.fetch(:supported_modes),
      supported_sequences: proof.fetch(:supported_sequences),
      last_preview_receipt_path: last_proof&.fetch("receipt_path", nil),
      last_proof_time: last_proof&.fetch("timestamp", nil),
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def proof_receipt(from:, to:, mode:, sequence:)
    proof = preview_proof(from: from, to: to, mode: mode, sequence: sequence)
    receipt = {
      action: "migration_route_proof",
      position_id: position&.id,
      hedge_id: position&.hedge&.id,
      source_snapshot_id: snapshot&.id,
      source_snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      from_venue: from,
      to_venue: to,
      mode: mode,
      migration_sequence: sequence,
      route_status: proof.fetch(:route_status),
      supported: proof.fetch(:supported),
      preview_available: proof.fetch(:preview_available),
      live_available: false,
      blockers: proof.fetch(:blockers),
      warnings: proof.fetch(:warnings),
      missing_capabilities: proof.fetch(:missing_capabilities),
      required_gates: proof.fetch(:required_gates),
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      dry_run: true,
      submitted: false,
      timestamp: now.call.utc.iso8601
    }
    receipt.merge!(proof.fetch(:planned_fields))
    receipt
  end

  def preview_proof(from:, to:, mode:, sequence:)
    return nado_proof(from, to) if [ from, to ].include?("nado")
    return unsupported_proof(from, to) unless SUPPORTED_PREVIEW_ROUTES.include?([ from, to ])

    result = HedgeVenueMigrationPlanner.new(now: now).plan(
      position: position,
      from_venue: from,
      to_venue: to,
      mode: mode,
      step_size_eth: ENV.fetch("MIGRATION_MAX_STEP_SIZE_ETH", "0.01"),
      full_migration_allowed: mode == "full",
      migration_sequence: sequence
    )
    blockers = result.blockers
    {
      supported: true,
      preview_available: true,
      readiness_status: blockers.empty? ? "ready" : "blocked",
      route_status: blockers.empty? ? "READY_FOR_DRY_RUN" : "PREVIEW_BLOCKED",
      blockers: blockers,
      warnings: result.warnings,
      missing_capabilities: [],
      required_gates: result.receipt[:required_gates] || [],
      supported_modes: modes,
      supported_sequences: sequences,
      planned_fields: planned_fields(result.receipt)
    }
  end

  def nado_proof(from, to)
    readiness = NadoMigrationReadiness.new(snapshot: snapshot).report
    missing = [
      "Nado migration readiness service must prove readback/open-orders support.",
      "Nado live migration executor must prove target/source leg sequencing.",
      "Nado close/open readback proof must be recorded before live migration."
    ]
    {
      supported: false,
      preview_available: false,
      readiness_status: readiness.fetch(:status),
      route_status: "NOT_IMPLEMENTED",
      blockers: readiness.fetch(:blockers),
      warnings: readiness.fetch(:warnings),
      missing_capabilities: missing,
      required_gates: required_gates(from, to),
      supported_modes: [],
      supported_sequences: [],
      planned_fields: {}
    }
  end

  def unsupported_proof(from, to)
    blocker = "Migration direction #{HedgeVenues.label(from)} -> #{HedgeVenues.label(to)} is not supported yet."
    {
      supported: false,
      preview_available: false,
      readiness_status: "not_implemented",
      route_status: "NOT_IMPLEMENTED",
      blockers: [ blocker ],
      warnings: [],
      missing_capabilities: [ blocker ],
      required_gates: required_gates(from, to),
      supported_modes: [],
      supported_sequences: [],
      planned_fields: {}
    }
  end

  def planned_fields(receipt)
    receipt.slice(
      :planned_first_leg,
      :planned_second_leg,
      :planned_target_leg,
      :planned_source_leg,
      :expected_final_combined,
      :expected_final_drift,
      :temporary_risk_type,
      :temporary_combined_after_first_leg,
      :temporary_drift_after_first_leg,
      :final_expected_inside_tolerance
    )
  end

  def required_gates(from, to)
    [
      "MIGRATION_LIVE_ENABLED=true for live execution",
      "exact dashboard migration confirmation phrase",
      "#{HedgeVenues.label(from)} live enabled",
      "#{HedgeVenues.label(to)} live enabled",
      "source and target auto disabled during migration",
      "open_orders_count=0 on both venues",
      "fresh PositionDashboardSnapshot",
      "Nado flat unless Nado migration support is explicitly proven"
    ]
  end

  def last_proof_for(from, to)
    proof_events
      .select { |event| event["action"] == "migration_route_proof" && event["from_venue"] == from && event["to_venue"] == to }
      .max_by { |event| event["timestamp"].to_s }
  end

  def proof_events
    @proof_events ||= Dir.glob(receipt_dir.join("*.jsonl")).flat_map do |path|
      File.readlines(path).filter_map { |line| JSON.parse(line) rescue nil }
    end
  rescue SystemCallError
    []
  end

  def receipt_writer
    @receipt_writer ||= HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir)
  end
end
