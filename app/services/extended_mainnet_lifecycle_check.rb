class ExtendedMainnetLifecycleCheck
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS".freeze
  MODES = %w[open_only delta_round_trip close_reopen].freeze

  def initialize(env: ENV, venue: HedgeVenues::Extended.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env), now: -> { Time.current })
    @env = env
    @venue = venue
    @signer_client = signer_client
    @now = now
  end

  def run(position:, mode:, size_eth:, confirmation:, dry_run: true, max_slippage: "0.01")
    mode = mode.to_s
    size = capped_size(size_eth)
    current_position = @venue.read_position(symbol: "ETH")
    orders = build_orders(position: position, mode: mode, size_eth: size, current_position: current_position, max_slippage: max_slippage)
    blockers = structural_blockers(mode: mode, orders: orders)

    if dry_run
      return result(
        status: "dry_run",
        blockers: blockers,
        position: position,
        mode: mode,
        dry_run: true,
        current_position: current_position,
        orders: orders
      )
    end

    blockers.concat(live_blockers(confirmation: confirmation))
    result(
      status: "blocked_before_submit",
      blockers: blockers.uniq,
      position: position,
      mode: mode,
      dry_run: false,
      current_position: current_position,
      orders: orders,
      signer_health: @signer_client.health
    )
  end

  private

  def build_orders(position:, mode:, size_eth:, current_position:, max_slippage:)
    case mode
    when "open_only"
      [ @venue.open_short_preview(symbol: "ETH", size_eth: size_eth, max_slippage: max_slippage) ]
    when "delta_round_trip"
      [
        @venue.rebalance_preview(symbol: "ETH", delta_eth: -size_eth, max_slippage: max_slippage),
        @venue.rebalance_preview(symbol: "ETH", delta_eth: size_eth, max_slippage: max_slippage)
      ]
    when "close_reopen"
      [
        @venue.close_preview(symbol: "ETH", size_eth: short_size(current_position)),
        @venue.open_short_preview(symbol: "ETH", size_eth: target_size(position), max_slippage: max_slippage)
      ]
    else
      []
    end
  end

  def structural_blockers(mode:, orders:)
    blockers = []
    blockers << "mode must be one of #{MODES.join(', ')}" unless mode.in?(MODES)
    blockers.concat(@venue.blockers)
    blockers.concat(orders.flat_map { |order| order.fetch(:blockers, []) })
    blockers << "Extended Stark order hash/signature algorithm is not verified; live submit remains disabled."
    blockers.uniq
  end

  def live_blockers(confirmation:)
    blockers = []
    blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" unless bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "EXTENDED_SIGNER_URL is required" if @env["EXTENDED_SIGNER_URL"].blank?
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless @signer_client.supports_extended_order_signing?
    blockers
  end

  def result(status:, blockers:, position:, mode:, dry_run:, current_position:, orders:, signer_health: nil)
    receipt = {
      venue: "extended",
      action: "mainnet_lifecycle_check",
      mode: mode,
      dry_run: dry_run,
      position_id: position.id,
      timestamp: @now.call.utc.iso8601,
      current_position: current_position,
      order_payload_summaries: orders.map { |order| order[:payload] },
      signer_health: sanitize_signer_health(signer_health),
      orders_placed: 0,
      signatures_created: 0,
      submitted: false,
      final_status: status,
      blockers: blockers.uniq,
      warnings: [ "Extended mainnet path is manual-only and fail-closed until Stark signing is verified." ]
    }
    Result.new(status, blockers.uniq, receipt[:warnings], receipt)
  end

  def capped_size(size_eth)
    requested = BigDecimal(size_eth.to_s)
    cap = BigDecimal(@env.fetch("EXTENDED_PROBE_MAX_SIZE_ETH", "0.005").to_s)
    [ requested, cap ].min
  end

  def target_size(position)
    hedge = position.hedge
    valuation = PositionValuation.current(position)
    exposure = valuation.weth_exposure || (position.mellow_weth_exposure if position.respond_to?(:mellow_weth_exposure))
    return BigDecimal("0") unless hedge && exposure

    BigDecimal(exposure.to_s) * BigDecimal(hedge.target.to_s)
  end

  def short_size(position)
    BigDecimal(position&.fetch(:short_size, 0).to_s)
  rescue ArgumentError
    BigDecimal("0")
  end

  def sanitize_signer_health(payload)
    return nil unless payload

    payload.to_h.except(:api_key, :private_key, :signature, "api_key", "private_key", "signature")
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(@env[key])
  end
end
