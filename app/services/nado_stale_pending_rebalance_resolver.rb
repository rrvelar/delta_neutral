class NadoStalePendingRebalanceResolver
  CONFIRMATION = "I_UNDERSTAND_THIS_ONLY_MARKS_STALE_NADO_PENDING_REBALANCES".freeze
  DEFAULT_STALE_AFTER_HOURS = 24
  RECEIPT_DIR = Rails.root.join("storage/nado_stale_pending_rebalances")

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, nado_venue: nil, now: -> { Time.current }, receipt_dir: RECEIPT_DIR)
    @env = env
    @nado_venue = nado_venue || HedgeVenues::Nado.new(env: env)
    @now = now
    @receipt_dir = Pathname(receipt_dir)
  end

  def report(position:, dry_run: true, confirmation: nil)
    hedge = position.hedge
    candidates = hedge ? pending_rows(hedge).map { |row| candidate_for(row, position: position) } : []
    stale_candidates = candidates.select { |candidate| candidate[:stale_candidate] }
    blockers = []
    blockers << "active hedge is required" unless hedge
    if !dry_run && confirmation.to_s != CONFIRMATION
      blockers << "confirmation must equal #{CONFIRMATION}"
    end

    applied = []
    if !dry_run && blockers.empty?
      stale_candidates.each do |candidate|
        row = ShortRebalance.find(candidate.fetch(:id))
        row.update!(
          status: candidate.fetch(:recommended_status),
          message: stale_message(candidate),
          rebalanced_at: row.rebalanced_at || row.created_at,
          updated_at: now.call
        )
        applied << candidate.merge(after_status: row.status)
      end
    end

    receipt = {
      action: "acknowledge_stale_nado_pending_rebalances",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      hedge_id: hedge&.id,
      dry_run: dry_run,
      stale_after_hours: stale_after_hours.to_s,
      current_nado_short_eth: decimal_string(current_nado_short),
      open_orders_count: open_orders_count,
      inside_tolerance: inside_tolerance?(position),
      newer_success_count: newer_success_count(hedge),
      checked: candidates.size,
      stale_candidates_count: stale_candidates.size,
      blocking_pending_count: candidates.count { |candidate| !candidate[:stale_candidate] },
      ignored_stale_count: ignored_stale_count(hedge),
      candidates: candidates,
      would_update: dry_run ? stale_candidates : [],
      applied: applied,
      recommended_command: "bin/rails nado:acknowledge_stale_pending_rebalances position_id=#{position.id} dry_run=false confirmation=#{CONFIRMATION}",
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      blockers: blockers,
      warnings: []
    }
    write_receipt(receipt) unless dry_run
    status = blockers.any? ? "blocked" : (dry_run ? "dry_run" : "applied")
    Result.new(status, blockers, [], receipt)
  end

  def active_pending?(rebalance, position:)
    candidate = candidate_for(rebalance, position: position)
    !candidate[:stale_candidate]
  end

  private

  attr_reader :env, :nado_venue, :now, :receipt_dir

  def pending_rows(hedge)
    hedge.short_rebalances.where(venue: "nado", status: ShortRebalance::STATUS_PENDING).order(:created_at, :id)
  end

  def candidate_for(rebalance, position:)
    expected = decimal(rebalance.new_short_size)
    current = current_nado_short
    age_hours = ((now.call - (rebalance.created_at || rebalance.rebalanced_at || now.call)) / 1.hour).round(3)
    stale_by_age = age_hours >= stale_after_hours
    current_far = expected && (current - expected).abs > stale_tolerance(position, expected)
    newer_success = newer_success_after?(rebalance)
    safe_state = open_orders_count.to_i.zero? && inside_tolerance?(position)
    stale_candidate = stale_by_age && current_far && newer_success && safe_state
    {
      id: rebalance.id,
      hedge_id: rebalance.hedge_id,
      exchange_order_id: rebalance.exchange_order_id,
      before_status: rebalance.status,
      expected_new_short_size: decimal_string(expected),
      current_nado_short_eth: decimal_string(current),
      age_hours: age_hours,
      stale_by_age: stale_by_age,
      current_far_from_expected: current_far,
      newer_success_exists: newer_success,
      open_orders_count: open_orders_count,
      production_inside_tolerance: inside_tolerance?(position),
      stale_candidate: stale_candidate,
      recommended_status: stale_candidate ? ShortRebalance::STATUS_STALE_SUPERSEDED : ShortRebalance::STATUS_PENDING,
      reason: stale_candidate ? "stale pending superseded by newer success/current safe Nado state" : "pending row still requires reconciliation or operator review"
    }
  end

  def stale_message(candidate)
    "Nado stale pending acknowledged: #{candidate.fetch(:reason)}; expected=#{candidate[:expected_new_short_size]} current=#{candidate[:current_nado_short_eth]} exchange_order_id=#{candidate[:exchange_order_id]}"
  end

  def stale_after_hours
    BigDecimal(env.fetch("NADO_PENDING_REBALANCE_STALE_AFTER_HOURS", DEFAULT_STALE_AFTER_HOURS).to_s)
  rescue ArgumentError
    BigDecimal(DEFAULT_STALE_AFTER_HOURS.to_s)
  end

  def current_nado_short
    return @current_nado_short if defined?(@current_nado_short)

    position = nado_venue.read_position(symbol: "ETH")
    size = decimal(position&.fetch(:short_size, 0))
    @current_nado_short = size
  rescue
    @current_nado_short = BigDecimal("0")
  end

  def open_orders_count
    return @open_orders_count if defined?(@open_orders_count)

    state = nado_venue.account_state
    @open_orders_count = (state[:open_orders_count] || state["open_orders_count"]).to_i
  rescue
    @open_orders_count = nil
  end

  def inside_tolerance?(position)
    snapshot = position.position_dashboard_snapshot
    return true if snapshot&.inside_tolerance == true

    target = decimal(snapshot&.target_short_eth)
    combined = decimal(snapshot&.combined_short_eth)
    tolerance = decimal(snapshot&.tolerance_abs_eth)
    return false unless target.positive? && tolerance.positive?

    (combined - target).abs <= tolerance
  rescue
    false
  end

  def newer_success_after?(rebalance)
    rebalance.hedge.short_rebalances
      .where(venue: "nado", status: ShortRebalance::STATUS_SUCCESS)
      .where("created_at > ?", rebalance.created_at || Time.zone.at(0))
      .exists?
  end

  def newer_success_count(hedge)
    return 0 unless hedge

    hedge.short_rebalances.where(venue: "nado", status: ShortRebalance::STATUS_SUCCESS).count
  end

  def ignored_stale_count(hedge)
    return 0 unless hedge

    hedge.short_rebalances.where(venue: "nado", status: ShortRebalance::STALE_PENDING_STATUSES).count
  end

  def stale_tolerance(position, expected)
    hedge_tolerance = position.hedge&.tolerance
    [ BigDecimal("0.001"), hedge_tolerance ? expected.abs * BigDecimal(hedge_tolerance.to_s) : BigDecimal("0") ].max
  end

  def write_receipt(receipt)
    FileUtils.mkdir_p(receipt_dir)
    path = receipt_dir.join("#{now.call.utc.strftime('%Y%m%d')}.jsonl")
    File.open(path, "a") { |file| file.puts(JSON.generate(receipt.merge(receipt_path: path.to_s))) }
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_string(value)
    value ? BigDecimal(value.to_s).to_s("F") : nil
  rescue ArgumentError, TypeError
    nil
  end
end
