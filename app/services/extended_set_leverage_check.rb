class ExtendedSetLeverageCheck
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_UPDATES_EXTENDED_LEVERAGE".freeze

  def initialize(env: ENV, venue: HedgeVenues::Extended.new(env: env), now: -> { Time.current })
    @env = env
    @venue = venue
    @now = now
  end

  def run(market: nil, leverage: nil, confirmation: nil, dry_run: true)
    market ||= @env["EXTENDED_MARKET_SYMBOL"].presence || "ETH-USD"
    target = BigDecimal((leverage || @env["EXTENDED_REQUIRED_LEVERAGE"].presence || "1").to_s)
    current_position = @venue.read_position(symbol: "ETH")
    account_state = @venue.account_state
    before = @venue.leverage_diagnostics(market: market)
    patch_payload = { market: market, leverage: target.to_s("F") }
    blockers = @venue.live_readiness_blockers

    if dry_run
      return result(
        status: "dry_run",
        blockers: blockers,
        market: market,
        target: target,
        current_position: current_position,
        account_state: account_state,
        before: before,
        patch_payload: patch_payload,
        dry_run: true
      )
    end

    blockers.concat(live_blockers(confirmation: confirmation, current_position: current_position, account_state: account_state))
    if blockers.any?
      return result(
        status: "blocked_before_patch",
        blockers: blockers.uniq,
        market: market,
        target: target,
        current_position: current_position,
        account_state: account_state,
        before: before,
        patch_payload: patch_payload,
        dry_run: false
      )
    end

    patch_response = @venue.update_leverage(market: market, leverage: target)
    after = @venue.leverage_diagnostics(market: market)
    confirmed = leverage_matches?(after[:current_leverage], target)
    result(
      status: confirmed ? "success" : "patch_submitted_but_readback_unconfirmed",
      blockers: [],
      market: market,
      target: target,
      current_position: current_position,
      account_state: account_state,
      before: before,
      after: after,
      patch_payload: patch_payload,
      patch_response: patch_response,
      dry_run: false,
      patch_submitted: true
    )
  end

  private

  def live_blockers(confirmation:, current_position:, account_state:)
    blockers = []
    blockers << "EXTENDED_SET_LEVERAGE_ENABLED must be true" unless bool_env("EXTENDED_SET_LEVERAGE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "Extended set leverage requires no current Extended position" if current_position
    blockers << "Extended set leverage requires open_orders_count=0" unless account_state[:open_orders_count].to_i.zero?
    blockers
  end

  def result(status:, blockers:, market:, target:, current_position:, account_state:, before:, patch_payload:, dry_run:, after: nil, patch_response: nil, patch_submitted: false)
    receipt = {
      venue: "extended",
      action: "set_leverage",
      dry_run: dry_run,
      timestamp: @now.call.utc.iso8601,
      market: market,
      current_position_status: current_position ? "position_present" : "no_position",
      open_orders_count: account_state[:open_orders_count],
      current_leverage: before[:current_leverage],
      target_leverage: target.to_s("F"),
      leverage_read_attempted: before[:leverage_read_attempted],
      patch_endpoint: "PATCH /user/leverage",
      patch_payload: patch_payload,
      patch_response: sanitize_sensitive(patch_response),
      readback_after_patch: after,
      patch_submitted: patch_submitted,
      orders_placed: 0,
      signatures_created: 0,
      final_status: status,
      blockers: blockers.uniq,
      warnings: [ "Extended leverage update is manual-only and does not sign or place orders." ]
    }.compact
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def leverage_matches?(value, target)
    value && (BigDecimal(value.to_s) - target).abs <= BigDecimal("0.000001")
  rescue ArgumentError
    false
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(@env[key])
  end

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = key.to_s.match?(/api[_-]?key|private|authorization|cookie|signature/i) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end
end
