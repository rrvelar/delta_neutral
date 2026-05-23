# Checks active hedges against current pool sizes and rebalances as needed.
#
# For each asset in a position, the job compares the current Hyperliquid
# short against the target derived from +hedge.target+. If the deviation
# exceeds +hedge.tolerance+, it closes the existing short, opens a new one
# at the target size, records a {ShortRebalance}, and sends a notification
# email via {HedgeRebalanceMailer}.
#
# The two assets in a position are managed independently. When a pool asset
# drops to zero (position fully out of range on that side), the target short
# for that asset is also zero, so the rebalance logic closes the over-hedged
# short automatically. The hedge remains active so the sibling asset's short
# continues to be managed, and the zero asset's short is re-opened if the
# position re-enters range on a future sync.
#
# When two hedges share the same HL asset (e.g. two ETH pools), subaccounts
# provide per-hedge isolation. The main account is used first; subsequent
# hedges for the same asset are allocated to subaccounts.
#
# @example Sync a single hedge
#   HedgeSyncJob.perform_later(hedge.id)
#
# @example Sync all active hedges (used by the recurring scheduler)
#   HedgeSyncJob.perform_later
class HedgeSyncJob < ApplicationJob
  queue_as :default

  # Performs the hedge sync.
  #
  # @param hedge_id [Integer, nil] ID of the hedge to sync, or +nil+ to
  #   sync all active hedges
  # @return [void]
  def perform(hedge_id = nil)
    Rails.logger.debug { "[HedgeSyncJob] starting — hedge_id=#{hedge_id || 'all active'}" }
    hedges = hedge_id ? Hedge.where(id: hedge_id) : Hedge.active
    hyperliquid = nil

    Rails.logger.debug { "[HedgeSyncJob] found #{hedges.count} hedge(s) to sync" }

    hedges.includes(position: :dex).find_each do |hedge|
      if aerodrome_position?(hedge.position)
        if Position.active_hedgeable.count > 1
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — #{Position::MULTIPLE_ACTIVE_HEDGEABLE_MESSAGE}")
          next
        end

        if hedge.nado_execution?
          sync_nado_aerodrome_hedge(hedge)
          next
        end

        if hedge.ethereal_execution?
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — ethereal live rebalance is not implemented")
          next
        end

        unless aerodrome_hedge_enabled?
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — Aerodrome hedge is disabled")
          next
        end

        unless hyperliquid_testnet_enabled? || (hyperliquid_mainnet_enabled? && aerodrome_live_approved?)
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — Aerodrome live hedge requires AERODROME_LIVE_APPROVED=true")
          next
        end

        if aerodrome_hedge_paused?
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — Aerodrome hedge paused by kill switch")
          next
        end

        readiness_errors = aerodrome_readiness_errors(hedge)
        if readiness_errors.any?
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — Aerodrome hedge data incomplete: #{readiness_errors.join(', ')}")
          next
        end

        hedge_assets = aerodrome_hedge_assets(hedge)
        if hedge_assets.empty?
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — no supported Aerodrome ETH/WETH hedge asset")
          next
        end

        safety_errors = aerodrome_safety_errors(hedge, hedge_assets)
        if safety_errors.any?
          Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — Aerodrome hedge safety gate blocked: #{safety_errors.join(', ')}")
          next
        end

        hyperliquid ||= HyperliquidService.new
        sync_aerodrome_hedge(hedge, hedge_assets, hyperliquid)
        next
      end

      hyperliquid ||= HyperliquidService.new
      sync_hedge(hedge, hyperliquid)
    rescue => e
      Rails.logger.error("HedgeSyncJob failed for hedge #{hedge.id}: #{e.message}")
    end

    Rails.logger.debug { "[HedgeSyncJob] complete" }
  end

  private

  # Checks and rebalances both assets for a hedge, if the position is active.
  #
  # @param hedge [Hedge] the hedge to evaluate
  # @param hyperliquid [HyperliquidService] configured Hyperliquid client
  # @return [void]
  def sync_hedge(hedge, hyperliquid)
    Rails.logger.debug { "[HedgeSyncJob] syncing hedge #{hedge.id} (target=#{hedge.target}, tolerance=#{hedge.tolerance})" }
    position = hedge.position
    unless position.active?
      Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — position #{position.id} is inactive")
      return
    end

    Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} position #{position.id} is active, checking assets" }
    check_and_rebalance(hedge, position.asset0, position.asset0_amount, 0, hyperliquid)
    check_and_rebalance(hedge, position.asset1, position.asset1_amount, 1, hyperliquid)
  end

  # Checks and rebalances only the supported ETH/WETH side for Aerodrome.
  #
  # Aerodrome WETH/USDC support is intentionally narrower than the existing
  # Uniswap hedge loop. USDC and other Aerodrome assets are never passed into
  # order logic.
  #
  # @param hedge [Hedge] the hedge to evaluate
  # @param hedge_assets [Array<Hash>] supported Aerodrome assets
  # @param hyperliquid [HyperliquidService] configured Hyperliquid client
  # @return [void]
  def sync_aerodrome_hedge(hedge, hedge_assets, hyperliquid)
    Rails.logger.debug { "[HedgeSyncJob] syncing Aerodrome hedge #{hedge.id} with ETH/WETH-only asset filter" }
    hedge_assets.each do |asset|
      check_and_rebalance(hedge, asset.fetch(:symbol), asset.fetch(:amount), asset.fetch(:index), hyperliquid, asset_price_usd: asset.fetch(:price))
    end
  end

  def sync_nado_aerodrome_hedge(hedge)
    unless nado_auto_rebalance_enabled?
      Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} — AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true")
      return
    end

    readiness_errors = aerodrome_readiness_errors(hedge)
    if readiness_errors.any?
      Rails.logger.warn("HedgeSyncJob: skipping Nado hedge #{hedge.id} — Aerodrome hedge data incomplete: #{readiness_errors.join(', ')}")
      return
    end

    valuation = PositionValuation.current(hedge.position)
    weth_exposure = valuation.weth_exposure
    unless weth_exposure
      Rails.logger.warn("HedgeSyncJob: skipping Nado hedge #{hedge.id} — Mellow WETH pro-rata exposure unavailable")
      return
    end

    target_short = weth_exposure * hedge.target
    price = nado_eth_price(hedge.position, valuation)
    safety_errors = nado_safety_errors(target_short: target_short, price: price)
    if safety_errors.any?
      Rails.logger.warn("HedgeSyncJob: skipping Nado hedge #{hedge.id} — #{safety_errors.join(', ')}")
      record_nado_rebalance(hedge, old_short: BigDecimal("0"), new_short: BigDecimal("0"), status: ShortRebalance::STATUS_FAILED, message: safety_errors.join("; "))
      return
    end

    service = NadoHedgeExecutionService.new
    current_position = service.read_position
    if current_position == :unavailable
      record_nado_rebalance(hedge, old_short: BigDecimal("0"), new_short: BigDecimal("0"), status: ShortRebalance::STATUS_FAILED, message: "Nado readback unavailable")
      return
    end

    current_size = nado_position_size(current_position)
    if current_size.positive?
      record_nado_rebalance(hedge, old_short: BigDecimal("0"), new_short: BigDecimal("0"), status: ShortRebalance::STATUS_FAILED, message: "current Nado position is long; manual action required")
      return
    end

    current_short = current_size.negative? ? current_size.abs : BigDecimal("0")
    delta = target_short - current_short
    tolerance = target_short * hedge.tolerance
    if delta.abs <= tolerance
      Rails.logger.debug { "[HedgeSyncJob] Nado hedge #{hedge.id}: within tolerance, no rebalance needed" }
      return
    end

    preview = service.build_order_preview(position: hedge.position, action: "rebalance", size_eth: delta, max_slippage: nado_max_slippage)
    rounded_size = BigDecimal(preview.dig(:summary, :rounded_size_eth).to_s)
    if rounded_size.zero?
      Rails.logger.warn("HedgeSyncJob: skipping Nado hedge #{hedge.id} — rounded order size is zero")
      return
    end

    result = service.auto_rebalance_short(position: hedge.position, delta_eth: delta, current_position: current_position, max_slippage: nado_max_slippage)
    receipt_path = write_nado_receipt(result.receipt)
    status = result.status.to_s.start_with?("submitted") ? ShortRebalance::STATUS_SUCCESS : ShortRebalance::STATUS_FAILED
    after_short = nado_readback_short(result.receipt[:post_submit_readback], fallback: current_short)
    record_nado_rebalance(
      hedge,
      old_short: current_short,
      new_short: after_short,
      status: status,
      message: result.blockers.presence&.join("; ") || result.receipt[:final_status],
      order_side: result.receipt.dig(:submitted_order_summary, :side),
      reduce_only: result.receipt.dig(:submitted_order_summary, :reduce_only),
      exchange_order_id: result.receipt[:exchange_order_id],
      receipt_path: receipt_path
    )
  end

  # Rebalances the short for a single asset if needed.
  #
  # When +pool_amount+ is zero the target short is also zero, so
  # {Hedge#needs_rebalance?} will return +true+ if any short is currently
  # open (the position is over-hedged on that asset). The short is closed,
  # no new short is opened, and the owner is notified. On subsequent syncs
  # the short stays at zero while the pool amount remains zero. If the asset
  # re-enters range (+pool_amount+ becomes positive again), the deviation
  # from zero triggers a normal rebalance that reopens the short.
  #
  # @param hedge [Hedge] the parent hedge
  # @param asset [String] the asset symbol (e.g. +"ETH"+)
  # @param pool_amount [BigDecimal] current token amount in the liquidity pool
  # @param asset_index [Integer] 0 or 1 — which asset in the pair
  # @param hyperliquid [HyperliquidService] configured Hyperliquid client
  # @return [void]
  def check_and_rebalance(hedge, asset, pool_amount, asset_index, hyperliquid, asset_price_usd: nil)
    hl_asset = HyperliquidService.normalize_symbol(asset)
    account_address = resolve_account(hedge, hl_asset, asset_index, hyperliquid)
    vault_address = account_address # nil for main, subaccount address otherwise

    Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset} (hl: #{hl_asset}): pool_amount=#{pool_amount}, account=#{account_address || 'main'}" }
    current_position = hyperliquid.get_position(hl_asset, address: account_address)
    current_short = current_position ? current_position[:size].abs : BigDecimal("0")
    decimals = hyperliquid.sz_decimals(hl_asset)
    target_short = (pool_amount * hedge.target).floor(decimals)
    delta = target_short - current_short

    Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: current_short=#{current_short}, target_short=#{target_short}, delta=#{delta}" }

    if target_short == current_short
      Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: rounded target equals current short; skipping order" }
      return
    end

    unless hedge.needs_rebalance?(pool_amount, current_short)
      Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: within tolerance, no rebalance needed" }
      return
    end

    if below_aerodrome_min_delta_notional?(delta, target_short, asset_price_usd)
      Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} #{asset} — delta below minimum order notional")
      return
    end

    # Skip if the last 3 rebalances for this asset all failed — avoids
    # polluting history with repeated identical failures (e.g. below $10 min).
    # The streak resets naturally when conditions change enough for one to succeed.
    recent = hedge.short_rebalances.where(asset: asset).where(rebalanced_at: 24.hours.ago..).order(rebalanced_at: :desc).limit(3)
    if !target_short.zero? && recent.size == 3 && recent.all? { |r| r.status == ShortRebalance::STATUS_FAILED }
      Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: skipping — last 3 rebalances all failed" }
      return
    end

    Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: REBALANCE NEEDED" }
    realized_pnl = BigDecimal("0")

    begin
      if delta.negative?
        reduce_size = delta.abs
        Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: reducing short by delta (size=#{reduce_size})" }
        before_close = Time.current
        close_result = hyperliquid.close_short(asset: hl_asset, size: reduce_size, vault_address: vault_address)
        if close_result.nil?
          raise HyperliquidService::OrderError, "Close short for #{hl_asset} returned nil despite reduce_size=#{reduce_size}"
        end

        realized_pnl = fetch_realized_pnl(hyperliquid, hl_asset, before_close, address: account_address)
        Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: realized_pnl=#{realized_pnl}" }
      end

      if delta.positive?
        # Ensure subaccount has sufficient margin before opening
        ensure_subaccount_margin(hyperliquid, account_address, hl_asset, target_short, hedge) if account_address

        setting = hedge.position.user.setting
        leverage = setting&.hyperliquid_leverage || 3
        is_cross = setting&.hyperliquid_cross_margin.nil? ? true : setting.hyperliquid_cross_margin
        Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: setting leverage=#{leverage}, is_cross=#{is_cross}" }
        hyperliquid.set_leverage(asset: hl_asset, leverage: leverage, is_cross: is_cross, vault_address: vault_address)
        Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: increasing short by delta (size=#{delta})" }
        hyperliquid.open_short(asset: hl_asset, size: delta, vault_address: vault_address)
      elsif target_short.zero?
        Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: target is zero, skipping open" }

        # Withdraw USDC back to main when closing to zero on a subaccount
        if account_address
          withdraw_subaccount_balance(hyperliquid, account_address)
          hl_col = asset_index == 0 ? :asset0_hl_account : :asset1_hl_account
          hedge.update!(hl_col => nil)
          Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: cleared subaccount assignment" }
        end
      end

      rebalance = hedge.short_rebalances.create!(
        asset: asset,
        old_short_size: current_short,
        new_short_size: target_short,
        realized_pnl: realized_pnl,
        status: ShortRebalance::STATUS_SUCCESS,
        rebalanced_at: Time.current
      )
      Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id} #{asset}: ShortRebalance ##{rebalance.id} created (#{current_short} → #{target_short}, realized_pnl=#{realized_pnl})" }

      HedgeRebalanceMailer.rebalance_notification(rebalance).deliver_later
    rescue => e
      actual_short = reconciled_short_size(hyperliquid, hl_asset, account_address, fallback: current_short)
      reconciled = ambiguous_order_error?(e) && reconciled_to_target?(hedge, target_short, actual_short)
      status = reconciled ? ShortRebalance::STATUS_SUCCESS : ShortRebalance::STATUS_FAILED
      message = if reconciled
        "Reconciled after ambiguous order error: #{e.message}"
      else
        "Attempted rebalance to #{target_short} #{hl_asset}: #{e.message}"
      end

      rebalance = hedge.short_rebalances.create!(
        asset: asset,
        old_short_size: current_short,
        new_short_size: actual_short,
        realized_pnl: realized_pnl,
        status: status,
        message: message,
        rebalanced_at: Time.current
      )
      Rails.logger.error("[HedgeSyncJob] hedge #{hedge.id} #{asset}: rebalance #{status} after error — ShortRebalance ##{rebalance.id}: #{e.message}")

      raise unless reconciled

      HedgeRebalanceMailer.rebalance_notification(rebalance).deliver_later
    end
  end

  def reconciled_short_size(hyperliquid, hl_asset, account_address, fallback:)
    position = hyperliquid.get_position(hl_asset, address: account_address)
    position ? position[:size].abs : BigDecimal("0")
  rescue => e
    Rails.logger.warn("[HedgeSyncJob] failed to reconcile #{hl_asset} after order error: #{e.message}")
    fallback
  end

  def reconciled_to_target?(hedge, target_short, actual_short)
    return actual_short.zero? if target_short.zero?

    (target_short - actual_short).abs <= (target_short * hedge.tolerance)
  end

  def ambiguous_order_error?(error)
    !error.is_a?(HyperliquidService::OrderError) || error.message.include?("returned nil")
  end

  def below_aerodrome_min_delta_notional?(delta, target_short, asset_price_usd)
    return false unless asset_price_usd
    return false if target_short.zero?

    min_notional = aerodrome_min_order_notional_usd
    return true unless min_notional

    (delta.abs * asset_price_usd) < min_notional
  end

  def aerodrome_min_order_notional_usd
    raw = ENV.fetch("AERODROME_MIN_ORDER_NOTIONAL_USD", "10").presence || "10"
    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  # Resolves which HL account (main or subaccount) to use for this hedge+asset.
  #
  # If an account is already assigned, returns it. Otherwise, checks if the
  # main account is free for this asset, and if not, finds or creates a subaccount.
  #
  # @param hedge [Hedge] the hedge
  # @param hl_asset [String] the HL trading symbol
  # @param asset_index [Integer] 0 or 1
  # @param hyperliquid [HyperliquidService] configured Hyperliquid client
  # @return [String, nil] subaccount address, or +nil+ for main account
  def resolve_account(hedge, hl_asset, asset_index, hyperliquid)
    existing = hedge.hl_account_for(asset_index)
    return existing if existing

    # Main account is free for this asset — use it (leave column nil)
    return nil unless Hedge.asset_account_in_use?(hl_asset, exclude_hedge: hedge)

    # Main is taken — find an available subaccount
    subaccounts = hyperliquid.list_subaccounts
    available = subaccounts.find do |sa|
      addr = sa["subAccountUser"]
      !Hedge.subaccount_in_use_for?(addr, hl_asset)
    end

    address = if available
      available["subAccountUser"]
    else
      result = hyperliquid.create_subaccount(name: "hedge-#{hedge.id}-#{hl_asset.downcase}")
      result["subAccountUser"]
    end

    # Persist the assignment
    hl_col = asset_index == 0 ? :asset0_hl_account : :asset1_hl_account
    hedge.update!(hl_col => address)
    Rails.logger.debug { "[HedgeSyncJob] hedge #{hedge.id}: assigned #{hl_asset} to subaccount #{address}" }
    address
  end

  # Ensures a subaccount has enough margin for the target short.
  #
  # Calculates the required margin with a 20% buffer, checks the existing
  # balance, and only transfers the difference.
  #
  # @param hyperliquid [HyperliquidService]
  # @param account_address [String] the subaccount address
  # @param hl_asset [String] the asset symbol
  # @param target_short [BigDecimal] the target short size
  # @param hedge [Hedge] the parent hedge (for leverage lookup)
  # @return [void]
  def ensure_subaccount_margin(hyperliquid, account_address, hl_asset, target_short, hedge)
    mark_price = hyperliquid.get_position(hl_asset, address: account_address)&.dig(:mark_price)
    mark_price ||= hyperliquid.get_positions.find { |p| p[:asset] == hl_asset }&.dig(:mark_price)
    return unless mark_price && mark_price > 0

    setting = hedge.position.user.setting
    leverage = setting&.hyperliquid_leverage || 3
    margin_needed = (target_short * mark_price / leverage * BigDecimal("1.2")).ceil(2)

    balance = hyperliquid.account_balance(account_address)
    existing = balance[:account_value]
    transfer_amount = margin_needed - existing

    if transfer_amount > 0
      Rails.logger.debug { "[HedgeSyncJob] transferring #{transfer_amount} USDC to subaccount #{account_address} (needed=#{margin_needed}, existing=#{existing})" }
      hyperliquid.transfer_to_subaccount(subaccount_address: account_address, usd: transfer_amount)
    end
  end

  # Withdraws all USDC from a subaccount back to the main account.
  #
  # @param hyperliquid [HyperliquidService]
  # @param account_address [String] the subaccount address
  # @return [void]
  def withdraw_subaccount_balance(hyperliquid, account_address)
    balance = hyperliquid.account_balance(account_address)
    withdrawable = balance[:withdrawable]
    if withdrawable > 0
      Rails.logger.debug { "[HedgeSyncJob] withdrawing #{withdrawable} USDC from subaccount #{account_address}" }
      hyperliquid.withdraw_from_subaccount(subaccount_address: account_address, usd: withdrawable)
    end
  end

  # Fetches the realized P&L for an asset from Hyperliquid fill data.
  #
  # Sums the +closedPnl+ field from fills that match the given asset and
  # occurred after the specified timestamp. Returns zero and logs a warning
  # on error.
  #
  # @param hyperliquid [HyperliquidService] configured Hyperliquid client
  # @param asset [String] the asset symbol to filter fills by
  # @param since [Time] only consider fills at or after this time
  # @param address [String, nil] wallet/subaccount address for fills query
  # @return [BigDecimal] total realized P&L, or +0+ on error
  def fetch_realized_pnl(hyperliquid, asset, since, address: nil)
    fills = hyperliquid.user_fills(start_time: since, address: address)
    fills
      .select { |f| f["coin"] == asset && f["closedPnl"].present? }
      .sum { |f| BigDecimal(f["closedPnl"]) }
  rescue => e
    Rails.logger.warn("Failed to fetch realized PnL from fills for #{asset}: #{e.message}")
    BigDecimal("0")
  end

  def aerodrome_position?(position)
    position.dex.name == "aerodrome_slipstream"
  end

  def aerodrome_hedge_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_HEDGE_ENABLED", "false"))
  end

  def hyperliquid_testnet_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["HYPERLIQUID_TESTNET"]) == true
  end

  def hyperliquid_mainnet_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["HYPERLIQUID_TESTNET"]) == false
  end

  def aerodrome_live_approved?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_LIVE_APPROVED", "false"))
  end

  def aerodrome_hedge_paused?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_HEDGE_PAUSED", "true"))
  end

  def nado_auto_rebalance_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_NADO_AUTO_REBALANCE_ENABLED", "false"))
  end

  def nado_max_slippage
    ENV.fetch("AERODROME_DASHBOARD_HEDGE_MAX_SLIPPAGE", "0.01")
  end

  def nado_position_size(position)
    return BigDecimal("0") unless position && position != :unavailable

    BigDecimal(position.fetch(:size).to_s)
  rescue ArgumentError
    BigDecimal("0")
  end

  def nado_readback_short(readback, fallback:)
    return fallback unless readback.is_a?(Hash)

    size = BigDecimal(readback.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError, KeyError
    fallback
  end

  def nado_eth_price(position, valuation)
    if position.mellow_autopilot? && valuation.weth_exposure&.positive? && valuation.current_value_usd
      usdc = valuation.usdc_exposure || BigDecimal("0")
      return (valuation.current_value_usd - usdc) / valuation.weth_exposure
    end

    position.asset0_price_usd
  end

  def nado_safety_errors(target_short:, price:)
    errors = []
    errors << aerodrome_limit_error("AERODROME_MAX_SHORT_ETH", target_short, "target ETH short")
    errors << aerodrome_limit_error("AERODROME_MAX_SHORT_NOTIONAL_USD", target_short * price, "target ETH notional") if price
    errors.compact
  end

  def record_nado_rebalance(hedge, old_short:, new_short:, status:, message: nil, order_side: nil, reduce_only: nil, exchange_order_id: nil, receipt_path: nil)
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: old_short,
      new_short_size: new_short,
      realized_pnl: BigDecimal("0"),
      status: status,
      message: message,
      rebalanced_at: Time.current,
      venue: "nado",
      order_side: order_side,
      reduce_only: reduce_only,
      exchange_order_id: exchange_order_id,
      receipt_path: receipt_path
    )
  end

  def write_nado_receipt(receipt)
    dir = Rails.root.join("storage", "nado_hedge_rebalances")
    FileUtils.mkdir_p(dir)
    path = dir.join("#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    event = receipt.merge(event: "nado_auto_rebalance", timestamp: Time.current.iso8601, receipt_path: path.to_s)
    File.open(path, "a") { |file| file.puts(JSON.generate(event)) }
    path.to_s
  end

  def aerodrome_readiness_errors(hedge)
    position = hedge.position
    errors = []

    errors << "position inactive" unless position.active?
    errors << "asset0 missing" if position.asset0.blank?
    errors << "asset1 missing" if position.asset1.blank?
    errors << "asset0 amount missing" if position.asset0_amount.nil?
    errors << "asset1 amount missing" if position.asset1_amount.nil?
    errors << "asset0 price missing" if position.asset0_price_usd.nil?
    errors << "asset1 price missing" if position.asset1_price_usd.nil?
    errors << "hedge missing" unless hedge.persisted?
    errors << "Mellow Autopilot pro-rata exposure is not hedge-ready" if position.mellow_autopilot? && !position.hedge_ready?

    errors
  end

  def aerodrome_hedge_assets(hedge)
    position = hedge.position
    [
      { index: 0, symbol: position.asset0, amount: position.asset0_amount, price: position.asset0_price_usd },
      { index: 1, symbol: position.asset1, amount: position.asset1_amount, price: position.asset1_price_usd }
    ].select do |asset|
      supported = aerodrome_supported_hedge_symbol?(asset.fetch(:symbol))
      unless supported
        Rails.logger.warn("HedgeSyncJob: skipping hedge #{hedge.id} #{asset.fetch(:symbol)} — Aerodrome supports ETH/WETH hedge side only")
      end
      supported
    end
  end

  def aerodrome_supported_hedge_symbol?(symbol)
    %w[ETH WETH].include?(symbol.to_s.upcase)
  end

  def aerodrome_safety_errors(hedge, hedge_assets)
    hedge_assets.flat_map { |asset| aerodrome_asset_safety_errors(hedge, asset) }.compact
  end

  def aerodrome_asset_safety_errors(hedge, asset)
    target_short = asset.fetch(:amount) * hedge.target
    price = asset.fetch(:price)
    target_notional = target_short * price
    leverage = hedge.position.user.setting&.hyperliquid_leverage || 3

    [
      aerodrome_limit_error("AERODROME_MAX_SHORT_ETH", target_short, "target ETH short"),
      aerodrome_limit_error("AERODROME_MAX_SHORT_NOTIONAL_USD", target_notional, "target ETH notional"),
      aerodrome_limit_error("AERODROME_MAX_LEVERAGE", BigDecimal(leverage.to_s), "configured leverage")
    ].compact
  end

  def aerodrome_limit_error(env_key, value, label)
    limit = aerodrome_decimal_env(env_key)
    return nil unless limit
    return nil if value <= limit

    "#{label} #{value.to_s('F')} exceeds #{env_key}=#{limit.to_s('F')}"
  end

  def aerodrome_decimal_env(env_key)
    raw = ENV[env_key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    BigDecimal("-1")
  end
end
